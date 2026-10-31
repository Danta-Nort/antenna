// SPDX-License-Identifier: AGPL-3.0-only
// antenna-touchid: Touch ID for the `antenna` command in a terminal (D-131, CONTROL §22). The window's Secure Enclave
// keys for one daemon live in its folder (macos/Runner/TouchID.swift makes them); this helper uses them the same way,
// for the CLI, which has no Swift of its own. Built by packaging/macos/build-dmg.sh with swiftc into
// Antenna.app/Contents/Helpers/ next to `antenna`; not part of the Xcode project.
//
//   antenna-touchid <folder>
//   stdin, one JSON object per line:  {"op":"sign","nonce":<64 hex>,"request":<text>,"reason":<text>,"reuse":<bool>}
//                                     {"op":"open_slot","reason":<text>}
//   stdout, one JSON object per line: {"sig":<base64 r‖s>} | {"slot_key":<base64>} | {"error":<code>,"message":<text>}
//
// The same rules as the Runner: biometrics only (no "Enter Password" fallback, the Mac's password must not approve), a
// fresh LAContext per prompt with the command's own words as its reason, a changed fingerprint set refuses (the keys
// are dead, `.biometryCurrentSet`), and the one reuse: the touch that opened the slot signs ONE following request
// with `reuse` within 30 s. The proof's message is "antenna/owner-proof/v1" ‖ 0x00 ‖ nonce ‖ SHA-256(request), signed
// with ECDSA P-256 / SHA-256. Nothing here logs a key, a slot key, a request or a signature.
import CryptoKit
import Foundation
import LocalAuthentication

struct HelperError: Error {
  let code: String
  let message: String
  init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
}

let proofLabel = Data("antenna/owner-proof/v1".utf8)
let hpkeInfo = Data("antenna/keyslot/v1/hpke".utf8)
let reuseWindow: TimeInterval = 30

var reusable: (context: LAContext, until: Date)?

func read(_ dir: URL, _ name: String) throws -> Data {
  guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else {
    throw HelperError("key_invalidated", "no \(name)")
  }
  return data
}

func domainState(_ context: LAContext) -> Data? {
  if #available(macOS 15, *) {
    return context.domainState.biometry.stateHash
  }
  return context.evaluatedPolicyDomainState
}

func authError(_ error: Error) -> HelperError {
  guard let la = error as? LAError else { return HelperError("failed", "Touch ID failed") }
  switch la.code {
  case .userCancel, .appCancel, .systemCancel, .userFallback:
    return HelperError("cancelled", "cancelled")
  case .biometryLockout:
    return HelperError("lockout", "too many failed attempts")
  case .biometryNotEnrolled:
    return HelperError("not_enrolled", "no fingerprint is set up")
  case .biometryNotAvailable, .passcodeNotSet, .notInteractive:
    return HelperError("unavailable", "Touch ID is not available")
  default:
    if la.code.rawValue == -12 || la.code.rawValue == -13 {
      return HelperError("unavailable", "the Touch ID keyboard is not connected")
    }
    return HelperError("failed", "Touch ID failed (\(la.code.rawValue))")
  }
}

func keyError(_ error: Error) -> HelperError {
  if error is LAError { return authError(error) }
  if let e = error as? HelperError { return e }
  return HelperError("key_invalidated", "the key can no longer be used")
}

/// One Touch ID prompt for biometrics only; after the touch, a changed fingerprint set refuses.
func evaluate(_ reason: String, dir: URL) throws -> LAContext {
  let context = LAContext()
  context.localizedReason = reason
  context.localizedFallbackTitle = ""
  let done = DispatchSemaphore(value: 0)
  var failure: Error?
  context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, error in
    if !ok { failure = error ?? HelperError("failed", "not authenticated") }
    done.signal()
  }
  done.wait()
  if let failure = failure {
    context.invalidate()
    if let e = failure as? HelperError { throw e }
    throw authError(failure)
  }
  if let stored = try? Data(contentsOf: dir.appendingPathComponent("domain.state")),
    let current = domainState(context), stored != current
  {
    context.invalidate()
    throw HelperError("key_invalidated", "the fingerprints changed since Touch ID was turned on")
  }
  return context
}

func dropReusable() {
  reusable?.context.invalidate()
  reusable = nil
}

func takeContext(reuse: Bool, reason: String, dir: URL) throws -> LAContext {
  if reuse, let kept = reusable {
    reusable = nil
    if kept.until > Date() { return kept.context }
    kept.context.invalidate()
  }
  dropReusable()
  return try evaluate(reason, dir: dir)
}

func bytes(hex: String) -> Data? {
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

func unpack(_ data: Data) -> (Data, Data)? {
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

func sign(_ dir: URL, _ args: [String: Any]) throws -> [String: Any] {
  guard let nonceHex = args["nonce"] as? String, let nonce = bytes(hex: nonceHex), nonce.count == 32,
    let request = args["request"] as? String, let reason = args["reason"] as? String, !reason.isEmpty
  else { throw HelperError("failed", "bad arguments") }
  let reuse = args["reuse"] as? Bool ?? false
  let blob = try read(dir, "signing.key")
  let context = try takeContext(reuse: reuse, reason: reason, dir: dir)
  defer { context.invalidate() }
  var message = proofLabel
  message.append(0)
  message.append(nonce)
  message.append(contentsOf: SHA256.hash(data: Data(request.utf8)))
  do {
    let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
    let sig = try key.signature(for: message)
    return ["sig": sig.rawRepresentation.base64EncodedString()]
  } catch {
    throw keyError(error)
  }
}

func openSlot(_ dir: URL, _ args: [String: Any]) throws -> [String: Any] {
  guard let reason = args["reason"] as? String, !reason.isEmpty else { throw HelperError("failed", "bad arguments") }
  guard #available(macOS 14, *) else { throw HelperError("unavailable", "HPKE needs macOS 14") }
  guard let parts = unpack(try read(dir, "slot.sealed")) else {
    throw HelperError("failed", "the sealed slot is damaged")
  }
  let (encapsulated, ciphertext) = parts
  let blob = try read(dir, "agreement.key")
  dropReusable()
  let context = try evaluate(reason, dir: dir)
  do {
    let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob, authenticationContext: context)
    var recipient = try HPKE.Recipient(
      privateKey: key, ciphersuite: .P256_SHA256_AES_GCM_256, info: hpkeInfo, encapsulatedKey: encapsulated)
    let slot = try recipient.open(ciphertext)
    reusable = (context, Date().addingTimeInterval(reuseWindow))
    return ["slot_key": slot.base64EncodedString()]
  } catch {
    context.invalidate()
    throw keyError(error)
  }
}

func reply(_ object: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: object), let line = String(data: data, encoding: .utf8)
  else { return }
  FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

let arguments = CommandLine.arguments
guard arguments.count == 2, arguments[1].hasPrefix("/") else {
  FileHandle.standardError.write(Data("usage: antenna-touchid <folder>\n".utf8))
  exit(2)
}
let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
guard SecureEnclave.isAvailable else {
  while readLine() != nil { reply(["error": "unavailable", "message": "no Secure Enclave"]) }
  exit(0)
}
while let line = readLine() {
  let args = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
  do {
    switch args["op"] as? String {
    case "sign": reply(try sign(folder, args))
    case "open_slot": reply(try openSlot(folder, args))
    default: throw HelperError("failed", "unknown op")
    }
  } catch let e as HelperError {
    reply(["error": e.code, "message": e.message])
  } catch {
    reply(["error": "failed", "message": String(describing: type(of: error))])
  }
}
dropReusable()
