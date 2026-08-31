// C11 / FR27 / FR115 (issue #210) — the client half of the trip-wide hazard
// roll-up. `plotlines_core.trips.hazards` is the authority; this pins that
// `HazardRollup.fromJson` reads the `/trips/split` payload faithfully and that
// `HazardRollup.fromTrip` — the mirror the client runs over a locally-assembled
// trip — walks hazards in the same order and flattens the same worst-first sync
// alerts.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/domain.dart';

Segment _seg(String id, {List<Hazard> hazards = const []}) => Segment(
      id: id,
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [0.0, 0.0],
      end: const [0.1, 0.1],
      metrics: RouteMetrics(distanceM: 5000),
      hazards: hazards,
    );

Trip _trip(List<Day> days, {List<Anchor> anchors = const []}) => Trip(
      id: 'trip-1',
      title: 'Hazard trip',
      createdAt: '2026-08-31T00:00:00Z',
      updatedAt: '2026-08-31T00:00:00Z',
      days: days,
      anchors: anchors,
    );

void main() {
  group('HazardRollup.fromTrip — the client mirror of hazards.py', () {
    test('walks day hazards then segment hazards, day by day, in reading order', () {
      final rollup = HazardRollup.fromTrip(_trip([
        Day(id: 'd1', index: 1, hazards: [
          Hazard(id: 'h-grit', severity: 'caution', title: 'Loose gravel'),
        ], segments: [
          _seg('s1', hazards: [Hazard(id: 'h-guard', severity: 'high', title: 'Cattle guard')]),
          _seg('s2', hazards: [Hazard(id: 'h-bend', severity: 'caution', title: 'Blind bend')]),
        ]),
        Day(id: 'd2', index: 2, segments: [_seg('s3')]),
      ]));

      expect(
        rollup.hazards.map((h) => (h.dayIndex, h.scope, h.hazard.title)).toList(),
        [
          (1, 'day', 'Loose gravel'),
          (1, 'passage', 'Cattle guard'),
          (1, 'passage', 'Blind bend'),
        ],
      );
      expect(rollup.hazards[1].segmentId, 's1');
    });

    test('sync alerts are the high+ subset, worst severity then day then distance', () {
      final rollup = HazardRollup.fromTrip(_trip([
        Day(id: 'd1', index: 1, segments: [
          _seg('s1', hazards: [
            Hazard(id: 'a', severity: 'high', title: 'D1 far', distanceAlongM: 9000),
            Hazard(id: 'b', severity: 'high', title: 'D1 near', distanceAlongM: 1000),
            Hazard(id: 'c', severity: 'mandatory_reroute', title: 'D1 reroute', distanceAlongM: 5000),
            Hazard(id: 'd', severity: 'caution', title: 'D1 puddle'),
          ]),
        ]),
        Day(id: 'd2', index: 2, segments: [
          _seg('s2', hazards: [Hazard(id: 'e', severity: 'high', title: 'D2 hazard', distanceAlongM: 500)]),
        ]),
      ]));

      expect(rollup.hasSyncAlerts, isTrue);
      expect(
        rollup.syncAlerts.map((a) => a.title).toList(),
        ['D1 reroute', 'D1 near', 'D1 far', 'D2 hazard'],
      );
      // the caution hazard is still in the full list, just not an alert
      expect(rollup.hazards.any((h) => h.hazard.title == 'D1 puddle'), isTrue);
    });

    test('a caution-only trip raises no interrupt', () {
      final rollup = HazardRollup.fromTrip(_trip([
        Day(id: 'd1', index: 1, segments: [
          _seg('s1', hazards: [Hazard(id: 'h', severity: 'caution', title: 'Puddle')]),
        ]),
      ]));
      expect(rollup.hasSyncAlerts, isFalse);
      expect(rollup.syncAlerts, isEmpty);
      expect(rollup.hazards, hasLength(1));
    });

    test('anchor_id wins the scope and resolves the anchor title', () {
      final rollup = HazardRollup.fromTrip(_trip(
        [
          Day(id: 'd1', index: 1, segments: [
            _seg('s1', hazards: [
              Hazard(id: 'h', severity: 'high', anchorId: 'anc-x', title: 'Class IV rapid'),
            ]),
          ]),
        ],
        anchors: [Anchor(id: 'anc-x', coord: const [-105.2, 40.0], title: 'The narrows', roles: [Role(id: 'r1', kind: RoleKind.narrative)])],
      ));
      final lh = rollup.hazards.single;
      expect(lh.scope, 'anchor');
      expect(lh.anchorId, 'anc-x');
      expect(lh.anchorTitle, 'The narrows');
      expect(lh.segmentId, 's1'); // still records the passage whose list carried it
      expect(rollup.syncAlerts.single.anchorTitle, 'The narrows');
    });

    test('a trip with no hazards has an empty roll-up', () {
      final rollup = HazardRollup.fromTrip(_trip([Day(id: 'd1', index: 1, segments: [_seg('s1')])]));
      expect(rollup.hasSyncAlerts, isFalse);
      expect(rollup.hazards, isEmpty);
      expect(rollup.syncAlerts, isEmpty);
    });
  });

  group('HazardRollup.fromJson — the /trips/split payload', () {
    test('reads has_sync_alerts, the alert list and the full list', () {
      final rollup = HazardRollup.fromJson({
        'has_sync_alerts': true,
        'sync_alerts': [
          {
            'hazard_id': 'h1',
            'severity': 'mandatory_reroute',
            'day_index': 2,
            'scope': 'passage',
            'title': 'Bridge out',
            'safety_note': 'Ford impassable above 2 m. Use FS-19.',
            'required_gear': ['helmet'],
            'segment_id': 's2',
            'distance_along_m': 4321.0,
            'coord': [-105.1, 40.1],
          },
        ],
        'hazards': [
          {
            'hazard': {'id': 'h0', 'severity': 'caution', 'title': 'Loose gravel'},
            'scope': 'day',
            'day_index': 1,
            'day_id': 'd1',
          },
          {
            'hazard': {'id': 'h1', 'severity': 'mandatory_reroute', 'title': 'Bridge out'},
            'scope': 'passage',
            'day_index': 2,
            'day_id': 'd2',
            'segment_id': 's2',
          },
        ],
      });

      expect(rollup.hasSyncAlerts, isTrue);
      expect(rollup.hazards.map((h) => h.hazard.title), ['Loose gravel', 'Bridge out']);
      final alert = rollup.syncAlerts.single;
      expect(alert.severity, 'mandatory_reroute');
      expect(alert.dayIndex, 2);
      expect(alert.requiredGear, ['helmet']);
      expect(alert.safetyNote, startsWith('Ford impassable'));
      expect(alert.coord, [-105.1, 40.1]);
    });

    test('empty lists parse to an empty roll-up', () {
      final rollup = HazardRollup.fromJson({
        'has_sync_alerts': false,
        'sync_alerts': <dynamic>[],
        'hazards': <dynamic>[],
      });
      expect(rollup.hasSyncAlerts, isFalse);
      expect(rollup.syncAlerts, isEmpty);
      expect(rollup.hazards, isEmpty);
    });
  });
}
