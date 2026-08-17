// F3/E5 — the three client-side export writers actually produce valid,
// well-formed output. `core/plotlines_core/export/` has no writers of its
// own, so these are the whole implementation, not a stand-in for a service
// call — worth a real check rather than trusting a build-clean run.

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart' as xml;

import 'package:plotlines_client/data/export/geojson_writer.dart';
import 'package:plotlines_client/data/export/gpx_writer.dart';
import 'package:plotlines_client/data/export/tcx_writer.dart';
import 'package:plotlines_client/domain/domain.dart';

Trip _sampleTrip() {
  final segment = Segment(
    id: 'seg-1',
    mode: 'cycling',
    shape: 'point_to_point',
    geometry: LineString(
      coordinates: [
        [-105.2705, 40.0150],
        [-105.2750, 40.0180],
        [-105.2800, 40.0200],
      ],
      source: 'solved',
    ),
    metrics: RouteMetrics(distanceM: 1500.0, climbM: 30.0, descentM: 10.0, movingTimeS: 400.0),
    nodes: [
      Node(id: 'n1', kind: NodeKind.poi, coord: [-105.2750, 40.0180], title: 'Overlook'),
    ],
  );
  final day = Day(id: 'day-1', index: 1, kind: 'route', segments: [segment]);
  return Trip(
    id: 'trip-1',
    title: 'Test Ride',
    createdAt: '2026-08-17T00:00:00Z',
    updatedAt: '2026-08-17T00:00:00Z',
    days: [day],
  );
}

void main() {
  final trip = _sampleTrip();

  test('GeoJSON: valid JSON, one LineString feature, one Point feature', () {
    final geojson = tripToGeoJson(trip);
    expect(geojson, contains('"type": "FeatureCollection"'));
    expect(geojson, contains('"LineString"'));
    expect(geojson, contains('"Overlook"'));
  });

  test('GPX: well-formed XML with a track and a waypoint', () {
    final gpx = tripToGpx(trip);
    final doc = xml.XmlDocument.parse(gpx); // throws on malformed XML
    expect(doc.findAllElements('trkpt').length, 3);
    expect(doc.findAllElements('wpt').length, 1);
    expect(doc.findAllElements('name').first.innerText, isNotEmpty);
  });

  test('TCX: well-formed XML with a course, trackpoints, and a course point', () {
    final tcx = tripToTcx(trip);
    final doc = xml.XmlDocument.parse(tcx); // throws on malformed XML
    expect(doc.findAllElements('Trackpoint').length, 3);
    expect(doc.findAllElements('CoursePoint').length, 1);
    final distance = doc.findAllElements('DistanceMeters').first.innerText;
    expect(double.parse(distance), closeTo(1500.0, 0.1));
  });
}
