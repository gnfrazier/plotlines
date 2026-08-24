/// The P11 gate (ARCH §2, §7.8, §9.1) — "the single highest-value lint or
/// architecture test in the v2.0 client." Every surface that renders a role's
/// content must go through [RevealResolver], never read `Role.title` /
/// `Role.note` / `Role.media` directly, so a withheld narrative role cannot
/// leak through a rarely-exercised path (a print preview, an export corner
/// case, an accessibility readout) that nobody thought to test.
///
/// O1 scope only: resolves [RevealPolicy] against a per-view arrival flag.
/// Two things this class is deliberately NOT yet, both reserved for O5
/// (FR114, FR115): it does not apply a default when [Role.reveal] is unset
/// (O1's AC allows reveal to be "set here or later" — an undecided role reads
/// as withheld until an Author or O5's default resolves it, never as an
/// accidental leak), and it has no hazard/crux exemption, because no role
/// carries a hazard flag yet. Both slot into [resolve] without changing its
/// shape when O5 adds them.
library;

import '../domain/anchor.dart';
import '../domain/json_utils.dart' show Coord;
import '../domain/node.dart' show MediaRef;

/// What a Character-facing (or Author-preview) surface may show for one role:
/// either the content, or nothing but the fact that something is here.
class RevealedRole {
  const RevealedRole({
    required this.roleId,
    required this.kind,
    required this.visible,
    this.coord,
    this.title,
    this.note,
    this.media = const [],
  });

  final String roleId;
  final RoleKind kind;

  /// `false` renders as a marker with no content — "something is here" —
  /// never as an empty/missing pin (PRD P1's AC).
  final bool visible;

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

  /// Resolves one [role] against [hasArrived]. [hasArrived] stands in for the
  /// Character reveal-state layer (P8: its own tables, never `trip.payload`)
  /// until that layer exists; callers pass `true` for an always-available
  /// Author preview-as-self and `false`/arrival-tracked otherwise.
  ///
  /// [anchorCoord], when given, is the owning anchor's coord — [resolveAnchor]
  /// always supplies it. It backstops [RevealedRole.coord] when [role] carries
  /// no offset of its own (FR107 / O2's "an anchor with no offsets behaves
  /// exactly as a single point").
  RevealedRole resolve(Role role, {required bool hasArrived, Coord? anchorCoord}) {
    final visible = switch (role.reveal) {
      RevealPolicy.alwaysVisible => true,
      RevealPolicy.onArrival => hasArrived,
      null => false,
    };
    return RevealedRole(
      roleId: role.id,
      kind: role.kind,
      visible: visible,
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
