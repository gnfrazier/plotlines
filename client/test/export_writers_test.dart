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

  test('GeoJSON: an anchor area exports as a Polygon feature alongside its point (FR108 / O3)', () {
    const ring = [
      [-105.28, 40.01],
      [-105.27, 40.01],
      [-105.27, 40.02],
      [-105.28, 40.02],
      [-105.28, 40.01],
    ];
    final tripWithArea = Trip(
      id: 'trip-4',
      title: 'Main Street',
      createdAt: '2026-08-17T00:00:00Z',
      updatedAt: '2026-08-17T00:00:00Z',
      anchors: [
        Anchor(
          id: 'a1',
          coord: [-105.275, 40.015],
          title: 'Historic District',
          area: Area(rings: [ring]),
          roles: [Role(id: 'r1', kind: RoleKind.narrative)],
        ),
      ],
    );
    final decoded = jsonDecode(tripToGeoJson(tripWithArea)) as Map<String, dynamic>;
    final features = (decoded['features'] as List).cast<Map<String, dynamic>>();

    // The point feature (the representative pin) still exports — the area
    // is additive, never a replacement (O2's AC extended to O3).
    final anchorPoints = features.where((f) => f['properties']['kind'] == 'anchor');
    expect(anchorPoints, hasLength(1));
    expect(anchorPoints.single['geometry']['type'], 'Point');

    final areaFeatures = features.where((f) => f['properties']['kind'] == 'anchor_area');
    expect(areaFeatures, hasLength(1));
    final areaFeature = areaFeatures.single;
    expect(areaFeature['geometry']['type'], 'Polygon');
    expect(areaFeature['geometry']['coordinates'], [ring]);
    expect(areaFeature['properties']['anchor_id'], 'a1');
    expect(areaFeature['properties']['title'], 'Historic District');
  });

  test('GeoJSON: a role area offset exports as its own Polygon feature (FR108 / O3)', () {
    const anchorRing = [
      [0.0, 0.0],
      [1.0, 0.0],
      [1.0, 1.0],
      [0.0, 1.0],
      [0.0, 0.0],
    ];
    const roleRing = [
      [2.0, 2.0],
      [3.0, 2.0],
      [3.0, 3.0],
      [2.0, 3.0],
      [2.0, 2.0],
    ];
    final tripWithRoleArea = Trip(
      id: 'trip-5',
      title: 'Park With A Picnic Area',
      createdAt: '2026-08-17T00:00:00Z',
      updatedAt: '2026-08-17T00:00:00Z',
      anchors: [
        Anchor(
          id: 'a1',
          coord: [0.5, 0.5],
          area: Area(rings: [anchorRing]),
          roles: [
            Role(id: 'r1', kind: RoleKind.provision, area: Area(rings: [roleRing])),
            Role(id: 'r2', kind: RoleKind.narrative),
          ],
        ),
      ],
    );
    final decoded = jsonDecode(tripToGeoJson(tripWithRoleArea)) as Map<String, dynamic>;
    final features = (decoded['features'] as List).cast<Map<String, dynamic>>();

    final anchorAreas = features.where((f) => f['properties']['kind'] == 'anchor_area');
    final roleAreas = features.where((f) => f['properties']['kind'] == 'role_area');
    expect(anchorAreas, hasLength(1));
    // Only the provision role carries its own area; the narrative role,
    // which has none, adds no feature — mirrors role_offset's "no offset,
    // no feature" rule (O2's AC).
    expect(roleAreas, hasLength(1));
    expect(roleAreas.single['geometry']['coordinates'], [roleRing]);
    expect(roleAreas.single['properties']['role_id'], 'r1');
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

  // FR45 — exported waypoints / course points preserve the plot-point note
  // as a native field, where the target format supports one.
  group('FR45: plot-point notes preserved', () {
    Trip tripWithNotedNode({String? segmentNote, String? dayNote}) {
      final segment = Segment(
        id: 'seg-1',
        mode: 'cycling',
        shape: 'point_to_point',
        geometry: LineString(
          coordinates: [
            [-105.2705, 40.0150],
            [-105.2800, 40.0200],
          ],
          source: 'solved',
        ),
        metrics: RouteMetrics(distanceM: 1200.0, climbM: 10.0, descentM: 5.0, movingTimeS: 300.0),
        nodes: [
          Node(
            id: 'n1',
            kind: NodeKind.poi,
            coord: [-105.2750, 40.0180],
            title: 'Overlook',
            note: segmentNote,
          ),
        ],
      );
      return Trip(
        id: 'trip-note',
        title: 'Noted Ride',
        createdAt: '2026-08-17T00:00:00Z',
        updatedAt: '2026-08-17T00:00:00Z',
        days: [
          Day(
            id: 'day-1',
            index: 1,
            kind: 'route',
            segments: [segment],
            nodes: [
              if (dayNote != null)
                Node(
                  id: 'dn1',
                  kind: NodeKind.regroup,
                  coord: [-105.2780, 40.0195],
                  title: 'Regroup at the gate',
                  note: dayNote,
                ),
            ],
          ),
        ],
      );
    }

    test('GPX: the note becomes a <desc> on the <wpt>, before <type>, still well-formed', () {
      final gpx = tripToGpx(tripWithNotedNode(segmentNote: 'Loose gravel on the descent'));
      final doc = xml.XmlDocument.parse(gpx);
      final wpt = doc.findAllElements('wpt').single;
      expect(wpt.findElements('desc').single.innerText, 'Loose gravel on the descent');
      // GPX 1.1 schema orders <desc> before <type> inside <wpt>.
      final children = wpt.childElements.map((e) => e.name.local).toList();
      expect(children.indexOf('desc'), lessThan(children.indexOf('type')));
    });

    test('GPX: a node with no note emits no empty <desc>', () {
      final gpx = tripToGpx(tripWithNotedNode());
      final wpt = xml.XmlDocument.parse(gpx).findAllElements('wpt').single;
      expect(wpt.findElements('desc'), isEmpty);
    });

    test('TCX: the note becomes <Notes> on the <CoursePoint>', () {
      final tcx = tripToTcx(tripWithNotedNode(segmentNote: 'Photograph the valley here'));
      final doc = xml.XmlDocument.parse(tcx);
      final cp = doc.findAllElements('CoursePoint').single;
      expect(cp.findElements('Notes').single.innerText, 'Photograph the valley here');
    });

    test('GeoJSON: the note rides along as a feature property', () {
      final geojson = tripToGeoJson(tripWithNotedNode(segmentNote: 'Water source, treat before drinking'));
      final decoded = jsonDecode(geojson) as Map<String, dynamic>;
      final features = (decoded['features'] as List).cast<Map<String, dynamic>>();
      final node = features.firstWhere((f) => f['properties']['kind'] == 'node');
      expect(node['properties']['note'], 'Water source, treat before drinking');
    });

    test('TCX: a day-scoped regroup node exports as its own CoursePoint (FR45 regroup markers)', () {
      final tcx = tripToTcx(tripWithNotedNode(dayNote: 'Wait for the whole group'));
      final doc = xml.XmlDocument.parse(tcx);
      final points = doc.findAllElements('CoursePoint').toList();
      // One for the segment node, one for the day-scoped regroup node.
      expect(points.length, 2);
      final regroup = points.firstWhere((p) => p.findElements('Name').single.innerText == 'Regroup at the gate');
      expect(regroup.findElements('Notes').single.innerText, 'Wait for the whole group');
    });

    test('GPX: a day-scoped regroup node keeps its note as <desc>', () {
      final gpx = tripToGpx(tripWithNotedNode(dayNote: 'Wait for the whole group'));
      final doc = xml.XmlDocument.parse(gpx);
      final wpt = doc
          .findAllElements('wpt')
          .firstWhere((w) => w.findElements('name').single.innerText == 'Regroup at the gate');
      expect(wpt.findElements('desc').single.innerText, 'Wait for the whole group');
    });
  });
}
