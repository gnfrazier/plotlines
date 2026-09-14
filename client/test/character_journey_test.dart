// H13 (FR132, FR116) — the Character-facing "plot points" list, resolved
// through RevealResolver rather than a raw Role read. Same spoiler-boundary
// discipline as reveal_resolver_test.dart: an on-arrival plot point must
// never surface title/note before arrival, but its arc stage always does
// (FR116's "the arc's shape" survives a held plot point), and a hazard/
// technical-crux narrative role is always visible regardless.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/character_journey.dart';
import 'package:plotlines_client/domain/domain.dart';

Trip _tripWithAnchors(List<Anchor> anchors) => Trip(
      id: 't1',
      title: 'Test Trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      anchors: anchors,
    );

void main() {
  group('buildPlotPoints', () {
    test('only narrative roles become plot points — provision/station are excluded', () {
      final trip = _tripWithAnchors([
        Anchor(id: 'a1', coord: const [0.0, 0.0], roles: [
          Role(id: 'r1', kind: RoleKind.provision, reveal: RevealPolicy.alwaysVisible, note: 'Water.'),
          Role(id: 'r2', kind: RoleKind.station, reveal: RevealPolicy.alwaysVisible, note: 'Crag.'),
        ]),
      ]);

      expect(buildPlotPoints(trip), isEmpty);
    });

    test('an always-visible narrative role shows its title and note with no arrival', () {
      final trip = _tripWithAnchors([
        Anchor(id: 'a1', coord: const [0.0, 0.0], roles: [
          Role(
            id: 'r1',
            kind: RoleKind.narrative,
            reveal: RevealPolicy.alwaysVisible,
            title: 'The Old Mill',
            note: 'Built in 1890.',
            arc: ArcStage.rising,
          ),
        ]),
      ]);

      final points = buildPlotPoints(trip);
      expect(points, hasLength(1));
      expect(points.single.visible, isTrue);
      expect(points.single.title, 'The Old Mill');
      expect(points.single.note, 'Built in 1890.');
      expect(points.single.arcStage, ArcStage.rising);
    });

    test('an on_arrival narrative role is withheld with no live arrival signal — '
        'the arc stage survives, the title and note do not', () {
      final trip = _tripWithAnchors([
        Anchor(id: 'a1', coord: const [0.0, 0.0], roles: [
          Role(
            id: 'r1',
            kind: RoleKind.narrative,
            reveal: RevealPolicy.onArrival,
            title: 'The Ambush Site',
            note: 'This is where it happened.',
            arc: ArcStage.crux,
          ),
        ]),
      ]);

      final points = buildPlotPoints(trip);
      expect(points, hasLength(1));
      expect(points.single.visible, isFalse);
      expect(points.single.title, isNull);
      expect(points.single.note, isNull);
      // FR116 — the arc's shape survives even though the content does not.
      expect(points.single.arcStage, ArcStage.crux);
    });

    test('an undecided narrative role (Author never set a reveal policy) stays withheld', () {
      final trip = _tripWithAnchors([
        Anchor(id: 'a1', coord: const [0.0, 0.0], roles: [
          Role(id: 'r1', kind: RoleKind.narrative, title: 'Undecided', note: 'Not yet.'),
        ]),
      ]);

      expect(buildPlotPoints(trip).single.visible, isFalse);
    });

    test('a hazard/technical-crux narrative role is always visible (FR115) '
        'even with an on_arrival-shaped policy left unset', () {
      final trip = _tripWithAnchors([
        Anchor(id: 'a1', coord: const [0.0, 0.0], roles: [
          Role(
            id: 'r1',
            kind: RoleKind.narrative,
            title: 'Loose Rock',
            note: 'Rockfall risk on the last pitch.',
            hazard: true,
          ),
        ]),
      ]);

      final point = buildPlotPoints(trip).single;
      expect(point.visible, isTrue);
      expect(point.title, 'Loose Rock');
      expect(point.hazard, isTrue);
    });

    test('hasArrived reveals an on_arrival plot point once the caller says the '
        'anchor has been reached', () {
      final trip = _tripWithAnchors([
        Anchor(id: 'a1', coord: const [0.0, 0.0], roles: [
          Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, title: 'Summit', note: 'Views.'),
        ]),
      ]);

      final points = buildPlotPoints(trip, hasArrived: (id) => id == 'a1');
      expect(points.single.visible, isTrue);
      expect(points.single.title, 'Summit');
    });

    test('with no hasArrived callback, every on_arrival plot point is withheld — '
        'the permanently-empty revealed set (ARCH D59) — never spoiling by default', () {
      final trip = _tripWithAnchors([
        Anchor(id: 'a1', coord: const [0.0, 0.0], roles: [
          Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, title: 'Summit'),
        ]),
        Anchor(id: 'a2', coord: const [1.0, 1.0], roles: [
          Role(id: 'r2', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival, title: 'Overlook'),
        ]),
      ]);

      expect(buildPlotPoints(trip).every((p) => !p.visible), isTrue);
    });

    test('a trip with no anchors yields no plot points', () {
      expect(buildPlotPoints(_tripWithAnchors(const [])), isEmpty);
    });
  });
}
