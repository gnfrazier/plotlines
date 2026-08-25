/// `$defs/attribute`, `$defs/band`, `$defs/violation`, `$defs/target_distance`.
library;

import 'json_utils.dart';

/// `$defs/attribute` — a REALISED route attribute, never a weight. Not a Dart enum:
/// payload.py itself carries this as a plain `str`, and a client-side enum would be
/// one more place to update when the schema's `attribute` list grows.
const List<String> attributeValues = [
  'distance_m',
  'climb_m',
  'descent_m',
  'traffic',
  'unpaved_frac',
  'scenic_frac',
  'salience',
];

/// FR6 / A5 — an inclusive acceptance range on one realised attribute. The schema's
/// `anyOf` requires at least one of [min]/[max]; both may be set.
class Band {
  Band({required this.attribute, this.min, this.max, this.source});

  final String attribute;
  final double? min;
  final double? max;
  final String? source;

  factory Band.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'band');
    final band = Band(
      attribute: f.takeString('attribute')!,
      min: f.takeNum('min'),
      max: f.takeNum('max'),
      source: f.takeString('source'),
    );
    f.done();
    return band;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'attribute': attribute,
        'min': min == null ? null : finite(min!, 'band.min'),
        'max': max == null ? null : finite(max!, 'band.max'),
        'source': source,
      });

  Band copyWith({String? attribute, double? min, double? max, String? source}) => Band(
        attribute: attribute ?? this.attribute,
        min: min ?? this.min,
        max: max ?? this.max,
        source: source ?? this.source,
      );
}

/// A6 / FR9 — one band the returned route does not satisfy.
class Violation {
  Violation({required this.attribute, required this.realised, required this.shortfall});

  final String attribute;
  final double realised;

  /// Signed, in the attribute's own units: negative under the min, positive over the max.
  final double shortfall;

  factory Violation.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'violation');
    final v = Violation(
      attribute: f.takeString('attribute')!,
      realised: f.takeNum('realised')!,
      shortfall: f.takeNum('shortfall')!,
    );
    f.done();
    return v;
  }

  Map<String, dynamic> toJson() => {
        'attribute': attribute,
        'realised': finite(realised, 'violation.realised'),
        'shortfall': finite(shortfall, 'violation.shortfall'),
      };
}

/// FR8 / A8 — banded by default, never a soft target. Loop and out-and-back only.
class TargetDistance {
  TargetDistance({required this.valueM, this.minM, this.maxM, this.advisory});

  final double valueM;
  final double? minM;
  final double? maxM;

  /// A9a — three-or-more via-nodes fix the loop's length; the target can only be
  /// reported, not honoured.
  final bool? advisory;

  factory TargetDistance.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'target_distance');
    final t = TargetDistance(
      valueM: f.takeNum('value_m')!,
      minM: f.takeNum('min_m'),
      maxM: f.takeNum('max_m'),
      advisory: f.takeBool('advisory'),
    );
    f.done();
    return t;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'value_m': finite(valueM, 'target_distance.value_m'),
        'min_m': minM == null ? null : finite(minM!, 'target_distance.min_m'),
        'max_m': maxM == null ? null : finite(maxM!, 'target_distance.max_m'),
        'advisory': advisory,
      });
}
