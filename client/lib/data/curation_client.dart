import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/candidate.dart';
import '../domain/cluster_proposal.dart';
import '../domain/json_utils.dart' show Coord;
import '../domain/trip_bbox.dart';

/// The layer catalog plus a resolved (mode, day type) default (FR97).
class LayerCatalog {
  const LayerCatalog({required this.layers, required this.defaultLive, required this.rulesetVersion});

  /// Every layer id the catalog spans — sight/amenity/natural/historic/
  /// leisure/man_made (FR97's AC).
  final List<String> layers;

  /// The default live set for the (mode, day type) this catalog was
  /// resolved against.
  final Set<String> defaultLive;

  /// ARCH §4.2's cache-key component — bumps when the notability ruleset
  /// changes, so a stale client can tell its cached scores apart.
  final String rulesetVersion;

  factory LayerCatalog.fromJson(Map<String, dynamic> json) => LayerCatalog(
        layers: (json['layers'] as List).cast<String>(),
        defaultLive: (json['default_live'] as List).cast<String>().toSet(),
        rulesetVersion: json['ruleset_version'] as String,
      );
}

/// `CurationClient` is deliberately separate from `RoutingClient` (ARCH
/// §9.1): different readiness dependency (layers ready, not elevation), and
/// one client for both would re-couple the two boundary B1 exists to keep
/// apart. Same transport pattern as `RoutingClient` — base URL only, no
/// business logic.
class CurationClient {
  CurationClient(this.baseUrl);

  final String baseUrl;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  /// FR97 — the layer catalog and this (mode, day type) pair's default live
  /// set.
  Future<LayerCatalog> layerCatalog({required String mode, required String dayType}) async {
    final resp = await http.get(_uri('/layers', {'mode': mode, 'day_type': dayType}));
    _checkOk(resp);
    return LayerCatalog.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// FR98/FR99 — score raw features against the Author's live layer
  /// selection. [features] is whatever a LayerProvider extraction already
  /// produced for the trip bbox; scoring itself is a sidecar call so
  /// sidecar and hosted deployments never disagree on salience (ARCH §4.2).
  Future<List<Candidate>> scoreCandidates({
    required Set<String> liveLayers,
    required List<RawCandidateFeature> features,
  }) async {
    final resp = await http.post(
      _uri('/candidates/score'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'live_layers': liveLayers.toList(),
        'features': features.map((f) => f.toJson()).toList(),
      }),
    );
    _checkOk(resp);
    final raw = jsonDecode(resp.body) as Map<String, dynamic>;
    return (raw['candidates'] as List)
        .map((c) => Candidate.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  /// ARCH §8.2's `GET /candidates?bbox=…&layers=…` — extracts [bbox]'s raw
  /// features via the sidecar's built-in LayerProvider and notability-scores
  /// them against [liveLayers] in one call, so a screen doesn't have to
  /// stage its own extraction step first.
  Future<List<Candidate>> candidatesForBbox({
    required TripBbox bbox,
    required Set<String> liveLayers,
  }) async {
    final resp = await http.get(_uri('/candidates', {
      'west': bbox.minLon.toString(),
      'south': bbox.minLat.toString(),
      'east': bbox.maxLon.toString(),
      'north': bbox.maxLat.toString(),
      'layers': liveLayers.join(','),
    }));
    _checkOk(resp);
    final raw = jsonDecode(resp.body) as Map<String, dynamic>;
    return (raw['candidates'] as List)
        .map((c) => Candidate.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  /// FR102–FR105a (Story N4) — "find the good spots". A **named Author
  /// action over the trip bbox**, never ambient: co-location analysis across
  /// the live heterogeneous layers, returning ranked, capped
  /// [ClusterProposal]s.
  ///
  /// [rejected] is the set of member-id sets the Author has already dismissed
  /// for this trip (ARCH §4.4) — a re-run does not re-propose them.
  /// [previous] is the prior run's member-id sets, so proposals not seen last
  /// time are flagged [ClusterProposal.isNew]. [route], when given, is a
  /// lon/lat polyline: every proposal then carries `distanceToRouteM`, and
  /// the reviewable cap grows with route length.
  Future<ColocationResult> analyzeColocation({
    required TripBbox bbox,
    required Set<String> liveLayers,
    List<Coord> route = const [],
    Iterable<Set<String>> rejected = const [],
    Iterable<Set<String>> previous = const [],
    String sort = 'rank',
  }) async {
    final resp = await http.post(
      _uri('/clusters/analyze'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'bbox': [bbox.minLon, bbox.minLat, bbox.maxLon, bbox.maxLat],
        'layers': liveLayers.toList(),
        if (route.isNotEmpty) 'route': route,
        if (rejected.isNotEmpty) 'rejected': [for (final s in rejected) s.toList()],
        if (previous.isNotEmpty) 'previous': [for (final s in previous) s.toList()],
        'sort': sort,
      }),
    );
    _checkOk(resp);
    return ColocationResult.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  void _checkOk(http.Response resp) {
    if (resp.statusCode >= 400) {
      throw CurationException(resp.statusCode, resp.body);
    }
  }
}

/// A feature as extracted from a LayerProvider (ARCH §14.2), awaiting
/// notability scoring — the request-side mirror of [Candidate].
class RawCandidateFeature {
  const RawCandidateFeature({
    required this.id,
    required this.coord,
    this.tags = const {},
    this.areaM2,
  });

  final String id;
  final Coord coord;
  final Map<String, String> tags;
  final double? areaM2;

  Map<String, dynamic> toJson() => {
        'id': id,
        'coord': coord,
        'tags': tags,
        if (areaM2 != null) 'area_m2': areaM2,
      };
}

class CurationException implements Exception {
  CurationException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  String get message {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] is String) {
        return decoded['detail'] as String;
      }
    } catch (_) {
      // Not JSON — fall through to the raw body.
    }
    return body.isEmpty ? 'Request failed ($statusCode)' : body;
  }

  @override
  String toString() => 'CurationException($statusCode): $message';
}
