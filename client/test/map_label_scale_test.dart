// Issue #321 — the app's TEXT SIZE preference and a desktop DPR floor must
// reach the vector map theme. These exercise the pure arithmetic and the
// pure style transform in `map_label_scale.dart`, plus an end-to-end check
// that a scaled copy of the committed style still parses.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/presentation/map/map_label_scale.dart';
import 'package:plotlines_client/presentation/map/tap_to_pick_map.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

void main() {
  group('desktopLabelBaseline', () {
    test('DPR 1.0 desktop asks for the capped 1.5x', () {
      expect(desktopLabelBaseline(1.0), 1.5);
    });

    test('DPR 1.5 makes up part of the shortfall', () {
      expect(desktopLabelBaseline(1.5), closeTo(2.0 / 1.5, 1e-9));
    });

    test('DPR 2.0 (phone / Retina) is left alone', () {
      expect(desktopLabelBaseline(2.0), 1.0);
    });

    test('DPR 3.0 never drops below the 1.0 floor', () {
      expect(desktopLabelBaseline(3.0), 1.0);
    });

    test('a nonsense DPR falls back to 1.0 rather than dividing by zero', () {
      expect(desktopLabelBaseline(0), 1.0);
      expect(desktopLabelBaseline(double.nan), 1.0);
    });
  });

  group('resolveMapLabelScale', () {
    test('DPR 2, no preference → exactly 1.0 (parse the shipped ramp)', () {
      expect(resolveMapLabelScale(1.0, 2.0), 1.0);
    });

    test('DPR 1 desktop, no preference → the 1.5x baseline', () {
      expect(resolveMapLabelScale(1.0, 1.0), 1.5);
    });

    test('app text scale multiplies the baseline', () {
      // 1.3 preference on a DPR 1.5 pane: 1.333.. * 1.3.
      expect(resolveMapLabelScale(1.3, 1.5), closeTo((2.0 / 1.5) * 1.3, 1e-9));
    });

    test('the product is capped at 2.0 so labels never collide', () {
      // DPR 1 (1.5 baseline) * 1.5 preference = 2.25 → clamped.
      expect(resolveMapLabelScale(1.5, 1.0), 2.0);
    });

    test('never returns below 1.0', () {
      expect(resolveMapLabelScale(0.5, 3.0), 1.0);
    });
  });

  group('mapLabelScaleBucket', () {
    test('the four preference-driven scales land in distinct buckets', () {
      final buckets = {
        mapLabelScaleBucket(1.0),
        mapLabelScaleBucket(1.15),
        mapLabelScaleBucket(1.3),
        mapLabelScaleBucket(1.5),
      };
      expect(buckets, hasLength(4));
    });

    test('a sub-perceptual DPR wobble does not change the bucket', () {
      expect(mapLabelScaleBucket(1.500), mapLabelScaleBucket(1.512));
    });
  });

  group('scaleStyleTextSizes', () {
    Map<String, dynamic> style() => {
          'version': 8,
          'layers': [
            {
              'id': 'bg',
              'type': 'background',
              'paint': {'background-color': '#fff'},
            },
            {
              'id': 'plain',
              'type': 'symbol',
              'layout': {
                'text-field': ['get', 'name'],
                'text-size': 12,
              },
            },
            {
              'id': 'ramp',
              'type': 'symbol',
              'layout': {
                'text-field': ['get', 'name'],
                'text-size': ['interpolate', ['linear'], ['zoom'], 3, 10, 10, 14],
              },
            },
            {
              'id': 'defaulted',
              'type': 'symbol',
              'layout': {
                'text-field': ['get', 'name'],
              },
            },
            {
              'id': 'not-a-label',
              'type': 'line',
              'layout': {'line-cap': 'round'},
            },
          ],
        };

    test('a plain numeric text-size is wrapped in a multiply', () {
      final out = scaleStyleTextSizes(style(), 1.5);
      final layout = (out['layers'] as List)[1]['layout'] as Map;
      expect(layout['text-size'], ['*', 12, 1.5]);
    });

    test('an expression text-size is wrapped whole, not rewritten', () {
      final out = scaleStyleTextSizes(style(), 2.0);
      final layout = (out['layers'] as List)[2]['layout'] as Map;
      expect(layout['text-size'], [
        '*',
        ['interpolate', ['linear'], ['zoom'], 3, 10, 10, 14],
        2.0,
      ]);
    });

    test('a symbol layer with no text-size gets the default 16 scaled', () {
      final out = scaleStyleTextSizes(style(), 1.5);
      final layout = (out['layers'] as List)[3]['layout'] as Map;
      expect(layout['text-size'], ['*', 16, 1.5]);
    });

    test('non-symbol layers are untouched', () {
      final out = scaleStyleTextSizes(style(), 1.5);
      final layout = (out['layers'] as List)[4]['layout'] as Map;
      expect(layout.containsKey('text-size'), isFalse);
    });

    test('a factor of 1.0 returns the style unchanged', () {
      final out = scaleStyleTextSizes(style(), 1.0);
      final layout = (out['layers'] as List)[1]['layout'] as Map;
      expect(layout['text-size'], 12);
    });

    test('the input is deep-copied, never mutated', () {
      final input = style();
      scaleStyleTextSizes(input, 1.8);
      final layout = (input['layers'] as List)[1]['layout'] as Map;
      expect(layout['text-size'], 12, reason: 'caller\'s map must be intact');
    });

    test('a scaled style is still a style ThemeReader accepts', () {
      final out = scaleStyleTextSizes(style(), 1.6);
      expect(() => ThemeReader().read(out), returnsNormally);
    });
  });

  group('the committed style, scaled', () {
    test('style_light parses at every preference-driven scale', () async {
      final paths = MapTileAssets.candidateStylePaths('light');
      for (final scale in [1.0, 1.15, 1.3, 1.5, 2.0]) {
        final result = await loadBasemapTheme(paths, labelScale: scale);
        expect(result.ok, isTrue,
            reason: 'style_light.json should parse at labelScale $scale');
      }
    });

    test('style_dark parses at the desktop baseline scale', () async {
      final paths = MapTileAssets.candidateStylePaths('dark');
      final result = await loadBasemapTheme(paths, labelScale: 1.5);
      expect(result.ok, isTrue);
    });
  });
}
