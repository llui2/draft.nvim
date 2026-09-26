import AppKit
import ApplicationServices
import Darwin
import WebKit

struct PreviewState: Codable {
    let pid: Int32
    let terminalPID: pid_t?
    let status: String
    let error: String?
}

func writeState(pid: Int32, terminalPID: pid_t?, status: String, error: String? = nil, to path: String) {
    let state = PreviewState(pid: pid, terminalPID: terminalPID, status: status, error: error)
    guard let data = try? JSONEncoder().encode(state) else { return }
    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
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
       let clientTTY = commandOutput("/usr/bin/env", ["tmux", "display-message", "-p", "-t", pane, "#{client_tty}"]),
       let table = commandOutput("/bin/ps", ["-axo", "pid=,ppid=,tty="]) {
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
                if let app = NSRunningApplication(processIdentifier: current), app.bundleIdentifier != nil { return app }
                guard let parent = parents[current], parent != current else { break }
                current = parent
            }
        }
    }

    let bundleIDs = [
        "Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2",
        "vscode": "com.microsoft.VSCode", "kitty": "net.kovidgoyal.kitty",
        "WezTerm": "org.wezfurlong.wezterm", "alacritty": "org.alacritty",
        "ghostty": "com.mitchellh.ghostty",
    ]
    if let program = environment["TERM_PROGRAM"], let bundleID = bundleIDs[program],
       let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) { return app }
    if let frontmost, frontmost.bundleIdentifier != "com.apple.notificationcenterui",
       frontmost.bundleIdentifier != "com.apple.systempreferences" { return frontmost }
    return nil
}

func axWindow(_ app: NSRunningApplication) -> AXUIElement? {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
       let window = value { return (window as! AXUIElement) }
    if AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &value) == .success,
       let window = value { return (window as! AXUIElement) }
    return nil
}

func terminalFrame(pid: pid_t, window: AXUIElement) -> NSRect? {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    var value: CFTypeRef?
    let number: CGWindowID? = AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value) == .success
        ? (value as? NSNumber).map { CGWindowID($0.uint32Value) } : nil
    let candidates = windows.filter {
        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
            && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
    }
    guard let info = number.flatMap({ id in candidates.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }) }) ?? candidates.first,
          let boundsValue = info[kCGWindowBounds as String],
          CFGetTypeID(boundsValue as CFTypeRef) == CFDictionaryGetTypeID() else { return nil }
    let bounds = unsafeBitCast(boundsValue as CFTypeRef, to: CFDictionary.self)
    guard let quartz = CGRect(dictionaryRepresentation: bounds) else { return nil }
    let top = NSScreen.screens.first(where: { $0 == NSScreen.main })?.frame.maxY ?? 0
    return NSRect(x: quartz.minX, y: top - quartz.maxY, width: quartz.width, height: quartz.height)
}

func initialFrame(terminal: NSRect?, screen: NSScreen?) -> NSRect {
    let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
    let size = NSSize(width: min(680, visible.width), height: min(820, visible.height))
    if let terminal {
        let right = visible.maxX - terminal.maxX
        let left = terminal.minX - visible.minX
        let x = right >= size.width + 12 || right >= left
            ? min(max(terminal.maxX + 12, visible.minX), visible.maxX - size.width)
            : min(max(terminal.minX - 12 - size.width, visible.minX), visible.maxX - size.width)
        let y = min(max(terminal.maxY - size.height, visible.minY), visible.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
    return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
}

final class PreviewWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let statePath: String
    private let terminalPID: pid_t?

    init(url: URL, frame: NSRect, statePath: String, terminalPID: pid_t?) {
        self.statePath = statePath
        self.terminalPID = terminalPID
        let webView = WKWebView(frame: .zero)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Draft"
        window.minSize = NSSize(width: 320, height: 240)
        window.contentView = webView
        window.delegate = self
        window.setFrame(frame, display: true)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
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

    func reportVisible() {
        guard window.isVisible else {
            writeState(pid: getpid(), terminalPID: terminalPID, status: "failed", error: "AppKit did not make the Draft window visible", to: statePath)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                NSApplication.shared.terminate(nil)
            }
            return
        }
        writeState(pid: getpid(), terminalPID: terminalPID, status: "visible", to: statePath)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, let terminalPID = pid_t(arguments[2]) else {
    fputs("usage: draft-preview <html> <state> <terminal-pid>\n", stderr)
    exit(EXIT_FAILURE)
}

let htmlPath = arguments[0]
let statePath = arguments[1]
guard FileManager.default.fileExists(atPath: htmlPath) else {
    fputs("preview HTML does not exist: \(htmlPath)\n", stderr)
    exit(EXIT_FAILURE)
}
writeState(pid: getpid(), terminalPID: terminalPID, status: "launched", to: statePath)

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let terminal = terminalApplication(frontmost: NSWorkspace.shared.frontmostApplication)
let accessibilityWindow = terminal.flatMap { AXIsProcessTrusted() ? axWindow($0) : nil }
let terminalBounds = terminal.flatMap { application in
    accessibilityWindow.flatMap { terminalFrame(pid: application.processIdentifier, window: $0) }
}
let screen = terminalBounds.flatMap { rect in NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }) } ?? NSScreen.main
let frame = initialFrame(terminal: terminalBounds, screen: screen)
let preview = PreviewWindow(url: URL(fileURLWithPath: htmlPath), frame: frame, statePath: statePath, terminalPID: terminal?.processIdentifier ?? terminalPID)
writeState(pid: getpid(), terminalPID: terminal?.processIdentifier ?? terminalPID, status: "initialized", to: statePath)
app.activate(ignoringOtherApps: true)
preview.window.makeKeyAndOrderFront(nil)
DispatchQueue.main.async {
    preview.reportVisible()
}
withExtendedLifetime(preview) { app.run() }
