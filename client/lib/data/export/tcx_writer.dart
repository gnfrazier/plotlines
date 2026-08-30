// F3 — Garmin Training Center XML (TCX). Like gpx_writer.dart and
// geojson_writer.dart, this runs entirely client-side: `core/plotlines_core/
// export/` has no writers at all, and TCX has no spike gating it the way
// FIT does (SPIKE-16, unresolved) — it was simply nobody's turn yet.
//
// One `<Course>` per day (a multi-segment multimodal day is one course with
// however many track segments; TCX has no native multi-segment-per-course
// break, so a day's segments are laid end-to-end in one `<Track>`), one
// `<CoursePoint>` per curated node.
//
// **`<Trackpoint><Time>` is synthetic, not measured.** The TCX schema
// requires a timestamp per trackpoint (that's how a Garmin device paces a
// virtual partner against the course), but the payload has no per-vertex
// time — only `metrics.moving_time_s` at the segment level, when a pace
// model applied at all (FR16/B7). Times are backfilled from a nominal pace
// when no better number exists, spread evenly across the segment's
// vertices; they are a device-compatibility fiction, not a claim about how
// fast the Author will actually go, and every FIT/TCX importer treats a
// course's trackpoint times this way (they're relative pacing data, not a
// historical record — unlike an activity file, which is what SPIKE-16 covers).
library;

import '../../domain/domain.dart';
import 'export_options.dart';
import 'geo_utils.dart';

//: Fallback pace by mode when no `moving_time_s` is available, m/s. Mirrors
//: `core/plotlines_core/multimodal/modes.py`'s `base_speed_kmh` domain
//: parameter — the same seed value B7/FR16 will make Author-configurable and
//: terrain-aware. `transit` has no traversal speed of its own (its timing is
//: an authored schedule, FR29); the number here is only so a TCX course a
//: Character loads onto a device still paces.
const Map<String, double> _fallbackSpeedMps = {
  'cycling': 4.17, // ~15 km/h
  'hiking': 1.39, // ~5 km/h
  'paddling': 1.11, // ~4 km/h
  'cross_country_skiing': 2.22, // ~8 km/h
  'packrafting': 1.25, // ~4.5 km/h
  'riverboarding': 1.11, // ~4 km/h
  'mountain_biking': 3.33, // ~12 km/h
  'driving': 16.67, // ~60 km/h
  'transit': 8.33, // ~30 km/h
};

String tripToTcx(Trip trip, {ExportOptions options = const ExportOptions()}) {
  final buffer = StringBuffer();
  buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  buffer.writeln('<TrainingCenterDatabase '
      'xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" '
      'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
      'xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 '
      'http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd">');
  buffer.writeln('  <Courses>');

  for (final day in trip.days) {
    if (day.segments.isEmpty) continue;
    _writeCourse(buffer, trip, day, options);
    if (options.includeAlternates) {
      for (final segment in day.segments) {
        for (final alt in segment.alternates) {
          _writeAlternateCourse(buffer, trip, day, alt);
        }
      }
    }
  }

  buffer.writeln('  </Courses>');
  buffer.writeln('</TrainingCenterDatabase>');
  return buffer.toString();
}

void _writeAlternateCourse(StringBuffer buffer, Trip trip, Day day, Alternate alt) {
  final coords = alt.geometry.coordinates;
  if (coords.isEmpty) return;
  final name = _esc('${day.title ?? '${trip.title} — Day ${day.index}'} — ${alt.isBranch ? 'Branch' : 'Alternate'}: ${alt.label ?? alt.kind}');
  buffer.writeln('    <Course>');
  buffer.writeln('      <Name>$name</Name>');
  var distance = 0.0;
  for (var i = 1; i < coords.length; i++) {
    distance += haversineM(coords[i - 1], coords[i]);
  }
  buffer.writeln('      <Lap>');
  buffer.writeln('        <TotalTimeSeconds>${(distance / (_fallbackSpeedMps['cycling'] ?? 3.0)).round()}</TotalTimeSeconds>');
  buffer.writeln('        <DistanceMeters>${distance.toStringAsFixed(1)}</DistanceMeters>');
  buffer.writeln('        <BeginPosition>${_position(coords.first)}</BeginPosition>');
  buffer.writeln('        <EndPosition>${_position(coords.last)}</EndPosition>');
  buffer.writeln('        <Intensity>Active</Intensity>');
  buffer.writeln('      </Lap>');
  buffer.writeln('      <Track>');
  _writeTrackpoints(buffer, coords, _fallbackSpeedMps['cycling'] ?? 3.0, DateTime.now().toUtc());
  buffer.writeln('      </Track>');
  buffer.writeln('    </Course>');
}

void _writeCourse(StringBuffer buffer, Trip trip, Day day, ExportOptions options) {
  final name = _esc(day.title ?? '${trip.title} — Day ${day.index}');
  buffer.writeln('    <Course>');
  buffer.writeln('      <Name>$name</Name>');

  double totalDistance = 0;
  for (final s in day.segments) {
    totalDistance += s.metrics?.distanceM ?? 0;
  }
  final firstStart = day.segments.first.geometry?.coordinates.firstOrNull;
  final lastEnd = day.segments.last.geometry?.coordinates.lastOrNull;

  buffer.writeln('      <Lap>');
  buffer.writeln('        <TotalTimeSeconds>'
      '${_totalMovingSeconds(day)}</TotalTimeSeconds>');
  buffer.writeln('        <DistanceMeters>${totalDistance.toStringAsFixed(1)}</DistanceMeters>');
  if (firstStart != null) {
    buffer.writeln('        <BeginPosition>${_position(firstStart)}</BeginPosition>');
  }
  if (lastEnd != null) {
    buffer.writeln('        <EndPosition>${_position(lastEnd)}</EndPosition>');
  }
  buffer.writeln('        <Intensity>Active</Intensity>');
  buffer.writeln('      </Lap>');

  buffer.writeln('      <Track>');
  var clock = DateTime.now().toUtc();
  for (final segment in day.segments) {
    final coords = segment.geometry?.coordinates ?? const [];
    if (coords.isEmpty) continue;
    final segStart = clock;
    final speed = _speedMps(segment);
    clock = _writeTrackpoints(buffer, coords, speed, segStart);
    if (options.includeWaypoints) {
      for (final node in segment.nodes) {
        buffer.writeln(_coursePoint(node, clock));
      }
    }
    if (options.includeCueSheet) {
      final sheet = options.cueSheetsBySegmentId[segment.id];
      if (sheet != null) {
        for (final cue in sheet.cues) {
          final at = pointAtDistance(coords, cue.distanceAlongM);
          final cueTime = segStart.add(Duration(milliseconds: (cue.distanceAlongM / speed * 1000).round()));
          buffer.writeln(_cueCoursePoint(cue, at, cueTime));
        }
      }
    }
  }
  buffer.writeln('      </Track>');
  buffer.writeln('    </Course>');
}

/// Writes one `<Trackpoint>` per coordinate, advancing a synthetic clock at
/// [speedMps] (see the file doc comment on why the time is synthetic).
/// Shared by the main course and the alternate course — both need the same
/// per-vertex distance/time bookkeeping. Returns the clock value after the
/// last point, so a caller stitching multiple legs together can carry it
/// forward.
DateTime _writeTrackpoints(StringBuffer buffer, List<Coord> coords, double speedMps, DateTime startClock) {
  var clock = startClock;
  var cumulativeM = 0.0;
  for (var i = 0; i < coords.length; i++) {
    final c = coords[i];
    if (i > 0) {
      final step = haversineM(coords[i - 1], c);
      cumulativeM += step;
      clock = clock.add(Duration(milliseconds: (step / speedMps * 1000).round()));
    }
    buffer.writeln('        <Trackpoint>');
    buffer.writeln('          <Time>${clock.toIso8601String().split('.').first}Z</Time>');
    buffer.writeln('          <Position>${_position(c)}</Position>');
    if (c.length > 2) buffer.writeln('          <AltitudeMeters>${c[2]}</AltitudeMeters>');
    buffer.writeln('          <DistanceMeters>${cumulativeM.toStringAsFixed(1)}</DistanceMeters>');
    buffer.writeln('        </Trackpoint>');
  }
  return clock;
}

String _coursePoint(Node node, DateTime approxTime) {
  final name = _esc(node.title ?? node.kind.wireValue);
  final type = switch (node.kind) {
    NodeKind.restStop => 'Rest',
    NodeKind.regroup => 'Generic',
    NodeKind.poi => 'Generic',
    NodeKind.start => 'Generic',
    NodeKind.finish => 'Generic',
    _ => 'Generic',
  };
  final buf = StringBuffer();
  buf.writeln('        <CoursePoint>');
  buf.writeln('          <Name>$name</Name>');
  buf.writeln('          <Time>${approxTime.toIso8601String().split('.').first}Z</Time>');
  buf.writeln('          <Position>${_position(node.coord)}</Position>');
  buf.writeln('          <PointType>$type</PointType>');
  if (node.note != null) buf.writeln('          <Notes>${_esc(node.note!)}</Notes>');
  buf.write('        </CoursePoint>');
  return buf.toString();
}

String _cueCoursePoint(Cue cue, Coord at, DateTime approxTime) {
  final name = _esc(cue.instruction ?? cue.kind);
  final type = switch (cue.kind) {
    'hazard' => 'Danger',
    'start' => 'Generic',
    'finish' => 'Generic',
    _ => 'Generic',
  };
  final buf = StringBuffer();
  buf.writeln('        <CoursePoint>');
  buf.writeln('          <Name>$name</Name>');
  buf.writeln('          <Time>${approxTime.toIso8601String().split('.').first}Z</Time>');
  buf.writeln('          <Position>${_position(at)}</Position>');
  buf.writeln('          <PointType>$type</PointType>');
  buf.write('        </CoursePoint>');
  return buf.toString();
}

String _position(Coord c) =>
    '<LatitudeDegrees>${c[1]}</LatitudeDegrees><LongitudeDegrees>${c[0]}</LongitudeDegrees>';

double _speedMps(Segment segment) {
  final distance = segment.metrics?.distanceM;
  final moving = segment.metrics?.movingTimeS;
  if (distance != null && moving != null && moving > 0) return distance / moving;
  return _fallbackSpeedMps[segment.mode] ?? 3.0;
}

int _totalMovingSeconds(Day day) {
  var seconds = 0.0;
  for (final s in day.segments) {
    final moving = s.metrics?.movingTimeS;
    if (moving != null) {
      seconds += moving;
    } else {
      final distance = s.metrics?.distanceM ?? 0;
      seconds += distance / (_fallbackSpeedMps[s.mode] ?? 3.0);
    }
  }
  return seconds.round();
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
