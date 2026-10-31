// SPDX-License-Identifier: AGPL-3.0-only
// Manual check on a Mac: inserts text into the focused Antenna composer the way dictation apps, clipboard managers and
// text expanders do, then presses Return so the text is sent and can be read back with the CLI. Run from Terminal
// with Antenna in front and the cursor in the composer (click into it first):
//
//   timeout 60 swift test/macos/paste_check.swift --shape flags-only --text "dictated text 123"
//
// Shapes:
//   flags-only  Cmd+V with Command only in the event's flags, no Command key press around it (Superwhisper, Wispr
//               Flow, Raycast): the event Flutter 3.47 drops by itself.
//   discrete    Command down, V down/up, Command up (what `osascript … keystroke "v" using command down` posts).
//   ax          no key events: sets AXSelectedText on the focused element (accessibility clients such as Typeless).
// Options: `--types plain|rich` (`rich` also puts public.rtf, public.html and a private type on the pasteboard, as
// many apps do), `--image FILE.png` (PNG data and no text on the pasteboard: the composer attaches it, Return sends
// it, and the history shows `file: image-….png`), `--restore-after-ms N` (put the previous clipboard back N ms after
// the paste, like Superwhisper's "Restore clipboard"), `--no-send` (leave the text in the composer instead of pressing
// Return), `--app NAME` (default Antenna, then antenna_desktop).
//
// Terminal needs Accessibility permission (System Settings > Privacy & Security > Accessibility) to post key events
// and to use the accessibility API. Then `antenna history <contact> --limit 1` shows the text as the last message.
import AppKit
import ApplicationServices

var shape = "flags-only"
var text = "dictated text 123"
var types = "plain"
var restoreAfterMs = -1
var image: String?
var send = true
var appNames = ["Antenna", "antenna_desktop"]
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
  let a = args.removeFirst()
  if a == "--no-send" {
    send = false
    continue
  }
  let v = args.isEmpty ? "" : args.removeFirst()
  switch a {
  case "--shape": shape = v
  case "--text": text = v
  case "--types": types = v
  case "--image": image = v
  case "--restore-after-ms": restoreAfterMs = Int(v) ?? -1
  case "--app": appNames = [v]
  default:
    print("unknown argument \(a)")
    exit(2)
  }
}
guard AXIsProcessTrusted() else {
  print("FAIL: this terminal has no Accessibility permission")
  exit(3)
}
guard
  let target = NSWorkspace.shared.runningApplications.first(where: { appNames.contains($0.localizedName ?? "") })
else {
  print("FAIL: Antenna is not running")
  exit(4)
}
target.activate()
usleep(500_000)

let kVKV: CGKeyCode = 9
let kVKCommand: CGKeyCode = 55
let kVKReturn: CGKeyCode = 36

/// A key event; a [modifier] key goes out as flagsChanged, as a keyboard sends it.
func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = [], modifier: Bool = false) {
  let source = CGEventSource(stateID: .combinedSessionState)
  guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
  if modifier {
    e.type = .flagsChanged
  }
  e.flags = flags
  e.post(tap: .cghidEventTap)
  usleep(20_000)
}

let pb = NSPasteboard.general
let previous = pb.string(forType: .string)
func setClipboard() {
  pb.clearContents()
  if let path = image {
    guard let data = FileManager.default.contents(atPath: path) else {
      print("FAIL: cannot read \(path)")
      exit(2)
    }
    pb.setData(data, forType: .png)
    return
  }
  pb.setString(text, forType: .string)
  if types == "rich" {
    let rtf = "{\\rtf1\\ansi {\\b \(text)}}"
    pb.setData(rtf.data(using: .utf8), forType: .rtf)
    pb.setString("<b>\(text)</b>", forType: .html)
    pb.setData(Data("private".utf8), forType: NSPasteboard.PasteboardType("com.example.dictation.private"))
  }
}

switch shape {
case "flags-only":
  setClipboard()
  key(kVKV, down: true, flags: .maskCommand)
  key(kVKV, down: false, flags: .maskCommand)
case "discrete":
  setClipboard()
  key(kVKCommand, down: true, flags: .maskCommand, modifier: true)
  key(kVKV, down: true, flags: .maskCommand)
  key(kVKV, down: false, flags: .maskCommand)
  key(kVKCommand, down: false, modifier: true)
case "ax":
  let app = AXUIElementCreateApplication(target.processIdentifier)
  var focused: CFTypeRef?
  let got = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
  guard got == .success, let element = focused else {
    print("FAIL: no focused accessibility element (AXError \(got.rawValue))")
    exit(5)
  }
  var role: CFTypeRef?
  AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
  let set = AXUIElementSetAttributeValue(
    element as! AXUIElement, kAXSelectedTextAttribute as CFString, text as CFString)
  print("focused role=\(role as? String ?? "?"); set AXSelectedText → AXError \(set.rawValue)")
default:
  print("--shape must be flags-only, discrete or ax")
  exit(2)
}

if restoreAfterMs >= 0 {
  usleep(useconds_t(restoreAfterMs * 1000))
  pb.clearContents()
  pb.setString(previous ?? "", forType: .string)
  print("clipboard restored after \(restoreAfterMs) ms")
}
usleep(600_000)
if send {
  key(kVKReturn, down: true)
  key(kVKReturn, down: false)
  print("sent with Return: check `antenna history <contact> --limit 1` for \"\(text)\"")
} else {
  print("left in the composer: check that it shows \"\(text)\" at the cursor")
}
