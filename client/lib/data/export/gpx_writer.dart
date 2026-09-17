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
import 'attribution_notice.dart';
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
  // Issue #277 — the licence notice rides in `<desc>` (GPX 1.1's one
  // metadata free-text slot; a `<copyright>` element allows only one
  // licence and this trip owes several). `<desc>` is optional and simply
  // omitted when there is nothing to say.
  final notice = exportAttributionNotice(trip);
  buffer.writeln('  <metadata><name>${_esc(trip.title)}</name>'
      '${notice.isEmpty ? '' : '<desc>${_esc(notice)}</desc>'}</metadata>');

  // FR45 — plot-point notes: PRD v2.0 §4.3 defines "plot point" as an
  // Anchor's narrative role, not a Node, so preserving them natively means
  // exporting `trip.anchors`, not only `Day.nodes`. Reveal is not applied
  // (matching every writer in this file and `geojson_writer.dart`'s own
  // anchor export): this is the Author exporting their own trip, where
  // nothing is hidden from them.
  if (options.includeWaypoints) {
    for (final anchor in trip.anchors) {
      for (final role in anchor.roles) {
        if (role.kind != RoleKind.narrative) continue;
        buffer.writeln(_anchorWaypoint(anchor, role));
      }
    }
  }

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

/// FR45 / PRD §4.3 — one narrative role as a `<wpt>`: the role's own
/// position ([Anchor.roleGeometry], which falls back to the anchor's own
/// coord when the role carries no offset — FR107/O2), its title (or the
/// anchor's, when the role left one unset), and its note in `<desc>`, the
/// same element every other waypoint in this file carries its note in.
String _anchorWaypoint(Anchor anchor, Role role) {
  final at = anchor.roleGeometry(role);
  final name = role.title ?? anchor.title ?? 'Plot point';
  final note = role.note;
  return '  <wpt lat="${at[1]}" lon="${at[0]}">'
      '<name>${_esc(name)}</name>'
      '${note != null && note.isNotEmpty ? '<desc>${_esc(note)}</desc>' : ''}'
      '<type>plot_point</type>'
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
