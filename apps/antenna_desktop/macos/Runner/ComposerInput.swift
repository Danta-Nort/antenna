// SPDX-License-Identifier: AGPL-3.0-only
// What the composer receives from other apps on macOS: drops (files, file promises, image data), pasted text and
// clipboard images. The window's side: lib/host/window_drop.dart, lib/host/paste.dart, lib/host/outgoing_staging.dart.
import Cocoa
import Darwin
import FlutterMacOS
import ObjectiveC

/// Drops onto the window, over the `antenna/drop` channel. A dragged file may vanish as soon as the drop ends: the
/// screenshot thumbnail offers a file in TemporaryItems and deletes it then, and `desktop_drop` hands paths to Dart only
/// after that. Here everything is staged before `performDragOperation` returns: file promises are received into the
/// window's staging folder, files are cloned there (APFS: instant, no extra space) or copied when small, image data is
/// written as a file. The window sends the copies and deletes them afterwards.
final class AntennaDropView: NSView {
  /// A file that cannot be cloned (another volume) is copied only up to this size, as in OutgoingStaging; a larger
  /// one is sent from where it is.
  private static let copyLimit = 64 << 20
  private static let legacyFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
  private static let jpeg = NSPasteboard.PasteboardType("public.jpeg")

  private let channel: FlutterMethodChannel
  private var stagingRoot: URL
  private let promiseQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.qualityOfService = .userInitiated
    return queue
  }()

  /// Put the view over the Flutter view as the only one that takes drops: `desktop_drop` adds a view of its own when
  /// the plugins are registered (the Linux window keeps using that plugin).
  static func install(over controller: FlutterViewController) {
    let view = AntennaDropView(frame: controller.view.bounds, messenger: controller.engine.binaryMessenger)
    for other in controller.view.subviews where !other.registeredDraggedTypes.isEmpty {
      other.unregisterDraggedTypes()
    }
    controller.view.addSubview(view)
  }

  private init(frame: NSRect, messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "antenna/drop", binaryMessenger: messenger)
    // The window sends its own path (`setStagingRoot`); this is the same default, for drops before it does.
    stagingRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Antenna/outgoing", isDirectory: true)
    super.init(frame: frame)
    autoresizingMask = [.width, .height]
    var types = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    types += [.fileURL, AntennaDropView.legacyFilenames, .png, .tiff, AntennaDropView.jpeg]
    registerForDraggedTypes(types)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setStagingRoot", let path = call.arguments as? String, let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.stagingRoot = URL(fileURLWithPath: path, isDirectory: true)
      result(nil)
    }
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    channel.invokeMethod("entered", arguments: point(sender))
    return .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    channel.invokeMethod("updated", arguments: point(sender))
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    channel.invokeMethod("exited", arguments: nil)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let pasteboard = sender.draggingPasteboard
    let at = point(sender)
    // The hover hint goes away now; promised files may take a while to arrive.
    channel.invokeMethod("exited", arguments: nil)
    // Promises first: a source that offers both (the screenshot thumbnail) writes a fresh file for us, while its file
    // URL is the one it deletes when the drag ends.
    let receivers =
      pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    if !receivers.isEmpty {
      receive(receivers, at: at)
      return true
    }
    var items: [[String: Any]] = []
    var seen = Set<String>()
    let urls =
      pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    let legacy = (pasteboard.propertyList(forType: AntennaDropView.legacyFilenames) as? [String] ?? [])
      .map { URL(fileURLWithPath: $0) }
    for url in urls + legacy where seen.insert(url.path).inserted {
      items.append(stage(url))
    }
    if items.isEmpty, let image = stageImage(pasteboard) {
      items.append(image)
    }
    if items.isEmpty {
      return false
    }
    report(items, failed: 0, at: at)
    return true
  }

  /// A dropped file as the window will send it: a clone or a copy in the staging folder, or the original path for a
  /// folder, a large file on another volume, or a file that cannot be copied (the daemon then says what is wrong).
  private func stage(_ url: URL) -> [String: Any] {
    let original: [String: Any] = ["path": url.path, "staged": false]
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true, let dir = makeItemDir() else {
      return original
    }
    let dest = dir.appendingPathComponent(url.lastPathComponent)
    if clonefile(url.path, dest.path, 0) == 0 {
      return ["path": dest.path, "staged": true]
    }
    if let size = values?.fileSize, size <= AntennaDropView.copyLimit,
      (try? FileManager.default.copyItem(at: url, to: dest)) != nil
    {
      return ["path": dest.path, "staged": true]
    }
    try? FileManager.default.removeItem(at: dir)
    return original
  }

  /// Image data dragged without a file (a selection from Preview, an image from some browsers), written as a file.
  private func stageImage(_ pasteboard: NSPasteboard) -> [String: Any]? {
    var data: Data?
    var ext = "png"
    if let png = pasteboard.data(forType: .png) {
      data = png
    } else if let jpeg = pasteboard.data(forType: AntennaDropView.jpeg) {
      data = jpeg
      ext = "jpg"
    } else if let tiff = pasteboard.data(forType: .tiff) {
      data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
    guard let bytes = data, !bytes.isEmpty, let dir = makeItemDir() else {
      return nil
    }
    let dest = dir.appendingPathComponent("\(AntennaDropView.imageName()).\(ext)")
    do {
      try bytes.write(to: dest, options: .withoutOverwriting)
      return ["path": dest.path, "staged": true]
    } catch {
      try? FileManager.default.removeItem(at: dir)
      return nil
    }
  }

  /// File promises (screenshots, Photos, Mail, browsers): each file is reported when the source has written it, which
  /// may take a while (Photos exports the original).
  private func receive(_ receivers: [NSFilePromiseReceiver], at: [CGFloat]) {
    for receiver in receivers {
      guard let dir = makeItemDir() else {
        report([], failed: 1, at: at)
        continue
      }
      receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: promiseQueue) {
        [weak self] url, error in
        DispatchQueue.main.async {
          if error == nil {
            self?.report([["path": url.path, "staged": true]], failed: 0, at: at)
          } else {
            self?.report([], failed: 1, at: at)
          }
        }
      }
    }
  }

  /// A new 0700 folder for one drop item inside the staging folder. A staging folder that is a symlink or a file is
  /// refused (the copies would land somewhere else).
  private func makeItemDir() -> URL? {
    let fm = FileManager.default
    if let type = (try? fm.attributesOfItem(atPath: stagingRoot.path))?[.type] as? FileAttributeType,
      type != .typeDirectory
    {
      return nil
    }
    let dir = stagingRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    do {
      try fm.createDirectory(
        at: stagingRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      return dir
    } catch {
      return nil
    }
  }

  private func report(_ items: [[String: Any]], failed: Int, at: [CGFloat]) {
    let args: [String: Any] = ["x": at[0], "y": at[1], "items": items, "failed": failed]
    channel.invokeMethod("dropped", arguments: args)
  }

  /// Window coordinates from the top left, in points (Flutter's logical pixels).
  private func point(_ sender: NSDraggingInfo) -> [CGFloat] {
    let p = convert(sender.draggingLocation, from: nil)
    return [p.x, bounds.height - p.y]
  }

  /// `image-2026-10-05-140322`, like `stagedImageName` in outgoing_staging.dart.
  private static func imageName() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return "image-\(formatter.string(from: Date()))"
  }
}

/// Text from dictation apps, clipboard managers and text expanders, over the `antenna/paste` channel. They put text
/// on the pasteboard and post a Cmd+V whose Command exists only in the event's flags, with no Command key press before
/// it. Flutter 3.47 drops that event (flutter/flutter#184571) and it ends in Edit > Paste, which changes only the text
/// view the engine keeps for accessibility, so the text disappears. Such a Cmd+V is caught here before Flutter sees it;
/// the pasteboard text, read at once because the app may put the old clipboard back a moment later, goes to the window,
/// which inserts it at the cursor. A Cmd+V typed on the keyboard has a Command press before it and stays on Flutter's
/// own path.
final class AntennaPaste {
  static let shared = AntennaPaste()

  private var channel: FlutterMethodChannel?
  private var monitor: Any?
  private var resignObserver: NSObjectProtocol?
  /// Command is down as far as the event stream says (flagsChanged), which is what Flutter's keyboard state follows.
  private var commandPressed = false
  /// The key-up of a caught Cmd+V: Flutter never saw its key-down.
  private var swallowKeyUp: UInt16?

  func attach(to messenger: FlutterBinaryMessenger) {
    if channel != nil {
      return
    }
    channel = FlutterMethodChannel(name: "antenna/paste", binaryMessenger: messenger)
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
      guard let self = self else {
        return event
      }
      return self.filter(event)
    }
    // A Command release in another app never reaches this one.
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.commandPressed = false
    }
    AntennaPaste.routeTextViewActions()
  }

  private func filter(_ event: NSEvent) -> NSEvent? {
    switch event.type {
    case .flagsChanged:
      commandPressed = event.modifierFlags.contains(.command)
      return event
    case .keyUp:
      if swallowKeyUp == event.keyCode {
        swallowKeyUp = nil
        return nil
      }
      return event
    case .keyDown:
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard flags.contains(.command), flags.isDisjoint(with: [.shift, .option, .control]), !commandPressed,
        AntennaPaste.isV(event)
      else {
        return event
      }
      swallowKeyUp = event.keyCode
      send()
      return nil
    default:
      return event
    }
  }

  /// The V key: by its character, or by its position (kVK_ANSI_V) when the layout types a non-Latin letter there
  /// (the Russian layout types U+043C there); Command shortcuts keep the Latin positions.
  private static func isV(_ event: NSEvent) -> Bool {
    let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
    if chars == "v" {
      return true
    }
    return event.keyCode == 9 && (chars.isEmpty || !chars.unicodeScalars.allSatisfy { $0.isASCII })
  }

  /// Read the pasteboard text now and hand it to the window.
  func send() {
    var args: [String: Any] = [:]
    if let text = NSPasteboard.general.string(forType: .string) {
      args["text"] = text
    }
    channel?.invokeMethod("paste", arguments: args)
  }

  /// Edit > Paste clicked in the menu bar sends `paste:` to the first responder, `FlutterTextInputPlugin`: an
  /// NSTextView the engine keeps for accessibility, whose inherited `paste:` changes only that view
  /// (flutter/flutter#184571). An accessibility client that sets AXSelectedText (some dictation tools) lands in the
  /// same view (flutter/flutter#191503). Give that class its own `paste:` and `pasteAsPlainText:`, which go to the
  /// window like a caught Cmd+V, and a selected-text setter that inserts like typing (`insertText:replacementRange:`,
  /// the path macOS Dictation takes). `class_addMethod` never replaces a method the class defines itself, so a Flutter
  /// release with its own fix keeps it.
  private static func routeTextViewActions() {
    guard let cls = NSClassFromString("FlutterTextInputPlugin") else {
      return
    }
    let paste: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in
      AntennaPaste.shared.send()
    }
    let pasteImp = imp_implementationWithBlock(unsafeBitCast(paste, to: AnyObject.self))
    for name in ["paste:", "pasteAsPlainText:"] {
      class_addMethod(cls, NSSelectorFromString(name), pasteImp, "v@:@")
    }
    let setSelectedText: @convention(block) (AnyObject, AnyObject?) -> Void = { target, value in
      guard let text = value as? String, let client = target as? NSTextInputClient else {
        return
      }
      client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    class_addMethod(
      cls, NSSelectorFromString("setAccessibilitySelectedText:"),
      imp_implementationWithBlock(unsafeBitCast(setSelectedText, to: AnyObject.self)), "v@:@")
  }
}

/// Image data on the clipboard for the composer's paste (lib/host/paste.dart, `ClipboardImages`), over
/// `antenna/clipboard`: `image` → PNG bytes, or nil when the pasteboard holds no image. Flutter's clipboard API is text
/// only.
enum AntennaClipboard {
  private static var channel: FlutterMethodChannel?

  static func attach(to messenger: FlutterBinaryMessenger) {
    if channel != nil {
      return
    }
    let ch = FlutterMethodChannel(name: "antenna/clipboard", binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      guard call.method == "image" else {
        result(FlutterMethodNotImplemented)
        return
      }
      if let png = imagePNG(NSPasteboard.general) {
        result(FlutterStandardTypedData(bytes: png))
      } else {
        result(nil)
      }
    }
    channel = ch
  }

  /// PNG as it is; another image type (TIFF from screenshots and Preview, JPEG, HEIC) is re-encoded as PNG.
  static func imagePNG(_ pasteboard: NSPasteboard) -> Data? {
    if let png = pasteboard.data(forType: .png), !png.isEmpty {
      return png
    }
    let others: [NSPasteboard.PasteboardType] = [
      .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ]
    for type in others {
      if let data = pasteboard.data(forType: type), let rep = NSBitmapImageRep(data: data),
        let png = rep.representation(using: .png, properties: [:])
      {
        return png
      }
    }
    return nil
  }
}
