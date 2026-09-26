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

final class DividerControl: NSPanel {
    var sourceAction: (() -> Void)?
    var previewAction: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 24, height: 58), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .normal
        collectionBehavior = [.ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let effect = NSVisualEffectView(frame: contentRect(forFrameRect: frame))
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .fill
        stack.spacing = 0
        for (symbol, label, action) in [("arrow.right", "Source to preview", #selector(sourcePressed)), ("arrow.left", "Preview to source", #selector(previewPressed))] {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
            button.setAccessibilityLabel(label)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.setButtonType(.momentaryChange)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            stack.addArrangedSubview(button)
        }
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 14).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.insertArrangedSubview(separator, at: 1)
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 1),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -1),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -1),
        ])
        contentView = effect
    }

    @objc private func sourcePressed() { sourceAction?() }
    @objc private func previewPressed() { previewAction?() }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
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
    private static let appearanceKey = "renderedAppearance"
    private enum WorkspaceState: Equatable {
        case pairedActive
        case hidden
        case unrelatedAppActive
        case terminalMinimized
        case draftMinimized
        case closing
    }

    let window: NSWindow
    private let statePath: String
    private let sourcePath: String
    private let commandPath: String
    private var lastCommand: String?
    private let server: String
    private let nvim: String
    private let terminalPID: pid_t?
    private let target: SplitTarget?
    private let webView: WKWebView
    private let dividerControl = DividerControl()
    private let appearanceButton = NSButton()
    private let appearanceAccessory = NSTitlebarAccessoryViewController()
    private var darkAppearance = false
    private var observer: AXObserver?
    private var signalSource: DispatchSourceSignal?
    private var hideSignalSource: DispatchSourceSignal?
    private var showSignalSource: DispatchSourceSignal?
    private var sourceWatcher: DispatchSourceFileSystemObject?
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var terminalMinimized = false
    private var workspaceState: WorkspaceState = .unrelatedAppActive
    private var sourceDebounce: DispatchWorkItem?
    private var currentSource: String?
    private var sentSource: String?
    private var pageLoaded = false
    private var splitX: CGFloat = 0
    private var terminalExpected: NSRect?
    private var previewExpected: NSRect?
    private var applying = false
    private var closing = false
    private var workspaceVisible = false
    private var layoutReady = false
    private(set) var warning: String?

    init(url: URL, sourcePath: String, statePath: String, commandPath: String, server: String, nvim: String, terminal: NSRunningApplication?, target: SplitTarget?) {
        self.statePath = statePath
        self.sourcePath = sourcePath
        self.commandPath = commandPath
        self.server = server
        self.nvim = nvim
        self.terminalPID = terminal?.processIdentifier
        self.target = target
        let screen = target?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        let size = NSSize(width: min(680, visible.width), height: min(820, visible.height))
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        let webView = WKWebView(frame: .zero)
        self.webView = webView
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = target == nil
        window.collectionBehavior = [.moveToActiveSpace]
        window.minSize = NSSize(width: min(240, visible.width * 0.20), height: min(240, visible.height))
        window.contentView = webView
        window.delegate = self
        configureAppearance()
        window.addChildWindow(dividerControl, ordered: .above)
        webView.navigationDelegate = self
        dividerControl.sourceAction = { [weak self] in self?.navigateToSource() }
        dividerControl.previewAction = { [weak self] in self?.navigateToPreview() }

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

    private func configureAppearance() {
        let saved = UserDefaults.standard.string(forKey: Self.appearanceKey)
        darkAppearance = saved == "dark" || (saved == nil && window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 38, height: 28))
        appearanceButton.frame = NSRect(x: 5, y: 0, width: 28, height: 28)
        appearanceButton.isBordered = false
        appearanceButton.imagePosition = .imageOnly
        appearanceButton.target = self
        appearanceButton.action = #selector(toggleAppearance)
        appearanceButton.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
        accessoryView.addSubview(appearanceButton)
        appearanceAccessory.view = accessoryView
        appearanceAccessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(appearanceAccessory)
        if darkAppearance {
            let script = WKUserScript(source: "document.documentElement.dataset.theme = 'dark'",
                                      injectionTime: .atDocumentStart, forMainFrameOnly: true)
            webView.configuration.userContentController.addUserScript(script)
        }
        applyAppearance()
    }

    @objc private func toggleAppearance() {
        darkAppearance.toggle()
        UserDefaults.standard.set(darkAppearance ? "dark" : "light", forKey: Self.appearanceKey)
        applyAppearance()
        window.makeFirstResponder(webView)
    }

    private func applyAppearance() {
        let background = darkAppearance
            ? NSColor(srgbRed: 28.0 / 255.0, green: 28.0 / 255.0, blue: 30.0 / 255.0, alpha: 1)
            : NSColor.white
        window.appearance = NSAppearance(named: darkAppearance ? .darkAqua : .aqua)
        window.backgroundColor = background
        webView.underPageBackgroundColor = background
        let symbol = darkAppearance ? "sun.max.fill" : "moon.fill"
        let label = darkAppearance ? "Use light appearance" : "Use dark appearance"
        appearanceButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        appearanceButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        appearanceButton.setAccessibilityLabel(label)
        if pageLoaded { webView.evaluateJavaScript("window.setDraftAppearance('\(darkAppearance ? "dark" : "light")')") }
    }

    private func watchSource() -> Bool {
        let directory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent().path
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        watcher.setEventHandler { [weak self] in
            self?.scheduleSourceRead()
            self?.readCommand()
        }
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

    private func readCommand() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: commandPath)),
              let raw = String(data: data, encoding: .utf8), raw != lastCommand,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["action"] as? String else { return }
        lastCommand = raw
        switch action {
        case "sync-source": navigateToSource()
        case "focus-preview": focusPreview()
        case "focus-source": focusSource()
        default: break
        }
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
        applyAppearance()
        readSource()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme == "draft" {
            if url.host == "sync" { navigateToPreview(); decisionHandler(.cancel); return }
            if url.host == "focus-source" { focusSource(); decisionHandler(.cancel); return }
            if url.host == "jump", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let start = components.queryItems?.first(where: { $0.name == "start" })?.value.flatMap(Int.init),
               let end = components.queryItems?.first(where: { $0.name == "end" })?.value.flatMap(Int.init) {
                syncToSource(start: start, end: end, mode: "cursor")
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    private func remoteExpression(_ expression: String) -> String? {
        commandOutput(nvim, ["--server", server, "--remote-expr", expression])
    }

    private func navigateToSource() {
        guard let json = remoteExpression("luaeval('require(\"draft.sync\").source_position()')"),
              let data = json.data(using: .utf8),
              let position = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let start = position["start"] as? Int, let end = position["finish"] as? Int else { return }
        let mode = position["mode"] as? String ?? "cursor"
        let script = "window.sourceToPreview(\(start), \(end), '\(mode)')"
        webView.evaluateJavaScript(script)
    }

    private func focusPreview() {
        guard workspaceVisible, target != nil else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        refreshWorkspaceState()
    }

    private func focusSource() {
        guard let target, workspaceVisible else { return }
        target.app.activate()
        _ = AXUIElementPerformAction(target.axWindow, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(target.axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(target.axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        refreshWorkspaceSoon()
    }

    private func navigateToPreview() {
        webView.evaluateJavaScript("window.previewReadingAnchor()") { [weak self] result, _ in
            guard let self, let anchor = result as? [String: Any],
                  let start = anchor["start"] as? Int, let end = anchor["end"] as? Int else { return }
            let mode = anchor["selection"] as? Bool == true ? "char" : "cursor"
            self.syncToSource(start: start, end: end, mode: mode)
        }
    }

    private func syncToSource(start: Int, end: Int, mode: String) {
        guard remoteExpression("luaeval('require(\"draft.sync\").jump_to_source(_A[1], _A[2], _A[3])', [\(start), \(end), '\(mode)'])") != nil else { return }
        webView.evaluateJavaScript("window.highlightPreviewAnchor(\(start), \(end))")
        focusSource()
    }

    private func positionDividerControl(in workspace: NSRect) {
        let frame = NSRect(x: splitX - 11, y: workspace.midY - 29, width: 24, height: 58)
        dividerControl.setFrame(frame, display: true)
    }

    private func showDividerControl() {
        guard layoutReady, window.isVisible, !window.isMiniaturized else { return }
        dividerControl.level = .floating
        if !dividerControl.isVisible { dividerControl.orderFront(nil) }
    }

    private func targetTerminalIsFocused() -> Bool {
        guard let target else { return false }
        let application = AXUIElementCreateApplication(target.app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused else { return false }
        if CFEqual(focused, target.axWindow) { return true }
        var focusedNumber: CFTypeRef?
        var targetNumber: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, "AXWindowNumber" as CFString, &focusedNumber) == .success,
              AXUIElementCopyAttributeValue(target.axWindow, "AXWindowNumber" as CFString, &targetNumber) == .success,
              let focusedNumber = focusedNumber as? NSNumber,
              let targetNumber = targetNumber as? NSNumber else { return false }
        return focusedNumber == targetNumber
    }

    private func targetTerminalIsMinimized() -> Bool {
        guard let target else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target.axWindow, kAXMinimizedAttribute as CFString, &value) == .success else { return terminalMinimized }
        return (value as? NSNumber)?.boolValue ?? terminalMinimized
    }

    func start() {
        workspaceVisible = true
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, !self.closing, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.applicationActivated(app)
        }
        deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshWorkspaceSoon() }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshWorkspaceSoon() }
        guard let target else {
            refreshWorkspaceState()
            return
        }
        var created: AXObserver?
        let status = AXObserverCreate(target.app.processIdentifier, { _, element, notification, refcon in
            guard let refcon else { return }
            let session = Unmanaged<PreviewSession>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async {
                if notification as String == kAXFocusedWindowChangedNotification as String {
                    session.terminalFocusChanged()
                } else if notification as String == kAXWindowMiniaturizedNotification as String {
                    session.terminalMiniaturized()
                } else if notification as String == kAXWindowDeminiaturizedNotification as String {
                    session.terminalDeminiaturized()
                } else {
                    session.terminalChanged(element)
                }
            }
        }, &created)
        guard status == .success, let created else {
            warning = "split mode unavailable: could not observe the terminal window"
            refreshWorkspaceState()
            return
        }
        observer = created
        let context = Unmanaged.passUnretained(self).toOpaque()
        let moved = AXObserverAddNotification(created, target.axWindow, kAXMovedNotification as CFString, context)
        let resized = AXObserverAddNotification(created, target.axWindow, kAXResizedNotification as CFString, context)
        AXObserverAddNotification(created, target.axWindow, kAXWindowMiniaturizedNotification as CFString, context)
        AXObserverAddNotification(created, target.axWindow, kAXWindowDeminiaturizedNotification as CFString, context)
        let application = AXUIElementCreateApplication(target.app.processIdentifier)
        let focused = AXObserverAddNotification(created, application, kAXFocusedWindowChangedNotification as CFString, context)
        guard moved == .success && resized == .success && focused == .success else {
            warning = "split mode unavailable: could not observe the terminal window"
            stopObserving()
            refreshWorkspaceState()
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
            refreshWorkspaceState()
            return
        }
        layoutReady = true
        positionDividerControl(in: visible)
        refreshWorkspaceState()
    }

    private func applicationActivated(_ app: NSRunningApplication) {
        // Activation notifications can precede the new app's focused-window update.
        // The foreground app and focused AX window are read together on the next turn.
        DispatchQueue.main.async { [weak self] in
            self?.refreshWorkspaceState(returningToPair: app.processIdentifier == self?.target?.app.processIdentifier)
        }
    }

    private func refreshWorkspaceSoon() {
        DispatchQueue.main.async { [weak self] in self?.refreshWorkspaceState() }
    }

    private func refreshWorkspaceState(returningToPair: Bool = false) {
        guard !closing else { transition(to: .closing); return }
        guard workspaceVisible else { transition(to: .hidden); return }
        guard !window.isMiniaturized else { transition(to: .draftMinimized); return }

        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let target else {
            transition(to: foregroundPID == ProcessInfo.processInfo.processIdentifier || foregroundPID == terminalPID
                ? .pairedActive : .unrelatedAppActive)
            return
        }
        guard foregroundPID == target.app.processIdentifier || foregroundPID == ProcessInfo.processInfo.processIdentifier else {
            transition(to: .unrelatedAppActive)
            return
        }
        guard !targetTerminalIsMinimized() else { transition(to: .terminalMinimized); return }
        let terminalOwnsFocusedWindow = foregroundPID == target.app.processIdentifier && targetTerminalIsFocused()
        let draftOwnsForeground = foregroundPID == ProcessInfo.processInfo.processIdentifier && targetTerminalIsFocused()
        transition(to: terminalOwnsFocusedWindow || draftOwnsForeground ? .pairedActive : .unrelatedAppActive, returningToPair: returningToPair)
    }

    private func transition(to next: WorkspaceState, returningToPair: Bool = false) {
        let changed = workspaceState != next
        workspaceState = next
        switch next {
        case .pairedActive:
            guard workspaceVisible, !window.isMiniaturized else { return }
            if changed || !window.isVisible || returningToPair { window.orderFrontRegardless() }
            showDividerControl()
        case .hidden, .unrelatedAppActive, .terminalMinimized, .draftMinimized, .closing:
            dividerControl.orderOut(nil)
            dividerControl.level = .normal
            if !window.isMiniaturized { window.orderOut(nil) }
        }
    }

    private func terminalFocusChanged() {
        guard !closing else { return }
        refreshWorkspaceState()
        refreshWorkspaceSoon()
    }

    private func terminalMiniaturized() {
        terminalMinimized = true
        refreshWorkspaceState()
    }

    private func terminalDeminiaturized() {
        terminalMinimized = false
        refreshWorkspaceState()
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
        positionDividerControl(in: target.screen.visibleFrame)
        applying = false
        return success
    }

    private func same(_ lhs: NSRect, _ rhs: NSRect, tolerance: CGFloat = 2) -> Bool {
        abs(lhs.minX - rhs.minX) < tolerance && abs(lhs.minY - rhs.minY) < tolerance
            && abs(lhs.width - rhs.width) < tolerance && abs(lhs.height - rhs.height) < tolerance
    }

    private func terminalChanged(_ element: AXUIElement) {
        guard !closing, workspaceVisible, !applying, layoutReady, let target,
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
    func windowDidMiniaturize(_ notification: Notification) { refreshWorkspaceState() }
    func windowDidDeminiaturize(_ notification: Notification) {
        positionDividerControl(in: target?.screen.visibleFrame ?? window.frame)
        refreshWorkspaceState()
    }

    private func previewChanged() {
        guard !closing, workspaceVisible, !applying, layoutReady, let target, let expected = previewExpected else { return }
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
        AXObserverRemoveNotification(observer, target.axWindow, kAXWindowMiniaturizedNotification as CFString)
        AXObserverRemoveNotification(observer, target.axWindow, kAXWindowDeminiaturizedNotification as CFString)
        AXObserverRemoveNotification(observer, AXUIElementCreateApplication(target.app.processIdentifier), kAXFocusedWindowChangedNotification as CFString)
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
    }

    func close() {
        guard !closing else { return }
        closing = true
        signalSource?.cancel()
        signalSource = nil
        hideSignalSource?.cancel()
        hideSignalSource = nil
        showSignalSource?.cancel()
        showSignalSource = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let deactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(deactivationObserver)
            self.deactivationObserver = nil
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
        sourceDebounce?.cancel()
        sourceDebounce = nil
        sourceWatcher?.cancel()
        sourceWatcher = nil
        stopObserving()
        restoreTerminal()
        window.removeChildWindow(dividerControl)
        try? FileManager.default.removeItem(atPath: sourcePath)
        try? FileManager.default.removeItem(atPath: sourcePath + ".tmp")
        try? FileManager.default.removeItem(atPath: commandPath)
        try? FileManager.default.removeItem(atPath: commandPath + ".tmp")
        transition(to: .closing)
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
        Darwin.signal(SIGUSR1, SIG_IGN)
        let hideSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        hideSource.setEventHandler { [weak self] in self?.hideWorkspace() }
        hideSource.resume()
        hideSignalSource = hideSource
        Darwin.signal(SIGUSR2, SIG_IGN)
        let showSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        showSource.setEventHandler { [weak self] in self?.showWorkspace() }
        showSource.resume()
        showSignalSource = showSource
    }

    func hideWorkspace() {
        guard !closing, workspaceVisible else { return }
        workspaceVisible = false
        applying = true
        restoreTerminal()
        applying = false
        dividerControl.orderOut(nil)
        window.orderOut(nil)
        transition(to: .hidden)
        writeState(pid: getpid(), terminalPID: terminalPID, status: "hidden", warning: warning, to: statePath)
    }

    func showWorkspace() {
        guard !closing, !workspaceVisible else { return }
        if let target {
            let arranged = frames(at: splitX, in: target.screen.visibleFrame)
            guard apply(arranged.terminal, arranged.preview) else { return }
            positionDividerControl(in: target.screen.visibleFrame)
        }
        workspaceVisible = true
        refreshWorkspaceState()
        writeState(pid: getpid(), terminalPID: terminalPID, status: "visible", warning: warning, to: statePath)
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
guard arguments.count == 7, let terminalPID = pid_t(arguments[5]) else {
    fputs("usage: draft-preview <html> <source> <state> <server> <nvim> <terminal-pid> <command>\n", stderr)
    exit(EXIT_FAILURE)
}
let htmlPath = arguments[0]
let sourcePath = arguments[1]
let statePath = arguments[2]
let commandPath = arguments[6]
let server = arguments[3]
let nvim = arguments[4]
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
app.setActivationPolicy(.accessory)
let terminal = terminalApplication(frontmost: NSWorkspace.shared.frontmostApplication)
let target = splitTarget(terminal: terminal, trusted: AXIsProcessTrusted())
let session = PreviewSession(url: URL(fileURLWithPath: htmlPath), sourcePath: sourcePath, statePath: statePath, commandPath: commandPath, server: server, nvim: nvim, terminal: terminal, target: target)
session.installTerminationHandler()
writeState(pid: getpid(), terminalPID: terminal?.processIdentifier ?? terminalPID, status: "initialized", to: statePath)
session.start()
DispatchQueue.main.async { session.reportVisible() }
withExtendedLifetime(session) { app.run() }
