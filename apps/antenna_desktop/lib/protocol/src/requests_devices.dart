// SPDX-License-Identifier: AGPL-3.0-only
// My devices (x-control/7, CONTROL §27, D-106; experimental): the requests. A part of requests.dart. A daemon older than
// these commands answers `unknown_command` (or `bad_request` from its strict parser): the window then shows nothing of
// them.

part of 'requests.dart';

/// This computer and every contact at ∞, as they told this one. Reply: `devices`.
final class DevicesRequest extends XRequest {
  const DevicesRequest();
  @override
  String get cmd => 'devices';
  @override
  Json get fields => const {};
}

/// The other computer's one-time challenge, for one approval answered from here with Touch ID. Reply:
/// `device_challenge`.
final class DeviceChallengeRequest extends XRequest {
  const DeviceChallengeRequest(this.contact);
  final String contact;
  @override
  String get cmd => 'device_challenge';
  @override
  Json get fields => {'contact': contact};
}

/// Approve a request of another own computer with a proof made here: [request] is the exact signed text
/// ([remoteApproveText]), [sig] the Secure Enclave key's signature over the challenge and that text. This daemon passes
/// it on unchanged; the other computer checks it. Reply: `device_decided`.
final class DeviceApproveRequest extends XRequest {
  const DeviceApproveRequest({
    required this.contact,
    required this.request,
    required this.nonce,
    required this.keyId,
    required this.sig,
  });
  final String contact;
  final String request;
  final String nonce;
  final String keyId;
  final String sig;
  @override
  String get cmd => 'device_approve';
  @override
  Json get fields => {'contact': contact, 'request': request, 'nonce': nonce, 'key_id': keyId, 'sig': sig};
}

/// Approve with this computer's password (the daemon checks it, then signs with its device key), or deny (no
/// password). Reply: `device_decided`.
final class DeviceDecideRequest extends XRequest {
  const DeviceDecideRequest({required this.contact, required this.id, required this.approve, this.fingerprint, this.password});
  final String contact;
  final String id;
  final bool approve;
  final String? fingerprint;
  final String? password;
  @override
  String get cmd => 'device_decide';
  @override
  Json get fields => {
        'contact': contact,
        'id': id,
        'decision': approve ? 'approve' : 'deny',
        'fingerprint': ?fingerprint,
        'password': ?password,
      };
}

/// Accept approvals from these keys of another own computer (all it offers when empty); the password. Reply: `devices`.
final class DeviceKeysConfirmRequest extends XRequest {
  const DeviceKeysConfirmRequest({required this.contact, required this.keyIds, required this.password});
  final String contact;
  final List<String> keyIds;
  final String password;
  @override
  String get cmd => 'device_keys_confirm';
  @override
  Json get fields => {'contact': contact, 'key_ids': keyIds, 'password': password};
}

/// Stop accepting approvals from these keys (all when empty); no password. Reply: `devices`.
final class DeviceKeysRemoveRequest extends XRequest {
  const DeviceKeysRemoveRequest({required this.contact, this.keyIds = const []});
  final String contact;
  final List<String> keyIds;
  @override
  String get cmd => 'device_keys_remove';
  @override
  Json get fields => {'contact': contact, 'key_ids': keyIds};
}

/// "Lend this computer to my teams": on with the password, off without. Reply: `devices`.
final class DeviceLendSetRequest extends XRequest {
  const DeviceLendSetRequest({required this.enabled, this.password});
  final bool enabled;
  final String? password;
  @override
  String get cmd => 'device_lend_set';
  @override
  Json get fields => {'enabled': enabled, 'password': ?password};
}

/// "Revoke this computer": its keys are reported to the owner's other computers, then the link is revoked; the
/// password. Reply: `revoked`.
final class DeviceRevokeRequest extends XRequest {
  const DeviceRevokeRequest({required this.contact, required this.password, this.deleteHistory = false});
  final String contact;
  final String password;
  final bool deleteHistory;
  @override
  String get cmd => 'device_revoke';
  @override
  Json get fields => {'contact': contact, if (deleteHistory) 'delete_history': true, 'password': password};
}

/// Clear "reported as lost by another computer". Reply: `devices`.
final class DeviceLostDismissRequest extends XRequest {
  const DeviceLostDismissRequest(this.contact);
  final String contact;
  @override
  String get cmd => 'device_lost_dismiss';
  @override
  Json get fields => {'contact': contact};
}
