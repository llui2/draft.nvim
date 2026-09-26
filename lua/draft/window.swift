import AppKit
import ApplicationServices
import Darwin
import WebKit

struct PreviewState: Codable {
    let pid: Int32
    let terminalPID: pid_t?
    let status: String
    let error: String?
    let warning: String?
}

func writeState(pid: Int32, terminalPID: pid_t?, status: String, error: String? = nil, warning: String? = nil, to path: String) {
    let state = PreviewState(pid: pid, terminalPID: terminalPID, status: status, error: error, warning: warning)
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

func focusedWindow(_ app: NSRunningApplication) -> AXUIElement? {
    let application = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
          let value else { return nil }
    return (value as! AXUIElement)
}

func quartzBounds(for screen: NSScreen) -> CGRect? {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
    return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
}

func intersectionArea(_ lhs: CGRect?, _ rhs: CGRect) -> CGFloat {
    guard let intersection = lhs?.intersection(rhs), !intersection.isNull else { return 0 }
    return intersection.width * intersection.height
}

func appKitFrame(forQuartzFrame quartz: CGRect) -> (frame: NSRect, screen: NSScreen)? {
    let center = CGPoint(x: quartz.midX, y: quartz.midY)
    let screen = NSScreen.screens.first(where: { quartzBounds(for: $0)?.contains(center) == true })
        ?? NSScreen.screens.max(by: {
            intersectionArea(quartzBounds(for: $0), quartz) < intersectionArea(quartzBounds(for: $1), quartz)
        })
    guard let screen, let display = quartzBounds(for: screen) else { return nil }
    let cocoa = screen.frame
    return (
        NSRect(
            x: cocoa.minX + quartz.minX - display.minX,
            y: cocoa.maxY + display.minY - quartz.minY - quartz.height,
            width: quartz.width,
            height: quartz.height
        ),
        screen
    )
}

func quartzPosition(for frame: NSRect, on screen: NSScreen) -> CGPoint? {
    guard let display = quartzBounds(for: screen) else { return nil }
    let cocoa = screen.frame
    return CGPoint(x: display.minX + frame.minX - cocoa.minX, y: display.minY + cocoa.maxY - frame.maxY)
}

func terminalFrame(pid: pid_t, window: AXUIElement) -> NSRect? {
    if let point = axPoint(window), let size = axSize(window),
       let mapped = appKitFrame(forQuartzFrame: CGRect(origin: point, size: size)) {
        return mapped.frame
    }
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    var value: CFTypeRef?
    let number = AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value) == .success
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
    return appKitFrame(forQuartzFrame: quartz)?.frame
}

func axPoint(_ window: AXUIElement) -> CGPoint? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
          let value else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
}

func axSize(_ window: AXUIElement) -> CGSize? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
          let value else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
}

func setAXFrame(_ frame: NSRect, window: AXUIElement, screen: NSScreen) -> Bool {
    guard var point = quartzPosition(for: frame, on: screen) else { return false }
    var size = frame.size
    guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) else { return false }
    let sizeStatus = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
    let positionStatus = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    return sizeStatus == .success && positionStatus == .success
}

struct SplitTarget {
    let app: NSRunningApplication
    let axWindow: AXUIElement
    let originalPosition: CGPoint
    let originalSize: CGSize
    let screen: NSScreen
}

func splitTarget(terminal: NSRunningApplication?, trusted: Bool) -> SplitTarget? {
    guard trusted, let terminal, let axWindow = focusedWindow(terminal),
          let originalPosition = axPoint(axWindow), let originalSize = axSize(axWindow),
          let mapped = appKitFrame(forQuartzFrame: CGRect(origin: originalPosition, size: originalSize)) else { return nil }
    let screen = mapped.screen
    return SplitTarget(app: terminal, axWindow: axWindow, originalPosition: originalPosition, originalSize: originalSize, screen: screen)
}

final class PreviewSession: NSObject, NSWindowDelegate, WKNavigationDelegate {
    let window: NSWindow
    private let statePath: String
    private let sourcePath: String
    private let terminalPID: pid_t?
    private let terminalApp: NSRunningApplication?
    private let target: SplitTarget?
    private let webView: WKWebView
    private var observer: AXObserver?
    private var signalSource: DispatchSourceSignal?
    private var sourceWatcher: DispatchSourceFileSystemObject?
    private var sourceDebounce: DispatchWorkItem?
    private var currentSource: String?
    private var sentSource: String?
    private var pageLoaded = false
    private var splitX: CGFloat = 0
    private var terminalExpected: NSRect?
    private var previewExpected: NSRect?
    private var applying = false
    private var closing = false
    private(set) var warning: String?

    init(url: URL, sourcePath: String, statePath: String, terminal: NSRunningApplication?, target: SplitTarget?) {
        self.statePath = statePath
        self.sourcePath = sourcePath
        self.terminalPID = terminal?.processIdentifier
        self.terminalApp = terminal
        self.target = target
        let screen = target?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        let size = NSSize(width: min(680, visible.width), height: min(820, visible.height))
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        let webView = WKWebView(frame: .zero)
        self.webView = webView
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Draft"
        window.minSize = NSSize(width: min(240, visible.width * 0.20), height: min(240, visible.height))
        window.contentView = webView
        window.delegate = self
        webView.navigationDelegate = self

        if target == nil {
            warning = AXIsProcessTrusted()
                ? "split mode unavailable: could not identify the active terminal window"
                : "split mode unavailable: Accessibility permission is required"
        }
        if !watchSource() {
            warning = [warning, "live updates unavailable: could not watch the source file"].compactMap { $0 }.joined(separator: "; ")
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func watchSource() -> Bool {
        let directory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent().path
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        watcher.setEventHandler { [weak self] in self?.scheduleSourceRead() }
        watcher.setCancelHandler { Darwin.close(descriptor) }
        sourceWatcher = watcher
        watcher.resume()
        return true
    }

    private func scheduleSourceRead() {
        guard !closing else { return }
        sourceDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readSource() }
        sourceDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
    }

    private func readSource() {
        guard !closing else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)),
              let source = try? JSONDecoder().decode(String.self, from: data) else { return }
        guard source != currentSource else {
            sendSourceIfReady()
            return
        }
        currentSource = source
        sendSourceIfReady()
    }

    private func sendSourceIfReady() {
        guard !closing, pageLoaded, let source = currentSource, source != sentSource,
              let data = try? JSONEncoder().encode(source),
              let literal = String(data: data, encoding: .utf8) else { return }
        sentSource = source
        webView.evaluateJavaScript("window.updateSource(\(literal))") { [weak self] _, error in
            guard let error else { return }
            NSLog("draft.nvim: preview source update failed: %@", error.localizedDescription)
            if self?.sentSource == source { self?.sentSource = nil }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        readSource()
    }

    func start() {
        guard let target else {
            returnFocusToTerminal()
            return
        }
        var created: AXObserver?
        let status = AXObserverCreate(target.app.processIdentifier, { _, element, _, refcon in
            guard let refcon else { return }
            let session = Unmanaged<PreviewSession>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { session.terminalChanged(element) }
        }, &created)
        guard status == .success, let created else {
            warning = "split mode unavailable: could not observe the terminal window"
            returnFocusToTerminal()
            return
        }
        observer = created
        let context = Unmanaged.passUnretained(self).toOpaque()
        let moved = AXObserverAddNotification(created, target.axWindow, kAXMovedNotification as CFString, context)
        let resized = AXObserverAddNotification(created, target.axWindow, kAXResizedNotification as CFString, context)
        guard moved == .success && resized == .success else {
            warning = "split mode unavailable: could not observe the terminal window"
            stopObserving()
            returnFocusToTerminal()
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        let visible = target.screen.visibleFrame
        splitX = visible.minX + visible.width * 0.55
        let initial = frames(at: splitX, in: visible)
        guard apply(initial.terminal, initial.preview),
              let arranged = terminalFrame(pid: target.app.processIdentifier, window: target.axWindow),
              same(arranged, initial.terminal, tolerance: 3) else {
            warning = "split mode unavailable: could not arrange the terminal window"
            restoreTerminal()
            stopObserving()
            returnFocusToTerminal()
            return
        }
        returnFocusToTerminal()
    }

    private func returnFocusToTerminal() {
        guard let app = target?.app ?? terminalApp else { return }
        app.activate(options: [.activateAllWindows])
        if let target { AXUIElementPerformAction(target.axWindow, kAXRaiseAction as CFString) }
    }

    private func frames(at divider: CGFloat, in workspace: NSRect) -> (terminal: NSRect, preview: NSRect) {
        let gap: CGFloat = 2
        let minimumDivider = workspace.minX + workspace.width * 0.40
        let maximumDivider = workspace.maxX - workspace.width * 0.20 - gap
        let x = min(max(divider, minimumDivider), maximumDivider)
        return (
            NSRect(x: workspace.minX, y: workspace.minY, width: x - workspace.minX, height: workspace.height),
            NSRect(x: x + gap, y: workspace.minY, width: workspace.maxX - x - gap, height: workspace.height)
        )
    }

    @discardableResult
    private func apply(_ terminalFrame: NSRect, _ previewFrame: NSRect) -> Bool {
        guard let target else { return false }
        applying = true
        terminalExpected = terminalFrame
        previewExpected = previewFrame
        let success = setAXFrame(terminalFrame, window: target.axWindow, screen: target.screen)
        window.setFrame(previewFrame, display: true)
        applying = false
        return success
    }

    private func same(_ lhs: NSRect, _ rhs: NSRect, tolerance: CGFloat = 2) -> Bool {
        abs(lhs.minX - rhs.minX) < tolerance && abs(lhs.minY - rhs.minY) < tolerance
            && abs(lhs.width - rhs.width) < tolerance && abs(lhs.height - rhs.height) < tolerance
    }

    private func terminalChanged(_ element: AXUIElement) {
        guard !closing, !applying, let target,
              let actual = terminalFrame(pid: target.app.processIdentifier, window: element),
              let expected = terminalExpected else { return }
        if same(actual, expected) { return }
        let dividerDrag = abs(actual.minX - expected.minX) < 3
            && abs(actual.minY - expected.minY) < 3
            && abs(actual.height - expected.height) < 3
            && abs(actual.width - expected.width) > 2
        guard dividerDrag else {
            let canonical = frames(at: splitX, in: target.screen.visibleFrame)
            _ = apply(canonical.terminal, canonical.preview)
            return
        }
        splitX = actual.maxX
        let canonical = frames(at: splitX, in: target.screen.visibleFrame)
        splitX = canonical.terminal.maxX
        _ = apply(canonical.terminal, canonical.preview)
    }

    func windowDidMove(_ notification: Notification) { previewChanged() }
    func windowDidResize(_ notification: Notification) { previewChanged() }
    func windowDidEndLiveResize(_ notification: Notification) { returnFocusToTerminal() }

    private func previewChanged() {
        guard !closing, !applying, let target, let expected = previewExpected else { return }
        let actual = window.frame
        if same(actual, expected) { return }
        let dividerDrag = abs(actual.maxX - expected.maxX) < 3
            && abs(actual.minY - expected.minY) < 3
            && abs(actual.height - expected.height) < 3
            && abs(actual.minX - expected.minX) > 2
        guard dividerDrag else {
            let canonical = frames(at: splitX, in: target.screen.visibleFrame)
            _ = apply(canonical.terminal, canonical.preview)
            return
        }
        splitX = actual.minX - 2
        let canonical = frames(at: splitX, in: target.screen.visibleFrame)
        splitX = canonical.terminal.maxX
        _ = apply(canonical.terminal, canonical.preview)
    }

    private func stopObserving() {
        guard let observer, let target else { return }
        AXObserverRemoveNotification(observer, target.axWindow, kAXMovedNotification as CFString)
        AXObserverRemoveNotification(observer, target.axWindow, kAXResizedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }

    private func restoreTerminal() {
        guard let target else { return }
        var point = target.originalPosition
        var size = target.originalSize
        if let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(target.axWindow, kAXSizeAttribute as CFString, dimensions)
            AXUIElementSetAttributeValue(target.axWindow, kAXPositionAttribute as CFString, position)
        }
        returnFocusToTerminal()
    }

    func close() {
        guard !closing else { return }
        closing = true
        signalSource?.cancel()
        signalSource = nil
        sourceDebounce?.cancel()
        sourceDebounce = nil
        sourceWatcher?.cancel()
        sourceWatcher = nil
        stopObserving()
        restoreTerminal()
        try? FileManager.default.removeItem(atPath: sourcePath)
        try? FileManager.default.removeItem(atPath: sourcePath + ".tmp")
        try? FileManager.default.removeItem(atPath: statePath)
        NSApplication.shared.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) { close() }

    func installTerminationHandler() {
        Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in self?.close() }
        source.resume()
        signalSource = source
    }

    func reportVisible() {
        guard window.isVisible else {
            writeState(pid: getpid(), terminalPID: terminalPID, status: "failed", error: "AppKit did not make the Draft window visible", to: statePath)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApplication.shared.terminate(nil) }
            return
        }
        writeState(pid: getpid(), terminalPID: terminalPID, status: "visible", warning: warning, to: statePath)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 4, let terminalPID = pid_t(arguments[3]) else {
    fputs("usage: draft-preview <html> <source> <state> <terminal-pid>\n", stderr)
    exit(EXIT_FAILURE)
}
let htmlPath = arguments[0]
let sourcePath = arguments[1]
let statePath = arguments[2]
guard FileManager.default.fileExists(atPath: htmlPath) else {
    fputs("preview HTML does not exist: \(htmlPath)\n", stderr)
    exit(EXIT_FAILURE)
}

guard FileManager.default.fileExists(atPath: sourcePath) else {
    fputs("preview source does not exist: \(sourcePath)\n", stderr)
    exit(EXIT_FAILURE)
}

writeState(pid: getpid(), terminalPID: terminalPID, status: "launched", to: statePath)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let terminal = terminalApplication(frontmost: NSWorkspace.shared.frontmostApplication)
let target = splitTarget(terminal: terminal, trusted: AXIsProcessTrusted())
let session = PreviewSession(url: URL(fileURLWithPath: htmlPath), sourcePath: sourcePath, statePath: statePath, terminal: terminal, target: target)
session.installTerminationHandler()
writeState(pid: getpid(), terminalPID: terminal?.processIdentifier ?? terminalPID, status: "initialized", to: statePath)
app.activate(ignoringOtherApps: true)
session.window.makeKeyAndOrderFront(nil)
session.start()
DispatchQueue.main.async { session.reportVisible() }
withExtendedLifetime(session) { app.run() }
