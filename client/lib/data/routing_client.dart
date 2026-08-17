import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/domain.dart';

/// The linchpin of the Data layer (ARCH §9.1): holds the sidecar's base URL and
/// nothing above it knows the transport. Talks to whatever `service/app.py`
/// actually exposes today — `/health`, `/segments/generate`,
/// `/segments/envelope`, `/segments/diagnose` (+poll). The rest of ARCH §7.2's
/// surface (`/days/compose`, `/trips/split`, `/trips/{id}/export`, `/geocode`,
/// `/tiles`, `/elevation`, `/weather`) is not implemented server-side yet —
/// see the MVP doc's open questions. Callers should expect [UnimplementedError]
/// from those methods rather than a silent no-op.
class RoutingClient {
  RoutingClient(this.baseUrl);

  final String baseUrl;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, dynamic>> health() async {
    final resp = await http.get(_uri('/health'));
    _checkOk(resp);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// A7/B1 — solve start (+ via + end) under a named theme or raw weights.
  /// Adapts the sidecar's flat `routing.solve.Segment.to_dict()` response
  /// (mode/theme/distance_m/coordinates/elevation/node_count/solve_ms/
  /// geometry_wkt — the SPIKE-00 solver's shape) onto the domain [Segment]
  /// (the `trip_payload.schema.json` shape); the two are deliberately
  /// different documents (see `weight_profile.dart`'s doc comment) and this
  /// is the one place that bridges them.
  Future<Segment> generateSegment({
    required Coord start,
    required Coord end,
    List<Coord> via = const [],
    String mode = 'cycling',
    String theme = 'balanced',
    Map<String, double>? weights,
  }) async {
    final resp = await http.post(
      _uri('/segments/generate'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'start': {'lat': start[1], 'lon': start[0]},
        'end': {'lat': end[1], 'lon': end[0]},
        'via': via.map((c) => {'lat': c[1], 'lon': c[0]}).toList(),
        'mode': mode,
        'theme': theme,
        if (weights != null) 'weights': weights,
      }),
    );
    _checkOk(resp);
    final raw = jsonDecode(resp.body) as Map<String, dynamic>;
    return _segmentFromSolveResponse(raw, mode: mode, start: start, end: end, via: via);
  }

  static Segment _segmentFromSolveResponse(
    Map<String, dynamic> raw, {
    required String mode,
    required Coord start,
    required Coord end,
    required List<Coord> via,
  }) {
    final coords = (raw['coordinates'] as List)
        .map((c) => (c as List).map((n) => (n as num).toDouble()).toList())
        .toList();
    final elevRaw = (raw['elevation'] as Map?) ?? const {};
    return Segment(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      mode: mode,
      // The solve.py engine only ever produces a routed point-to-point/via
      // path today; loop closure and out-and-back live in routing/loops.py
      // and are not what /segments/generate calls (open question).
      shape: 'point_to_point',
      start: start,
      end: end,
      via: via,
      geometry: LineString(coordinates: coords, source: 'solved'),
      metrics: RouteMetrics(distanceM: (raw['distance_m'] as num).toDouble()),
      elevation: Elevation(
        ascentM: (elevRaw['ascent_m'] as num?)?.toDouble(),
        descentM: (elevRaw['descent_m'] as num?)?.toDouble(),
        minM: (elevRaw['min_m'] as num?)?.toDouble(),
        maxM: (elevRaw['max_m'] as num?)?.toDouble(),
      ),
      solve: SolveProvenance(
        solveMs: (raw['solve_ms'] as num?)?.toDouble(),
        solvedAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  /// A5 — the attainable envelope for a loop of [targetM] from [start], so band
  /// sliders open on a real range (SPIKE-03). metric -> [min, max].
  Future<Map<String, List<double>>> envelope({
    required Coord start,
    required double targetM,
    List<Coord> via = const [],
  }) async {
    final resp = await http.post(
      _uri('/segments/envelope'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'start': {'lat': start[1], 'lon': start[0]},
        'target_m': targetM,
        'via': via.map((c) => {'lat': c[1], 'lon': c[0]}).toList(),
      }),
    );
    _checkOk(resp);
    final raw = jsonDecode(resp.body) as Map<String, dynamic>;
    return raw.map((k, v) =>
        MapEntry(k, (v as List).map((n) => (n as num).toDouble()).toList()));
  }

  /// A6, step 1 of 2 — submit bands that a solve failed to satisfy; returns a
  /// job id to poll (diagnosis is async: SPIKE-02 measured 1.3-15.0s).
  Future<String> submitDiagnose({
    required Coord start,
    required double targetM,
    required List<Band> bands,
    List<Coord> via = const [],
  }) async {
    final resp = await http.post(
      _uri('/segments/diagnose'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'start': {'lat': start[1], 'lon': start[0]},
        'target_m': targetM,
        'via': via.map((c) => {'lat': c[1], 'lon': c[0]}).toList(),
        'bands': bands
            .map((b) => {
                  'metric': b.attribute,
                  'minimum': b.min,
                  'maximum': b.max,
                })
            .toList(),
      }),
    );
    _checkOk(resp);
    return (jsonDecode(resp.body) as Map<String, dynamic>)['id'] as String;
  }

  /// A6, step 2 of 2 — poll until the diagnosis is ready. Returns null while
  /// still pending.
  Future<Diagnosis?> pollDiagnose(String jobId) async {
    final resp = await http.get(_uri('/segments/diagnose/$jobId'));
    _checkOk(resp);
    final raw = jsonDecode(resp.body) as Map<String, dynamic>;
    if (raw['status'] == 'pending') return null;
    return Diagnosis.fromJson(raw['diagnosis'] as Map<String, dynamic>);
  }

  void _checkOk(http.Response resp) {
    if (resp.statusCode >= 400) {
      throw RoutingException(resp.statusCode, resp.body);
    }
  }
}

class RoutingException implements Exception {
  RoutingException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  /// A6/M13: honest, screen-displayable text — FastAPI's `HTTPException`
  /// bodies are `{"detail": "..."}`, which is the message an Author actually
  /// wrote a band/relaxation string into (see `service/app.py`).
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
  String toString() => 'RoutingException($statusCode): $message';
}
