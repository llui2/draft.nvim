import AppKit
import WebKit

final class PreviewWindow: NSObject, NSWindowDelegate {
    let window: NSWindow

    init(url: URL) {
        let webView = WKWebView(frame: .zero)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.contentView = webView
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let path = CommandLine.arguments.last!
let preview = PreviewWindow(url: URL(fileURLWithPath: path))
withExtendedLifetime(preview) {
    app.run()
}
