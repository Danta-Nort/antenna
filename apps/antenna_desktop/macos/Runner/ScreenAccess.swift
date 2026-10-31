// SPDX-License-Identifier: AGPL-3.0-only
// Screen Recording for the screenshot tool (D-UI-27, D-UI-41): the permission's real state over the `antenna/screen`
// channel, read before the window runs `screencapture -i`. The Dart side is lib/host/screen_permission.dart.
//
// - `preflight`: CGPreflightScreenCaptureAccess() (macOS 10.15+), which never shows a prompt. macOS answers for this
//   build only: it keeps the grant with the app's designated requirement, and an ad-hoc signature's requirement is its
//   cdhash (Apple TN3127), so after an update the switch in System Settings can be on for the previous build. The answer
//   is cached for the life of the process: a grant made while the app runs is seen after a restart.
// - `request`: CGRequestScreenCaptureAccess() (macOS 10.15+), which shows macOS's own question at most once for this
//   build and puts the app into the list in System Settings; it returns at once with the current state.
// Both reply with a Bool. Nothing else is read or kept.
import Cocoa
import CoreGraphics
import FlutterMacOS

final class AntennaScreenAccess {
  static let shared = AntennaScreenAccess()

  private var channel: FlutterMethodChannel?

  func attach(to messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "antenna/screen", binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "preflight": result(CGPreflightScreenCaptureAccess())
      case "request": result(CGRequestScreenCaptureAccess())
      default: result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }
}
