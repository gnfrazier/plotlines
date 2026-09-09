// Issue #154 — the honest-empty basemap check: "the notice appears when
// the current camera has no coverage, not when the tile directory is
// missing." `tilesLikelyCoverViewport` is the pure predicate every map
// widget's notice now gates on. Issue #184 adds the style-defect vs.
// coverage wording split.
//
// Issue #318 — the predicate now answers "what fraction of the viewport is
// covered," not "do these rectangles touch." A viewport mostly outside the
// archive that clips one corner of a coverage area used to report covered,
// which suppressed the notice on exactly the screen (a small box of tiles
// in a large grey pane) that needed it.
//
// These exercise the predicate and the notice widget directly rather than
// through a full map widget.
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

LatLngBounds _bounds({
  required double south,
  required double west,
  required double north,
  required double east,
}) =>
    LatLngBounds(ll.LatLng(south, west), ll.LatLng(north, east));

void main() {
  test('a viewport centred on the home region is covered', () {
    final viewport = _boundsAround(HomeRegion.centerLat, HomeRegion.centerLon);
    expect(coveredViewportFraction(viewport), 1.0);
    expect(tilesLikelyCoverViewport(viewport), isTrue);
  });

  test('a viewport far from the home region and with no trip bbox is not covered', () {
    // The Boulder, CO fixture's own coordinates — nowhere near Buncombe
    // County and, deliberately, not passed as a tripBbox here.
    final viewport = _boundsAround(40.02, -105.27);
    expect(coveredViewportFraction(viewport), 0.0);
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

  group('coverage is measured as a fraction, not an intersection (issue #318)', () {
    test('a viewport that only clips a corner of coverage reads as out-of-coverage', () {
      // The straddle case that returned `true` before #318: the covered
      // corner is 0.01° × 0.01° of a 0.51° × 0.51° viewport — ~0.04%.
      final viewport = _bounds(
        south: HomeRegion.maxLat - 0.01,
        west: HomeRegion.maxLon - 0.01,
        north: HomeRegion.maxLat + 0.5,
        east: HomeRegion.maxLon + 0.5,
      );
      expect(coveredViewportFraction(viewport), lessThan(0.01));
      expect(tilesLikelyCoverViewport(viewport), isFalse);
    });

    test('a viewport mostly outside the archive (the #318 screenshot) is out-of-coverage', () {
      // 1.0° wide, 0.1° tall; the home region covers a 0.26° × 0.1° slice —
      // ~26% of the frame, the rest bare ground.
      final viewport = _bounds(south: 35.50, west: -82.40, north: 35.60, east: -81.40);
      expect(coveredViewportFraction(viewport), closeTo(0.26, 0.005));
      expect(tilesLikelyCoverViewport(viewport), isFalse);
    });

    test('a viewport mostly inside the archive is covered even when its edge runs off', () {
      // 0.83° wide, 0.3° tall; the home region covers a 0.69° × 0.3° slice —
      // ~83% of the frame.
      final viewport = _bounds(south: 35.40, west: -82.83, north: 35.70, east: -82.00);
      expect(coveredViewportFraction(viewport), closeTo(0.83, 0.01));
      expect(tilesLikelyCoverViewport(viewport), isTrue);
    });

    test('the trip bbox is unioned with the home region, not double-counted where they overlap', () {
      // Trip bbox identical to the home region. Viewport 1.53° wide, lat
      // wholly inside — the home region alone covers 0.69/1.53 ≈ 45%, and a
      // naive sum would report ~90% and flip the notice off.
      const sameAsHome = TripBbox(
        minLat: HomeRegion.minLat,
        minLon: HomeRegion.minLon,
        maxLat: HomeRegion.maxLat,
        maxLon: HomeRegion.maxLon,
      );
      final viewport = _bounds(south: 35.40, west: -82.83, north: 35.70, east: -81.30);
      expect(
        coveredViewportFraction(viewport, tripBbox: sameAsHome),
        closeTo(0.451, 0.005),
      );
      expect(tilesLikelyCoverViewport(viewport, tripBbox: sameAsHome), isFalse);
    });

    test('a trip bbox abutting the home region tips a half-covered viewport back over the line', () {
      // Home region on the left half, trip bbox on the right half; neither
      // alone clears the threshold, together they do.
      const eastBbox = TripBbox(
        minLat: 35.36,
        minLon: -82.14,
        maxLat: 35.79,
        maxLon: -81.70,
      );
      final viewport = _bounds(south: 35.20, west: -82.50, north: 35.90, east: -81.70);
      expect(coveredViewportFraction(viewport), closeTo(0.276, 0.005));
      expect(tilesLikelyCoverViewport(viewport), isFalse);
      expect(
        coveredViewportFraction(viewport, tripBbox: eastBbox),
        closeTo(0.614, 0.005),
      );
      expect(tilesLikelyCoverViewport(viewport, tripBbox: eastBbox), isTrue);
    });
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

  testWidgets('MapGraticule renders its ground without a map camera to project against', (tester) async {
    // Outside a FlutterMap there is no camera — the widget must still paint
    // the designed ground and a reference grid rather than throw.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MapGraticule(
          ground: Color(0xFFEBE3D4),
          line: Color(0xFF8C8476),
          label: Color(0xFF544D42),
        ),
      ),
    ));
    expect(find.byType(MapGraticule), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
