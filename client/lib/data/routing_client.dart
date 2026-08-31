import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/domain.dart';
import '../domain/json_utils.dart' show dayLimitsToJson;

/// The linchpin of the Data layer (ARCH §9.1): holds the sidecar's base URL and
/// nothing above it knows the transport. `/health`, `/segments/generate`
/// (all three shapes), `/segments/envelope`, `/segments/diagnose` (+poll),
/// `/segments/cues`, `/days/compose`, `/trips/split`, and `/geocode` are all
/// real and wired here. Still not implemented server-side: `/trips/{id}/export`
/// (GPX/GeoJSON/TCX are client-side writers instead, see `data/export/`),
/// `/tiles` (no basemap-tile endpoint — the client reads exploded tiles off
/// disk directly, see `presentation/map/vector_tile_provider.dart`), and
/// `/elevation`/`/weather` as standalone probes (elevation rides along
/// inside `/segments/generate`; weather is Leg 3, MVP doc §1.4.2).
class RoutingClient {
  RoutingClient(this.baseUrl);

  final String baseUrl;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, dynamic>> health() async {
    final resp = await http.get(_uri('/health'));
    _checkOk(resp);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// FR120/D41, issue #154 — ensures a routable graph exists for [bboxWsen]
  /// (`[west, south, east, north]`), returning the region key every
  /// `/segments/*` call must now carry. Idempotent and cheap to call again
  /// for a bbox already ensured (a dict lookup server-side, no rebuild) —
  /// callers are not expected to cache the result themselves.
  Future<String> ensureRegion(List<double> bboxWsen, {String networkType = 'bike'}) async {
    final resp = await http.post(
      _uri('/regions'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'bbox': bboxWsen, 'network_type': networkType}),
    );
    _checkOk(resp);
    return (jsonDecode(resp.body) as Map<String, dynamic>)['region'] as String;
  }

  Map<String, dynamic> _latLon(Coord c) => {'lat': c[1], 'lon': c[0]};

  /// A7/A8/A9/B1 — solve under a named theme or raw weights, for any of the
  /// three shapes. `end` is required for `point_to_point` and optional
  /// elsewhere (an out-and-back turnaround, or absent — a loop always closes
  /// on `start`); `targetM` is required for `loop` and is `out_and_back`'s
  /// envelope target when no `end` is given (FR8/A8).
  ///
  /// Adapts the sidecar's flat response (mode/theme/distance_m/coordinates/
  /// elevation/solve_ms, plus `shape`/`closed`/`hit_via`/`target_m` for the
  /// two loop-family shapes) onto the domain [Segment] (the
  /// `trip_payload.schema.json` shape); the two are deliberately different
  /// documents (see `weight_profile.dart`'s doc comment) and this is the one
  /// place that bridges them.
  Future<Segment> generateSegment({
    required String region,
    required Coord start,
    Coord? end,
    List<Coord> via = const [],
    String mode = 'cycling',
    String shape = 'loop',
    String theme = 'balanced',
    Map<String, double>? weights,
    double? targetM,
  }) async {
    final resp = await http.post(
      _uri('/segments/generate'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'region': region,
        'start': _latLon(start),
        if (end != null) 'end': _latLon(end),
        'via': via.map(_latLon).toList(),
        'mode': mode,
        'shape': shape,
        'theme': theme,
        if (weights != null) 'weights': weights,
        if (targetM != null) 'target_m': targetM,
      }),
    );
    _checkOk(resp);
    final raw = jsonDecode(resp.body) as Map<String, dynamic>;
    return _segmentFromSolveResponse(raw, mode: mode, shape: shape, start: start, end: end, via: via);
  }

  static Segment _segmentFromSolveResponse(
    Map<String, dynamic> raw, {
    required String mode,
    required String shape,
    required Coord start,
    required Coord? end,
    required List<Coord> via,
  }) {
    final coords = (raw['coordinates'] as List)
        .map((c) => (c as List).map((n) => (n as num).toDouble()).toList())
        .toList();
    final elevRaw = (raw['elevation'] as Map?) ?? const {};
    return Segment(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      mode: mode,
      shape: (raw['shape'] as String?) ?? shape,
      start: start,
      end: end ?? (coords.isNotEmpty ? coords.last : null),
      via: via,
      targetDistance: raw['target_m'] == null
          ? null
          : TargetDistance(
              valueM: (raw['target_m'] as num).toDouble(),
              // A9a/FR8a — three or more via-anchors fixed the loop's length,
              // so the target was reported, not honoured. The deviation is an
              // editing decision (A0a), routed through `submitDiagnose`.
              advisory: raw['target_advisory'] as bool?,
            ),
      geometry: LineString(coordinates: coords, source: 'solved'),
      // A9/FR8a — the loop-family response also carries the overlap split
      // (`Loop.metrics`, SPIKE-01's lollipop distinction) when the sidecar sent
      // it; point_to_point's flat response never includes these keys, so they
      // stay null rather than reading as an honest zero.
      metrics: RouteMetrics(
        distanceM: (raw['distance_m'] as num).toDouble(),
        overlapFrac: (raw['overlap_frac'] as num?)?.toDouble(),
        overlapNearFrac: (raw['overlap_near_frac'] as num?)?.toDouble(),
        overlapFarFrac: (raw['overlap_far_frac'] as num?)?.toDouble(),
      ),
      elevation: Elevation(
        ascentM: (elevRaw['ascent_m'] as num?)?.toDouble(),
        descentM: (elevRaw['descent_m'] as num?)?.toDouble(),
        minM: (elevRaw['min_m'] as num?)?.toDouble(),
        maxM: (elevRaw['max_m'] as num?)?.toDouble(),
      ),
      solve: SolveProvenance(
        solveMs: (raw['solve_ms'] as num?)?.toDouble(),
        solvedAt: DateTime.now().toUtc().toIso8601String(),
        closed: raw['closed'] as bool?,
        hitVia: raw['hit_via'] as bool?,
      ),
    );
  }

  /// A5 — the attainable envelope for a loop of [targetM] from [start], so band
  /// sliders open on a real range (SPIKE-03). metric -> [min, max].
  Future<Map<String, List<double>>> envelope({
    required String region,
    required Coord start,
    required double targetM,
    List<Coord> via = const [],
  }) async {
    final resp = await http.post(
      _uri('/segments/envelope'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'region': region,
        'start': _latLon(start),
        'target_m': targetM,
        'via': via.map(_latLon).toList(),
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
    required String region,
    required Coord start,
    required double targetM,
    required List<Band> bands,
    List<Coord> via = const [],
  }) async {
    final resp = await http.post(
      _uri('/segments/diagnose'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'region': region,
        'start': _latLon(start),
        'target_m': targetM,
        'via': via.map(_latLon).toList(),
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

  /// F1 — real turn-by-turn cues (SPIKE-21's `derive_cue_sheet`), re-solved
  /// server-side against the graph rather than trusted from client geometry
  /// (same pattern as `/segments/envelope` and `/segments/diagnose`).
  /// [segment] supplies the routing inputs (start/end/via/mode/shape/
  /// weights/target distance); its `nodes`/`hazards`/`portages`/`alternates`
  /// are the curated content the sheet is derived around.
  Future<CueSheet> cuesFor(Segment segment, {required String region}) async {
    final resp = await http.post(
      _uri('/segments/cues'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'region': region,
        'start': _latLon(segment.start!),
        if (segment.end != null) 'end': _latLon(segment.end!),
        'via': segment.via.map(_latLon).toList(),
        'shape': segment.shape,
        if (segment.weights?.name != null) 'theme': segment.weights!.name,
        if (segment.targetDistance != null) 'target_m': segment.targetDistance!.valueM,
        'segment_id': segment.id,
        'nodes': segment.nodes.map((n) => {
              'id': n.id, 'kind': n.kind.wireValue, 'coord': n.coord,
              'distance_along_m': n.distanceAlongM, 'title': n.title,
              'instructions': n.instructions,
              // C5 / F1 (FR133) — woven into the cue's own instruction text
              // server-side (`cues.node_cues`), not a separate logistics list.
              'amenities': n.amenities,
            }).toList(),
        'hazards': segment.hazards.map((h) => {
              'id': h.id, 'severity': h.severity, 'coord': h.coord,
              'distance_along_m': h.distanceAlongM, 'title': h.title,
              'safety_note': h.safetyNote,
            }).toList(),
        'portages': segment.portages.map((p) => {
              'id': p.id,
              'geometry': {'coordinates': p.geometry.coordinates},
              'exit_bank': p.exitBank, 'mandatory': p.mandatory ?? false,
              'distance_m': p.distanceM,
            }).toList(),
        'alternates': segment.alternates.map((a) => {
              'id': a.id, 'intent': a.intent, 'kind': a.kind,
              'geometry': {'coordinates': a.geometry.coordinates},
              'label': a.label, 'diverges_at_m': a.divergesAtM,
            }).toList(),
      }),
    );
    _checkOk(resp);
    final raw = jsonDecode(resp.body) as Map<String, dynamic>;
    return CueSheet.fromJson(raw['cue_sheet'] as Map<String, dynamic>);
  }

  /// B2/D1/C3 — the only supported way to build a day's derived half
  /// (transition gap warnings, roll-up): `trips/compose.py`'s `compose_day`.
  Future<Day> composeDay({
    required List<Segment> segments,
    List<Transition> transitions = const [],
    int index = 1,
    String kind = 'route',
  }) async {
    final resp = await http.post(
      _uri('/days/compose'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'segments': segments.map((s) => s.toJson()).toList(),
        'transitions': transitions.map((t) => t.toJson()).toList(),
        'index': index,
        'kind': kind,
      }),
    );
    _checkOk(resp);
    return Day.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// C3 — assemble days into a trip and apply per-mode day limits
  /// (`split_trip`; see that function's docstring for why "split" is the
  /// ARCH-inherited name for an assemble operation).
  Future<Trip> assembleTrip({
    required List<Day> days,
    required String title,
    Map<String, DayLimit>? limits,
    WeightProfile? defaultWeights,
  }) async {
    final resp = await http.post(
      _uri('/trips/split'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'days': days.map((d) => d.toJson()).toList(),
        'title': title,
        if (limits != null) 'limits': dayLimitsToJson(limits),
        if (defaultWeights != null) 'default_weights': defaultWeights.toJson(),
      }),
    );
    _checkOk(resp);
    return Trip.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// A10 / New Route's location search — Nominatim via OSMnx (ARCH §7.2).
  Future<List<GeocodeResult>> geocode(String query) async {
    final resp = await http.get(_uri('/geocode').replace(queryParameters: {'q': query}));
    _checkOk(resp);
    final raw = jsonDecode(resp.body) as Map<String, dynamic>;
    return (raw['results'] as List)
        .map((r) => GeocodeResult.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  void _checkOk(http.Response resp) {
    if (resp.statusCode >= 400) {
      throw RoutingException(resp.statusCode, resp.body);
    }
  }
}

class GeocodeResult {
  const GeocodeResult({required this.label, required this.coord, this.bbox});
  final String label;
  final Coord coord;

  /// `[west, south, east, north]` (issue #154) — Nominatim's own bounding
  /// geometry for this place, letting the trip-area draw map frame itself on
  /// a real extent. **Never becomes the trip bbox** (FR96: the location
  /// prompt only ever centers the map) — callers must not pass this to
  /// `RoutingClient.ensureRegion` as if the Author had drawn it.
  final List<double>? bbox;

  factory GeocodeResult.fromJson(Map<String, dynamic> j) => GeocodeResult(
        label: j['label'] as String,
        coord: (j['coord'] as List).map((e) => (e as num).toDouble()).toList(),
        bbox: (j['bbox'] as List?)?.map((e) => (e as num).toDouble()).toList(),
      );
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
