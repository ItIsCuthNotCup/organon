import AppKit
import Carbon.HIToolbox
import NotchCore
import ServiceManagement
import SwiftUI
import os

private struct WindowListHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

@MainActor
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        NotchController.shared?.hidePanel()
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let store: WindowStore
    private var panel: NotchPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var host: NSHostingView<PanelView>?
    private let logger = Logger(subsystem: "com.itiscuthnotcup.Notch", category: "perf")
    private var lastHiddenAt: ContinuousClock.Instant?
    var isVisible: Bool { panel?.isVisible ?? false }
    var wasHiddenRecently: Bool {
        guard let lastHiddenAt else { return false }
        return lastHiddenAt.duration(to: .now) < .milliseconds(300)
    }

    init(store: WindowStore) {
        self.store = store
        super.init()
    }

    func show() {
        let started = ContinuousClock.now
        store.panelWillOpen()
        NotchController.shared?.updateStatusIcon()
        let panel = panel ?? createPanel()
        self.panel = panel
        ensureHostedContent(in: panel)
        positionPanel(height: panel.frame.height, panel: panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        installMouseMonitors()
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, let host = self.host else { return }
            host.layoutSubtreeIfNeeded()
            self.positionPanel(height: host.fittingSize.height, panel: panel)
            panel.makeKey()
            self.logger.info("Open-to-first-render completed in \(started.duration(to: .now).formatted())")
        }
    }

    func hide() {
        guard panel?.isVisible == true else { return }
        removeMouseMonitors()
        panel?.orderOut(nil)
        lastHiddenAt = .now
        store.panelDidClose()
        host?.removeFromSuperview()
        host = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func createPanel() -> NotchPanel {
        let panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        panel.contentView = effect
        return panel
    }

    private func ensureHostedContent(in panel: NotchPanel) {
        guard host == nil else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let maxListHeight = screen.map { maximumPanelHeight(for: $0) - 120 } ?? 440
        let rootView = PanelView(store: store, maxListHeight: maxListHeight) { [weak self, weak panel] in
            guard let self, let panel, let host = self.host else { return }
            host.layoutSubtreeIfNeeded()
            self.positionPanel(height: host.fittingSize.height, panel: panel)
        }
        let created = NSHostingView(rootView: rootView)
        created.sizingOptions = [.preferredContentSize]
        created.translatesAutoresizingMaskIntoConstraints = false
        guard let effect = panel.contentView else { return }
        effect.addSubview(created)
        NSLayoutConstraint.activate([
            created.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            created.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            created.topAnchor.constraint(equalTo: effect.topAnchor),
            created.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        host = created
    }

    private func maximumPanelHeight(for screen: NSScreen) -> CGFloat {
        min(560, screen.visibleFrame.height * 0.7)
    }

    private func positionPanel(height proposedHeight: CGFloat, panel: NotchPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let maximum = maximumPanelHeight(for: screen)
        let height = min(maximum, max(210, proposedHeight))
        let width: CGFloat = 380
        let x: CGFloat
        let top: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            x = (left.maxX + right.minX - width) / 2
            top = screen.frame.maxY - screen.safeAreaInsets.top - 4
        } else {
            x = screen.frame.midX - width / 2
            top = screen.visibleFrame.maxY - 4
        }
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
    }

    private func installMouseMonitors() {
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.hide()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if !panel.frame.contains(NSEvent.mouseLocation) {
                self.hide()
            }
            return event
        }
    }

    private func removeMouseMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}

private struct PanelView: View {
    @ObservedObject var store: WindowStore
    let maxListHeight: CGFloat
    let onContentHeightChange: () -> Void
    @FocusState private var searchFocused: Bool
    @State private var selectedWindowID: UInt32?
    @State private var contentHeight: CGFloat = 0

    private var visibleGroups: [NotchCore.WindowGroup] {
        let query = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.groups }
        return store.groups.compactMap { group in
            let matches = group.windows.filter {
                FuzzyMatch.score(query: query, candidate: "\($0.title) \($0.appName)") != nil
            }
            return matches.isEmpty ? nil : NotchCore.WindowGroup(category: group.category, windows: matches)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if !store.accessibilityTrusted {
                HStack(spacing: 8) {
                    Image(systemName: "accessibility")
                        .foregroundStyle(.secondary)
                    Text("Notch needs Accessibility access to switch windows.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Button("Open Settings") { store.requestAccessibility() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            if let suggestion = suggestion, store.configuration.settings.suggestNewGroups {
                suggestionBanner(suggestion)
            }
            if visibleGroups.isEmpty {
                ContentUnavailableView(store.searchText.isEmpty ? "No windows open" : "No matches",
                                       systemImage: store.searchText.isEmpty ? "rectangle.stack" : "magnifyingglass")
                    .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(visibleGroups) { group in
                            groupSection(group)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: WindowListHeightPreferenceKey.self,
                                               value: geometry.size.height)
                    })
                }
                .frame(height: min(contentHeight, maxListHeight))
            }
        }
        .frame(width: 380)
        .background(Color.clear)
        .onPreferenceChange(WindowListHeightPreferenceKey.self) { contentHeight = $0 }
        .onChange(of: contentHeight) { _, _ in onContentHeightChange() }
        .onChange(of: visibleGroups.isEmpty) { _, isEmpty in
            if isEmpty { contentHeight = 0 }
        }
        .onAppear {
            searchFocused = true
            selectedWindowID = visibleGroups.first?.windows.first?.windowID
        }
        .onChange(of: store.focusSearchGeneration) { _, _ in searchFocused = true }
        .onMoveCommand { direction in
            let rows = visibleGroups.flatMap(\.windows)
            guard !rows.isEmpty else { return }
            let index = rows.firstIndex(where: { $0.windowID == selectedWindowID }) ?? 0
            switch direction {
            case .down: selectedWindowID = rows[(index + 1) % rows.count].windowID
            case .up: selectedWindowID = rows[(index - 1 + rows.count) % rows.count].windowID
            default: break
            }
        }
        .onSubmit(of: .search) { focusSelected() }
        .onExitCommand {
            if !store.searchText.isEmpty { store.searchText = "" }
            else { NotchController.shared?.hidePanel() }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search windows", text: $store.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onChange(of: store.searchText) { _, _ in
                    selectedWindowID = visibleGroups.first?.windows.first?.windowID
                }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .padding(10)
    }

    private func groupSection(_ group: NotchCore.WindowGroup) -> some View {
        VStack(spacing: 2) {
            Button {
                store.cycleFocus(in: group.category.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: group.category.symbol).frame(width: 17)
                    Text(group.category.name)
                    Spacer()
                    Text("\(group.windows.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(group.windows) { window in
                windowRow(window, categoryID: group.category.id)
            }
        }
        .dropDestination(for: String.self) { identifiers, _ in
            guard let value = identifiers.first, let id = UInt32(value) else { return false }
            store.move(id, to: group.category.id)
            return true
        }
    }

    private func windowRow(_ window: WindowFeatures, categoryID: CategoryID) -> some View {
        Button {
            store.focus(window)
        } label: {
            HStack(spacing: 9) {
                if let icon = store.icon(for: window) {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "app").frame(width: 18, height: 18).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(window.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.system(size: 13))
                    if window.title != window.appName {
                        Text(window.appName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selectedWindowID == window.windowID ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in if hovering { selectedWindowID = window.windowID } }
        .draggable(String(window.windowID))
        .contextMenu {
            Menu("Move to") {
                ForEach(store.configuration.categories) { category in
                    Button(category.name) { store.move(window.windowID, to: category.id) }
                }
            }
            Menu("Always put \(window.appName) in") {
                ForEach(store.configuration.categories) { category in
                    Button(category.name) { store.addAlwaysRule(for: window, categoryID: category.id) }
                }
            }
        }
    }

    private var suggestion: GroupSuggestion? {
        var assignment: [String: CategoryID] = [:]
        for group in store.groups {
            for window in group.windows {
                if let bundleID = window.bundleID { assignment[bundleID] = group.category.id }
            }
        }
        return GroupSuggester.suggest(store: store.coActivity, currentAssignment: assignment,
                                      dismissed: store.configuration.settings.dismissedSuggestions)
    }

    private func suggestionBanner(_ suggestion: GroupSuggestion) -> some View {
        let names = suggestion.keys.map { key in
            NSRunningApplication.runningApplications(withBundleIdentifier: key).first?.localizedName ?? key
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("You often use \(names.joined(separator: ", ")) together.")
                .font(.system(size: 12))
            HStack {
                Button("Make a group") {
                    store.createSuggestedGroup(keys: suggestion.keys, appNames: names)
                }.buttonStyle(.borderedProminent).controlSize(.small)
                Button("Not now") { store.dismissSuggestion(suggestion.keys) }.controlSize(.small)
                Spacer()
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func focusSelected() {
        guard let selectedWindowID,
              let window = visibleGroups.flatMap(\.windows).first(where: { $0.windowID == selectedWindowID }) else {
            return
        }
        store.focus(window)
    }
}

@MainActor
final class SettingsController {
    private let store: WindowStore
    private var window: NSWindow?

    init(store: WindowStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView(store: store))
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
            created.title = "Notch Settings"
            created.contentView = hosting
            created.isReleasedWhenClosed = false
            window = created
        }
        NSApp.activate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class HotKeyCapture: ObservableObject {
    @Published var isRecording = false
    private let store: WindowStore
    private var monitor: Any?

    init(store: WindowStore) {
        self.store = store
    }

    func start() {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 {
                self.stop()
                return nil
            }
            let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            guard !flags.intersection(modifiers).isEmpty else { return nil }
            var carbon: UInt32 = 0
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            self.stop()
            self.store.updateSettings { $0.hotKey = HotKeySpec(keyCode: UInt32(event.keyCode), carbonModifiers: carbon) }
            NotchController.shared?.updateTriggers()
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

private struct SettingsView: View {
    private let store: WindowStore
    @StateObject private var keyCapture: HotKeyCapture
    @State private var newCategoryName = ""
    @State private var selectedCategoryID: CategoryID? = CategoryID.communication
    @State private var categoryName = ""
    @State private var categorySymbol = "square.grid.2x2"
    @State private var ruleText = ""
    @State private var ruleKind = "bundle"
    @State private var launchAtLogin = false
    @State private var launchStatus = ""
    @State private var runningApps: [RunningAppChoice] = []

    init(store: WindowStore) {
        self.store = store
        _keyCapture = StateObject(wrappedValue: HotKeyCapture(store: store))
    }

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            categoriesTab.tabItem { Label("Categories", systemImage: "square.grid.2x2") }
            correctionsTab.tabItem { Label("Corrections", systemImage: "arrow.uturn.backward") }
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 420)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            runningApps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in
                    guard let bundleID = app.bundleIdentifier else { return nil }
                    return RunningAppChoice(id: bundleID, name: app.localizedName ?? bundleID)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if let category = store.configuration.categories.first(where: { $0.id == selectedCategoryID }) {
                categoryName = category.name
                categorySymbol = category.symbol
            }
        }
    }

    private var generalTab: some View {
        Form {
            HStack {
                Text("Show windows")
                Spacer()
                Button(keyCapture.isRecording ? "Press a shortcut…" : shortcutName) {
                    keyCapture.start()
                }
                .disabled(keyCapture.isRecording)
                if keyCapture.isRecording {
                    Button("Cancel") { keyCapture.stop() }
                }
            }
            Toggle("Open when hovering over the notch", isOn: Binding(
                get: { store.configuration.settings.openOnNotchHover },
                set: { value in store.updateSettings { $0.openOnNotchHover = value }; NotchController.shared?.updateTriggers() }
            ))
            Toggle("Suggest new groups", isOn: Binding(
                get: { store.configuration.settings.suggestNewGroups },
                set: { value in store.updateSettings { $0.suggestNewGroups = value } }
            ))
            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { value in
                do {
                    if value { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                    launchStatus = SMAppService.mainApp.status == .requiresApproval
                        ? "Approval is required in System Settings." : ""
                } catch {
                    launchStatus = error.localizedDescription
                }
            }))
            if !launchStatus.isEmpty {
                Text(launchStatus).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Accessibility")
                Spacer()
                Text(store.accessibilityTrusted ? "Allowed" : "Not allowed").foregroundStyle(.secondary)
                Button("Open Settings") { store.requestAccessibility() }
            }
        }
        .formStyle(.grouped)
    }

    private var categoriesTab: some View {
        HStack(spacing: 12) {
            VStack(spacing: 8) {
                List(store.configuration.categories) { category in
                    Button {
                        selectedCategoryID = category.id
                        categoryName = category.name
                        categorySymbol = category.symbol
                    } label: {
                        Label(category.name, systemImage: category.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .background(selectedCategoryID == category.id ? Color.accentColor.opacity(0.12) : .clear)
                }
                HStack {
                    TextField("New category", text: $newCategoryName)
                    Button {
                        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        let id = CategoryID(rawValue: name.lowercased().replacingOccurrences(of: " ", with: "-"))
                        store.updateCategory(NotchCore.Category(id: id, name: name, symbol: "square.grid.2x2"))
                        selectedCategoryID = id
                        categoryName = name
                        categorySymbol = "square.grid.2x2"
                        newCategoryName = ""
                    } label: { Image(systemName: "plus") }
                    .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(width: 190)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                if let category = store.configuration.categories.first(where: { $0.id == selectedCategoryID }) {
                    HStack {
                        TextField("Category name", text: $categoryName)
                        Picker("Symbol", selection: $categorySymbol) {
                            ForEach(["square.grid.2x2", "bubble.left.and.bubble.right", "chevron.left.forwardslash.chevron.right",
                                     "globe", "play.rectangle", "book", "gearshape", "star", "heart", "briefcase",
                                     "graduationcap", "music.note"], id: \.self) { symbol in
                                Label(symbol, systemImage: symbol).tag(symbol)
                            }
                        }
                        .labelsHidden()
                    }
                    HStack {
                        Button("Save category") {
                            store.updateCategory(NotchCore.Category(id: category.id, name: categoryName, symbol: categorySymbol,
                                                                    isBuiltIn: category.isBuiltIn))
                        }
                        if !category.isBuiltIn {
                            Button("Delete") { store.deleteCategory(category.id) }
                                .foregroundStyle(.red)
                        }
                    }
                    Divider()
                    Text("Rules").font(.headline)
                    List(store.configuration.rules.filter { $0.categoryID == category.id }) { rule in
                        HStack {
                            Text(ruleDescription(rule)).lineLimit(1)
                            Spacer()
                            Button(role: .destructive) { store.removeRule(rule.id) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Picker("Rule type", selection: $ruleKind) {
                            Text("App bundle").tag("bundle")
                            Text("Browser title").tag("keyword")
                        }
                        .frame(width: 135)
                        if ruleKind == "bundle", !runningApps.isEmpty {
                            Picker("Running app", selection: $ruleText) {
                                Text("Choose app…").tag("")
                                ForEach(runningApps) { app in
                                    Text(app.name).tag(app.id)
                                }
                            }
                        } else {
                            TextField(ruleKind == "bundle" ? "Bundle ID" : "Title keyword", text: $ruleText)
                        }
                        Button("Add") {
                            let value = ruleText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty else { return }
                            let kind: Rule.Kind
                            if ruleKind == "bundle" {
                                kind = .bundleID(value)
                            } else {
                                let browserIDs = DefaultRules.rules.compactMap { rule -> String? in
                                    guard rule.categoryID == .browser, case let .bundleID(id) = rule.kind else { return nil }
                                    return id
                                }
                                kind = .titleKeyword(value, scopedToBundleIDs: browserIDs)
                            }
                            store.addRule(Rule(categoryID: category.id, kind: kind))
                            ruleText = ""
                        }
                        .disabled(ruleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Button("Restore default rules") { store.restoreDefaultRules() }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var correctionsTab: some View {
        List {
            ForEach(store.configuration.corrections) { correction in
                HStack {
                    VStack(alignment: .leading) {
                        Text(correction.title).lineLimit(1)
                        Text("\(correction.appName) → \(store.configuration.categories.first(where: { $0.id == correction.categoryID })?.name ?? correction.categoryID.rawValue)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget") { store.forgetCorrection(correction.id) }
                }
            }
        }
    }

    private var shortcutName: String {
        KeyNames.shortcutName(for: store.configuration.settings.hotKey)
    }

    private func ruleDescription(_ rule: Rule) -> String {
        switch rule.kind {
        case let .bundleID(identifier):
            return runningApps.first(where: { $0.id == identifier })?.name ?? identifier
        case let .titleKeyword(keyword, scope):
            return scope == nil ? keyword : "\(keyword) · browsers only"
        }
    }
}

private struct RunningAppChoice: Identifiable {
    var id: String
    var name: String
}

@MainActor
final class OnboardingController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var allowed = AXIsProcessTrusted()
    private let store: WindowStore
    private var window: NSWindow?
    private var trustTimer: Timer?
    private let statusLabel = NSTextField(wrappingLabelWithString: "Notch organizes your windows")

    init(store: WindowStore) { self.store = store }

    func show() {
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        created.title = "Welcome to Notch"
        let icon = NSImageView(image: NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Notch") ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 34).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let explanation = NSTextField(wrappingLabelWithString:
            "To switch to a window when you click it, Notch needs Accessibility access. macOS will ask you to allow it in System Settings. Notch only reads window titles and brings windows forward — it never moves them and nothing leaves your Mac.")
        explanation.font = .systemFont(ofSize: 13)
        explanation.textColor = .secondaryLabelColor
        explanation.alignment = .center
        statusLabel.stringValue = allowed ? shortcutInstruction : "Notch organizes your windows"
        statusLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        statusLabel.alignment = .center
        let allowButton = NSButton(title: "Allow Access…", target: self, action: #selector(allowAccessibility))
        allowButton.bezelStyle = .rounded
        allowButton.keyEquivalent = "\r"
        let laterButton = NSButton(title: "Not now", target: self, action: #selector(dismissOnboarding))
        laterButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [allowButton, laterButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        let stack = NSStackView(views: [icon, statusLabel, explanation, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16)
        ])
        created.contentView = content
        created.isReleasedWhenClosed = false
        created.delegate = self
        created.center()
        NSApp.activate()
        created.makeKeyAndOrderFront(nil)
        window = created
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.allowed = AXIsProcessTrusted()
                self.statusLabel.stringValue = self.allowed
                    ? self.shortcutInstruction
                    : "Notch organizes your windows"
                if self.allowed { self.store.completeOnboarding() }
            }
        }
    }

    private var shortcutInstruction: String {
        "You're all set — press \(KeyNames.shortcutName(for: store.configuration.settings.hotKey)) or hover over the notch"
    }

    @objc private func allowAccessibility() {
        store.requestAccessibility()
    }

    @objc private func dismissOnboarding() {
        store.completeOnboarding()
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        trustTimer?.invalidate()
        trustTimer = nil
        store.completeOnboarding()
    }
}
