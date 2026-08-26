/// FR124, FR114 / P1 (ARCH §6, §6.2, §6.7) — the offline GPS engine that
/// turns a raw position stream into permanent per-role reveal state. This is
/// deliberately the narrow slice of the Field Runtime ARCH §6 describes:
/// reveal-on-arrival only. Cue-state derivation (§6.3), narration playback
/// (FR49, Story H2), hazard alerts (FR53, Story I5), and group relay of
/// arrivals (§8.5, Story P3) are separate, not-yet-built stories that will
/// eventually sit beside this in the same `FieldRuntime` name; this file
/// does not anticipate their shape.
///
/// **FR124's three properties, each load-bearing here:**
/// - **Runs fully offline from raw GPS.** [ingestPosition] is a pure,
///   synchronous function over an in-memory position: no HTTP client, no
///   `Future`, no dependency this class owns on connectivity. "No network in
///   the critical path" (ARCH §6.1) is true by construction, not by care.
/// - **Reveal is permanent once fired** (ARCH §6.7). A role, once in
///   [revealedRoleIds], never leaves it — there is no re-hiding, no expiry.
///   [initiallyRevealed] exists so a caller can hydrate this from the
///   Character's persisted reveal log (P8, a local drift layer — not built
///   by this story) across an app restart; this class does not persist
///   anything itself.
/// - **Reveal fires from a role's own geometry, never its anchor's**
///   (FR107 / O2, ARCH §6.2) — via [Anchor.roleGeometry] / [Anchor.roleArea],
///   the same fallback [RevealResolver] itself reads.
///
/// **What this class deliberately does not decide:** whether a role is
/// visible. That is [RevealResolver]'s job alone (P11) — this class only
/// ever produces the `hasArrived` flag [RevealResolver.resolve] already
/// takes as a parameter, and [resolveAnchor] below does nothing but call
/// through to it once per role. Provision and hazard content is therefore
/// never gated here either: [_TriggerableRole]s are built only for roles
/// whose [RevealResolver.effectivePolicy] is [RevealPolicy.onArrival] in the
/// first place, so an always-visible role never enters this engine at all.
library;

import '../domain/domain.dart';
import 'reveal_resolver.dart';

class _TriggerableRole {
  const _TriggerableRole({required this.role, this.center, this.area});
  final Role role;
  final Coord? center;
  final Area? area;
}

/// Feeds a raw GPS stream against every on-arrival role in a set of
/// [anchors] and tracks which have permanently fired. One instance covers
/// one Character's run through one trip; construct a fresh one (or seed
/// [initiallyRevealed]) per Character.
class FieldRuntime {
  FieldRuntime({
    required List<Anchor> anchors,
    required double Function(Role role) pointTriggerDistanceM,
    this.resolver = const RevealResolver(),
    Set<String> initiallyRevealed = const {},
    int enterStreak = 3,
    int exitStreak = 3,
  })  : _pointTriggerDistanceM = pointTriggerDistanceM,
        _revealed = {...initiallyRevealed},
        _anchorByRoleId = {for (final a in anchors) for (final r in a.roles) r.id: a} {
    for (final anchor in anchors) {
      for (final role in anchor.roles) {
        if (resolver.effectivePolicy(role) != RevealPolicy.onArrival) continue;
        final area = anchor.roleArea(role);
        _triggerable[role.id] = _TriggerableRole(
          role: role,
          center: area == null ? anchor.roleGeometry(role) : null,
          area: area,
        );
        if (area != null) {
          _areaTriggers[role.id] = AreaEntryTrigger(enterStreak: enterStreak, exitStreak: exitStreak);
        } else {
          _pointTriggers[role.id] = PointEntryTrigger(enterStreak: enterStreak, exitStreak: exitStreak);
        }
      }
    }
  }

  final RevealResolver resolver;
  final double Function(Role role) _pointTriggerDistanceM;
  final Set<String> _revealed;
  final Map<String, Anchor> _anchorByRoleId;
  final Map<String, _TriggerableRole> _triggerable = {};
  final Map<String, AreaEntryTrigger> _areaTriggers = {};
  final Map<String, PointEntryTrigger> _pointTriggers = {};

  /// FR124 — `true` once [roleId] has fired its trigger (or was seeded via
  /// [initiallyRevealed]), permanently, regardless of current position.
  bool hasArrived(String roleId) => _revealed.contains(roleId);

  /// The permanent arrival log so far — membership only, fire order is not
  /// tracked. A copy, not a live view: callers cannot mutate reveal state
  /// except through [ingestPosition].
  Set<String> get revealedRoleIds => Set.unmodifiable(_revealed);

  /// Feeds one raw GPS [position] update against every role that has not yet
  /// fired. Returns the role ids that fired on exactly this update — empty
  /// on every update that confirms nothing new (ARCH §6.2's debounce, same
  /// mechanism [AreaEntryTrigger] and [PointEntryTrigger] each use alone).
  ///
  /// Order of iteration does not matter: two roles can fire on the same
  /// update (an anchor whose narrative role sits at a spur the Character
  /// just reached, while its own always-visible provision role needed no
  /// trigger at all), and each is evaluated independently — FR114's "reveal
  /// is a property of a role, not of a place" holds here too.
  List<String> ingestPosition(Coord position) {
    final fired = <String>[];
    for (final entry in _triggerable.entries) {
      final roleId = entry.key;
      if (_revealed.contains(roleId)) continue;
      final triggerable = entry.value;
      final justFired = triggerable.area != null
          ? _areaTriggers[roleId]!.update(triggerable.area!, position)
          : _pointTriggers[roleId]!.update(
              triggerable.center!,
              _pointTriggerDistanceM(triggerable.role),
              position,
            );
      if (justFired) {
        _revealed.add(roleId);
        fired.add(roleId);
      }
    }
    return fired;
  }

  /// One role, resolved through [RevealResolver] (P11) against this
  /// runtime's own arrival state for that role — never a stand-in decision
  /// made here.
  RevealedRole resolveRole(Role role) {
    final anchor = _anchorByRoleId[role.id];
    return resolver.resolve(role, hasArrived: hasArrived(role.id), anchorCoord: anchor?.coord);
  }

  /// [anchor]'s roles resolved in order, each against its **own** arrival
  /// state — unlike [RevealResolver.resolveAnchor], which takes a single
  /// `hasArrived` for the whole anchor (right for O5's pre-departure
  /// preview, wrong for field execution, where two roles on the same anchor
  /// can genuinely be revealed at different times: FR114's whole point).
  List<RevealedRole> resolveAnchor(Anchor anchor) => [
        for (final role in anchor.roles)
          resolver.resolve(role, hasArrived: hasArrived(role.id), anchorCoord: anchor.coord),
      ];
}
