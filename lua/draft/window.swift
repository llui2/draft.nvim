import AppKit
import ApplicationServices
import Darwin
import WebKit

struct PreviewState: Codable {
    let pid: Int32
    let terminalPID: pid_t?
    let status: String?
}

func commandOutput(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func terminalApplication(frontmost: NSRunningApplication?) -> NSRunningApplication? {
    let environment = ProcessInfo.processInfo.environment
    if let pane = environment["TMUX_PANE"],
       let clientTTY = commandOutput("/usr/bin/env", ["tmux", "display-message", "-p", "-t", pane, "#{client_tty}"]) {
        if let table = commandOutput("/bin/ps", ["-axo", "pid=,ppid=,tty="]) {
            var parents: [Int32: Int32] = [:]
            var ttys: [(Int32, String)] = []
            for line in table.split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { continue }
                parents[pid] = parent
                ttys.append((pid, String(fields[2])))
            }
            let tty = URL(fileURLWithPath: clientTTY).lastPathComponent
            for (pid, processTTY) in ttys where processTTY == tty {
                var current = pid
                for _ in 0..<10 {
                    if let app = NSRunningApplication(processIdentifier: current), app.bundleIdentifier != nil {
                        return app
                    }
                    guard let parent = parents[current], parent != current else { break }
                    current = parent
                }
            }
        }
    }

    let bundleIDs = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "vscode": "com.microsoft.VSCode",
        "kitty": "net.kovidgoyal.kitty",
        "WezTerm": "org.wezfurlong.wezterm",
        "alacritty": "org.alacritty",
        "ghostty": "com.mitchellh.ghostty",
    ]
    if let program = environment["TERM_PROGRAM"], let bundleID = bundleIDs[program],
       let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
        return app
    }
    if let frontmost, frontmost.bundleIdentifier != "com.apple.notificationcenterui",
       frontmost.bundleIdentifier != "com.apple.systempreferences" {
        return frontmost
    }
    return nil
}

func axWindow(_ app: NSRunningApplication) -> AXUIElement? {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
       let window = value {
        return (window as! AXUIElement)
    }
    if AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &value) == .success,
       let window = value {
        return (window as! AXUIElement)
    }
    return nil
}

func terminalFrame(pid: pid_t, window: AXUIElement) -> NSRect? {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    var value: CFTypeRef?
    let number: CGWindowID? = AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value) == .success
        ? (value as? NSNumber).map { CGWindowID($0.uint32Value) }
        : nil
    let candidates = windows.filter { info in
        (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
            && (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
    }
    let info = number.flatMap { id in
        candidates.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id })
    } ?? candidates.first
    guard let boundsValue = info?[kCGWindowBounds as String],
          CFGetTypeID(boundsValue as CFTypeRef) == CFDictionaryGetTypeID() else { return nil }
    let bounds = unsafeBitCast(boundsValue as CFTypeRef, to: CFDictionary.self)
    guard let quartz = CGRect(dictionaryRepresentation: bounds) else { return nil }
    let top = NSScreen.screens.first(where: { $0 == NSScreen.main })?.frame.maxY ?? 0
    return NSRect(x: quartz.minX, y: top - quartz.maxY, width: quartz.width, height: quartz.height)
}

func companionFrame(terminal: NSRect, size: NSSize) -> NSRect {
    let center = NSPoint(x: terminal.midX, y: terminal.midY)
    let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
    let width = min(size.width, visible.width)
    let height = min(size.height, visible.height)
    let gap: CGFloat = 12
    let rightRoom = visible.maxX - terminal.maxX
    let leftRoom = terminal.minX - visible.minX
    let x: CGFloat
    if rightRoom >= width + gap || rightRoom >= leftRoom {
        x = min(max(terminal.maxX + gap, visible.minX), visible.maxX - width)
    } else {
        x = min(max(terminal.minX - gap - width, visible.minX), visible.maxX - width)
    }
    let y = min(max(terminal.maxY - height, visible.minY), visible.maxY - height)
    return NSRect(x: x, y: y, width: width, height: height)
}

func readState(_ path: String) -> PreviewState? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return try? JSONDecoder().decode(PreviewState.self, from: data)
}

func writeState(_ state: PreviewState, to path: String) {
    guard let data = try? JSONEncoder().encode(state) else { return }
    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

@discardableResult
func closeWorkspace(_ statePath: String) -> Bool {
    guard let state = readState(statePath) else { return true }
    try? FileManager.default.removeItem(atPath: statePath)
    kill(state.pid, SIGTERM)
    return true
}

final class TerminalFollower {
    private let pid: pid_t
    private let window: AXUIElement
    private weak var preview: NSWindow?
    private var observer: AXObserver?
    private var previousFrame: NSRect?

    init?(app: NSRunningApplication, window: AXUIElement, preview: NSWindow) {
        pid = app.processIdentifier
        self.window = window
        self.preview = preview
        guard AXObserverCreate(pid, { _, element, _, refcon in
            guard let refcon else { return }
            let follower = Unmanaged<TerminalFollower>.fromOpaque(refcon).takeUnretainedValue()
            follower.terminalGeometryChanged(element)
        }, &observer) == .success, let observer else { return nil }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, window, kAXMovedNotification as CFString, context)
        AXObserverAddNotification(observer, window, kAXResizedNotification as CFString, context)
        previousFrame = terminalFrame(pid: pid, window: window)
    }

    private func terminalGeometryChanged(_ element: AXUIElement) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let preview = self.preview,
                  let next = terminalFrame(pid: self.pid, window: element),
                  let previous = self.previousFrame else { return }
            self.previousFrame = next
            guard next.origin != previous.origin || next.size != previous.size else { return }
            let destination = companionFrame(terminal: next, size: preview.frame.size)
            preview.setFrameOrigin(destination.origin)
        }
    }
}

final class PreviewWindow: NSObject, NSWindowDelegate {
    let window: NSPanel
    let statePath: String
    let terminalPID: pid_t?
    let terminalAXWindow: AXUIElement?
    var follower: TerminalFollower?
    private var activationObserver: NSObjectProtocol?

    init(url: URL, frame: NSRect, statePath: String, terminal: NSRunningApplication?, terminalAXWindow: AXUIElement?) {
        self.statePath = statePath
        terminalPID = terminal?.processIdentifier
        self.terminalAXWindow = terminalAXWindow
        let webView = WKWebView(frame: .zero)
        window = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Draft"
        window.minSize = NSSize(width: 320, height: 240)
        window.contentView = webView
        window.delegate = self
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        if let terminal, let terminalAXWindow {
            follower = TerminalFollower(app: terminal, window: terminalAXWindow, preview: window)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.processIdentifier == self.terminalPID || app.processIdentifier == getpid() {
                self.window.orderFrontRegardless()
            } else {
                self.window.orderOut(nil)
            }
        }

        var lastModified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak webView] _ in
            guard let webView,
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified != lastModified else { return }
            lastModified = modified
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func windowWillClose(_ notification: Notification) {
        try? FileManager.default.removeItem(atPath: statePath)
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--close", arguments.count == 2 {
    exit(closeWorkspace(arguments[1]) ? EXIT_SUCCESS : EXIT_FAILURE)
} else if arguments.count == 3, let terminalPID = pid_t(arguments[2]) {
    let htmlPath = arguments[0]
    let statePath = arguments[1]
    if FileManager.default.fileExists(atPath: statePath) {
        exit(closeWorkspace(statePath) ? EXIT_SUCCESS : EXIT_FAILURE)
    } else {
        let terminal = terminalApplication(frontmost: NSWorkspace.shared.frontmostApplication)
        let trusted = AXIsProcessTrusted()
        let targetWindow = trusted ? terminal.flatMap(axWindow) : nil
        let frame = targetWindow.flatMap { window in
            terminal.map { terminalFrame(pid: $0.processIdentifier, window: window) } ?? nil
        }
        let status: String?
        if !trusted {
            status = "Accessibility access is optional; allow the preview helper in System Settings → Privacy & Security → Accessibility to follow terminal moves and resizes. The preview is open without tracking."
        } else if targetWindow == nil || frame == nil {
            status = "Could not identify the terminal window. The preview is open without tracking."
        } else {
            status = nil
        }
        let screen = frame.flatMap { rect in
            NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) })
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        let initialSize = NSSize(width: min(680, visible.width), height: min(820, visible.height))
        let previewFrame: NSRect
        if let frame {
            previewFrame = companionFrame(terminal: frame, size: initialSize)
        } else {
            previewFrame = NSRect(x: visible.midX - initialSize.width / 2, y: visible.midY - initialSize.height / 2, width: initialSize.width, height: initialSize.height)
        }

        let state = PreviewState(pid: getpid(), terminalPID: terminal?.processIdentifier ?? terminalPID, status: status)
        writeState(state, to: statePath)
        let preview = PreviewWindow(
            url: URL(fileURLWithPath: htmlPath),
            frame: previewFrame,
            statePath: statePath,
            terminal: terminal,
            terminalAXWindow: targetWindow
        )
        withExtendedLifetime(preview) {
            app.run()
        }
    }
}
