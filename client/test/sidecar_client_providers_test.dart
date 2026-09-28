// ARCH §9.1 — `routingClientProvider` / `curationClientProvider` hand out a
// client bound to the sidecar's base URL. They used to `ref.watch` the whole
// `SidecarManager`, which notifies on every `/health` change — every 2 s
// while a region builds — so both clients were rebuilt on each tick, and so
// was everything that watched them: `proposalsProvider` threw away the
// Author's co-location result, Defer set and selection, and
// `layerCatalogProvider` re-fetched `/layers`. Only a port change should.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/state/proposals_provider.dart';
import 'package:plotlines_client/state/providers.dart';

/// A manager whose only behaviour is notifying — a `/health` poll that saw a
/// capability change, with the port untouched.
class _TickingManager extends SidecarManager {
  void tick() => notifyListeners();
}

void main() {
  test('a capability tick does not rebuild the sidecar clients', () {
    final manager = _TickingManager();
    final container = ProviderContainer(overrides: [
      sidecarManagerProvider.overrideWith((ref) => manager),
    ]);
    addTearDown(container.dispose);

    final routing = container.read(routingClientProvider);
    final curation = container.read(curationClientProvider);
    manager.tick();

    expect(identical(container.read(routingClientProvider), routing), isTrue);
    expect(identical(container.read(curationClientProvider), curation), isTrue);
  });

  test('a capability tick does not reset the proposals review state', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final manager = _TickingManager();
    final container = ProviderContainer(overrides: [
      sidecarManagerProvider.overrideWith((ref) => manager),
      appDatabaseProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);
    container.listen(proposalsProvider, (_, _) {});

    final notifier = container.read(proposalsProvider.notifier);
    await notifier.ready;
    notifier.defer('p1');
    notifier.select('p1');
    manager.tick();

    final state = container.read(proposalsProvider);
    expect(state.deferredIds, {'p1'});
    expect(state.selectedId, 'p1');
  });
}
