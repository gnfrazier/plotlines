// F3/E5 — the three client-side export writers actually produce valid,
// well-formed output. `core/plotlines_core/export/` has no writers of its
// own, so these are the whole implementation, not a stand-in for a service
// call — worth a real check rather than trusting a build-clean run.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart' as xml;

import 'package:plotlines_client/data/export/export_options.dart';
import 'package:plotlines_client/data/export/fit_writer.dart';
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

  group('FIT (issue #211 — core ships fit.py, client ports it)', () {
    int u16le(Uint8List b, int at) => b[at] | (b[at + 1] << 8);
    int u32le(Uint8List b, int at) =>
        b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);

    test('CRC-16/ARC matches the canonical check value', () {
      expect(fitCrc16(ascii.encode('123456789')), 0xBB3D);
    });

    test('produces a structurally valid FIT file: header, .FIT tag, both CRCs', () {
      final fit = tripToFit(trip);

      expect(fit[0], 14, reason: 'header size byte');
      expect(fit[1], 0x20, reason: 'FIT protocol 2.0');
      expect(String.fromCharCodes(fit.sublist(8, 12)), '.FIT');

      final dataSize = u32le(fit, 4);
      expect(fit.length, 14 + dataSize + 2,
          reason: 'header + body + trailing file CRC');

      // Header CRC covers the first 12 bytes; file CRC covers everything
      // before the trailing 2 bytes — the check a real head unit runs.
      expect(u16le(fit, 12), fitCrc16(fit.sublist(0, 12)));
      expect(u16le(fit, fit.length - 2),
          fitCrc16(fit.sublist(0, fit.length - 2)));
    });

    test('omitting waypoints drops the course_point messages (smaller file)', () {
      final withPoints = tripToFit(trip);
      final withoutPoints =
          tripToFit(trip, options: const ExportOptions(includeWaypoints: false));
      expect(withoutPoints.length, lessThan(withPoints.length));
    });

    test('a trip with no routed geometry throws rather than emitting a bad file', () {
      final empty = Trip(
        id: 'trip-empty',
        title: 'Nothing Routed',
        createdAt: '2026-08-17T00:00:00Z',
        updatedAt: '2026-08-17T00:00:00Z',
        days: [Day(id: 'd1', index: 1, kind: 'route')],
      );
      expect(() => tripToFit(empty), throwsStateError);
    });

    test('FR45: a long plot-point note is carried in the cue name, word-clipped', () {
      final noted = Trip(
        id: 'trip-fit-note',
        title: 'Noted Ride',
        createdAt: '2026-08-17T00:00:00Z',
        updatedAt: '2026-08-17T00:00:00Z',
        days: [
          Day(id: 'day-1', index: 1, kind: 'route', segments: [
            Segment(
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
              metrics: RouteMetrics(distanceM: 1200, movingTimeS: 300),
              nodes: [
                Node(
                  id: 'n1',
                  kind: NodeKind.poi,
                  coord: [-105.2750, 40.0180],
                  title: 'Overlook',
                  note:
                      'Loose gravel across the whole descent, take it slow here',
                ),
              ],
            ),
          ]),
        ],
      );
      final fit = tripToFit(noted);
      // The course_point.name string is UTF-8 + NUL somewhere in the body.
      final text = utf8.decode(fit, allowMalformed: true);
      expect(text, contains('Overlook — Loose'));
      // Clipped well under the raw note length, and not mid-word.
      expect(text, isNot(contains('Loose gravel across the whole descent')));
    });
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

  // F3/FR45 remaining gap — PRD v2.0 §4.3 defines "plot point" as an
  // Anchor's narrative role, not a Node; GPX and GeoJSON are the two formats
  // with a native standalone-point construct, so they carry it. TCX/FIT's
  // day-scoped `<CoursePoint>`/`course_point` cannot place a trip-scoped
  // anchor without either an arbitrary day guess or duplicating it across
  // every per-day split file — see the scope notes atop `tcx_writer.dart`
  // and `fit_writer.dart`.
  group('FR45: anchor narrative-role (plot point) notes', () {
    Trip tripWithAnchor({RevealPolicy? reveal, Coord? roleCoord, String? note = 'The old mill site.'}) =>
        Trip(
          id: 'trip-anchor',
          title: 'Anchored Ride',
          createdAt: '2026-08-17T00:00:00Z',
          updatedAt: '2026-08-17T00:00:00Z',
          days: const [],
          anchors: [
            Anchor(
              id: 'a1',
              coord: const [-105.28, 40.02],
              title: 'The Old Mill',
              roles: [
                Role(id: 'r1', kind: RoleKind.narrative, coord: roleCoord, reveal: reveal, note: note),
                Role(id: 'r2', kind: RoleKind.provision, reveal: RevealPolicy.alwaysVisible, note: 'Water.'),
              ],
            ),
          ],
        );

    test('GPX: a narrative role exports as a <wpt> with its note as <desc>, '
        'reveal not applied (the Author sees their own trip)', () {
      final gpx = tripToGpx(tripWithAnchor(reveal: RevealPolicy.onArrival));
      final doc = xml.XmlDocument.parse(gpx);
      final wpts = doc.findAllElements('wpt').toList();
      // Only the narrative role — the provision role on the same anchor is
      // not a plot point and does not get its own waypoint here.
      expect(wpts, hasLength(1));
      final wpt = wpts.single;
      expect(wpt.getAttribute('lat'), '40.02');
      expect(wpt.getAttribute('lon'), '-105.28');
      expect(wpt.findElements('name').single.innerText, 'The Old Mill');
      expect(wpt.findElements('desc').single.innerText, 'The old mill site.');
    });

    test('GPX: a role offset (FR107) positions the waypoint at the role\'s own coord', () {
      final gpx = tripToGpx(tripWithAnchor(roleCoord: const [-105.30, 40.05]));
      final wpt = xml.XmlDocument.parse(gpx).findAllElements('wpt').single;
      expect(wpt.getAttribute('lat'), '40.05');
      expect(wpt.getAttribute('lon'), '-105.3');
    });

    test('GPX: a narrative role with no note emits no empty <desc>', () {
      final gpx = tripToGpx(tripWithAnchor(note: null));
      final wpt = xml.XmlDocument.parse(gpx).findAllElements('wpt').single;
      expect(wpt.findElements('desc'), isEmpty);
    });

    test('GeoJSON: the anchor feature carries the narrative role\'s note', () {
      final geojson = tripToGeoJson(tripWithAnchor());
      final decoded = jsonDecode(geojson) as Map<String, dynamic>;
      final features = (decoded['features'] as List).cast<Map<String, dynamic>>();
      final anchor = features.firstWhere((f) => f['properties']['kind'] == 'anchor');
      expect(anchor['properties']['note'], 'The old mill site.');
    });

    test('TCX: no CoursePoint is fabricated for a trip-scoped anchor with no routed day', () {
      final tcx = tripToTcx(tripWithAnchor());
      expect(xml.XmlDocument.parse(tcx).findAllElements('CoursePoint'), isEmpty);
    });
  });

  // Issue #386 — #384 gave a role a real, optional dayId/segmentId
  // attachment; TCX/FIT can now place a `<CoursePoint>`/`course_point` for an
  // attached role, inside the day's course it's attached to, and must still
  // omit an unattached one (same precedent the group above already covers).
  group('Issue #386: an attached narrative role emits a CoursePoint/course_point', () {
    Day dayWithSegment() => Day(id: 'day-1', index: 1, kind: 'route', segments: [
          Segment(
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
            metrics: RouteMetrics(distanceM: 1200.0, movingTimeS: 300.0),
          ),
        ]);

    Trip tripWithAttachedRole({String? dayId, String? segmentId, bool hazard = false}) => Trip(
          id: 'trip-attached',
          title: 'Attached Ride',
          createdAt: '2026-08-17T00:00:00Z',
          updatedAt: '2026-08-17T00:00:00Z',
          days: [dayWithSegment()],
          anchors: [
            Anchor(
              id: 'a1',
              coord: const [-105.28, 40.02],
              title: 'The Old Mill',
              roles: [
                Role(
                  id: 'r1',
                  kind: RoleKind.narrative,
                  note: 'The old mill site.',
                  dayId: dayId,
                  segmentId: segmentId,
                  hazard: hazard,
                  reveal: hazard ? null : RevealPolicy.onArrival,
                ),
              ],
            ),
          ],
        );

    test('TCX: attached to the day and its segment', () {
      final tcx = tripToTcx(tripWithAttachedRole(dayId: 'day-1', segmentId: 'seg-1'));
      final points = xml.XmlDocument.parse(tcx).findAllElements('CoursePoint').toList();
      expect(points, hasLength(1));
      expect(points.single.findElements('Name').single.innerText, 'The Old Mill');
      expect(points.single.findElements('Notes').single.innerText, 'The old mill site.');
      expect(points.single.findElements('PointType').single.innerText, 'Generic');
    });

    test('TCX: attached to the day only (no segment) still emits a CoursePoint', () {
      final tcx = tripToTcx(tripWithAttachedRole(dayId: 'day-1'));
      final points = xml.XmlDocument.parse(tcx).findAllElements('CoursePoint').toList();
      expect(points, hasLength(1));
      expect(points.single.findElements('Name').single.innerText, 'The Old Mill');
    });

    test('TCX: a hazard role uses the Danger PointType (PRD §1.5, never withheld)', () {
      final tcx = tripToTcx(tripWithAttachedRole(dayId: 'day-1', segmentId: 'seg-1', hazard: true));
      final point = xml.XmlDocument.parse(tcx).findAllElements('CoursePoint').single;
      expect(point.findElements('PointType').single.innerText, 'Danger');
    });

    test('TCX: attached to a day that is not in the export still omits the point '
        '(no arbitrary-day guess)', () {
      final tcx = tripToTcx(tripWithAttachedRole(dayId: 'day-does-not-exist'));
      expect(xml.XmlDocument.parse(tcx).findAllElements('CoursePoint'), isEmpty);
    });

    test('FIT: attached to the day and its segment carries the note in the course_point name', () {
      final fit = tripToFit(tripWithAttachedRole(dayId: 'day-1', segmentId: 'seg-1'));
      final text = utf8.decode(fit, allowMalformed: true);
      // Combined name+note exceeds the 30-char cue-name cap, so it's
      // word-clipped with an ellipsis (`_fitCueName`, already covered on its
      // own by the "long plot-point note" test above) — assert on the
      // surviving prefix rather than the untruncated string.
      expect(text, contains('The Old Mill — The old mill'));
    });

    test('FIT: attached to the day only (no segment) still carries the note', () {
      final fit = tripToFit(tripWithAttachedRole(dayId: 'day-1'));
      final text = utf8.decode(fit, allowMalformed: true);
      expect(text, contains('The Old Mill — The old mill'));
    });

    test('FIT: an unattached role (dayId null) is omitted, not guessed onto the only day', () {
      final withAttachment = tripToFit(tripWithAttachedRole(dayId: 'day-1', segmentId: 'seg-1'));
      final unattached = tripToFit(tripWithAttachedRole());
      final unattachedText = utf8.decode(unattached, allowMalformed: true);
      expect(unattachedText, isNot(contains('The Old Mill')));
      expect(unattached.length, lessThan(withAttachment.length));
    });
  });

  group('Issue #386: GeoJSON carries a role\'s day/segment attachment', () {
    test('an anchor feature carries index-aligned day_ids/segment_ids across its roles', () {
      final trip = Trip(
        id: 'trip-geojson-attach',
        title: 'Attach Export',
        createdAt: '2026-08-17T00:00:00Z',
        updatedAt: '2026-08-17T00:00:00Z',
        days: const [],
        anchors: [
          Anchor(
            id: 'a1',
            coord: const [-105.28, 40.02],
            roles: [
              Role(id: 'r1', kind: RoleKind.narrative, dayId: 'day-1', segmentId: 'seg-1'),
              Role(id: 'r2', kind: RoleKind.provision, reveal: RevealPolicy.alwaysVisible),
            ],
          ),
        ],
      );
      final decoded = jsonDecode(tripToGeoJson(trip)) as Map<String, dynamic>;
      final features = (decoded['features'] as List).cast<Map<String, dynamic>>();
      final anchor = features.firstWhere((f) => f['properties']['kind'] == 'anchor');
      expect(anchor['properties']['day_ids'], ['day-1', null]);
      expect(anchor['properties']['segment_ids'], ['seg-1', null]);
    });

    test('an anchor with no role attachments carries neither property', () {
      final trip = Trip(
        id: 'trip-geojson-unattached',
        title: 'Unattached Export',
        createdAt: '2026-08-17T00:00:00Z',
        updatedAt: '2026-08-17T00:00:00Z',
        days: const [],
        anchors: [
          Anchor(id: 'a1', coord: const [0.0, 0.0], roles: [Role(id: 'r1', kind: RoleKind.provision)]),
        ],
      );
      final decoded = jsonDecode(tripToGeoJson(trip)) as Map<String, dynamic>;
      final features = (decoded['features'] as List).cast<Map<String, dynamic>>();
      final anchor = features.firstWhere((f) => f['properties']['kind'] == 'anchor');
      expect(anchor['properties'].containsKey('day_ids'), isFalse);
      expect(anchor['properties'].containsKey('segment_ids'), isFalse);
    });

    test('a role_offset feature carries its own day_id/segment_id', () {
      final trip = Trip(
        id: 'trip-geojson-offset-attach',
        title: 'Offset Attach Export',
        createdAt: '2026-08-17T00:00:00Z',
        updatedAt: '2026-08-17T00:00:00Z',
        days: const [],
        anchors: [
          Anchor(
            id: 'a1',
            coord: const [-105.28, 40.02],
            roles: [
              Role(
                id: 'r1',
                kind: RoleKind.narrative,
                coord: const [-105.30, 40.05],
                dayId: 'day-1',
                segmentId: 'seg-1',
              ),
            ],
          ),
        ],
      );
      final decoded = jsonDecode(tripToGeoJson(trip)) as Map<String, dynamic>;
      final features = (decoded['features'] as List).cast<Map<String, dynamic>>();
      final offset = features.firstWhere((f) => f['properties']['kind'] == 'role_offset');
      expect(offset['properties']['day_id'], 'day-1');
      expect(offset['properties']['segment_id'], 'seg-1');
    });
  });
}
