// SPDX-License-Identifier: AGPL-3.0-only
// Manual check on a Mac: drags a picture into the Antenna window the way other apps do, and, like the screenshot
// thumbnail, deletes its file right after the drag ends. Run from Terminal with Antenna open on a conversation:
//
//   timeout 60 swift test/macos/drop_check.swift --mode url --delete-after-ms 100
//
// Modes: `url` a file URL to a temporary file, deleted N ms after the drag ends (default 0: at once); `promise` a file
// promise only (Photos, Mail); `both` a promise and a URL to a file that is deleted (the screenshot thumbnail);
// `data` PNG data only (an image dragged out of a browser or Preview). `--target X,Y` sets the drop point in screen
// coordinates (top left origin); by default it is the composer row of the Antenna window. `--app NAME` names the
// window's owner (default: Antenna, then antenna_desktop for a debug build).
//
// Terminal needs Accessibility permission (System Settings > Privacy & Security > Accessibility) to move the mouse.
// The drag ends with `operation=copy` when the window took it, and the file waits above the input as a chip. Press
// Send: `antenna history <contact> --limit 3` shows a `file: drop-check-<mode>-….png` line, and
// ~/Library/Application Support/Antenna/outgoing holds no copy any more.
import AppKit
import ApplicationServices

var mode = "url"
var deleteAfterMs = 0
var target: CGPoint?
var appNames = ["Antenna", "antenna_desktop"]
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
  let a = args.removeFirst()
  let v = args.isEmpty ? "" : args.removeFirst()
  switch a {
  case "--mode": mode = v
  case "--delete-after-ms": deleteAfterMs = Int(v) ?? 0
  case "--target":
    let xy = v.split(separator: ",").compactMap { Double($0) }
    if xy.count == 2 { target = CGPoint(x: xy[0], y: xy[1]) }
  case "--app": appNames = [v]
  default:
    print("unknown argument \(a)")
    exit(2)
  }
}
guard ["url", "promise", "both", "data"].contains(mode) else {
  print("--mode must be url, promise, both or data")
  exit(2)
}
guard AXIsProcessTrusted() else {
  print("FAIL: this terminal has no Accessibility permission (needed to move the mouse)")
  exit(3)
}

/// A 64×48 PNG.
func pngData() -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSColor.systemBlue.setFill()
  NSRect(x: 0, y: 0, width: 64, height: 48).fill()
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let stamp = Int(Date().timeIntervalSince1970)
let fileName = "drop-check-\(mode)-\(stamp).png"
let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TemporaryItems/drop-check-\(stamp)")
try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
let tempFile = tempDir.appendingPathComponent(fileName)
try! pngData().write(to: tempFile)

/// A file promise that also offers the URL of a file that will be deleted, as the screenshot thumbnail does.
final class PromiseAndURL: NSFilePromiseProvider {
  var url: URL?
  override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
    var types = super.writableTypes(for: pasteboard)
    if url != nil { types.append(.fileURL) }
    return types
  }
  override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
    if type == .fileURL { return url?.absoluteString }
    return super.pasteboardPropertyList(forType: type)
  }
}

final class Source: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
  private var started = false

  override func draw(_ dirtyRect: NSRect) {
    NSColor.systemBlue.setFill()
    bounds.fill()
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseDragged(with event: NSEvent) {
    if started { return }
    started = true
    let writer: NSPasteboardWriting
    switch mode {
    case "url":
      writer = tempFile as NSURL
    case "promise":
      writer = NSFilePromiseProvider(fileType: "public.png", delegate: self)
    case "both":
      let p = PromiseAndURL(fileType: "public.png", delegate: self)
      p.url = tempFile
      writer = p
    default:
      let item = NSPasteboardItem()
      item.setData(pngData(), forType: .png)
      writer = item
    }
    let dragged = NSDraggingItem(pasteboardWriter: writer)
    dragged.setDraggingFrame(bounds, contents: NSImage(data: pngData()))
    beginDraggingSession(with: [dragged], event: event, source: self)
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
    -> NSDragOperation
  {
    return .copy
  }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    let op = operation.isEmpty ? "none" : (operation.contains(.copy) ? "copy" : "other")
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(deleteAfterMs)) {
      try? FileManager.default.removeItem(at: tempDir)
      print("drag ended: operation=\(op); the temporary file was deleted \(deleteAfterMs) ms later")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      print(op == "copy" ? "OK: the window took the drop of \(fileName)" : "FAIL: the window refused the drop")
      exit(op == "copy" ? 0 : 1)
    }
  }

  func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
    return fileName
  }

  func filePromiseProvider(
    _ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void
  ) {
    do {
      try pngData().write(to: url)
      completionHandler(nil)
    } catch {
      completionHandler(error)
    }
  }
}

/// The Antenna window's bounds in screen coordinates (top left origin).
func antennaWindow() -> CGRect? {
  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
  for name in appNames {
    for w in list where (w[kCGWindowOwnerName as String] as? String) == name {
      if let b = w[kCGWindowBounds as String] as? [String: CGFloat], let width = b["Width"], width > 400 {
        return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: width, height: b["Height"] ?? 0)
      }
    }
  }
  return nil
}

func post(_ type: CGEventType, _ p: CGPoint) {
  CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = NSWindow(
  contentRect: NSRect(x: 40, y: screen.height - 160, width: 80, height: 80), styleMask: [.borderless],
  backing: .buffered, defer: false)
window.level = .floating
window.contentView = Source(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
window.orderFrontRegardless()

guard let drop = target ?? antennaWindow().map({ CGPoint(x: $0.minX + $0.width * 0.62, y: $0.maxY - 80) }) else {
  print("FAIL: no Antenna window on screen (or pass --target X,Y)")
  exit(4)
}
print("mode=\(mode) file=\(tempFile.path) drop at \(Int(drop.x)),\(Int(drop.y))")
let start = CGPoint(x: 80, y: 120)
DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
  post(.mouseMoved, start)
  usleep(100_000)
  post(.leftMouseDown, start)
  usleep(100_000)
  for i in 1...30 {
    let t = CGFloat(i) / 30
    post(.leftMouseDragged, CGPoint(x: start.x + (drop.x - start.x) * t, y: start.y + (drop.y - start.y) * t))
    usleep(20_000)
  }
  usleep(300_000)
  post(.leftMouseUp, drop)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
  print("FAIL: the drag never ended")
  exit(5)
}
app.run()
