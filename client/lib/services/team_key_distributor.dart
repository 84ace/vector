import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/operator_profile.dart';

/// Outcome of one delivery sweep, for the caller's event log.
class RekeyDeliveryReport {
  final int delivered;
  final int stillPending;

  const RekeyDeliveryReport({required this.delivered, required this.stillPending});

  bool get isComplete => stillPending == 0;
}

/// Tracks which contacts still owe us an acknowledgement for the current team
/// key, and re-attempts delivery when a route to them appears.
///
/// Rotation used to be a single best-effort sweep: members who were offline at
/// that moment simply never got the new key, and the only trace was an event-log
/// line saying distribution was incomplete. Their team traffic then failed to
/// decrypt indefinitely, because nothing ever tried again.
///
/// Delivery is confirmed rather than assumed. A send returning true only means
/// the envelope was handed to a transport, so a recipient stays pending until it
/// acknowledges — which is the difference between "we tried" and "they have it".
class TeamKeyDistributor {
  /// Seals and sends a GROUP_REKEY to one contact. True if a transport accepted
  /// it; that is necessary but not sufficient, hence the acknowledgement.
  final Future<bool> Function(OperatorProfile recipient) sendRekey;

  /// Resolves an operator ID to a paired contact, or null if no longer paired.
  final OperatorProfile? Function(String operatorId) lookupContact;

  /// The epoch we are currently trying to distribute.
  final int Function() currentEpoch;

  /// Persists [pendingOperatorIds] so a restart does not forget who is owed a
  /// key. Rotation survives process death; the obligation has to as well.
  final Future<void> Function(Set<String> pending) persist;

  /// How often to re-attempt while anything is pending. Delivery is mainly
  /// event-driven — this is a backstop for a peer that reappears without either
  /// transport announcing it.
  static const _retryInterval = Duration(seconds: 30);

  /// Bounded so an unreachable contact does not leave the device transmitting
  /// forever. Re-armed whenever a transport event arrives, so a peer that comes
  /// back after this expires is still served.
  static const _maxBackstopTicks = 40; // ~20 minutes.

  final Set<String> _pending = {};
  Timer? _retryTimer;
  int _ticksRemaining = 0;
  bool _sweepInFlight = false;
  bool _disposed = false;

  TeamKeyDistributor({
    required this.sendRekey,
    required this.lookupContact,
    required this.currentEpoch,
    required this.persist,
  });

  /// Operators that have not yet confirmed the current key.
  Set<String> get pending => Set.unmodifiable(_pending);

  bool get hasPending => _pending.isNotEmpty;

  /// Restores pending obligations from storage at startup.
  void restore(Iterable<String> operatorIds) {
    _pending.addAll(operatorIds);
    if (_pending.isNotEmpty) _scheduleBackstop();
  }

  /// Records that every one of [recipients] needs the current key, then makes a
  /// first delivery attempt.
  ///
  /// Call immediately after rotating. Everyone starts pending — including
  /// operators that are reachable right now — and only an acknowledgement
  /// clears them.
  Future<RekeyDeliveryReport> distributeToAll(
    Iterable<OperatorProfile> recipients,
  ) async {
    _pending
      ..clear()
      ..addAll(recipients.map((r) => r.id));
    await persist(_pending);
    return sweep();
  }

  /// Attempts delivery to everyone still pending.
  ///
  /// Guarded against overlap: the relay reconnecting and a P2P peer appearing
  /// can land in the same instant, and two concurrent sweeps would send every
  /// recipient a duplicate key.
  Future<RekeyDeliveryReport> sweep() async {
    if (_disposed || _sweepInFlight || _pending.isEmpty) {
      return RekeyDeliveryReport(delivered: 0, stillPending: _pending.length);
    }
    _sweepInFlight = true;

    var accepted = 0;
    try {
      for (final operatorId in _pending.toList()) {
        final contact = lookupContact(operatorId);
        if (contact == null || !contact.hasValidKeys) {
          // Unpaired since the rotation, so there is nothing left to owe them.
          _pending.remove(operatorId);
          continue;
        }

        try {
          if (await sendRekey(contact)) accepted++;
        } catch (e) {
          debugPrint('[TEAM_KEY] Delivery to $operatorId failed: $e');
        }
      }
      await persist(_pending);
    } finally {
      _sweepInFlight = false;
    }

    if (_pending.isNotEmpty) _scheduleBackstop();
    return RekeyDeliveryReport(delivered: accepted, stillPending: _pending.length);
  }

  /// Clears [operatorId] once it confirms an epoch at least as new as ours.
  ///
  /// A stale acknowledgement must not clear the obligation: if we rotated again
  /// while the first delivery was in flight, an ack for the older epoch means
  /// that operator is still behind. Accepting a *newer* epoch is correct too —
  /// it means they already hold a key we are about to receive ourselves.
  Future<bool> acknowledge(String operatorId, int ackedEpoch) async {
    if (ackedEpoch < currentEpoch()) return false;
    if (!_pending.remove(operatorId)) return false;

    await persist(_pending);
    if (_pending.isEmpty) _cancelBackstop();
    return true;
  }

  /// Drops an operator we are no longer paired with.
  Future<void> forget(String operatorId) async {
    if (!_pending.remove(operatorId)) return;
    await persist(_pending);
    if (_pending.isEmpty) _cancelBackstop();
  }

  /// Called when a transport event suggests peers may now be reachable.
  void onRouteAvailable() {
    if (_disposed || _pending.isEmpty) return;
    _scheduleBackstop(); // Re-arm: a peer reappearing deserves a fresh window.
    unawaited(sweep());
  }

  void _scheduleBackstop() {
    if (_disposed) return;
    _ticksRemaining = _maxBackstopTicks;
    if (_retryTimer != null) return;

    _retryTimer = Timer.periodic(_retryInterval, (timer) {
      if (_pending.isEmpty || _ticksRemaining-- <= 0) {
        _cancelBackstop();
        return;
      }
      unawaited(sweep());
    });
  }

  void _cancelBackstop() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _ticksRemaining = 0;
  }

  void dispose() {
    _disposed = true;
    _cancelBackstop();
  }
}
