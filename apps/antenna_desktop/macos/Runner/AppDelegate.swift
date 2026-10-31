// SPDX-License-Identifier: AGPL-3.0-only
import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Invite links antenna://pair#… (scheme declared in CFBundleURLTypes in Info.plist) queue up here; the window
  /// takes them over the antenna/links channel (lib/host/links.dart). Registered before launch so that the link
  /// the system launched the app with is not lost.
  let links = AntennaLinks()

  override init() {
    super.init()
    addApplicationLifecycleDelegate(links)
  }

  /// Fallback in case the window did not attach the channel while loading (MainFlutterWindow.awakeFromNib).
  override func applicationDidFinishLaunching(_ notification: Notification) {
    // No super call: FlutterAppDelegate does not implement this protocol method (it only declares it via NSApplicationDelegate).
    if let vc = mainFlutterWindow?.contentViewController as? FlutterViewController {
      links.attach(to: vc.engine.binaryMessenger)
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

/// Receives links from FlutterAppDelegate (application:openURLs: → handleOpenURLs:).
final class AntennaLinks: NSObject, FlutterAppLifecycleDelegate {
  private var pending: [String] = []
  private var channel: FlutterMethodChannel?

  /// Channel to the window: `takePending` returns the queued links; `linksAvailable` nudges the window.
  func attach(to messenger: FlutterBinaryMessenger) {
    if channel != nil {
      return
    }
    let ch = FlutterMethodChannel(name: "antenna/links", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      guard call.method == "takePending", let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self.pending)
      self.pending.removeAll()
    }
    channel = ch
  }

  @objc(handleOpenURLs:)
  func handleOpen(_ urls: [URL]) -> Bool {
    let mine = urls.filter { $0.scheme?.lowercased() == "antenna" }.map { $0.absoluteString }
    if mine.isEmpty {
      return false
    }
    pending.append(contentsOf: mine)
    channel?.invokeMethod("linksAvailable", arguments: nil)
    return true
  }
}
