import AppKit
import NotchCore
import Foundation

@main
struct NotchMain {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--measure") {
            await NotchMeasurement.run()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        controller?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.store.coActivity.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        controller?.togglePanel()
        return true
    }
}
