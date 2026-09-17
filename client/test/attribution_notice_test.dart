// Issue #277 (Phase 3.5) — `exportAttributionNotice` is the one place every
// export writer's licence notice comes from.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/export/attribution_notice.dart';
import 'package:plotlines_client/domain/domain.dart';

Trip _trip({Provenance? provenance}) => Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      provenance: provenance,
    );

void main() {
  test('a pre-#270 trip with no provenance still carries the always-owed static credits', () {
    final notice = exportAttributionNotice(_trip());
    expect(notice, contains('© OpenStreetMap contributors'));
    expect(notice, contains('GEDTM30'));
    // No fabricated snapshot line — issue #277 acceptance item 4.
    expect(notice, isNot(contains('OSM data snapshot')));
  });

  test('a trip with a mirror-build-id osm_source carries the snapshot line', () {
    final notice = exportAttributionNotice(_trip(
      provenance: Provenance(osmSource: 'geofabrik:2026-09-01'),
    ));
    expect(notice, contains('OSM data snapshot: geofabrik:2026-09-01'));
  });

  test('a credit with a terms URL carries it inline, one line per credit', () {
    final notice = exportAttributionNotice(_trip());
    final lines = notice.split('\n');
    expect(
      lines,
      contains('Routing data: © OpenStreetMap contributors '
          '(https://www.openstreetmap.org/copyright)'),
    );
  });

  test('a trip-recorded plugin attribution rides alongside the static credits', () {
    final notice = exportAttributionNotice(_trip(
      provenance: Provenance(
        osmSource: 'geofabrik:2026-09-01',
        attribution: [
          Attribution(source: 'trailforks', licence: 'CC-BY-SA-4.0',
              credit: 'Trail data: Trailforks', url: 'https://www.trailforks.com'),
        ],
      ),
    ));
    expect(notice, contains('Trail data: Trailforks (https://www.trailforks.com)'));
    expect(notice, contains('OSM data snapshot: geofabrik:2026-09-01'));
  });
}
