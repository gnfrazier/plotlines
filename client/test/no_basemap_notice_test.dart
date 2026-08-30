// Issue #154 — the honest-empty basemap check: "the notice appears when
// the current camera has no coverage, not when the tile directory is
// missing." `tilesLikelyCoverViewport` is the pure predicate every map
// widget's notice now gates on. Issue #184 adds the style-defect vs.
// coverage wording split. These exercise the predicate and the notice
// widget directly rather
// than through a full map widget.
import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' as ll;

import 'package:plotlines_client/domain/home_region.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/map/no_basemap_notice.dart';

LatLngBounds _boundsAround(double lat, double lon, {double span = 0.01}) => LatLngBounds(
      ll.LatLng(lat - span, lon - span),
      ll.LatLng(lat + span, lon + span),
    );

void main() {
  test('a viewport centred on the home region is covered', () {
    final viewport = _boundsAround(HomeRegion.centerLat, HomeRegion.centerLon);
    expect(tilesLikelyCoverViewport(viewport), isTrue);
  });

  test('a viewport far from the home region and with no trip bbox is not covered', () {
    // The Boulder, CO fixture's own coordinates — nowhere near Buncombe
    // County and, deliberately, not passed as a tripBbox here.
    final viewport = _boundsAround(40.02, -105.27);
    expect(tilesLikelyCoverViewport(viewport), isFalse);
  });

  test('a viewport inside the trip bbox is covered even far from the home region', () {
    const tripBbox = TripBbox(minLat: 39.9, minLon: -105.4, maxLat: 40.1, maxLon: -105.1);
    final viewport = _boundsAround(40.0, -105.25);
    expect(tilesLikelyCoverViewport(viewport, tripBbox: tripBbox), isTrue);
  });

  test('a viewport outside both the home region and the trip bbox is not covered', () {
    const tripBbox = TripBbox(minLat: 39.9, minLon: -105.4, maxLat: 40.1, maxLon: -105.1);
    final viewport = _boundsAround(-33.87, 151.21); // Sydney — nowhere near either
    expect(tilesLikelyCoverViewport(viewport, tripBbox: tripBbox), isFalse);
  });

  group('NoBasemapNotice text distinguishes coverage from a style defect (issue #184)', () {
    Future<String> noticeText(WidgetTester tester, NoBasemapNotice notice) async {
      // Mirror production: the notice sits in a `Positioned` inside a
      // `Stack`, i.e. with unbounded width — never a fixed-width Row.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [Positioned(left: 0, bottom: 0, child: notice)]),
        ),
      ));
      return tester.widget<Text>(find.byType(Text)).data!;
    }

    testWidgets('loading wins over every other flag', (tester) async {
      final text = await noticeText(
        tester,
        const NoBasemapNotice(loading: true, outOfCoverage: true, styleFailed: true),
      );
      expect(text, 'Loading basemap…');
    });

    testWidgets('a style failure reads as a defect, not a coverage answer', (tester) async {
      final text = await noticeText(
        tester,
        const NoBasemapNotice(loading: false, styleFailed: true),
      );
      expect(text, contains('style failed to load'));
      expect(text, isNot(contains('No basemap tiles here')));
    });

    testWidgets('out-of-coverage keeps its own legitimate wording', (tester) async {
      final text = await noticeText(
        tester,
        const NoBasemapNotice(loading: false, outOfCoverage: true),
      );
      expect(text, startsWith('No basemap tiles here'));
      expect(text, contains('outside the shipped home region'));
    });

    testWidgets('the bare fallback is unchanged', (tester) async {
      final text = await noticeText(tester, const NoBasemapNotice(loading: false));
      expect(text, 'No basemap tiles here');
    });
  });

  test('a viewport straddling the home region edge still counts as covered', () {
    // Partial overlap is enough — this is a plausibility check, not "the
    // whole viewport is covered."
    final viewport = LatLngBounds(
      ll.LatLng(HomeRegion.maxLat - 0.01, HomeRegion.maxLon - 0.01),
      ll.LatLng(HomeRegion.maxLat + 0.5, HomeRegion.maxLon + 0.5),
    );
    expect(tilesLikelyCoverViewport(viewport), isTrue);
  });
}
