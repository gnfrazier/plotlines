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

import 'support/fake_window_manager.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}

  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

void main() {
  // The app now wraps its content in DesktopWindowFrame (X1 / issue #180),
  // which drives the `window_manager` channel from the title bar — fake it so
  // the smoke test isn't fighting a missing desktop embedder.
  late FakeWindowManager wm;
  setUp(() => wm = FakeWindowManager());
  tearDown(() => wm.dispose());

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
    // A10's cold-start home-region preview embeds a real flutter_map, whose
    // vector_map_tiles ticker (see trip_shell_screen_test.dart's note on the
    // same ticker) needs several short pumps to settle rather than one.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
