// E3 / FR39 / FR117 / FR118 (issue #214) — the client half of compose mode's
// places-first views. `plotlines_core.trips.spine` is the authority; this only
// reads the `itinerary` / `recap` / `cues` block `/days/compose` now returns
// alongside the `Day` (`spine.*.to_dict()`), so a sidecar and a future hosted
// assembly hand the client identical structure. Nothing here recomputes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/domain.dart';

Map<String, dynamic> _response({
  double? targetM,
  bool routed = true,
}) =>
    {
      'id': 'day-1',
      'index': 1,
      'kind': 'route',
      'segments': <dynamic>[],
      'itinerary': {
        'planning_mode': 'compose',
        'spine': ['anc-trailhead', 'anc-old-mine', 'anc-summit'],
        'stops': [
          {
            'anchor_id': 'anc-trailhead',
            'order': 0,
            'title': 'Trailhead',
            'coord': [-105.30, 40.00],
            'roles': ['provision'],
            'arc_stages': <dynamic>[],
            'hazard': false,
            'distance_along_m': 0.0,
            'has_unrevealed_narrative': false,
          },
          {
            'anchor_id': 'anc-old-mine',
            'order': 1,
            'title': 'Old mine',
            'coord': [-105.25, 40.00],
            'roles': ['narrative'],
            'arc_stages': ['rising'],
            'hazard': true,
            'distance_along_m': routed ? 4260.0 : null,
            'has_unrevealed_narrative': true,
          },
          {
            'anchor_id': 'anc-summit',
            'order': 2,
            'title': 'Summit',
            'coord': [-105.20, 40.00],
            'roles': ['narrative'],
            'arc_stages': ['climax'],
            'hazard': false,
            'distance_along_m': routed ? 8520.0 : null,
            'has_unrevealed_narrative': false,
          },
        ],
        'legs': [
          {
            'order': 0,
            'segment_id': 'seg-1',
            'mode': 'hiking',
            'distance_m': routed ? 4260.0 : null,
            'arc_stage': null,
            'planning_mode': 'compose',
            'hazards': null,
          },
          {
            'order': 1,
            'segment_id': 'seg-2',
            'mode': 'hiking',
            'distance_m': routed ? 4260.0 : null,
            'arc_stage': 'climax',
            'planning_mode': 'compose',
            'hazards': null,
          },
        ],
        'distance': {
          'planning_mode': 'compose',
          'realised_m': routed ? 8520.0 : 0.0,
          'target_m': targetM,
          'deviation_m': targetM == null ? null : (routed ? 8520.0 : 0.0) - targetM,
          'deviation_frac': null,
          'dispositions':
              targetM == null ? ['accept'] : ['drop', 'defer', 'split', 'accept'],
          'is_conflict': false,
          'is_error': false,
        },
      },
      'recap': [
        {
          'order': 0,
          'anchor_id': 'anc-old-mine',
          'title': 'Old mine',
          'arc_stages': ['rising'],
          'distance_along_m': routed ? 4260.0 : null,
        },
        {
          'order': 1,
          'anchor_id': 'anc-summit',
          'title': 'Summit',
          'arc_stages': ['climax'],
          'distance_along_m': routed ? 8520.0 : null,
        },
      ],
      'cues': [
        {
          'id': 'cue-0',
          'sequence': 0,
          'distance_along_m': 0.0,
          'kind': 'start',
          'instruction': 'Trailhead',
          'ref_id': 'anc-trailhead',
        },
      ],
    };

void main() {
  test('fromResponse reads the places-first itinerary, folding in recap + cues', () {
    final itin = ComposeItinerary.fromResponse(_response())!;

    expect(itin.planningMode, 'compose');
    expect(itin.spine, ['anc-trailhead', 'anc-old-mine', 'anc-summit']);
    expect(itin.stops.map((s) => s.order), [0, 1, 2]);
    expect(itin.stops[1].title, 'Old mine');
    expect(itin.stops[1].roles, ['narrative']);
    expect(itin.stops[1].arcStages, ['rising']);
    expect(itin.stops[1].hazard, isTrue);
    expect(itin.stops[1].hasUnrevealedNarrative, isTrue);
    expect(itin.stops[2].distanceAlongM, 8520.0);

    // one leg fewer than stops, each between its pair
    expect(itin.legs.map((l) => l.order), [0, 1]);
    expect(itin.legs[0].mode, 'hiking');
    expect(itin.legs[0].distanceM, 4260.0);
    expect(itin.legs[0].hazards, isEmpty);

    // recap is only the plot points — the provision-only trailhead is off it
    expect(itin.recap.map((e) => e.anchorId), ['anc-old-mine', 'anc-summit']);
    expect(itin.cues.single.refId, 'anc-trailhead');
  });

  test('a pure-compose distance outcome reports the length and never conflicts', () {
    final d = ComposeItinerary.fromResponse(_response())!.distance;

    expect(d.realisedM, 8520.0);
    expect(d.hasTarget, isFalse);
    expect(d.deviationM, isNull);
    expect(d.dispositions, ['accept']);
    expect(d.isConflict, isFalse);
    expect(d.isError, isFalse);
  });

  test('a target the Author had in mind is quantified but still not a conflict', () {
    final d = ComposeItinerary.fromResponse(_response(targetM: 10000.0))!.distance;

    expect(d.hasTarget, isTrue);
    expect(d.targetM, 10000.0);
    expect(d.deviationM, -1480.0);
    expect(d.dispositions, ['drop', 'defer', 'split', 'accept']);
    expect(d.isConflict, isFalse);
    expect(d.isError, isFalse);
  });

  test('an unrouted spine degrades to unmeasured — never a guessed zero', () {
    final itin = ComposeItinerary.fromResponse(_response(routed: false))!;

    expect(itin.stops[0].distanceAlongM, 0.0);
    expect(itin.stops[1].distanceAlongM, isNull);
    expect(itin.stops[2].distanceAlongM, isNull);
    expect(itin.legs[0].distanceM, isNull);
  });

  test('no itinerary block in the response yields null, not a throw', () {
    expect(ComposeItinerary.fromResponse({'id': 'd', 'index': 1}), isNull);
  });
}
