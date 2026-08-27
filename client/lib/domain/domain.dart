/// Barrel export for the pure-Dart trip payload domain layer (ARCH §9.1).
///
/// Authority: `docs/schemas/trip_payload.schema.json` (ARCH decision D28). See each
/// file's own doc comment for which `$defs` entry it implements.
library;

export 'anchor.dart';
export 'area_trigger.dart';
export 'band.dart';
export 'cue.dart';
export 'day.dart';
export 'day_timeline.dart';
export 'diagnosis.dart';
export 'edit_scope.dart';
export 'empty_state.dart';
export 'hazard.dart';
export 'itinerary.dart';
export 'json_utils.dart'
    show Coord, DayLimit, JsonFields, Ring, checkCoord, checkPolygonRings, checkRing, finite, pruneJson;
export 'message_catalog.dart';
export 'message_template.dart';
export 'node.dart';
export 'passage_sequence.dart';
export 'point_trigger.dart';
export 'profile_request.dart';
export 'reachability.dart';
export 'reason_phrase.dart';
export 'reveal_state.dart';
export 'route_metrics.dart';
export 'segment.dart';
export 'stale_work.dart';
export 'teaching.dart';
export 'transition.dart';
export 'travel_mode.dart';
export 'trip.dart';
export 'undo_stack.dart';
export 'weight_profile.dart';
