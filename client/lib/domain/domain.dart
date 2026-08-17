/// Barrel export for the pure-Dart trip payload domain layer (ARCH §9.1).
///
/// Authority: `docs/schemas/trip_payload.schema.json` (ARCH decision D28). See each
/// file's own doc comment for which `$defs` entry it implements.
library;

export 'band.dart';
export 'cue.dart';
export 'day.dart';
export 'diagnosis.dart';
export 'hazard.dart';
export 'json_utils.dart' show Coord, DayLimit, JsonFields, checkCoord, finite, pruneJson;
export 'node.dart';
export 'route_metrics.dart';
export 'segment.dart';
export 'transition.dart';
export 'trip.dart';
export 'weight_profile.dart';
