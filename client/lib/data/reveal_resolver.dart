/// The P11 gate (ARCH §2, §7.8, §9.1) — "the single highest-value lint or
/// architecture test in the v2.0 client." Every surface that renders a role's
/// content must go through [RevealResolver], never read `Role.title` /
/// `Role.note` / `Role.media` directly, so a withheld narrative role cannot
/// leak through a rarely-exercised path (a print preview, an export corner
/// case, an accessibility readout) that nobody thought to test.
///
/// O1 gave this class a per-view arrival flag to resolve [RevealPolicy]
/// against. O5 (FR114, FR115, FR116) adds the two things it deliberately did
/// not do yet: [effectivePolicy] applies FR114's defaults when [Role.reveal]
/// is unset (provision defaults to always-visible; narrative and station have
/// no engine default — "the Author's choice" — so they stay withheld until
/// the Author actually sets one), and it forces [Role.hazard] roles to
/// always-visible unconditionally (FR115's hard constraint), overriding
/// whatever [Role.reveal] happens to hold. Because every surface — the
/// offline package, web, print, cue sheets, TTS, exports — is required to
/// call through this one resolver (P11), that single override point is what
/// makes FR116 ("print and web inherit reveal policy") true for free: there
/// is no second reveal decision for a surface-specific renderer to get wrong.
library;

import '../domain/anchor.dart';
import '../domain/json_utils.dart' show Coord;
import '../domain/node.dart' show MediaRef;
import '../domain/reveal_state.dart';

/// What a Character-facing (or Author-preview) surface may show for one role:
/// either the content, or nothing but the fact that something is here.
class RevealedRole {
  const RevealedRole({
    required this.roleId,
    required this.kind,
    required this.state,
    this.coord,
    this.title,
    this.note,
    this.media = const [],
  });

  final String roleId;
  final RoleKind kind;

  /// FR114, FR115 / O5 — the resolved reveal state this role rendered from.
  /// [visible] is a convenience over [RevealState.isVisible]; a surface that
  /// needs to distinguish "revealed on arrival" from "always visible" (an
  /// Author preview, a hazard badge) reads this instead.
  final RevealState state;

  /// `false` renders as a marker with no content — "something is here" —
  /// never as an empty/missing pin (PRD P1's AC).
  bool get visible => state.isVisible;

  /// FR107 / O2 — the coord a marker for this role renders at: the role's
  /// own offset when [resolveAnchor] was used (or an [anchorCoord] was
  /// passed to [resolve] directly), `null` otherwise. Visibility gating
  /// above is independent of this — a withheld role still resolves a
  /// position, since "something is here" (PRD P1) has to render *somewhere*.
  final Coord? coord;
  final String? title;
  final String? note;
  final List<MediaRef> media;
}

class RevealResolver {
  const RevealResolver();

  /// FR114, FR115 / O5 — the policy [role] actually resolves against, after
  /// applying (in order): the FR115 hazard override, then [role.reveal] if
  /// the Author set one, then [RoleKind.defaultReveal] if not. `null` only
  /// for a non-hazard narrative/station role the Author has never set —
  /// "the Author's choice," left open rather than defaulted.
  RevealPolicy? effectivePolicy(Role role) {
    if (role.hazard) return RevealPolicy.alwaysVisible;
    return role.reveal ?? role.kind.defaultReveal;
  }

  /// Resolves one [role] against [hasArrived]. [hasArrived] stands in for the
  /// Character reveal-state layer (P8: its own tables, never `trip.payload`)
  /// until that layer exists; callers pass `true` for an always-available
  /// Author preview-as-self, and `false` for the Author's pre-departure
  /// "preview as a Character would see it" (O5's AC) as well as for a
  /// Character who has not yet arrived.
  ///
  /// [anchorCoord], when given, is the owning anchor's coord — [resolveAnchor]
  /// always supplies it. It backstops [RevealedRole.coord] when [role] carries
  /// no offset of its own (FR107 / O2's "an anchor with no offsets behaves
  /// exactly as a single point").
  RevealedRole resolve(Role role, {required bool hasArrived, Coord? anchorCoord}) {
    final state = switch (effectivePolicy(role)) {
      RevealPolicy.alwaysVisible => RevealState.alwaysVisible,
      RevealPolicy.onArrival => hasArrived ? RevealState.revealed : RevealState.withheld,
      null => RevealState.withheld,
    };
    final visible = state.isVisible;
    return RevealedRole(
      roleId: role.id,
      kind: role.kind,
      state: state,
      coord: role.coord ?? anchorCoord,
      title: visible ? role.title : null,
      note: visible ? role.note : null,
      media: visible ? role.media : const [],
    );
  }

  /// [Anchor.roles] resolved in order — the shape a map pin's info panel or a
  /// cue-sheet entry actually renders. Triggers fire from the role's own
  /// geometry, not the anchor's (FR107 / O2, ARCH §6.2) — [Anchor.roleGeometry]
  /// is exactly what each [RevealedRole.coord] ends up holding here.
  List<RevealedRole> resolveAnchor(Anchor anchor, {required bool hasArrived}) => [
        for (final role in anchor.roles)
          resolve(role, hasArrived: hasArrived, anchorCoord: anchor.coord),
      ];
}
