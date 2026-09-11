// FR25 (Story C9) — the client half of water-carry distance between sources.
// `plotlines_core.trips.water_carry` is the authority; this pins that
// `collectWaterSources` / `waterCarryForDay` place and gap sources the same
// way over a locally-assembled trip.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/domain.dart';

// A straight line north along one meridian — five vertices, four ~1112 m legs.
const _lon = -105.30;
const _lats = [40.00, 40.01, 40.02, 40.03, 40.04];
final _line = [for (final lat in _lats) [_lon, lat]];

Anchor _provisionAnchor(String id, Coord coord, {required bool potable, String? title}) => Anchor(
      id: id,
      coord: coord,
      title: title,
      roles: [Role(id: '$id-role', kind: RoleKind.provision, provision: ProvisionDetail(water: WaterSource(potable: potable)))],
    );

Day _dayWithRoute({String id = 'day-1', int index = 1}) => Day(
      id: id,
      index: index,
      segments: [
        Segment(id: 'seg-1', mode: 'hiking', shape: 'point_to_point', geometry: LineString(coordinates: _line)),
      ],
    );

Trip _trip(List<Day> days, List<Anchor> anchors) => Trip(
      id: 'trip-1',
      title: 'Water trip',
      createdAt: '2026-09-11T00:00:00Z',
      updatedAt: '2026-09-11T00:00:00Z',
      days: days,
      anchors: anchors,
    );

void main() {
  group('collectWaterSources', () {
    test('reads only provision roles with water set', () {
      final tap = _provisionAnchor('a-tap', _line[1], potable: true, title: 'Trailhead tap');
      final resupplyOnly = Anchor(
        id: 'a-store', coord: _line[2], title: 'General store',
        roles: [Role(id: 'r-store', kind: RoleKind.provision)],
      );
      final narrativeOnly = Anchor(
        id: 'a-view', coord: _line[3], title: 'Overlook',
        roles: [Role(id: 'r-view', kind: RoleKind.narrative)],
      );
      final sources = collectWaterSources(_trip([], [tap, resupplyOnly, narrativeOnly]));
      expect(sources.map((s) => s.anchorId).toList(), ['a-tap']);
      expect(sources.single.potable, isTrue);
      expect(sources.single.title, 'Trailhead tap');
    });

    test('reports filter-required sources too', () {
      final spring = _provisionAnchor('a-spring', _line[1], potable: false, title: 'Cold Spring');
      final sources = collectWaterSources(_trip([], [spring]));
      expect(sources.single.potable, isFalse);
    });
  });

  group('waterCarryForDay', () {
    test('two sources on route produce one leg in route order', () {
      final v1 = _provisionAnchor('a1', _line[1], potable: true, title: 'Spring 1');
      final v3 = _provisionAnchor('a3', _line[3], potable: true, title: 'Spring 3');
      // Deliberately out of order — the day's route decides order, not the list.
      final sources = collectWaterSources(_trip([], [v3, v1]));
      final report = waterCarryForDay(_dayWithRoute(), sources);

      expect(report.legs, hasLength(1));
      final leg = report.legs.single;
      expect(leg.fromAnchorId, 'a1');
      expect(leg.toAnchorId, 'a3');
      expect(leg.fromTitle, 'Spring 1');
      expect(leg.toTitle, 'Spring 3');

      final expectedM = haversineM(_line[1], _line[2]) + haversineM(_line[2], _line[3]);
      expect(leg.distanceM, closeTo(expectedM, 0.5));
    });

    test('three sources produce two legs summing to the span', () {
      final v0 = _provisionAnchor('a0', _line[0], potable: true);
      final v2 = _provisionAnchor('a2', _line[2], potable: true);
      final v4 = _provisionAnchor('a4', _line[4], potable: true);
      final sources = collectWaterSources(_trip([], [v0, v2, v4]));
      final report = waterCarryForDay(_dayWithRoute(), sources);

      expect(
        report.legs.map((l) => (l.fromAnchorId, l.toAnchorId)).toList(),
        [('a0', 'a2'), ('a2', 'a4')],
      );
      final totalSpan = [
        for (var i = 0; i < _line.length - 1; i++) haversineM(_line[i], _line[i + 1]),
      ].reduce((a, b) => a + b);
      final summed = report.legs.fold(0.0, (sum, l) => sum + l.distanceM);
      expect(summed, closeTo(totalSpan, 1.0));
    });

    test('a single source produces no legs', () {
      final v1 = _provisionAnchor('a1', _line[1], potable: true);
      final report = waterCarryForDay(_dayWithRoute(), collectWaterSources(_trip([], [v1])));
      expect(report.legs, isEmpty);
      expect(report.offRoute, isEmpty);
    });

    test('no sources at all is the common case, not an error', () {
      final report = waterCarryForDay(_dayWithRoute(), const []);
      expect(report.legs, isEmpty);
      expect(report.offRoute, isEmpty);
    });

    test('a source far from the route is reported off-route, not dropped', () {
      final onRoute = _provisionAnchor('a1', _line[1], potable: true);
      final far = _provisionAnchor('a-far', [_lon + 1.0, 41.0], potable: true, title: 'Town spigot');
      final sources = collectWaterSources(_trip([], [onRoute, far]));
      final report = waterCarryForDay(_dayWithRoute(), sources);
      expect(report.legs, isEmpty); // only one source actually on this day's route
      expect(report.offRoute.map((s) => s.anchorId).toList(), ['a-far']);
    });

    test('a source just within the snap tolerance is placed', () {
      final near = _provisionAnchor('a-near', [_lon + 0.00001, _lats[2]], potable: true);
      final report = waterCarryForDay(_dayWithRoute(), collectWaterSources(_trip([], [near])));
      expect(report.offRoute, isEmpty);
      expect(waterCarrySnapToleranceM, greaterThan(0));
    });

    test('a day with no solved geometry reports every source off-route', () {
      final restDay = Day(id: 'rest', index: 2, kind: 'rest');
      final v1 = _provisionAnchor('a1', _line[1], potable: true);
      final sources = collectWaterSources(_trip([], [v1]));
      final report = waterCarryForDay(restDay, sources);
      expect(report.legs, isEmpty);
      expect(report.offRoute.map((s) => s.anchorId).toList(), ['a1']);
    });
  });

  group('TripWaterCarry.fromTrip', () {
    test('carries one report per day and the shared source list', () {
      final v1 = _provisionAnchor('a1', _line[1], potable: true);
      final v3 = _provisionAnchor('a3', _line[3], potable: false);
      final trip = _trip([_dayWithRoute(), Day(id: 'd2', index: 2, kind: 'rest')], [v1, v3]);
      final out = TripWaterCarry.fromTrip(trip);
      expect(out.waterSources, hasLength(2));
      expect(out.byDay, hasLength(2));
      expect(out.byDay[0].dayIndex, 1);
      expect(out.byDay[0].legs, hasLength(1));
      expect(out.byDay[1].dayIndex, 2);
      expect(out.byDay[1].legs, isEmpty);
    });
  });
}
