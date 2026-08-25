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

import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/home_region.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/map/trip_area_map.dart';
import 'package:plotlines_client/state/providers.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}

  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
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
}
