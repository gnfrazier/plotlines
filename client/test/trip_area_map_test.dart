// N1 (PRD FR120) — the bbox-drawing map: dragging while in draw mode
// proposes a rectangle from the drag's two corners; once a bbox exists and
// drawing has stopped, corner handles are offered instead. This is a
// controlled widget (see the file's own doc comment) — it never mutates
// [TripAreaMap.bbox] itself, only proposes via [onProposeChange].
//
// Issue #154's verification list calls this out by name: the harness used
// to center on the Boulder fixture ([-105.27, 40.02]) and so never
// exercised the Buncombe County path every other part of this fix moved to
// — re-pointed at `HomeRegion`'s own center.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drift/native.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/home_region.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/map/tap_to_pick_map.dart' show MapTileAssets;
import 'package:plotlines_client/presentation/map/map_label_scale.dart';
import 'package:plotlines_client/presentation/map/trip_area_map.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart' show VectorTileLayer, VectorTileLayerMode;
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/settings_provider.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}

  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

/// Issue #522 — a sidecar with a basemap cell filling over the home region
/// (Greensboro stands in: any cell the viewport reaches), until [land].
class _FillingTilesSidecarManager extends _FakeSidecarManager {
  bool _landed = false;

  void land() {
    _landed = true;
    notifyListeners();
  }

  @override
  Capabilities? get capabilities => Capabilities.fromJson({
        'tiles': {
          'ready': true,
          'archive': _landed ? 'after-fill' : 'before-fill',
          'regions': {
            'r1': _landed
                ? {'ready': true}
                : {
                    'ready': false,
                    'reason': 'The map-data mirror is fetching the basemap for this area.',
                    'pending_upstream': true,
                    'progress': 0.0,
                    'cells': [
                      [-84.0, 34.0, -80.0, 38.0],
                    ],
                  },
          },
        },
        'layers': {'ready': true},
        'routing': {'regions': <String, dynamic>{}},
        'elevation': {'ready': true},
      });
}

/// flutter_map's vector tile loading leaves a ticker that a single `pump()`
/// doesn't fully settle (same issue `trip_library_screen_test.dart`'s
/// `_settleMap` works around) — several short pumps clear it without the
/// hang a `pumpAndSettle()` risks on that same ticker.
Future<void> _settleMap(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Widget _harness({
  required bool drawing,
  TripBbox? bbox,
  required ValueChanged<TripBbox> onProposeChange,
}) {
  return ProviderScope(
    overrides: [sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager())],
    child: MaterialApp(
      home: Scaffold(
        body: TripAreaMap(
          center: HomeRegion.center,
          bbox: bbox,
          drawing: drawing,
          onProposeChange: onProposeChange,
        ),
      ),
    ),
  );
}

/// Issue #465 — an in-memory settings DB pre-seeded with a basemap-style
/// choice (settings_provider_test.dart's own pattern), plus a chosen
/// [Brightness], for the basemap-style-selection tests below.
Future<Widget> _harnessWithBasemapPref({
  required BasemapStylePref basemapStyle,
  required Brightness brightness,
}) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await db.setSetting('basemap_style', basemapStyle.name);
  return ProviderScope(
    overrides: [
      sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
      appDatabaseProvider.overrideWithValue(db),
    ],
    child: MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: TripAreaMap(
          center: HomeRegion.center,
          bbox: null,
          drawing: false,
          onProposeChange: (_) {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('dragging in draw mode proposes a bbox spanning the drag', (tester) async {
    TripBbox? proposed;
    await tester.pumpWidget(_harness(drawing: true, onProposeChange: (b) => proposed = b));
    await _settleMap(tester);

    await tester.dragFrom(const Offset(200, 150), const Offset(120, 90));
    await _settleMap(tester);

    expect(proposed, isNotNull);
    // The two corners are distinct on both axes — a real rectangle, not a
    // degenerate point or line.
    expect(proposed!.minLat, lessThan(proposed!.maxLat));
    expect(proposed!.minLon, lessThan(proposed!.maxLon));
  });

  testWidgets('a drag thinner than TripBbox.minSideM proposes nothing (#628)', (tester) async {
    // At the harness's z9 one logical pixel is ~250 m here, so half a pixel
    // of height is a ~125 m sliver: #628's 110 m × 6 m press, scaled.
    var calls = 0;
    await tester.pumpWidget(_harness(drawing: true, onProposeChange: (_) => calls++));
    await _settleMap(tester);

    await tester.dragFrom(const Offset(200, 150), const Offset(120, 0.5));
    await _settleMap(tester);

    expect(calls, 0);
  });

  testWidgets('dragging while not in draw mode never proposes a new bbox', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_harness(drawing: false, onProposeChange: (_) => calls++));
    await _settleMap(tester);

    await tester.dragFrom(const Offset(200, 150), const Offset(120, 90));
    await _settleMap(tester);

    expect(calls, 0);
  });

  testWidgets('a committed bbox offers four corner handles once drawing stops', (tester) async {
    final bbox = TripBbox(
      minLat: HomeRegion.minLat,
      minLon: HomeRegion.minLon,
      maxLat: HomeRegion.maxLat,
      maxLon: HomeRegion.maxLon,
    );
    await tester.pumpWidget(_harness(drawing: false, bbox: bbox, onProposeChange: (_) {}));
    await _settleMap(tester);

    expect(find.byTooltip('Recenter'), findsOneWidget);
    // Four resize handles, one per corner, each its own drag target.
    final handles = find.byWidgetPredicate(
      (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeUpLeftDownRight,
    );
    expect(handles, findsNWidgets(4));
  });

  testWidgets('no bbox yet and not drawing offers no handles', (tester) async {
    await tester.pumpWidget(_harness(drawing: false, onProposeChange: (_) {}));
    await _settleMap(tester);

    final handles = find.byWidgetPredicate(
      (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeUpLeftDownRight,
    );
    expect(handles, findsNothing);
  });

  group('basemap style preference (issue #465)', () {
    testWidgets('an explicit preference reaches MapTileAssets.theme', (tester) async {
      await tester.pumpWidget(await _harnessWithBasemapPref(
        basemapStyle: BasemapStylePref.grayscale,
        brightness: Brightness.light,
      ));
      await _settleMap(tester);

      expect(
        MapTileAssets.requestedKeysForTesting.any((k) => k.startsWith('grayscale@')),
        isTrue,
      );
    });

    testWidgets('matchAppearance still tracks the device brightness (regression guard)',
        (tester) async {
      await tester.pumpWidget(await _harnessWithBasemapPref(
        basemapStyle: BasemapStylePref.matchAppearance,
        brightness: Brightness.dark,
      ));
      await _settleMap(tester);

      expect(
        MapTileAssets.requestedKeysForTesting.any((k) => k.startsWith('dark@')),
        isTrue,
      );
    });
  });

  testWidgets('a filling basemap cell shows the mirror wait, and the tiles reload '
      'when it lands (issue #522)', (tester) async {
    final sidecar = _FillingTilesSidecarManager();
    // The style is real file I/O, which never completes under the test's
    // fake clock — parse it for real first, under the key the map asks for.
    // Its own DPR gives it its own cache key: an earlier test in this file
    // left the default key holding a future its fake clock never finished.
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => MapTileAssets.theme('light',
        labelScale: resolveMapLabelScale(1, tester.view.devicePixelRatio)));
    await tester.pumpWidget(ProviderScope(
      overrides: [sidecarManagerProvider.overrideWith((ref) => sidecar)],
      child: MaterialApp(
        home: Scaffold(
          body: TripAreaMap(
            center: HomeRegion.center,
            bbox: null,
            drawing: false,
            onProposeChange: (_) {},
          ),
        ),
      ),
    ));
    // One real-time turn so the FutureBuilder sees the parsed theme.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await _settleMap(tester);

    expect(find.text(kMirrorFetchingSentence), findsOneWidget);
    expect(find.textContaining('No basemap tiles here'), findsNothing);
    final before = tester.widget<VectorTileLayer>(find.byType(VectorTileLayer)).key;
    // Issue #575 — the basemap re-renders at the camera's zoom, so its labels
    // hold their size between zoom levels instead of scaling with a raster.
    expect(tester.widget<VectorTileLayer>(find.byType(VectorTileLayer)).layerMode,
        VectorTileLayerMode.vector);

    sidecar.land();
    await _settleMap(tester);

    expect(find.text(kMirrorFetchingSentence), findsNothing);
    // A new archive identity is a fresh layer: every tile is asked again.
    expect(tester.widget<VectorTileLayer>(find.byType(VectorTileLayer)).key, isNot(before));

    // The live tile layer leaves timers of its own; let them run out.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}
