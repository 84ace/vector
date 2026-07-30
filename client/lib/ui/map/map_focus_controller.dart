import 'package:flutter/foundation.dart';

/// A request from elsewhere in the app to put the map onto a particular
/// operator.
///
/// The map and the squad list are two children of the same [IndexedStack], so
/// the list cannot reach the map's [MapController] directly. This carries the
/// request across the gap.
///
/// The sequence number is what makes a repeat tap work: without it, asking for
/// the same operator twice looks like "no change" to a listener that compares
/// the previous value, and the second tap would be swallowed — which is exactly
/// the case where an operator has panned away and wants to snap back.
@immutable
class MapFocusRequest {
  final String operatorId;

  /// Whether to engage continuous tracking rather than a one-off recentre.
  final bool lock;

  final int seq;

  const MapFocusRequest({
    required this.operatorId,
    required this.lock,
    required this.seq,
  });
}

/// Carries "show me this operator" from the squad list to the map.
class MapFocusController extends ChangeNotifier {
  MapFocusRequest? _pending;
  int _seq = 0;

  MapFocusRequest? get pending => _pending;

  /// Centres the map on [operatorId]. With [lock], the map also keeps following
  /// them as their position reports arrive.
  void focus(String operatorId, {bool lock = false}) {
    _pending = MapFocusRequest(operatorId: operatorId, lock: lock, seq: ++_seq);
    notifyListeners();
  }

  /// Marks the outstanding request as handled.
  ///
  /// The map calls this once it has moved, so that a later rebuild for an
  /// unrelated reason does not yank the camera back to a stale request.
  void consume() {
    _pending = null;
  }
}
