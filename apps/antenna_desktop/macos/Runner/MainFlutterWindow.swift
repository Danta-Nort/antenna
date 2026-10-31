// SPDX-License-Identifier: AGPL-3.0-only
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// The title bar in the app's own theme (lib/host/window_chrome.dart).
  private var chromeChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Drops and pasted text from other apps for the composer (ComposerInput.swift); after the plugins, so the drop
    // view sits over desktop_drop's.
    AntennaDropView.install(over: flutterViewController)
    AntennaPaste.shared.attach(to: flutterViewController.engine.binaryMessenger)
    AntennaClipboard.attach(to: flutterViewController.engine.binaryMessenger)

    // Touch ID for owner commands (TouchID.swift, D-102): Secure Enclave keys the window enrolls with the daemon.
    AntennaTouchID.shared.attach(to: flutterViewController.engine.binaryMessenger)

    // Screen Recording, checked before the screenshot tool runs (ScreenAccess.swift).
    AntennaScreenAccess.shared.attach(to: flutterViewController.engine.binaryMessenger)

    // antenna:// invite links go to the window (AppDelegate.links).
    if let app = NSApp.delegate as? AppDelegate {
      app.links.attach(to: flutterViewController.engine.binaryMessenger)
    }

    // The title bar follows the app theme (light by default, dark from the system or the user's choice);
    // the minimum size fits the navigation, the chat list and the conversation.
    self.titlebarAppearsTransparent = true
    self.backgroundColor = NSColor.windowBackgroundColor
    self.minSize = NSSize(width: 960, height: 640)

    // AppKit draws the title bar from the system's appearance; the app may be light under a dark system (or the other
    // way round), so the window takes the app's theme and the navigation's color from the app instead.
    let chrome = FlutterMethodChannel(
      name: "antenna/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    chrome.setMethodCallHandler { [weak self] call, result in
      guard call.method == "chrome", let args = call.arguments as? [String: Any],
        let dark = args["dark"] as? Bool, let argb = args["color"] as? Int
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      self?.backgroundColor = NSColor(
        srgbRed: CGFloat((argb >> 16) & 0xff) / 255, green: CGFloat((argb >> 8) & 0xff) / 255,
        blue: CGFloat(argb & 0xff) / 255, alpha: 1)
      result(nil)
    }
    chromeChannel = chrome

    super.awakeFromNib()
  }
}
