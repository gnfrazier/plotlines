/// FR98/FR99 (Story N3) — a notability-scored candidate as returned by the
/// sidecar's `/candidates/score`. Not part of `trip_payload.schema.json`:
/// candidates are not canon (ARCH P10) and never round-trip through the
/// trip payload, so this is a plain transport type like
/// `data/routing_client.dart`'s `GeocodeResult`, not a payload `$def`.
library;

import 'json_utils.dart' show Coord;

/// ARCH D47's role affinity — narrative | provision | station.
enum RoleAffinity {
  narrative,
  provision,
  station;

  static RoleAffinity fromWire(String value) => switch (value) {
        'narrative' => RoleAffinity.narrative,
        'provision' => RoleAffinity.provision,
        'station' => RoleAffinity.station,
        _ => throw FormatException('unknown role_affinity "$value"'),
      };
}

class Candidate {
  const Candidate({
    required this.id,
    required this.coord,
    required this.layer,
    required this.salience,
    required this.roleAffinity,
    this.title,
    this.tags = const {},
  });

  final String id;
  final Coord coord;

  /// One of `taxonomy.LAYERS` — sight | amenity | natural | historic |
  /// leisure | man_made.
  final String layer;

  /// FR98 — 0.0-1.0, never a binary verdict.
  final double salience;
  final RoleAffinity roleAffinity;
  final String? title;
  final Map<String, String> tags;

  factory Candidate.fromJson(Map<String, dynamic> json) => Candidate(
        id: json['id'] as String,
        coord: (json['coord'] as List).map((v) => (v as num).toDouble()).toList(),
        layer: json['layer'] as String,
        salience: (json['salience'] as num).toDouble(),
        roleAffinity: RoleAffinity.fromWire(json['role_affinity'] as String),
        title: json['title'] as String?,
        tags: (json['tags'] as Map?)?.map((k, v) => MapEntry(k as String, v as String)) ??
            const {},
      );
}

/// Issue #415 (SPIKE-D #159, N2) — the whole of a `GET /candidates`
/// response, not just its candidates. **One failing layer never fails the
/// request**: the sidecar returns what every layer that served produced,
/// [layersServed] naming them and [layersUnavailable] mapping each layer
/// that did not to its wire reason (`loading` / `failed:<reason>` /
/// `unknown_layer`). Dropping the two lists on the floor is what made a
/// partially served bbox render as an empty one — an Author whose plugin
/// layer timed out saw fewer candidates and no notice.
class CandidateExtraction {
  const CandidateExtraction({
    required this.candidates,
    this.layersServed = const [],
    this.layersUnavailable = const {},
  });

  final List<Candidate> candidates;
  final List<String> layersServed;

  /// Layer id → wire reason. Never shown as-is: the presentation layer maps
  /// it through `unavailableLayerReason` to a bounded `ReasonCode` (FR145).
  final Map<String, String> layersUnavailable;

  /// Some requested layers served and some did not — M13's
  /// `layersPartiallyServed` state (#400).
  bool get isPartial => layersUnavailable.isNotEmpty && layersServed.isNotEmpty;

  /// Nothing requested served — M13's `layerExtractionFailed`, the total
  /// case, reached through a 200 rather than an exception.
  bool get isTotalFailure => layersUnavailable.isNotEmpty && layersServed.isEmpty;

  factory CandidateExtraction.fromJson(Map<String, dynamic> json) => CandidateExtraction(
        candidates: (json['candidates'] as List)
            .map((c) => Candidate.fromJson(c as Map<String, dynamic>))
            .toList(),
        layersServed: (json['layers_served'] as List?)?.cast<String>() ?? const [],
        layersUnavailable:
            (json['layers_unavailable'] as Map?)?.map((k, v) => MapEntry(k as String, '$v')) ??
                const {},
      );
}
