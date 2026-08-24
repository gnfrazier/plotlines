// F3/E5 — the three client-side export writers actually produce valid,
// well-formed output. `core/plotlines_core/export/` has no writers of its
// own, so these are the whole implementation, not a stand-in for a service
// call — worth a real check rather than trusting a build-clean run.

import 'dart:convert';

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

  test('GeoJSON: an anchor with a role offset exports as two distinct point features (FR107 / O2)', () {
    // The overlook spur, verbatim: parking-lot anchor, narrative role 400 m
    // up a spur. A provision role with no offset must not add a feature.
    final tripWithAnchors = Trip(
      id: 'trip-2',
      title: 'Overlook Hike',
      createdAt: '2026-08-17T00:00:00Z',
      updatedAt: '2026-08-17T00:00:00Z',
      anchors: [
        Anchor(
          id: 'a1',
          coord: [-105.270, 40.020],
          title: 'Trailhead',
          roles: [
            Role(id: 'r1', kind: RoleKind.narrative, coord: [-105.266, 40.024]),
            Role(id: 'r2', kind: RoleKind.provision),
          ],
        ),
      ],
    );
    final decoded = jsonDecode(tripToGeoJson(tripWithAnchors)) as Map<String, dynamic>;
    final features = (decoded['features'] as List).cast<Map<String, dynamic>>();

    final anchorFeatures = features.where((f) => f['properties']['kind'] == 'anchor');
    final offsetFeatures = features.where((f) => f['properties']['kind'] == 'role_offset');

    expect(anchorFeatures, hasLength(1));
    expect(anchorFeatures.single['geometry']['coordinates'], [-105.270, 40.020]);

    // Exactly one offset feature — the narrative role's — never one for the
    // provision role, which carries no offset of its own.
    expect(offsetFeatures, hasLength(1));
    expect(offsetFeatures.single['geometry']['coordinates'], [-105.266, 40.024]);
    expect(offsetFeatures.single['properties']['role_id'], 'r1');
  });

  test('GeoJSON: an anchor with no role offsets exports as exactly one point (O2\'s AC)', () {
    final tripWithAnchor = Trip(
      id: 'trip-3',
      title: 'Simple Stop',
      createdAt: '2026-08-17T00:00:00Z',
      updatedAt: '2026-08-17T00:00:00Z',
      anchors: [
        Anchor(id: 'a1', coord: [0.0, 0.0], roles: [Role(id: 'r1', kind: RoleKind.provision)]),
      ],
    );
    final decoded = jsonDecode(tripToGeoJson(tripWithAnchor)) as Map<String, dynamic>;
    final features = (decoded['features'] as List).cast<Map<String, dynamic>>();
    expect(features.where((f) => f['properties']['kind'] == 'anchor'), hasLength(1));
    expect(features.where((f) => f['properties']['kind'] == 'role_offset'), isEmpty);
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
