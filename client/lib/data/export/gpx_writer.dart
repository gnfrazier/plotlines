// F3 (PRD FR-family; MVP doc §1.4.1's F3 "export contents & splitting").
// GPX 1.1: one `<trk>` per day with a `<trkseg>` per segment (so a
// multi-segment multimodal day still reads as one track), plus `<wpt>`
// entries for every curated node — the two constructs a GPX consumer
// actually renders. No route (`<rte>`) elements: MVP has nothing that
// distinguishes a suggested route from a recorded track, and adding both
// would just duplicate the same points under a second, less-supported tag.
//
// Same reasoning as geojson_writer.dart: `core/plotlines_core/export/` has
// no writers yet and no `/trips/{id}/export` endpoint exists, so this is a
// real, complete client-side implementation rather than a stub waiting on
// server work.
library;

import '../../domain/domain.dart';
import 'export_options.dart';
import 'geo_utils.dart';

String tripToGpx(Trip trip, {ExportOptions options = const ExportOptions()}) {
  final buffer = StringBuffer();
  buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  buffer.writeln('<gpx version="1.1" creator="Plotlines" '
      'xmlns="http://www.topografix.com/GPX/1/1" '
      'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
      'xsi:schemaLocation="http://www.topografix.com/GPX/1/1 '
      'http://www.topografix.com/GPX/1/1/gpx.xsd">');
  buffer.writeln('  <metadata><name>${_esc(trip.title)}</name></metadata>');

  for (final day in trip.days) {
    if (day.segments.isEmpty) continue;
    buffer.writeln('  <trk>');
    buffer.writeln('    <name>${_esc(day.title ?? 'Day ${day.index}')}</name>');
    for (final segment in day.segments) {
      final coords = segment.geometry?.coordinates ?? const [];
      if (coords.isEmpty) continue;
      _writeTrkseg(buffer, coords);
      if (options.includeWaypoints) {
        for (final node in segment.nodes) {
          buffer.writeln(_waypoint(node));
        }
      }
      if (options.includeCueSheet) {
        final sheet = options.cueSheetsBySegmentId[segment.id];
        if (sheet != null) {
          for (final cue in sheet.cues) {
            buffer.writeln(_cueWaypoint(cue, pointAtDistance(coords, cue.distanceAlongM)));
          }
        }
      }
    }
    buffer.writeln('  </trk>');
    if (options.includeWaypoints) {
      for (final node in day.nodes) {
        buffer.writeln(_waypoint(node));
      }
    }
    if (options.includeAlternates) {
      for (final segment in day.segments) {
        for (final alt in segment.alternates) {
          if (alt.geometry.coordinates.isEmpty) continue;
          buffer.writeln('  <trk>');
          buffer.writeln('    <name>${_esc('${alt.isBranch ? 'Branch' : 'Alternate'}: ${alt.label ?? alt.kind}')}</name>');
          _writeTrkseg(buffer, alt.geometry.coordinates);
          buffer.writeln('  </trk>');
        }
      }
    }
  }

  buffer.writeln('</gpx>');
  return buffer.toString();
}

void _writeTrkseg(StringBuffer buffer, List<Coord> coords) {
  buffer.writeln('    <trkseg>');
  for (final c in coords) {
    final ele = c.length > 2 ? ' <ele>${c[2]}</ele>' : '';
    buffer.writeln('      <trkpt lat="${c[1]}" lon="${c[0]}">$ele</trkpt>'.replaceAll('> <ele', '><ele'));
  }
  buffer.writeln('    </trkseg>');
}

String _waypoint(Node node) {
  final name = node.title ?? node.kind.wireValue;
  // FR45 — a curated node's plot-point note is preserved as the waypoint's
  // native `<desc>` (GPX 1.1 supports it, and it must precede `<type>` in the
  // element sequence to stay schema-valid). TCX carries the same text in
  // `<CoursePoint><Notes>`; GPX has no CoursePoint, so the note rides on the
  // `<wpt>` every GPX consumer already renders.
  final note = node.note;
  return '  <wpt lat="${node.coord[1]}" lon="${node.coord[0]}">'
      '<name>${_esc(name)}</name>'
      '${note != null && note.isNotEmpty ? '<desc>${_esc(note)}</desc>' : ''}'
      '<type>${_esc(node.kind.wireValue)}</type>'
      '</wpt>';
}

String _cueWaypoint(Cue cue, Coord at) {
  final name = cue.instruction ?? cue.kind;
  return '  <wpt lat="${at[1]}" lon="${at[0]}">'
      '<name>${_esc(name)}</name>'
      '<type>cue_${_esc(cue.kind)}</type>'
      '</wpt>';
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
