import AppKit
import ApplicationServices
import CoreGraphics
import Dispatch
import Foundation
import NotchCore

private final class WindowTitleResults: @unchecked Sendable {
    private let lock = NSLock()
    private var titles: [UInt32: String] = [:]

    func merge(_ values: [UInt32: String]) {
        lock.lock()
        defer { lock.unlock() }
        titles.merge(values) { _, latest in latest }
    }

    func snapshot() -> [UInt32: String] {
        lock.lock()
        defer { lock.unlock() }
        return titles
    }
}

struct WindowInfo: Sendable {
    var features: WindowFeatures
    var bounds: CGRect
}

enum WindowEnumerator {
    nonisolated static func enumerate() -> [WindowInfo] {
        let excluded = Set(["Window Server", "Dock", "Control Center", "Notification Center", "Spotlight"])
        guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        var windows: [WindowInfo] = []
        for record in records {
            guard (record[kCGWindowLayer as String] as? Int ?? -1) == 0,
                  (record[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let width = record[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: width as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40,
                  let pidValue = record[kCGWindowOwnerPID as String] as? Int32,
                  pidValue != ProcessInfo.processInfo.processIdentifier,
                  let owner = record[kCGWindowOwnerName as String] as? String,
                  !excluded.contains(owner),
                  let id = record[kCGWindowNumber as String] as? UInt32 else { continue }
            let runningApp = NSRunningApplication(processIdentifier: pid_t(pidValue))
            let title = record[kCGWindowName as String] as? String ?? ""
            let features = WindowFeatures(
                windowID: id,
                pid: pidValue,
                bundleID: runningApp?.bundleIdentifier,
                appName: runningApp?.localizedName ?? owner,
                title: title.isEmpty ? (runningApp?.localizedName ?? owner) : title
            )
            windows.append(WindowInfo(features: features, bounds: bounds))
        }
        guard AXIsProcessTrusted() else { return windows }
        let byPID = Dictionary(grouping: windows, by: { $0.features.pid })
        let pids = Array(byPID.keys)
        let titleResults = WindowTitleResults()
        DispatchQueue.concurrentPerform(iterations: pids.count) { index in
            let pid = pids[index]
            guard let appWindows = byPID[pid] else { return }
            let application = AXUIElementCreateApplication(pid_t(pid))
            AXUIElementSetMessagingTimeout(application, 0.25)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
                  let axWindows = value as? [AXUIElement] else { return }
            var titles: [UInt32: String] = [:]
            for axWindow in axWindows {
                let matchedID = matchingWindowID(axWindow, candidates: appWindows)
                guard let matchedID, let title = title(of: axWindow) else { continue }
                titles[matchedID] = title
            }
            titleResults.merge(titles)
        }
        let resolvedTitles = titleResults.snapshot()
        for index in windows.indices {
            if let title = resolvedTitles[windows[index].features.windowID] {
                windows[index].features.title = title
            }
        }
        return windows
    }

    nonisolated static func cgWindow(pid: Int32, id: UInt32) -> WindowInfo? {
        guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]],
              let record = records.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? Int32) == pid &&
                      ($0[kCGWindowNumber as String] as? UInt32) == id
              }),
              let boundsDictionary = record[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { return nil }
        let features = WindowFeatures(windowID: id, pid: pid, bundleID: nil, appName: "", title: "")
        return WindowInfo(features: features, bounds: bounds)
    }

    nonisolated static func matchingWindowID(_ axWindow: AXUIElement, candidates: [WindowInfo]) -> UInt32? {
        var windowID: CGWindowID = 0
        if _AXUIElementGetWindow(axWindow, &windowID) == .success,
           candidates.contains(where: { $0.features.windowID == windowID }) {
            return windowID
        }
        guard let position = pointAttribute(axWindow, kAXPositionAttribute as CFString),
              let size = sizeAttribute(axWindow, kAXSizeAttribute as CFString) else { return nil }
        return candidates.first {
            abs($0.bounds.origin.x - position.x) <= 2 &&
                abs($0.bounds.origin.y - position.y) <= 2 &&
                abs($0.bounds.width - size.width) <= 2 &&
                abs($0.bounds.height - size.height) <= 2
        }?.features.windowID
    }

    nonisolated static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String, !title.isEmpty else { return nil }
        return title
    }

    nonisolated private static func pointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    nonisolated private static func sizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

@MainActor
final class IconCache {
    private var icons: [String: NSImage] = [:]

    func icon(for window: WindowFeatures) -> NSImage? {
        let key = "\(window.bundleID ?? "pid"):\(window.pid)"
        if let cached = icons[key] { return cached }
        guard let image = NSRunningApplication(processIdentifier: pid_t(window.pid))?.icon else { return nil }
        let sized = NSImage(size: NSSize(width: 32, height: 32))
        sized.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        sized.unlockFocus()
        icons[key] = sized
        return sized
    }
}

@MainActor
enum WindowFocuser {
    static func focus(_ features: WindowFeatures) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(features.pid)) else { return false }
        if AXIsProcessTrusted() {
            let application = AXUIElementCreateApplication(pid_t(features.pid))
            AXUIElementSetMessagingTimeout(application, 0.25)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
               let axWindows = value as? [AXUIElement],
               let cgWindow = WindowEnumerator.cgWindow(pid: features.pid, id: features.windowID),
               let window = axWindows.first(where: {
                   WindowEnumerator.matchingWindowID($0, candidates: [cgWindow]) == features.windowID
               }) {
                AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
        }
        return app.activate()
    }
}
