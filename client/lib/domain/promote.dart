/// FR106, FR110 / O1 — promotion as a pure function: turning a candidate or a
/// hand-placed coordinate into an [Anchor] and folding it into the trip's
/// existing anchor set.
///
/// Cluster-proposal review (N4a) is [P1], not MVP (punchlist §2 — "the MVP path
/// through the curation workspace is layers → candidates → promote directly →
/// roles"); [roleKindFromAffinity] is nonetheless the seam N4a's affinity-union
/// pre-fill plugs into once it exists, since it already does the one-candidate
/// case a cluster's affinity union generalizes.
library;

import 'anchor.dart';
import 'candidate.dart';
import 'json_utils.dart' show Coord;

/// A candidate's [RoleAffinity] pre-fills exactly one initial role kind for the
/// promotion dialog — "suggested roles pre-filled..., always editable" (O1's AC).
RoleKind roleKindFromAffinity(RoleAffinity affinity) => switch (affinity) {
      RoleAffinity.narrative => RoleKind.narrative,
      RoleAffinity.provision => RoleKind.provision,
      RoleAffinity.station => RoleKind.station,
    };

/// §4.2 / P10 — the candidate's geometry, name and source tags, copied rather
/// than referenced, plus [Candidate.id] kept only for [promoteAnchor]'s
/// same-session duplicate check (never dereferenced afterward).
AnchorProvenance provenanceFromCandidate(Candidate candidate) => AnchorProvenance(
      kind: AnchorSourceKind.candidate,
      sourceId: candidate.id,
      layer: candidate.layer,
      tags: candidate.tags,
    );

/// Thrown when a promotion would create a second anchor for the same source.
/// FR106's "one anchor per place": re-promoting an already-promoted candidate
/// must not silently duplicate the pin.
class DuplicatePromotionException implements Exception {
  DuplicatePromotionException({required this.existingAnchorId, required this.sourceId});

  final String existingAnchorId;
  final String sourceId;

  @override
  String toString() => 'DuplicatePromotionException: source "$sourceId" is already '
      'anchor "$existingAnchorId"';
}

/// An anchor already promoted from [sourceId] in [anchors], if any.
Anchor? anchorForSource(List<Anchor> anchors, String sourceId) =>
    anchors.where((a) => a.provenance?.sourceId == sourceId).firstOrNull;

/// FR110 — promotion is a single interaction: accept/edit a proposal or promote
/// a bare candidate/hand-placed point, assigning the role set (and, optionally,
/// per-role reveal/content) in one step. Returns the new [Anchor]; the caller
/// folds it into `trip.anchors` (a plain [Trip.copyWith], since anchors are
/// trip-scoped rather than day- or segment-scoped).
///
/// Throws [DuplicatePromotionException] rather than creating a second anchor
/// when [provenance] names a [AnchorProvenance.sourceId] already promoted in
/// [existingAnchors] — the caller should route the Author to editing that
/// anchor's role set instead.
Anchor promoteAnchor({
  required List<Anchor> existingAnchors,
  required String id,
  required Coord coord,
  required List<Role> roles,
  String? title,
  AnchorProvenance? provenance,
}) {
  final sourceId = provenance?.sourceId;
  if (sourceId != null) {
    final duplicate = anchorForSource(existingAnchors, sourceId);
    if (duplicate != null) {
      throw DuplicatePromotionException(existingAnchorId: duplicate.id, sourceId: sourceId);
    }
  }
  return Anchor(id: id, coord: coord, title: title, roles: roles, provenance: provenance);
}
