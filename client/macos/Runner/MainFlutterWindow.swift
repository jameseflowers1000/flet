import Cocoa
import FlutterMacOS
import WebKit

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController.init()
    flutterViewController.backgroundColor = .clear
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  // ── Key equivalent routing ────────────────────────────────────
  // Flutter's FlutterViewWrapper.performKeyEquivalent intercepts ALL
  // Cmd+key events and routes them through the Dart framework, even
  // when a platform view (WKWebView) is the macOS first responder.
  // Regular keyDown events reach the WKWebView correctly, but key
  // equivalents (Cmd+V, Cmd+C, etc.) never do.
  //
  // Fix: if the first responder is inside a WKWebView, route the
  // key equivalent directly to the WKWebView before Flutter can
  // intercept it.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if let responder = firstResponder as? NSView,
       let wk = ancestorWKWebView(of: responder) {
      // For Cmd+V, use the paste: action (same path as right-click → Paste)
      // because WKWebView.performKeyEquivalent doesn't reliably trigger
      // the JavaScript paste event in the web content.
      if event.modifierFlags.contains(.command),
         let chars = event.charactersIgnoringModifiers,
         chars == "v" {
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        return true
      }
      // Other key equivalents (Cmd+C, Cmd+A, etc.)
      if wk.performKeyEquivalent(with: event) {
        return true
      }
    }
    return super.performKeyEquivalent(with: event)
  }

  // ── Clipboard preservation across first responder changes ─────
  // When Flutter's text editing system loses first responder (e.g.,
  // user clicks on a WKWebView terminal), Flutter/SelectableText may
  // clear its text selection, which on macOS writes empty content to
  // the system pasteboard — destroying whatever the user just copied.
  //
  // Fix: snapshot the pasteboard before first responder changes and
  // restore it if the transition cleared it.
  private var _savedClipboard: String?

  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    // Snapshot current clipboard
    _savedClipboard = NSPasteboard.general.string(forType: .string)

    let result = super.makeFirstResponder(responder)

    // Check if the transition cleared the clipboard and restore if so
    if let saved = _savedClipboard, !saved.isEmpty {
      DispatchQueue.main.async {
        let current = NSPasteboard.general.string(forType: .string)
        if current == nil || current!.isEmpty {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(saved, forType: .string)
        }
      }
    }
    _savedClipboard = nil

    return result
  }

  /// Walk up from a view to find an enclosing WKWebView.
  private func ancestorWKWebView(of view: NSView) -> WKWebView? {
    var current: NSView? = view
    while let v = current {
      if let wk = v as? WKWebView { return wk }
      current = v.superview
    }
    return nil
  }

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
