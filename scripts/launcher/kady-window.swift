// kady-window — minimal native browser window for the Kady launcher.
// Usage: kady-window <url>
// A plain WKWebView in an NSWindow; the process exits when the window
// closes (the supervisor treats that as "app quit") or on SIGTERM.
// Navigation failures show a small "connecting" page and retry forever —
// transient backend gaps must not leave the user staring at a dead pane.
import Cocoa
import WebKit

final class Delegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
	var webView: WKWebView?
	var targetURL: URL?
	private var retryAttempt = 0
	private var retryWork: DispatchWorkItem?
	private var showingRetryPage = false
	private var lastExternalOpen: (url: URL, at: Date)?

	func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
		return true
	}

	func load() {
		guard let url = targetURL else { return }
		showingRetryPage = false
		webView?.load(URLRequest(url: url))
	}

	func webView(_: WKWebView, didFinish _: WKNavigation!) {
		// loadHTMLString also produces didFinish; only a real navigation resets
		// the backoff.
		if !showingRetryPage { retryAttempt = 0 }
	}

	func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
		scheduleRetry(error)
	}

	func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
		scheduleRetry(error)
	}

	// WKWebView does not open a native file picker by itself in a bare AppKit
	// shell; connect <input type=file> (including webkitdirectory) to NSOpenPanel.
	func webView(
		_ webView: WKWebView,
		runOpenPanelWith parameters: WKOpenPanelParameters,
		initiatedByFrame _: WKFrameInfo,
		completionHandler: @escaping ([URL]?) -> Void
	) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = parameters.allowsDirectories
		panel.allowsMultipleSelection = parameters.allowsMultipleSelection
		panel.prompt = parameters.allowsDirectories ? "Choose Folder" : "Choose File"

		if let window = webView.window {
			panel.beginSheetModal(for: window) { response in
				completionHandler(response == .OK ? panel.urls : nil)
			}
		} else {
			completionHandler(panel.runModal() == .OK ? panel.urls : nil)
		}
	}

	// WKWebView cannot create a browser window by itself. Return nil after
	// delegating the request to the user's default browser.
	func webView(
		_: WKWebView,
		createWebViewWith _: WKWebViewConfiguration,
		for navigationAction: WKNavigationAction,
		windowFeatures _: WKWindowFeatures
	) -> WKWebView? {
		openExternally(navigationAction.request.url)
		return nil
	}

	func webView(
		_: WKWebView,
		decidePolicyFor navigationAction: WKNavigationAction,
		decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
	) {
		if navigationAction.targetFrame == nil {
			openExternally(navigationAction.request.url)
			decisionHandler(.cancel)
			return
		}
		decisionHandler(.allow)
	}

	private func openExternally(_ url: URL?) {
		guard let url,
			  let scheme = url.scheme?.lowercased(),
			  ["http", "https", "mailto"].contains(scheme)
		else { return }

		// WebKit can report one popup through both WKUIDelegate and navigation
		// policy; suppress that duplicate hand-off.
		if let last = lastExternalOpen,
		   last.url == url,
		   Date().timeIntervalSince(last.at) < 1
		{
			return
		}
		lastExternalOpen = (url, Date())
		NSWorkspace.shared.open(url)
	}

	private func scheduleRetry(_ error: Error) {
		// Aborted navigations (reloads, shutdown) are not failures.
		if (error as NSError).code == NSURLErrorCancelled { return }
		retryAttempt += 1
		showRetryPage()
		retryWork?.cancel()
		let delay = min(15.0, pow(2.0, Double(min(retryAttempt, 4)))) // 2,4,8,15,15…
		let work = DispatchWorkItem { [weak self] in self?.load() }
		retryWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
	}

	private func showRetryPage() {
		showingRetryPage = true
		let html = """
		<!doctype html><meta charset="utf-8"><title>Kady</title>
		<style>
		  body { font: 14px -apple-system, sans-serif; display: flex; height: 100vh;
		         margin: 0; align-items: center; justify-content: center;
		         flex-direction: column; color: #555; background: #fafafa; }
		  .dot { animation: pulse 1.2s infinite; font-size: 40px; margin-bottom: 16px; }
		  @keyframes pulse { 0%,100% { opacity: .3 } 50% { opacity: 1 } }
		</style>
		<div class="dot">●</div>
		<div>Connecting to Kady…</div>
		<div style="margin-top:8px;color:#888">Kady is still starting or the connection dropped. Retrying automatically.</div>
		"""
		webView?.loadHTMLString(html, baseURL: nil)
	}
}

guard CommandLine.arguments.count > 1, let url = URL(string: CommandLine.arguments[1]) else {
	FileHandle.standardError.write("usage: kady-window <url>\n".data(using: .utf8)!)
	exit(2)
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
// No Dock icon or menu-bar presence of its own — Kady.app owns those.
app.setActivationPolicy(.accessory)

// Minimal menus so standard shortcuts (Cmd+Q/W, copy/paste, undo) behave.
let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Kady", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu

let editItem = NSMenuItem()
mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(NSMenuItem.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu

let windowItem = NSMenuItem()
mainMenu.addItem(windowItem)
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
windowItem.submenu = windowMenu
app.mainMenu = mainMenu
app.windowsMenu = windowMenu

let window = NSWindow(
	contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
	styleMask: [.titled, .closable, .miniaturizable, .resizable],
	backing: .buffered,
	defer: false
)
window.title = "Kady"
window.minSize = NSSize(width: 720, height: 480)

let webView = WKWebView(frame: window.contentView!.bounds)
webView.autoresizingMask = [.width, .height]
webView.navigationDelegate = delegate
webView.uiDelegate = delegate
window.contentView!.addSubview(webView)

delegate.webView = webView
delegate.targetURL = url

window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

// The supervisor sends SIGUSR1 when the user clicks Kady's Dock icon while the
// window already exists; activating here avoids both a duplicate window and
// Accessibility permissions for GUI scripting.
signal(SIGUSR1, SIG_IGN)
let reopenSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
reopenSource.setEventHandler {
	window.deminiaturize(nil)
	window.makeKeyAndOrderFront(nil)
	app.activate(ignoringOtherApps: true)
}
reopenSource.resume()

delegate.load()
app.run()
