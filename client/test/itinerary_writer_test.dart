// F2 (FR48, FR133) — `itineraryToMarkdown` renders an [Itinerary] as a plain
// document: one heading per day, paragraphs directly beneath it, no table.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/export/itinerary_writer.dart';
import 'package:plotlines_client/domain/domain.dart';

void main() {
  test('renders a master itinerary\'s title, day headings, and paragraphs', () {
    final itinerary = Itinerary(
      title: 'Blue Ridge Traverse',
      isIndividual: false,
      days: [
        ItineraryDayEntry(
          day: Day(id: 'd1', index: 1, title: 'To the Gap'),
          heading: 'Day 1 — To the Gap',
          paragraphs: ['Ride (42.0 km).', 'Along the way: Elk Falls overlook.'],
        ),
      ],
    );

    final md = itineraryToMarkdown(itinerary);

    expect(md, contains('# Blue Ridge Traverse'));
    expect(md, contains('_Master itinerary — every day._'));
    expect(md, contains('## Day 1 — To the Gap'));
    expect(md, contains('Ride (42.0 km).'));
    expect(md, contains('Along the way: Elk Falls overlook.'));
    expect(md, isNot(contains('|'))); // no table syntax — FR133.
  });

  test('marks an individual itinerary distinctly from the master', () {
    final itinerary = Itinerary(title: 'Blue Ridge Traverse — Sam', isIndividual: true, days: []);
    final md = itineraryToMarkdown(itinerary);
    expect(md, contains('_Individual itinerary — attended days only._'));
    expect(md, contains('_No days on this itinerary._'));
  });
}
