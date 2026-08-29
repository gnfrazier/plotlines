/// FR102–FR105a (Story N4/N4a) — a co-location proposal as returned by the
/// sidecar's `POST /clusters/analyze`. A **reviewable object, not a map pin**
/// (N4a): it renders as a card carrying a generated name, its contributing
/// members with type/name/salience, the suggested role set with the affinity
/// that produced it, the cluster's extent + tightness, and its distance from
/// the current route where one exists.
///
/// Not part of `trip_payload.schema.json` — proposals are never canon
/// (ARCH P10). Only the *fact* that one was rejected is persisted, as a small
/// member-id set (ARCH §4.4), so a re-run does not re-propose it.
library;

import 'candidate.dart' show RoleAffinity;
import 'json_utils.dart' show Coord;

/// One contributing feature inside a [ClusterProposal].
class ClusterMember {
  const ClusterMember({
    required this.candidateId,
    required this.layer,
    required this.type,
    required this.salience,
    required this.roleAffinity,
    this.title,
  });

  final String candidateId;
  final String layer;

  /// The resolved `key=value` of the source feature's tags, e.g.
  /// `tourism=viewpoint` — shown so the Author judges the proposal.
  final String type;
  final double salience;
  final RoleAffinity roleAffinity;
  final String? title;

  factory ClusterMember.fromJson(Map<String, dynamic> json) => ClusterMember(
        candidateId: json['candidate_id'] as String,
        layer: json['layer'] as String,
        type: json['type'] as String,
        salience: (json['salience'] as num).toDouble(),
        roleAffinity: RoleAffinity.fromWire(json['role_affinity'] as String),
        title: json['title'] as String?,
      );
}

class ClusterProposal {
  const ClusterProposal({
    required this.id,
    required this.name,
    required this.kind,
    required this.roleAffinities,
    required this.members,
    required this.centroid,
    required this.extentM,
    required this.tightness,
    required this.salienceScore,
    required this.rankScore,
    this.distanceToRouteM,
    this.isNew = true,
  });

  /// Stable across runs — `cl_<sha1(sorted member ids)>` — so a rejected
  /// proposal's identity survives a re-analysis.
  final String id;

  /// Generated from the highest-salience member (its title, else its type).
  final String name;

  /// `narrative` | `provision` | `narrative+provision` (+`+station`).
  final String kind;

  /// FR105's affinity union, sorted — the suggested role set.
  final List<RoleAffinity> roleAffinities;
  final List<ClusterMember> members;
  final Coord centroid;

  /// Radius of the cluster (max member distance to centroid), metres.
  final double extentM;

  /// 0..1 — higher is more compact.
  final double tightness;

  /// 0..1 — noisy-OR of member saliences.
  final double salienceScore;

  /// What the list is sorted by: combined salience × tightness.
  final double rankScore;

  /// Present only when the analysis was given an existing route.
  final double? distanceToRouteM;

  /// False when an equivalent proposal was in the previous run (N4a).
  final bool isNew;

  /// The member-id set — what a rejection persists (ARCH §4.4).
  Set<String> get memberIds => {for (final m in members) m.candidateId};

  factory ClusterProposal.fromJson(Map<String, dynamic> json) => ClusterProposal(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: json['kind'] as String,
        roleAffinities: (json['role_affinities'] as List)
            .map((v) => RoleAffinity.fromWire(v as String))
            .toList(),
        members: (json['members'] as List)
            .map((m) => ClusterMember.fromJson(m as Map<String, dynamic>))
            .toList(),
        centroid: (json['centroid'] as List).map((v) => (v as num).toDouble()).toList(),
        extentM: (json['extent_m'] as num).toDouble(),
        tightness: (json['tightness'] as num).toDouble(),
        salienceScore: (json['salience_score'] as num).toDouble(),
        rankScore: (json['rank_score'] as num).toDouble(),
        distanceToRouteM: (json['distance_to_route_m'] as num?)?.toDouble(),
        isNew: json['is_new'] as bool? ?? true,
      );
}

/// The full `POST /clusters/analyze` response — the ranked, **capped** list
/// plus the count beyond the cap, which N4a states rather than truncating
/// silently (FR105a).
class ColocationResult {
  const ColocationResult({
    required this.proposals,
    required this.cap,
    required this.nBeyondCap,
    required this.nCandidates,
    required this.rulesetVersion,
    this.layersServed = const [],
    this.layersUnavailable = const {},
  });

  final List<ClusterProposal> proposals;
  final int cap;

  /// FR105a — how many proposals lie beyond the reviewable cap. Always
  /// shown ("+N more"), never a silent truncation.
  final int nBeyondCap;
  final int nCandidates;
  final String rulesetVersion;
  final List<String> layersServed;

  /// Layer id → reason (`loading` / `failed:<reason>` / `unknown_layer`) —
  /// one bad layer never fails the run (story N2).
  final Map<String, String> layersUnavailable;

  bool get isEmpty => proposals.isEmpty && nBeyondCap == 0;

  factory ColocationResult.fromJson(Map<String, dynamic> json) => ColocationResult(
        proposals: (json['proposals'] as List)
            .map((p) => ClusterProposal.fromJson(p as Map<String, dynamic>))
            .toList(),
        cap: json['cap'] as int,
        nBeyondCap: json['n_beyond_cap'] as int,
        nCandidates: json['n_candidates'] as int? ?? 0,
        rulesetVersion: json['ruleset_version'] as String,
        layersServed: (json['layers_served'] as List?)?.cast<String>() ?? const [],
        layersUnavailable:
            (json['layers_unavailable'] as Map?)?.map((k, v) => MapEntry(k as String, '$v')) ??
                const {},
      );
}
