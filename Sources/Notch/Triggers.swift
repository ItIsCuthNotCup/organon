import AppKit
import Carbon.HIToolbox
import Foundation
import NotchCore

@MainActor
final class HotKeyManager {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(spec: HotKeySpec) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), notchHotKeyCallback, 1, &eventType, nil, &handler)
        register(spec)
    }

    func register(_ spec: HotKeySpec) {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        let identifier = EventHotKeyID(signature: OSType(0x4E544348), id: 1)
        RegisterEventHotKey(spec.keyCode, spec.carbonModifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
    }

}

private let notchHotKeyCallback: EventHandlerProcPtr = { _, _, _ in
    Task { @MainActor in
        NotificationCenter.default.post(name: .notchTogglePanel, object: nil)
    }
    return noErr
}

@MainActor
private final class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class HoverView: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    private var dwellTask: Task<Void, Never>?
    private var generation = 0

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        generation += 1
        let current = generation
        dwellTask?.cancel()
        dwellTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, current == generation else { return }
            onHover?()
        }
    }

    override func mouseExited(with event: NSEvent) {
        generation += 1
        dwellTask?.cancel()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

@MainActor
final class NotchHoverTrigger {
    private let onTrigger: () -> Void
    private var panel: HoverPanel?
    private var screenObserver: NSObjectProtocol?

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
    }

    func rebuild() {
        hide()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let rect: NSRect
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            rect = NSRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                          width: right.minX - left.maxX, height: max(screen.safeAreaInsets.top, 24))
        } else {
            rect = NSRect(x: screen.frame.midX - 100, y: screen.frame.maxY - 24, width: 200, height: 24)
        }
        let created = HoverPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        created.level = .statusBar
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = false
        let hoverView = HoverView(frame: NSRect(origin: .zero, size: rect.size))
        hoverView.onHover = onTrigger
        hoverView.onClick = onTrigger
        created.contentView = hoverView
        created.orderFrontRegardless()
        panel = created
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

}
