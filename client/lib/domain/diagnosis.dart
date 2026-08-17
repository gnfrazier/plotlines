/// `Relaxation`/`Diagnosis`, mirroring `plotlines_core.routing.diagnose` (FR9, Story
/// A6). Not part of the trip payload schema — these describe why a solve failed and
/// how to relax it, surfaced by the sidecar rather than stored in `trip.payload`.
///
/// `diagnose.py`'s `Relaxation`/`Diagnosis` carry a rich `scoring.bands.Band` object
/// internally (with `.describe()`/`.shortfall()` methods), but `Diagnosis.to_dict()`
/// and `Relaxation.to_dict()` both flatten those bands to plain human-readable
/// strings before they ever reach JSON — `conflict` becomes `list[str]`, and a
/// relaxation's `band`/`proposed` become the `from`/`to` string pair. That flattened
/// shape, not `scoring.bands.Band` itself, is what a Dart client actually
/// deserializes, so no separate `Band`/`BandSet` port of `scoring/bands.py` is
/// included here — `band.dart`'s [Band] already covers the one Band shape that
/// travels on the wire (the payload's `weight_profile`-adjacent `band` $def).
library;

import 'json_utils.dart';

/// One applyable change to one band, with what it costs the Author.
class Relaxation {
  Relaxation({
    required this.metric,
    required this.from,
    required this.to,
    required this.tradeOff,
    required this.reachedBy,
  });

  final String metric;

  /// The original band, human-readable (`Band.describe()` on the Python side).
  final String from;

  /// The proposed, widened band, human-readable.
  final String to;
  final String tradeOff;

  /// Which weight archetype's attempt reached this relaxation.
  final String reachedBy;

  factory Relaxation.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'relaxation');
    final r = Relaxation(
      metric: f.takeString('metric')!,
      from: f.takeString('from')!,
      to: f.takeString('to')!,
      tradeOff: f.takeString('trade_off')!,
      reachedBy: f.takeString('reached_by')!,
    );
    f.done();
    return r;
  }

  Map<String, dynamic> toJson() => {
        'metric': metric,
        'from': from,
        'to': to,
        'trade_off': tradeOff,
        'reached_by': reachedBy,
      };
}

/// A6's diagnosis: route if possible, otherwise name the specific conflicting
/// constraints and offer nearest relaxations, each stating its trade-off.
class Diagnosis {
  Diagnosis({
    required this.feasible,
    required this.kind,
    this.conflict = const [],
    required this.explanation,
    this.viaImplicated = false,
    this.viaRelaxation,
    this.relaxations = const [],
    this.envelope = const {},
    required this.solves,
    required this.elapsedMs,
    this.bestEffort,
  });

  final bool feasible;

  /// One of `none` | `unattainable` | `combination`.
  final String kind;

  /// Human-readable band descriptions (`Band.describe()`), not structured bands —
  /// see the library doc comment for why.
  final List<String> conflict;
  final String explanation;

  /// Set when a via-node, not the terrain, is what makes the request impossible.
  final bool viaImplicated;
  final Map<String, dynamic>? viaRelaxation;
  final List<Relaxation> relaxations;

  /// metric -> `[min, max]` observed across every attempt.
  final Map<String, List<double>> envelope;
  final int solves;
  final double elapsedMs;

  /// Opaque best-effort route dict (a solved segment's `to_dict()` on the Python
  /// side) — not deeply typed here since `diagnose.py` itself carries it as
  /// `dict | None`.
  final Map<String, dynamic>? bestEffort;

  factory Diagnosis.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'diagnosis');
    final rawEnvelope = f.take('envelope');
    final envelope = rawEnvelope == null
        ? const <String, List<double>>{}
        : (rawEnvelope as Map).map((k, v) => MapEntry(
            k as String, (v as List).map((n) => (n as num).toDouble()).toList()));
    final viaRelaxation = f.take('via_relaxation');
    final bestEffort = f.take('best_effort');
    final d = Diagnosis(
      feasible: f.takeBool('feasible')!,
      kind: f.takeString('kind')!,
      conflict: f.takeStrings('conflict'),
      explanation: f.takeString('explanation')!,
      viaImplicated: f.takeBool('via_implicated') ?? false,
      viaRelaxation: viaRelaxation == null ? null : Map<String, dynamic>.from(viaRelaxation as Map),
      relaxations: f.takeList('relaxations', Relaxation.fromJson),
      envelope: envelope,
      solves: f.takeInt('solves')!,
      elapsedMs: f.takeNum('elapsed_ms')!,
      bestEffort: bestEffort == null ? null : Map<String, dynamic>.from(bestEffort as Map),
    );
    f.done();
    return d;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'feasible': feasible,
        'kind': kind,
        'conflict': conflict,
        'explanation': explanation,
        'via_implicated': viaImplicated,
        'via_relaxation': viaRelaxation,
        'relaxations': relaxations.map((r) => r.toJson()).toList(),
        'envelope': envelope.map((k, v) => MapEntry(
            k, v.map((n) => finite(n, 'diagnosis.envelope.$k')).toList())),
        'solves': solves,
        'elapsed_ms': finite(elapsedMs, 'diagnosis.elapsed_ms'),
        'best_effort': bestEffort,
      });
}
