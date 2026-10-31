// SPDX-License-Identifier: AGPL-3.0-only
// How the owner confirms one owner command (D-102, D-131): the password typed for it, or one touch whose proof covers
// exactly that command. The window keeps neither: a [PasswordAuth] lives for one call, and a [TouchAuth] is only the
// words of the prompt; the proof is made when the request is sent, over a fresh challenge, and used once
// ([TouchIdMixin.ownerOp]).

/// One owner command's confirmation.
sealed class OwnerAuth {
  const OwnerAuth();
}

/// The password the owner typed for this command.
final class PasswordAuth extends OwnerAuth {
  const PasswordAuth(this.password);
  final String password;

  @override
  String toString() => 'PasswordAuth(…)';
}

/// One touch; [reason] is the prompt's text (macOS shows "“Antenna” is trying to `reason`.").
final class TouchAuth extends OwnerAuth {
  const TouchAuth(this.reason);
  final String reason;

  @override
  String toString() => 'TouchAuth($reason)';
}
