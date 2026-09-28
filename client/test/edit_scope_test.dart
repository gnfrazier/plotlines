// FR139 (Story Q1/Q2) — the pure scope checks behind the day-count-reduction
// and passage-removal prompts: what a day or a run of days holds, what
// removing a passage would carry away with it, and which days a target day
// count would remove. `trip_bbox_revision_test.dart`'s shape (a pure check
// behind a prompt) is the precedent this follows.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  group('DayContentSummary / summarizeDayContent', () {
    test('an empty day summarizes to isEmpty', () {
      final day = Day(id: 'd1', index: 1);
      expect(summarizeDayContent(day).isEmpty, isTrue);
    });

    test('a rest day with a day-scoped POI node counts as an anchor, not empty', () {
      final day = Day(
        id: 'd1',
        index: 1,
        kind: 'rest',
        nodes: [Node(id: 'n1', kind: NodeKind.poi, coord: const [-105.2, 40.0])],
      );
      final summary = summarizeDayContent(day);
      expect(summary.isEmpty, isFalse);
      expect(summary.anchors, 1);
      expect(summary.passages, 0);
      expect(summary.scheduledEvents, 0);
    });

    test('counts passages, anchors and scheduled events separately without double-counting', () {
      final scheduledNode = Node(
        id: 'n-event',
        kind: NodeKind.event,
        coord: const [-105.2, 40.0],
        scheduled: ScheduledWindow(opensAt: '2026-06-01T09:00:00Z'),
      );
      final poiNode = Node(id: 'n-poi', kind: NodeKind.poi, coord: const [-105.21, 40.01]);
      final segment = Segment(
        id: 's1',
        mode: 'cycling',
        shape: 'point_to_point',
        nodes: [poiNode],
      );
      final day = Day(id: 'd1', index: 1, segments: [segment], nodes: [scheduledNode]);

      final summary = summarizeDayContent(day);
      expect(summary.passages, 1);
      expect(summary.anchors, 1); // only the segment's POI node, not the scheduled one
      expect(summary.scheduledEvents, 1);
      expect(summary.isEmpty, isFalse);
    });

    test('summarizeDaysContent sums across multiple days, matching the AC\'s worked example shape', () {
      final day5 = Day(
        id: 'd5',
        index: 5,
        segments: [
          Segment(id: 's1', mode: 'cycling', shape: 'loop', nodes: [
            Node(id: 'n1', kind: NodeKind.poi, coord: const [0, 0]),
            Node(id: 'n2', kind: NodeKind.poi, coord: const [0, 0]),
          ]),
          Segment(id: 's2', mode: 'cycling', shape: 'loop'),
        ],
        nodes: [
          Node(
            id: 'n3',
            kind: NodeKind.event,
            coord: const [0, 0],
            scheduled: ScheduledWindow(opensAt: '2026-06-01T09:00:00Z'),
          ),
        ],
      );
      final day6 = Day(
        id: 'd6',
        index: 6,
        segments: [
          Segment(id: 's3', mode: 'hiking', shape: 'out_and_back', nodes: [
            Node(id: 'n4', kind: NodeKind.poi, coord: const [0, 0]),
            Node(id: 'n5', kind: NodeKind.poi, coord: const [0, 0]),
            Node(id: 'n6', kind: NodeKind.poi, coord: const [0, 0]),
            Node(id: 'n7', kind: NodeKind.poi, coord: const [0, 0]),
            Node(id: 'n8', kind: NodeKind.poi, coord: const [0, 0]),
          ]),
          Segment(id: 's4', mode: 'hiking', shape: 'out_and_back'),
        ],
        nodes: [
          Node(
            id: 'n9',
            kind: NodeKind.event,
            coord: const [0, 0],
            scheduled: ScheduledWindow(opensAt: '2026-06-02T09:00:00Z'),
          ),
        ],
      );

      final summary = summarizeDaysContent([day5, day6]);
      expect(summary.passages, 4);
      expect(summary.anchors, 7);
      expect(summary.scheduledEvents, 2);
    });
  });

  group('daysBeyondCount', () {
    Day day(int index) => Day(id: 'd$index', index: index);

    test('empty when the target count is not actually a reduction', () {
      final days = [day(1), day(2), day(3)];
      expect(daysBeyondCount(days, 3), isEmpty);
      expect(daysBeyondCount(days, 5), isEmpty);
    });

    test('returns the highest-indexed days, sorted ascending by index', () {
      final days = [day(3), day(1), day(2), day(4)];
      final beyond = daysBeyondCount(days, 2);
      expect(beyond.map((d) => d.index), [3, 4]);
    });

    test('rejects a negative target count', () {
      expect(() => daysBeyondCount([day(1)], -1), throwsArgumentError);
    });
  });

  group('SegmentContentSummary / summarizeSegmentContent', () {
    test('a bare segment with no nodes/hazards/arc carries no authored content', () {
      final segment = Segment(id: 's1', mode: 'cycling', shape: 'loop');
      final summary = summarizeSegmentContent(segment);
      expect(summary.hasAuthoredContent, isFalse);
    });

    test('a segment with a plain node has authored content', () {
      final segment = Segment(
        id: 's1',
        mode: 'cycling',
        shape: 'loop',
        nodes: [Node(id: 'n1', kind: NodeKind.poi, coord: const [0, 0])],
      );
      expect(summarizeSegmentContent(segment).hasAuthoredContent, isTrue);
    });

    test('a segment with a hazard has authored content even with no nodes', () {
      final segment = Segment(
        id: 's1',
        mode: 'cycling',
        shape: 'loop',
        hazards: [Hazard(id: 'h1', severity: 'caution')],
      );
      expect(summarizeSegmentContent(segment).hasAuthoredContent, isTrue);
    });

    test('a segment carrying only an arc stage has authored content', () {
      final segment = Segment(id: 's1', mode: 'cycling', shape: 'loop', arcStage: 'crux');
      final summary = summarizeSegmentContent(segment);
      expect(summary.hasAuthoredContent, isTrue);
      expect(summary.hasArcStage, isTrue);
    });

    test('names transition nodes carrying Author instructions specifically', () {
      final instructed = Node(
        id: 'n1',
        kind: NodeKind.transition,
        coord: const [0, 0],
        instructions: 'Gear stash behind the trailhead sign',
      );
      final plainTransition = Node(id: 'n2', kind: NodeKind.transition, coord: const [0, 0]);
      final segment = Segment(
        id: 's1',
        mode: 'cycling',
        shape: 'loop',
        nodes: [instructed, plainTransition],
      );
      final summary = summarizeSegmentContent(segment);
      expect(summary.instructedTransitionNodes, [instructed]);
      expect(summary.hasAuthoredContent, isTrue);
    });

    test('a passage note, media, alternates and portages are authored content too', () {
      // Removing a passage drops every one of these with it — none moves to
      // the day the way its nodes do — so each has to raise the FR139
      // prompt rather than vanish on one click.
      final line = LineString(coordinates: const [[0, 0], [0.01, 0.01]], source: 'authored');
      final cases = <String, Segment>{
        'note': Segment(id: 's1', mode: 'paddling', shape: 'loop', note: 'Scout the ledge.'),
        'media': Segment(
            id: 's1', mode: 'paddling', shape: 'loop',
            media: [MediaRef(id: 'm1', kind: 'image', path: 'ledge.jpg')]),
        'alternate': Segment(
            id: 's1', mode: 'paddling', shape: 'loop',
            alternates: [Alternate(id: 'a1', kind: 'bypass', geometry: line)]),
        'portage': Segment(
            id: 's1', mode: 'paddling', shape: 'loop',
            portages: [Portage(id: 'p1', geometry: line)]),
      };
      for (final entry in cases.entries) {
        expect(summarizeSegmentContent(entry.value).hasAuthoredContent, isTrue,
            reason: entry.key);
      }
      final summary = summarizeSegmentContent(cases['portage']!);
      expect(summary.portageCount, 1);
      expect(summarizeSegmentContent(cases['alternate']!).alternateCount, 1);
      expect(summarizeSegmentContent(cases['note']!).hasNote, isTrue);
      expect(summarizeSegmentContent(cases['media']!).mediaCount, 1);
    });
  });

  group('DayContentSummary — content that is not a passage or a node', () {
    test('a day-level hazard is not an empty day', () {
      // FR115: a hazard is never hidden — removing it without a word is worse.
      final day = Day(id: 'd1', index: 1, hazards: [Hazard(id: 'h1', severity: 'high')]);
      final summary = summarizeDayContent(day);
      expect(summary.isEmpty, isFalse);
      expect(summary.hazards, 1);
    });

    test("a day's note, media or rest-day place is not an empty day", () {
      final noted = Day(id: 'd1', index: 1, note: 'Laundry in town.');
      final pictured = Day(
          id: 'd2', index: 2, media: [MediaRef(id: 'm1', kind: 'image', path: 'p.jpg')]);
      final placed = Day(id: 'd3', index: 3, kind: 'rest', location: const [-82.55, 35.6]);
      expect(summarizeDayContent(noted).isEmpty, isFalse);
      expect(summarizeDayContent(pictured).isEmpty, isFalse);
      expect(summarizeDayContent(placed).isEmpty, isFalse);
      final summary = summarizeDaysContent([noted, pictured, placed]);
      expect(summary.notes, 1);
      expect(summary.media, 1);
      expect(summary.places, 1);
    });
  });
}
