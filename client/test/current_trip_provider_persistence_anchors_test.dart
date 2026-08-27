// G2a (FR74a) — the AC's "selecting reopens into the planner with all edits
// intact — including promoted anchors, roles, and reveal settings". The
// declared-modes round trip is covered separately
// (current_trip_provider_persistence_declared_modes_test.dart); this file
// covers the promotion-era object model that FR74a calls out by name:
// `Trip.anchors`, each `Role`'s kind/reveal/arc, and a role's own point
// offset — all of which ride inside the JSON `payload` column rather than a
// dedicated one, so this is the one place that actually exercises the
// save/reopen path against them.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/domain/anchor.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';

void main() {
  test(
      'a saved trip\'s promoted anchors, role kinds, reveal policies, and arc stages '
      'survive reopening in a fresh container', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final writer = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(writer.dispose);

    writer.read(currentTripProvider.notifier).promoteAnchor(
      coord: [-82.55, 35.6],
      title: 'Hot Spring Overlook',
      roles: [
        Role(
          id: 'role-narrative',
          kind: RoleKind.narrative,
          reveal: RevealPolicy.onArrival,
          arc: ArcStage.crux,
          note: 'The vista the whole day builds to.',
        ),
        Role(
          id: 'role-provision',
          kind: RoleKind.provision,
          reveal: RevealPolicy.alwaysVisible,
          coord: [-82.551, 35.601],
        ),
      ],
    );
    final tripId = writer.read(currentTripProvider).id;
    await writer.read(tripPersistenceProvider).save();

    // A fresh container — nothing carries over except what actually persisted.
    final reader = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(reader.dispose);
    await reader.read(tripPersistenceProvider).open(tripId);

    final reopened = reader.read(currentTripProvider).anchors;
    expect(reopened, hasLength(1));
    final reopenedAnchor = reopened.single;
    expect(reopenedAnchor.title, 'Hot Spring Overlook');
    expect(reopenedAnchor.coord, [-82.55, 35.6]);
    expect(reopenedAnchor.roles, hasLength(2));

    final narrative = reopenedAnchor.roles.firstWhere((r) => r.id == 'role-narrative');
    expect(narrative.kind, RoleKind.narrative);
    expect(narrative.reveal, RevealPolicy.onArrival);
    expect(narrative.arc, ArcStage.crux);
    expect(narrative.note, 'The vista the whole day builds to.');

    final provision = reopenedAnchor.roles.firstWhere((r) => r.id == 'role-provision');
    expect(provision.kind, RoleKind.provision);
    expect(provision.reveal, RevealPolicy.alwaysVisible);
    expect(provision.coord, [-82.551, 35.601]);
  });
}
