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

String itineraryToMarkdown(Itinerary itinerary) {
  final buffer = StringBuffer();
  buffer.writeln('# ${itinerary.title}');
  buffer.writeln();
  buffer.writeln(itinerary.isIndividual
      ? '_Individual itinerary — attended days only._'
      : '_Master itinerary — every day._');
  if (itinerary.days.isEmpty) {
    buffer.writeln();
    buffer.writeln('_No days on this itinerary._');
    return buffer.toString();
  }
  for (final entry in itinerary.days) {
    buffer.writeln();
    buffer.writeln('## ${entry.heading}');
    for (final paragraph in entry.paragraphs) {
      buffer.writeln();
      buffer.writeln(paragraph);
    }
  }
  return buffer.toString();
}
