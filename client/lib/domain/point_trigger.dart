/// FR41, FR124, FR126 / P1 (ARCH §6.2) — "reaching a role's trigger" for a
/// point role means entering a circle of some radius around its geometry,
/// the same debounced-entry shape `area_trigger.dart`'s [AreaEntryTrigger]
/// already gives polygon roles (FR126). This file is that circle's version
/// of the same primitive: deliberately pure and stateful-by-injection, one
/// instance per role, fed a raw position stream by the field runtime
/// (`data/field_runtime.dart`) that owns turning a fired trigger into a
/// reveal (FR124) or narration (FR49) event.
///
/// The radius itself is not read from [Role] here — no per-role trigger
/// distance field exists on the wire model yet (FR41 / Story H2, not yet
/// built); callers supply it per update, exactly as [AreaEntryTrigger]
/// takes its geometry per update rather than owning it.
library;

import 'dart:math' as math;

import 'json_utils.dart' show Coord;

const _earthRm = 6371000.0;

/// Great-circle distance between [a] and [b] in metres. A private copy of
/// the same haversine formula `data/export/geo_utils.dart` uses for export
/// writers — kept local rather than imported so this (pure, no-I/O) domain
/// file never depends on the Data layer, mirroring how `anchor.dart`'s
/// `_ringContainsPoint` implements its own point-in-polygon test rather
/// than reaching for a shared geometry package.
double _haversineM(Coord a, Coord b) {
  final lat1 = a[1] * math.pi / 180.0;
  final lat2 = b[1] * math.pi / 180.0;
  final dLat = (b[1] - a[1]) * math.pi / 180.0;
  final dLon = (b[0] - a[0]) * math.pi / 180.0;
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * _earthRm * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Tracks one point's entry/exit state across a stream of position updates,
/// reporting the same kind of trigger event [AreaEntryTrigger] reports for a
/// polygon: entry, fired exactly once per approach, immune to GPS noise that
/// hovers a position right at the trigger radius.
///
/// The debounce is symmetric hysteresis on consecutive samples, identical in
/// shape to [AreaEntryTrigger]'s: [enterStreak] consecutive "inside the
/// radius" samples confirm an entry (and fire it exactly once); [exitStreak]
/// consecutive "outside" samples then re-arm the trigger for a future entry.
class PointEntryTrigger {
  PointEntryTrigger({this.enterStreak = 3, this.exitStreak = 3})
      : assert(enterStreak >= 1, 'enterStreak must be at least 1'),
        assert(exitStreak >= 1, 'exitStreak must be at least 1');

  final int enterStreak;
  final int exitStreak;

  bool _confirmedInside = false;
  int _insideRun = 0;
  int _outsideRun = 0;

  /// True once an entry has been confirmed and not yet exited.
  bool get isInside => _confirmedInside;

  /// Feeds one position update: [position] is the Character's current raw
  /// GPS fix, [center] and [radiusM] are the role's trigger geometry (a
  /// point plus a radius). Returns `true` on exactly the sample that
  /// confirms entry, `false` every other time — including every sample of a
  /// wobble at the radius boundary that never completes [exitStreak].
  bool update(Coord center, double radiusM, Coord position) {
    final inside = _haversineM(center, position) <= radiusM;
    if (inside) {
      _outsideRun = 0;
      _insideRun++;
      if (!_confirmedInside && _insideRun >= enterStreak) {
        _confirmedInside = true;
        return true;
      }
    } else {
      _insideRun = 0;
      _outsideRun++;
      if (_confirmedInside && _outsideRun >= exitStreak) {
        _confirmedInside = false;
      }
    }
    return false;
  }

  /// Back to never-entered, as if no [update] had ever been fed.
  void reset() {
    _confirmedInside = false;
    _insideRun = 0;
    _outsideRun = 0;
  }
}
