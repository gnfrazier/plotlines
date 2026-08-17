// Smoke test: the app builds and renders its first frame without throwing.
// Two real-world dependencies get faked so the test doesn't fight
// flutter_test's FakeAsync zone: SidecarManager (spawns a real OS process in
// `start()`) and AppDatabase (drift_flutter's native connection opener
// leaves its own pending timer) — neither leaves anything pending once
// replaced, so this only exercises the shell, not a real generate/save/
// export flow.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/main.dart';
import 'package:plotlines_client/state/providers.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}

  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

void main() {
  testWidgets('app shell builds without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
          appDatabaseProvider
              .overrideWithValue(AppDatabase.forTesting(NativeDatabase.memory())),
        ],
        child: const PlotlinesApp(),
      ),
    );
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
