// Issue #321 — the app's text scale, and a desktop DPR floor, reach the
// vector map theme.
//
// #230 A3 fixed one half of "map labels are too small" (the tile was packed
// into a 256-logical-px square; see `vector_tile_provider.dart`'s
// `TileOffset.mapbox`). Two causes were left:
//
//  1. The app is scalable and the map inside it is not. `main.dart`'s
//     `_TextScale` wrapper applies the TEXT SIZE preference to every Flutter
//     `Text`, but the vector basemap renders its own labels from the style
//     JSON and never sees that scaler — so "130%" means one thing outside the
//     map pane and nothing inside it.
//  2. The bundled Protomaps type ramp is authored for a phone at
//     devicePixelRatio 2–3. On a desktop pane at DPR 1.0 (every WSLg build,
//     and any unscaled 1080p panel) each label lands at roughly half the
//     physical size it was drawn for, independently of any offset bug.
//
// Both are corrected by multiplying the style's `text-size` before the theme
// is parsed. This file is the pure arithmetic and the pure JSON transform;
// `MapTileAssets.theme` (tap_to_pick_map.dart) is the only caller and the map
// widgets feed it the two inputs from their `BuildContext`.
library;

/// The DPR-aware baseline multiplier for map label size (#321 item 2).
///
/// The style's ramp assumes it will be rendered at about devicePixelRatio 2.
/// This returns how much of that shortfall to make up at the real DPR —
/// `2 / dpr`, so DPR 1.0 asks for 2.0× — capped at [_maxBaseline] so a large
/// bump does not turn a street name into a banner, and floored at 1.0 so a
/// Retina/HiDPI desktop (DPR ≥ 2) is left exactly as authored.
///
/// It is deliberately not conditioned on "is this desktop": a phone reports
/// DPR 2–3 and lands on the 1.0 floor on its own, so the same expression is
/// correct on every platform.
double desktopLabelBaseline(double devicePixelRatio) {
  if (devicePixelRatio <= 0 || devicePixelRatio.isNaN) return 1.0;
  final want = 2.0 / devicePixelRatio;
  return want.clamp(1.0, _maxBaseline);
}

const double _maxBaseline = 1.5;

/// The factor applied to every `text-size` in the style, combining the
/// resolved app text scale ([appTextScale], already platform × TEXT SIZE
/// preference from `resolveTextScale`) with the DPR baseline
/// ([desktopLabelBaseline]).
///
/// Clamped to [_maxLabelScale]: at DPR 1.0 with TEXT SIZE = Largest (150%)
/// the raw product is 2.25, which would set a z13 street label near 27 logical
/// px and start colliding labels. 2.0 keeps the largest step legible without
/// the map turning into a word cloud.
double resolveMapLabelScale(double appTextScale, double devicePixelRatio) {
  final combined = desktopLabelBaseline(devicePixelRatio) * appTextScale;
  return combined.clamp(1.0, _maxLabelScale);
}

const double _maxLabelScale = 2.0;

/// [factor] rounded to a coarse bucket, so `MapTileAssets.theme`'s cache is
/// keyed by something that changes when the Author moves the TEXT SIZE
/// control but not on every sub-pixel DPR wobble. 0.05 steps — finer than any
/// perceptible label-size change, coarse enough that the four TEXT SIZE
/// settings land in four distinct buckets.
String mapLabelScaleBucket(double factor) =>
    (factor.clamp(1.0, _maxLabelScale) * 20).round().toString();

/// Returns a deep copy of [style] with every symbol layer's `text-size`
/// multiplied by [factor], leaving the input untouched.
///
/// Rather than rewrite the literals inside an `interpolate` / `case` / `step`
/// expression — which would mean re-deriving each expression grammar — the
/// original `text-size` value is wrapped in a MapLibre multiply expression:
///
///     "text-size": ["*", <original>, <factor>]
///
/// `vector_tile_renderer`'s expression parser evaluates the inner value to a
/// number and multiplies, so this is correct for a plain number, a zoom
/// interpolation, a `{stops}` object, and a per-feature `case` alike — and a
/// stop that resolves to 0 (the style's way of hiding a label below a
/// population rank) stays 0.
///
/// A [factor] within [_identityEpsilon] of 1.0 returns the style unchanged
/// (still a copy) so the DPR-2 / no-preference path parses exactly the bytes
/// that shipped.
Map<String, dynamic> scaleStyleTextSizes(
  Map<String, dynamic> style,
  double factor,
) {
  final copy = _deepCopyMap(style);
  if ((factor - 1.0).abs() < _identityEpsilon) return copy;

  final layers = copy['layers'];
  if (layers is! List) return copy;

  for (final layer in layers) {
    if (layer is! Map) continue;
    if (layer['type'] != 'symbol') continue;
    final layout = layer['layout'];
    if (layout is! Map) continue;
    if (!layout.containsKey('text-field')) continue;

    // An explicit `text-size`, or the renderer's own default of 16 when a
    // symbol layer has a `text-field` but no size — scale both so a label
    // relying on the default is not left behind.
    final original = layout.containsKey('text-size') ? layout['text-size'] : 16;
    layout['text-size'] = <dynamic>['*', original, factor];
  }
  return copy;
}

const double _identityEpsilon = 0.001;

Map<String, dynamic> _deepCopyMap(Map<String, dynamic> src) {
  final out = <String, dynamic>{};
  src.forEach((k, v) => out[k] = _deepCopyValue(v));
  return out;
}

dynamic _deepCopyValue(dynamic v) {
  if (v is Map) {
    final out = <String, dynamic>{};
    v.forEach((k, val) => out[k as String] = _deepCopyValue(val));
    return out;
  }
  if (v is List) {
    return v.map(_deepCopyValue).toList();
  }
  return v;
}
