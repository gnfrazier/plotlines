// Issue #321 item 4 (carried from #230's outstanding contrast check) —
// waterway / water-body labels in the bundled basemap style were a washed
// light blue (`#728dd4` light, `#717784` dark) with no halo, landing around
// 2:1 against the `#cccccc` landcover. WCAG 2.2 AA is Plotlines' floor
// (plotlines-constraints), so this pins the label colour and its halo
// against the backgrounds it actually sits on. It fails against the
// pre-#321 style.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

/// WCAG relative luminance of a `#rrggbb` string.
double _luminance(String hex) {
  final h = hex.replaceFirst('#', '');
  final rgb = [
    int.parse(h.substring(0, 2), radix: 16),
    int.parse(h.substring(2, 4), radix: 16),
    int.parse(h.substring(4, 6), radix: 16),
  ].map((v) {
    final c = v / 255.0;
    return c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }).toList();
  return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
}

double _contrast(String a, String b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

List<Map<String, dynamic>> _waterLabelLayers(String styleName) {
  final raw = File('assets/map_style/style_$styleName.json').readAsStringSync();
  final style = jsonDecode(raw) as Map<String, dynamic>;
  return (style['layers'] as List)
      .cast<Map<String, dynamic>>()
      .where((l) => const {
            'water_waterway_label',
            'water_label_ocean',
            'water_label_lakes',
          }.contains(l['id']))
      .toList();
}

void main() {
  // The self-check: our own contrast maths against a known WCAG pair.
  test('contrast helper matches the WCAG reference (#000 on #fff = 21)', () {
    expect(_contrast('#000000', '#ffffff'), closeTo(21.0, 0.01));
  });

  // Representative landcover / water fills the labels are drawn over, read
  // from each committed style. Kept as literals with the layer they come
  // from so a style edit that moves them shows up here.
  const lightBackdrops = {
    'background': '#cccccc',
    'landuse_park (z12)': '#9cd3b4',
    'water fill': '#80deea',
  };
  const darkBackdrops = {
    'background': '#34373d',
    'landuse_park': '#232325',
    'earth': '#1f1f1f',
  };

  for (final entry in {
    'light': lightBackdrops,
    'dark': darkBackdrops,
  }.entries) {
    final styleName = entry.key;
    final backdrops = entry.value;

    group('style_$styleName water labels', () {
      final layers = _waterLabelLayers(styleName);

      test('all three water-label layers are present', () {
        expect(layers.map((l) => l['id']),
            containsAll(['water_waterway_label', 'water_label_ocean', 'water_label_lakes']));
      });

      for (final layer in layers) {
        final id = layer['id'] as String;
        final paint = layer['paint'] as Map<String, dynamic>;
        final textColor = paint['text-color'] as String;

        test('$id text colour clears 4.5:1 on every backdrop', () {
          backdrops.forEach((where, bg) {
            expect(_contrast(textColor, bg), greaterThanOrEqualTo(4.5),
                reason: '$id ($textColor) on $where ($bg)');
          });
        });

        test('$id carries a halo (needed for the varied water fill)', () {
          expect(paint['text-halo-color'], isA<String>());
          expect(paint['text-halo-width'], isNotNull);
          // The halo must actually contrast the glyph, not tint it.
          final haloVsText = _contrast(textColor, paint['text-halo-color'] as String);
          expect(haloVsText, greaterThanOrEqualTo(3.0),
              reason: '$id halo ${paint['text-halo-color']} vs text $textColor');
        });
      }
    });
  }
}
