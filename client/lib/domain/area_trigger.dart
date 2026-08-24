/// FR126 / O3 — "entry into a polygon anchor's boundary fires its narration,
/// reveal, or notification the way point-proximity does for a point anchor,
/// with entry debounced so a boundary-hugging route does not re-fire" (ARCH
/// §6.2). This file is that debounce primitive, and nothing more: the field
/// runtime that would feed it a live GPS stream, hold one instance per role's
/// [Anchor.roleArea], and route a firing into the reveal/narration/arrival
/// pipeline (ARCH §6's four effect kinds) does not exist in this codebase yet
/// — GPS-triggered playback is out of desktop MVP scope, same carve-out
/// `node.dart`'s [Narration] doc comment already makes for point triggers.
/// [AreaEntryTrigger] is deliberately pure and stateful-by-injection so it is
/// usable and testable today, ahead of that runtime.
library;

import 'json_utils.dart' show Coord;
import 'anchor.dart' show Area;

/// Tracks one polygon's entry/exit state across a stream of position updates
/// and reports the trigger event ARCH §6.2 describes: entry, fired exactly
/// once per approach, immune to a route that hugs the boundary and wobbles
/// across it on GPS noise alone.
///
/// The debounce is symmetric hysteresis on consecutive samples, not a
/// geometric buffer around the boundary — no route geometry is needed, only
/// the position stream itself, which keeps this usable with any position
/// source. [enterStreak] consecutive "inside" samples confirm an entry (and
/// fire it exactly once); [exitStreak] consecutive "outside" samples then
/// re-arm the trigger for a future entry. A boundary-hugging route toggles
/// inside/outside faster than either streak completes, so it fires nothing.
class AreaEntryTrigger {
  AreaEntryTrigger({this.enterStreak = 3, this.exitStreak = 3})
      : assert(enterStreak >= 1, 'enterStreak must be at least 1'),
        assert(exitStreak >= 1, 'exitStreak must be at least 1');

  final int enterStreak;
  final int exitStreak;

  bool _confirmedInside = false;
  int _insideRun = 0;
  int _outsideRun = 0;

  /// True once an entry has been confirmed and not yet exited — the state a
  /// resumed session or an Author preview would want to check without
  /// waiting for a fresh [update] to report it.
  bool get isInside => _confirmedInside;

  /// Feeds one position update against [area]. Returns `true` on exactly the
  /// sample that confirms entry — the trigger fires — and `false` every
  /// other time, including while already inside and including every sample
  /// of a boundary-hugging wobble that never completes [exitStreak].
  bool update(Area area, Coord position) {
    final inside = area.containsPoint(position);
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

  /// Back to never-entered, as if no [update] had ever been fed. A Character
  /// re-downloading the same plotline after clearing local state is the real
  /// case; tests use it to start a second scenario from a clean tracker.
  void reset() {
    _confirmedInside = false;
    _insideRun = 0;
    _outsideRun = 0;
  }
}
