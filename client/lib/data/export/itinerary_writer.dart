// F2 (FR48, FR133) — renders an [Itinerary] (`domain/itinerary.dart`) to a
// plain Markdown document: one heading and a run of prose paragraphs per
// day, matching FR133's "narrative register" — no logistics table, here or
// in the domain layer that built the [Itinerary] this reads.
//
// Same reasoning as `gpx_writer.dart`/`tcx_writer.dart`/`geojson_writer.dart`:
// `core/plotlines_core/export/` has no writers yet, so this is a real,
// complete client-side implementation rather than a stub waiting on server
// work.
library;

import '../../domain/domain.dart';

/// [attributionNotice] (issue #277) — `export_tab.dart`'s own
/// `exportAttributionNotice(trip)`, passed in rather than derived here:
/// this function only ever sees the already-reduced [Itinerary], which
/// carries no `Trip`/`Provenance` back-reference of its own. `null`/empty
/// omits the section entirely — this is the "cue sheet / human-readable
/// export" issue #277 names as having room for a full notice line.
String itineraryToMarkdown(Itinerary itinerary, {String? attributionNotice}) {
  final buffer = StringBuffer();
  buffer.writeln('# ${itinerary.title}');
  buffer.writeln();
  buffer.writeln(itinerary.isIndividual
      ? '_Individual itinerary — attended days only._'
      : '_Master itinerary — every day._');
  if (itinerary.days.isEmpty) {
    buffer.writeln();
    buffer.writeln('_No days on this itinerary._');
  } else {
    for (final entry in itinerary.days) {
      buffer.writeln();
      buffer.writeln('## ${entry.heading}');
      for (final paragraph in entry.paragraphs) {
        buffer.writeln();
        buffer.writeln(paragraph);
      }
    }
  }
  if (attributionNotice != null && attributionNotice.isNotEmpty) {
    buffer.writeln();
    buffer.writeln('---');
    buffer.writeln();
    for (final line in attributionNotice.split('\n')) {
      buffer.writeln(line);
      buffer.writeln();
    }
  }
  return buffer.toString();
}
