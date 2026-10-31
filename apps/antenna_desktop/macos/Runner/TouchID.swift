// SPDX-License-Identifier: AGPL-3.0-only
// Touch ID for owner commands (D-102, CONTROL §22, experimental): the window's Secure Enclave keys over the
// `antenna/touchid` channel. The Dart side is lib/host/touch_id.dart.
//
// - Two CryptoKit Secure Enclave P-256 keys per daemon folder: a signing key (the owner key the daemon enrolls) and a
//   key-agreement key (the unlock slot's key is sealed to it with HPKE). Both are made with `.privateKeyUsage` +
//   `.biometryCurrentSet` and `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: each use needs a touch of a finger that
//   was enrolled when the key was made, and adding or removing a fingerprint kills the key. Never `.userPresence`: the
//   Mac's password must not approve.
// - The keys are kept as their `dataRepresentation` (a blob wrapped by this Mac's Secure Enclave, useless elsewhere)
//   in the folder the window passes (0700, files 0600). No keychain item: an ad-hoc signed app has no access group for
//   biometric items (D-102). Any process of the user that reads a blob can ask the
//   Secure Enclave to use it; each use still needs the touch (CONTROL §22.6).
// - Every prompt starts from a click in the window. A fresh LAContext per prompt, evaluated for biometrics only (no
//   "Enter Password" fallback), with the request's own words as its reason. The one reuse: `openSlot` keeps its
//   evaluated context for ONE following `sign` with `reuse` within 30 s, so unlocking and signing in are one touch.
// - The proof's message is built here, so the window needs no cryptography of its own:
//   "antenna/owner-proof/v1" ‖ 0x00 ‖ nonce (32 bytes) ‖ SHA-256(request's UTF-8 bytes), signed with ECDSA P-256 /
//   SHA-256 (CryptoKit hashes the message), returned as base64 of the 64-byte r ‖ s.
// Errors are FlutterError codes: cancelled, unavailable, lockout, key_invalidated, not_enrolled, failed. Nothing here
// logs a key, a slot key, a request or a signature.
import Cocoa
import CryptoKit
import Darwin
import FlutterMacOS
import LocalAuthentication

private struct TouchIDError: Error {
  let code: String
  let message: String
  init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
}

final class AntennaTouchID {
  static let shared = AntennaTouchID()

  private static let proofLabel = Data("antenna/owner-proof/v1".utf8)
  private static let hpkeInfo = Data("antenna/keyslot/v1/hpke".utf8)
  private static let reuseWindow: TimeInterval = 30
  private static let signingFile = "signing.key"
  private static let agreementFile = "agreement.key"
  private static let domainFile = "domain.state"
  private static let slotFile = "slot.sealed"

  private var channel: FlutterMethodChannel?
  /// Secure Enclave work blocks while the prompt is up: never on the main thread. Serial, so `reusable` needs no lock.
  private let queue = DispatchQueue(label: "io.github.danta-nort.antenna.touchid")
  /// The context `openSlot` evaluated, for one `sign` with `reuse` before `until`.
  private var reusable: (context: LAContext, until: Date)?

  func attach(to messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "antenna/touchid", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      let method = call.method
      let args = call.arguments as? [String: Any] ?? [:]
      self.queue.async {
        let reply: Any?
        do {
          reply = try self.handle(method, args)
        } catch let e as TouchIDError {
          reply = FlutterError(code: e.code, message: e.message, details: nil)
        } catch {
          reply = FlutterError(code: "failed", message: String(describing: type(of: error)), details: nil)
        }
        DispatchQueue.main.async { result(reply) }
      }
    }
    channel = ch
  }

  private func handle(_ method: String, _ args: [String: Any]) throws -> Any? {
    switch method {
    case "status": return try status(folder(args))
    case "create": return try create(folder(args))
    case "sign": return try sign(folder(args), args)
    case "seal": return try seal(folder(args), args)
    case "openSlot": return try openSlot(folder(args), args)
    case "delete": return try delete(folder(args))
    default: return FlutterMethodNotImplemented
    }
  }

  // MARK: Methods

  private func status(_ dir: URL) -> [String: Any] {
    var out: [String: Any] = [
      "available": false,
      "hpke": AntennaTouchID.hpkeSupported,
      "enrolled": exists(dir, Self.signingFile) && exists(dir, Self.agreementFile),
      "domainChanged": false,
    ]
    guard SecureEnclave.isAvailable else {
      out["reason"] = "no_secure_enclave"
      return out
    }
    let context = LAContext()
    var error: NSError?
    if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
      out["available"] = true
    } else {
      out["reason"] = error.map { Self.authError($0).code } ?? "unavailable"
    }
    if let stored = try? Data(contentsOf: dir.appendingPathComponent(Self.domainFile)),
      let current = Self.domainState(context)
    {
      out["domainChanged"] = stored != current
    }
    return out
  }

  private func create(_ dir: URL) throws -> [String: Any] {
    guard SecureEnclave.isAvailable else { throw TouchIDError("unavailable", "no Secure Enclave") }
    try makeFolder(dir)
    dropReusable()
    let access = try Self.accessControl()
    let signing: SecureEnclave.P256.Signing.PrivateKey
    let agreement: SecureEnclave.P256.KeyAgreement.PrivateKey
    do {
      signing = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
      agreement = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
    } catch {
      throw TouchIDError("unavailable", "the Secure Enclave did not create the keys")
    }
    try write(signing.dataRepresentation, dir, Self.signingFile)
    try write(agreement.dataRepresentation, dir, Self.agreementFile)
    // The fingerprints as they are now: a later difference means the keys are dead (`.biometryCurrentSet`).
    let context = LAContext()
    var error: NSError?
    _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    if let state = Self.domainState(context) {
      try write(state, dir, Self.domainFile)
    } else {
      remove(dir, Self.domainFile)
    }
    // A slot sealed to older keys cannot open with these.
    remove(dir, Self.slotFile)
    let pub = signing.publicKey.x963Representation
    let keyId = SHA256.hash(data: pub).prefix(8).map { String(format: "%02x", $0) }.joined()
    return [
      "keyId": keyId,
      "signingPublic": pub.base64EncodedString(),
      "agreementPublic": agreement.publicKey.x963Representation.base64EncodedString(),
    ]
  }

  private func sign(_ dir: URL, _ args: [String: Any]) throws -> [String: Any] {
    guard let nonceHex = args["nonce"] as? String, let nonce = Self.bytes(hex: nonceHex), nonce.count == 32,
      let request = args["request"] as? String, let reason = args["reason"] as? String, !reason.isEmpty
    else { throw TouchIDError("failed", "bad arguments") }
    let reuse = args["reuse"] as? Bool ?? false
    let blob = try read(dir, Self.signingFile)
    let context = try takeContext(reuse: reuse, reason: reason, dir: dir)
    defer { context.invalidate() }
    var message = Self.proofLabel
    message.append(0)
    message.append(nonce)
    message.append(contentsOf: SHA256.hash(data: Data(request.utf8)))
    do {
      let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
      let sig = try key.signature(for: message)
      return ["sig": sig.rawRepresentation.base64EncodedString()]
    } catch {
      throw Self.keyError(error)
    }
  }

  private func seal(_ dir: URL, _ args: [String: Any]) throws -> Any? {
    guard let b64 = args["slotKey"] as? String, let slot = Data(base64Encoded: b64), slot.count == 32 else {
      throw TouchIDError("failed", "bad arguments")
    }
    guard #available(macOS 14, *) else { throw TouchIDError("unavailable", "HPKE needs macOS 14") }
    let blob = try read(dir, Self.agreementFile)
    do {
      // Only the public key is used: sealing needs no touch.
      let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
      var sender = try HPKE.Sender(
        recipientKey: key.publicKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: Self.hpkeInfo)
      let ciphertext = try sender.seal(slot)
      try write(Self.pack(sender.encapsulatedKey, ciphertext), dir, Self.slotFile)
      return nil
    } catch let e as TouchIDError {
      throw e
    } catch {
      throw TouchIDError("failed", "the slot key was not sealed")
    }
  }

  private func openSlot(_ dir: URL, _ args: [String: Any]) throws -> [String: Any] {
    guard let reason = args["reason"] as? String, !reason.isEmpty else { throw TouchIDError("failed", "bad arguments") }
    guard #available(macOS 14, *) else { throw TouchIDError("unavailable", "HPKE needs macOS 14") }
    guard let parts = Self.unpack(try read(dir, Self.slotFile)) else {
      throw TouchIDError("failed", "the sealed slot is damaged")
    }
    let (encapsulated, ciphertext) = parts
    let blob = try read(dir, Self.agreementFile)
    dropReusable()
    let context = try evaluate(reason, dir: dir)
    do {
      let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob, authenticationContext: context)
      var recipient = try HPKE.Recipient(
        privateKey: key, ciphersuite: .P256_SHA256_AES_GCM_256, info: Self.hpkeInfo,
        encapsulatedKey: encapsulated)
      let slot = try recipient.open(ciphertext)
      // The same touch signs the sign-in that follows (one `sign` with `reuse`, within 30 s).
      reusable = (context, Date().addingTimeInterval(Self.reuseWindow))
      return ["slotKey": slot.base64EncodedString()]
    } catch {
      context.invalidate()
      throw Self.keyError(error)
    }
  }

  private func delete(_ dir: URL) throws -> Any? {
    dropReusable()
    for name in [Self.signingFile, Self.agreementFile, Self.domainFile, Self.slotFile, "owner_key.json"] {
      remove(dir, name)
    }
    // Only an empty folder goes (rmdir), never anything else that may be in it.
    _ = rmdir(dir.path)
    return nil
  }

  // MARK: Touch

  /// The context for one use of the signing key: the one `openSlot` evaluated (with `reuse`, within 30 s, once), or a
  /// fresh one evaluated now with `reason`.
  private func takeContext(reuse: Bool, reason: String, dir: URL) throws -> LAContext {
    if reuse, let kept = reusable {
      reusable = nil
      if kept.until > Date() { return kept.context }
      kept.context.invalidate()
    }
    dropReusable()
    return try evaluate(reason, dir: dir)
  }

  /// One Touch ID prompt for biometrics only: no "Enter Password" button, so the Mac's password cannot stand in. After
  /// the touch, a changed fingerprint set means the keys are dead.
  private func evaluate(_ reason: String, dir: URL) throws -> LAContext {
    let context = LAContext()
    context.localizedReason = reason
    context.localizedFallbackTitle = ""
    let done = DispatchSemaphore(value: 0)
    var failure: Error?
    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, error in
      if !ok { failure = error ?? TouchIDError("failed", "not authenticated") }
      done.signal()
    }
    done.wait()
    if let failure = failure {
      context.invalidate()
      if let e = failure as? TouchIDError { throw e }
      throw Self.authError(failure)
    }
    if let stored = try? Data(contentsOf: dir.appendingPathComponent(Self.domainFile)),
      let current = Self.domainState(context), stored != current
    {
      context.invalidate()
      throw TouchIDError("key_invalidated", "the fingerprints changed since Touch ID was turned on")
    }
    return context
  }

  private func dropReusable() {
    reusable?.context.invalidate()
    reusable = nil
  }

  private static var hpkeSupported: Bool {
    if #available(macOS 14, *) { return true }
    return false
  }

  /// LocalAuthentication's biometry state after `canEvaluatePolicy` or `evaluatePolicy`; it changes when fingerprints
  /// are added or removed.
  private static func domainState(_ context: LAContext) -> Data? {
    if #available(macOS 15, *) {
      return context.domainState.biometry.stateHash
    }
    return context.evaluatedPolicyDomainState
  }

  private static func accessControl() throws -> SecAccessControl {
    var error: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &error)
    else {
      error?.release()
      throw TouchIDError("failed", "no access control")
    }
    return access
  }

  private static func authError(_ error: Error) -> TouchIDError {
    guard let la = error as? LAError else { return TouchIDError("failed", "Touch ID failed") }
    switch la.code {
    case .userCancel, .appCancel, .systemCancel, .userFallback:
      return TouchIDError("cancelled", "cancelled")
    case .biometryLockout:
      return TouchIDError("lockout", "too many failed attempts")
    case .biometryNotEnrolled:
      return TouchIDError("not_enrolled", "no fingerprint is set up")
    case .biometryNotAvailable, .passcodeNotSet, .notInteractive:
      return TouchIDError("unavailable", "Touch ID is not available")
    default:
      // -12 and -13: a Magic Keyboard with Touch ID that is not paired or not connected now (macOS 11.2 and later).
      if la.code.rawValue == -12 || la.code.rawValue == -13 {
        return TouchIDError("unavailable", "the Touch ID keyboard is not connected")
      }
      return TouchIDError("failed", "Touch ID failed (\(la.code.rawValue))")
    }
  }

  /// A key that does not load or sign after a successful touch: its fingerprint set is gone (`.biometryCurrentSet`)
  /// or the blob is not this Mac's.
  private static func keyError(_ error: Error) -> TouchIDError {
    if error is LAError { return authError(error) }
    if let e = error as? TouchIDError { return e }
    return TouchIDError("key_invalidated", "the key can no longer be used")
  }

  // MARK: Files

  private func folder(_ args: [String: Any]) throws -> URL {
    guard let dir = args["dir"] as? String, dir.hasPrefix("/") else { throw TouchIDError("failed", "no folder") }
    return URL(fileURLWithPath: dir, isDirectory: true)
  }

  private func makeFolder(_ dir: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    } catch {
      throw TouchIDError("failed", "cannot create the key folder")
    }
  }

  private func exists(_ dir: URL, _ name: String) -> Bool {
    FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
  }

  private func read(_ dir: URL, _ name: String) throws -> Data {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else {
      throw TouchIDError("key_invalidated", "no \(name)")
    }
    return data
  }

  /// Written whole to a temporary file created 0600 in the 0700 folder, then renamed over the old one.
  private func write(_ data: Data, _ dir: URL, _ name: String) throws {
    let path = dir.appendingPathComponent(name).path
    let tmp = path + ".tmp"
    unlink(tmp)
    guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]),
      rename(tmp, path) == 0
    else {
      unlink(tmp)
      throw TouchIDError("failed", "cannot write \(name)")
    }
  }

  private func remove(_ dir: URL, _ name: String) {
    unlink(dir.appendingPathComponent(name).path)
  }

  // MARK: Encoding

  private static func bytes(hex: String) -> Data? {
    guard hex.count % 2 == 0 else { return nil }
    var out = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let b = UInt8(hex[index..<next], radix: 16) else { return nil }
      out.append(b)
      index = next
    }
    return out
  }

  /// `slot.sealed`: the HPKE encapsulated key and the ciphertext, each with a 4-byte big-endian length.
  private static func pack(_ a: Data, _ b: Data) -> Data {
    var out = Data()
    for part in [a, b] {
      var n = UInt32(part.count).bigEndian
      out.append(Data(bytes: &n, count: 4))
      out.append(part)
    }
    return out
  }

  private static func unpack(_ data: Data) -> (Data, Data)? {
    var parts: [Data] = []
    var at = data.startIndex
    while parts.count < 2 {
      guard data.endIndex - at >= 4 else { return nil }
      let n = data[at..<at + 4].reduce(0) { ($0 << 8) | Int($1) }
      at += 4
      guard n > 0, data.endIndex - at >= n else { return nil }
      parts.append(data.subdata(in: at..<at + n))
      at += n
    }
    guard at == data.endIndex else { return nil }
    return (parts[0], parts[1])
  }
}
