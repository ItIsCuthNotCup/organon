import AppKit
import ApplicationServices
import Combine
import Foundation
import NotchCore
import os

extension Notification.Name {
    static let notchTogglePanel = Notification.Name("Notch.TogglePanel")
}

enum PanelKeyCommand: Sendable {
    case up
    case down
    case submit
}

@MainActor
final class WindowStore: ObservableObject {
    @Published private(set) var groups: [NotchCore.WindowGroup] = []
    @Published var searchText = ""
    @Published private(set) var focusSearchGeneration = 0
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var configuration: NotchConfiguration
    let panelKeyCommands = PassthroughSubject<PanelKeyCommand, Never>()
    let coActivity: CoActivityStore
    let icons = IconCache()
    private let configStore: ConfigStore
    private var sessionOverrides: [UInt32: CategoryID] = [:]
    private var focusIndices: [CategoryID: Int] = [:]
    private var refreshTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: "com.itiscuthnotcup.Notch", category: "perf")
    private var visible = false
    private var pipeline: ClassificationPipeline

    init(configStore: ConfigStore = ConfigStore()) {
        self.configStore = configStore
        let loaded = (try? configStore.load()) ?? NotchConfiguration()
        configuration = loaded
        coActivity = CoActivityStore(directory: configStore.directory)
        pipeline = .defaults(corrections: loaded.corrections, rules: loaded.rules, store: coActivity,
                             categories: loaded.categories)
        observeWorkspace()
    }

    func panelWillOpen() {
        visible = true
        refreshAccessibilityState()
        focusSearchGeneration += 1
        refresh()
    }

    func refreshAccessibilityState() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    func panelDidClose() {
        visible = false
        debounceTask?.cancel()
    }

    func refresh() {
        refreshTask?.cancel()
        let started = ContinuousClock.now
        refreshTask = Task {
            let enumerated = await Task.detached(priority: .userInitiated) {
                WindowEnumerator.enumerate()
            }.value
            guard !Task.isCancelled else { return }
            let features = enumerated.map(\.features)
            let fresh = await pipeline.groups(features, sessionOverrides: sessionOverrides)
            guard !Task.isCancelled else { return }
            groups = fresh
            logger.info("Window refresh completed in \(started.duration(to: .now).formatted())")
        }
    }

    func move(_ windowID: UInt32, to categoryID: CategoryID) {
        guard let window = groups.flatMap(\.windows).first(where: { $0.windowID == windowID }) else { return }
        sessionOverrides[windowID] = categoryID
        let correction = Correction(bundleID: window.bundleID, appName: window.appName, title: window.title,
                                    categoryID: categoryID)
        do {
            try configStore.addCorrection(correction, to: &configuration)
            rebuildPipeline()
            refreshFromCurrentWindows()
        } catch {
            logger.error("Could not save correction: \(error.localizedDescription, privacy: .public)")
        }
    }

    func addAlwaysRule(for window: WindowFeatures, categoryID: CategoryID) {
        guard let bundleID = window.bundleID else { return }
        configuration.rules.removeAll {
            if case let .bundleID(existing) = $0.kind { return existing == bundleID }
            return false
        }
        configuration.rules.insert(Rule(categoryID: categoryID, kind: .bundleID(bundleID)), at: 0)
        persistConfiguration()
        rebuildPipeline()
        refresh()
    }

    func focus(_ window: WindowFeatures) {
        _ = WindowFocuser.focus(window)
        NotchController.shared?.hidePanel()
    }

    func cycleFocus(in categoryID: CategoryID) {
        guard let group = groups.first(where: { $0.category.id == categoryID }), !group.windows.isEmpty else { return }
        let next = focusIndices[categoryID, default: -1] + 1
        focusIndices[categoryID] = next % group.windows.count
        focus(group.windows[focusIndices[categoryID, default: 0]])
    }

    func icon(for window: WindowFeatures) -> NSImage? { icons.icon(for: window) }

    func updateSettings(_ update: (inout Settings) -> Void) {
        update(&configuration.settings)
        persistConfiguration()
    }

    func updateCategory(_ category: NotchCore.Category) {
        let exists = configuration.categories.contains(where: { $0.id == category.id })
        if let index = configuration.categories.firstIndex(where: { $0.id == category.id }) {
            configuration.categories[index] = category
        } else {
            configuration.categories.insert(category, at: max(0, configuration.categories.count - 1))
        }
        persistConfiguration()
        rebuildPipeline()
        if exists { refreshFromCurrentWindows() } else { refresh() }
    }

    func addRule(_ rule: Rule) {
        configuration.rules.insert(rule, at: 0)
        persistConfiguration()
        rebuildPipeline()
        refresh()
    }

    func removeRule(_ id: UUID) {
        configuration.rules.removeAll { $0.id == id }
        persistConfiguration()
        rebuildPipeline()
        refresh()
    }

    func deleteCategory(_ id: CategoryID) {
        do {
            try configStore.removeCategory(id, from: &configuration)
            rebuildPipeline()
            refresh()
        } catch {
            logger.error("Could not remove category: \(error.localizedDescription, privacy: .public)")
        }
    }

    func forgetCorrection(_ id: String) {
        configuration.corrections.removeAll { $0.id == id }
        persistConfiguration()
        rebuildPipeline()
        refresh()
    }

    func dismissSuggestion(_ keys: [String]) {
        configuration.settings.dismissedSuggestions.append(keys.sorted())
        persistConfiguration()
    }

    func createSuggestedGroup(keys: [String], appNames: [String]) {
        let name = appNames.joined(separator: " + ")
        let category = NotchCore.Category(id: CategoryID(rawValue: "group-\(UUID().uuidString.lowercased())"),
                                          name: name, symbol: "square.stack.3d.up")
        configuration.categories.insert(category, at: max(0, configuration.categories.count - 1))
        for key in keys {
            configuration.rules.insert(Rule(categoryID: category.id, kind: .bundleID(key)), at: 0)
        }
        persistConfiguration()
        rebuildPipeline()
        refresh()
    }

    func restoreDefaultRules() {
        do {
            try configStore.restoreDefaultRules(in: &configuration)
            rebuildPipeline()
            refresh()
        } catch {
            logger.error("Could not restore default rules: \(error.localizedDescription, privacy: .public)")
        }
    }

    func completeOnboarding() {
        configuration.hasCompletedOnboarding = true
        persistConfiguration()
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func rebuildPipeline() {
        pipeline = .defaults(corrections: configuration.corrections, rules: configuration.rules, store: coActivity,
                             categories: configuration.categories)
    }

    private func persistConfiguration() {
        do {
            try configStore.save(configuration)
        } catch {
            logger.error("Could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshFromCurrentWindows() {
        let features = groups.flatMap(\.windows)
        Task {
            groups = await pipeline.groups(features, sessionOverrides: sessionOverrides)
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let activatedBundleID = name == NSWorkspace.didActivateApplicationNotification
                    ? (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                    : nil
                Task { @MainActor in
                    if let bundleID = activatedBundleID {
                        self.coActivity.record(key: bundleID)
                    }
                    guard self.visible else { return }
                    self.debounceTask?.cancel()
                    self.debounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        self.refresh()
                    }
                }
            })
        }
    }

}

@MainActor
final class NotchController: NSObject {
    static weak var shared: NotchController?
    let store = WindowStore()
    private var panelController: PanelController!
    private var statusItem: NSStatusItem!
    private var statusButton: NSStatusBarButton?
    private var hotKeyManager: HotKeyManager!
    private var hoverTrigger: NotchHoverTrigger!
    private var settingsController: SettingsController!
    private var onboardingController: OnboardingController?
    private var toggleObserver: NSObjectProtocol?

    override init() {
        super.init()
        Self.shared = self
    }

    func start() {
        panelController = PanelController(store: store)
        settingsController = SettingsController(store: store)
        hotKeyManager = HotKeyManager(spec: store.configuration.settings.hotKey)
        hoverTrigger = NotchHoverTrigger { [weak self] in self?.togglePanel() }
        setupStatusItem()
        toggleObserver = NotificationCenter.default.addObserver(forName: .notchTogglePanel, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor in self?.togglePanel() }
        }
        if store.configuration.settings.openOnNotchHover { hoverTrigger.rebuild() }
        if !store.configuration.hasCompletedOnboarding {
            onboardingController = OnboardingController(store: store)
            onboardingController?.show()
        }
    }

    func togglePanel() {
        if panelController.isVisible {
            panelController.hide()
        } else if !panelController.wasHiddenRecently {
            panelController.show()
        }
    }

    func hidePanel() { panelController.hide() }

    func showSettings() {
        settingsController.show()
    }

    func updateTriggers() {
        hotKeyManager.register(store.configuration.settings.hotKey)
        if store.configuration.settings.openOnNotchHover { hoverTrigger.rebuild() }
        else { hoverTrigger.hide() }
    }

    func updateStatusIcon() {
        let base = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Notch")
        let symbol = store.accessibilityTrusted ? nil :
            NSImage(systemSymbolName: "rectangle.3.group.badge.exclamationmark", accessibilityDescription: "Accessibility needed")
        if let symbol {
            statusButton?.image = symbol
        } else if store.accessibilityTrusted {
            statusButton?.image = base
        } else if let base {
            let marked = NSImage(size: base.size)
            marked.lockFocus()
            base.draw(in: NSRect(origin: .zero, size: base.size))
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: base.size.width - 5, y: 1, width: 4, height: 4)).fill()
            marked.unlockFocus()
            statusButton?.image = marked
        }
        statusButton?.image?.isTemplate = true
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        statusButton = button
        updateStatusIcon()
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
            let menu = NSMenu()
            let shortcut = KeyNames.shortcutName(for: store.configuration.settings.hotKey)
            menu.addItem(withTitle: "Show Windows  \(shortcut)", action: #selector(toggleFromMenu), keyEquivalent: "")
            menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Notch", action: #selector(quitFromMenu), keyEquivalent: "q")
            for item in menu.items { item.target = self }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
        } else {
            togglePanel()
        }
    }

    @objc private func toggleFromMenu() { togglePanel() }
    @objc private func openSettingsFromMenu() { showSettings() }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }
}
