import AppKit
import ApplicationServices
import Darwin
import WebKit

struct Frame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: NSRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}

struct LayoutState: Codable {
    let pid: Int32
    let terminalPID: pid_t?
    let originalFrame: Frame?
    let tiled: Bool
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

func readState(_ path: String) -> LayoutState? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return try? JSONDecoder().decode(LayoutState.self, from: data)
}

func writeState(_ state: LayoutState, to path: String) {
    guard let data = try? JSONEncoder().encode(state) else { return }
    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
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

func framesExactlyMatch(_ actual: NSRect, _ expected: NSRect) -> Bool {
    abs(actual.minX - expected.minX) < 1 && abs(actual.minY - expected.minY) < 1
        && abs(actual.width - expected.width) < 1 && abs(actual.height - expected.height) < 1
}

func frameDescription(_ rect: NSRect) -> String {
    "x=\(Int(rect.minX.rounded())) y=\(Int(rect.minY.rounded())) w=\(Int(rect.width.rounded())) h=\(Int(rect.height.rounded()))"
}

func windowNumber(_ window: AXUIElement) -> CGWindowID? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value) == .success,
          let number = value as? NSNumber else { return nil }
    return CGWindowID(number.uint32Value)
}

func quartzFrame(pid: pid_t, window: AXUIElement) -> NSRect? {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    let number = windowNumber(window)
    let candidates = windows.filter { info in
        (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
            && (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
    }
    let info = (number.flatMap { id in
        candidates.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id })
    }) ?? candidates.first
    guard let value = info?[kCGWindowBounds as String],
          CFGetTypeID(value as CFTypeRef) == CFDictionaryGetTypeID() else { return nil }
    let dictionary = unsafeBitCast(value as CFTypeRef, to: CFDictionary.self)
    guard let bounds = CGRect(dictionaryRepresentation: dictionary) else { return nil }
    let top = NSScreen.screens.first(where: { $0 == NSScreen.main })?.frame.maxY ?? 0
    return NSRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height)
}

func setAXFrame(_ rect: NSRect, on window: AXUIElement, pid: pid_t) -> NSRect? {
    let top = NSScreen.screens.first(where: { $0 == NSScreen.main })?.frame.maxY ?? 0
    var requested = rect
    for _ in 0..<4 {
        var point = CGPoint(x: requested.minX, y: top - requested.maxY)
        var size = CGSize(width: requested.width, height: requested.height)
        guard let pointValue = AXValueCreate(.cgPoint, &point),
              let sizeValue = AXValueCreate(.cgSize, &size),
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success,
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue) == .success else { return nil }
        Thread.sleep(forTimeInterval: 0.1)
        guard let actual = quartzFrame(pid: pid, window: window) else { return nil }
        if framesExactlyMatch(actual, rect) { return actual }
        requested = NSRect(
            x: requested.minX + rect.minX - actual.minX,
            y: requested.minY + rect.minY - actual.minY,
            width: requested.width + rect.width - actual.width,
            height: requested.height + rect.height - actual.height
        )
    }
    return quartzFrame(pid: pid, window: window)
}

func restoreTerminal(_ state: LayoutState) -> Bool {
    guard state.tiled else { return true }
    guard let pid = state.terminalPID, let original = state.originalFrame, AXIsProcessTrusted() else { return false }
    let app = NSRunningApplication(processIdentifier: pid)
    if let app, let window = axWindow(app) {
        guard let actual = setAXFrame(original.rect, on: window, pid: pid), framesExactlyMatch(actual, original.rect) else { return false }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        app.activate(options: [])
        return true
    }
    return false
}

@discardableResult
func closeWorkspace(_ statePath: String) -> Bool {
    guard let state = readState(statePath) else { return true }
    let restored = restoreTerminal(state)
    try? FileManager.default.removeItem(atPath: statePath)
    kill(state.pid, SIGTERM)
    return restored
}

final class PreviewWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let state: LayoutState
    let statePath: String

    init(url: URL, frame: NSRect, state: LayoutState, statePath: String) {
        self.state = state
        self.statePath = statePath
        let webView = WKWebView(frame: .zero)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.contentView = webView
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
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
        _ = restoreTerminal(state)
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
        let frontmost = NSWorkspace.shared.frontmostApplication
        let terminal = terminalApplication(frontmost: frontmost)
        let prompt = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(prompt)
        let targetWindow = trusted ? terminal.flatMap(axWindow) : nil
        let original = targetWindow.flatMap { window in
            terminal.map { quartzFrame(pid: $0.processIdentifier, window: window) } ?? nil
        }
        let screen = original.flatMap { frame in
            NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) })
        } ?? NSScreen.main
        let fallback = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 760, height: 900)
        let fallbackWidth = min(760, fallback.width)
        let fallbackHeight = min(900, fallback.height)
        var previewFrame = NSRect(
            x: fallback.midX - fallbackWidth / 2,
            y: fallback.midY - fallbackHeight / 2,
            width: fallbackWidth,
            height: fallbackHeight
        )
        var tiled = false
        var status: String?

        if !trusted {
            status = "Allow draft.nvim's preview helper in the macOS Accessibility prompt, then toggle the preview off and on to tile the terminal. The preview is open without tiling."
        } else if let original, let targetWindow, let screen, let terminal {
            let visible = screen.visibleFrame
            let gap: CGFloat = 2
            let terminalWidth = (visible.width - gap) * 0.55
            let previewWidth = visible.width - gap - terminalWidth
            let terminalFrame = NSRect(x: visible.minX, y: visible.minY, width: terminalWidth, height: visible.height)
            previewFrame = NSRect(x: visible.minX + terminalWidth + gap, y: visible.minY, width: previewWidth, height: visible.height)
            if let actual = setAXFrame(terminalFrame, on: targetWindow, pid: terminal.processIdentifier) {
                tiled = framesExactlyMatch(actual, terminalFrame)
                if !tiled {
                    status = "Terminal frame mismatch; expected \(frameDescription(terminalFrame)), got \(frameDescription(actual))."
                }
            }
            if !tiled {
                _ = setAXFrame(original, on: targetWindow, pid: terminal.processIdentifier)
                status = status ?? "Could not arrange the active terminal window. Check Accessibility access in System Settings → Privacy & Security → Accessibility. The preview is open."
            }
        } else {
            status = "Could not identify the active terminal window. The preview is open without tiling."
        }

        let state = LayoutState(
            pid: getpid(),
            terminalPID: terminal?.processIdentifier ?? terminalPID,
            originalFrame: tiled ? original.map(Frame.init) : nil,
            tiled: tiled,
            status: status
        )
        writeState(state, to: statePath)
        let preview = PreviewWindow(url: URL(fileURLWithPath: htmlPath), frame: previewFrame, state: state, statePath: statePath)
        if tiled, let terminal {
            terminal.activate(options: [])
        }
        withExtendedLifetime(preview) {
            app.run()
        }
    }
}
