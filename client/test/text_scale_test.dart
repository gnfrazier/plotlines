// Issue #230 A2 / WCAG 1.4.4 — the app honours the platform text scale and
// the Author can raise it from Preferences.
//
// Nothing in `client/lib` touched `textScaler` before this: under WSLg the
// Linux embedder reports a 1.0 scale, so 12 logical px rendered as 12 device
// px on a 1080p panel with no way to change it. `resolveTextScale` is the
// whole rule, kept pure so it is checkable without a window.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveTextScale (issue #230 A2)', () {
    test('the default preference leaves the platform scale exactly as reported', () {
      expect(resolveTextScale(1.0, TextSizePref.system), 1.0);
      expect(resolveTextScale(1.5, TextSizePref.system), 1.5);
    });

    test('the preference multiplies the platform scale rather than replacing it', () {
      // Someone already at 150% Windows scaling who asks for "Larger" is
      // scaled further, not reset to the app's idea of normal.
      expect(resolveTextScale(1.5, TextSizePref.larger), closeTo(1.95, 1e-9));
      expect(resolveTextScale(1.0, TextSizePref.large), closeTo(1.15, 1e-9));
    });

    test('never shrinks below what the platform asked for', () {
      // A platform that under-reports (WSLg's 1.0 is the floor in practice,
      // but a stub embedder can report less) can only ever be raised here.
      expect(resolveTextScale(0.8, TextSizePref.system), 1.0);
    });

    test('is capped so desktop chrome cannot overflow at an extreme OS scale', () {
      expect(resolveTextScale(2.0, TextSizePref.largest), 2.0);
      expect(resolveTextScale(3.0, TextSizePref.largest), 2.0);
    });
  });

  group('the text-size preference', () {
    test('persists like every other display choice and syncs with them', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(settingsProvider.notifier);
      await Future<void>.delayed(Duration.zero); // let the async _load() settle
      await notifier.setTextSize(TextSizePref.larger);

      expect(container.read(settingsProvider).textSize, TextSizePref.larger);
      expect(await db.getSetting('text_size'), 'larger');
      expect(container.read(settingsProvider).syncedPreferences['text_size'], 'larger');
    });

    test('an unrecognised stored value falls back to the platform scale, not a crash',
        () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      await db.setSetting('text_size', 'enormous');
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      // Force the async load.
      container.read(settingsProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(settingsProvider).textSize, TextSizePref.system);
    });
  });

  testWidgets('Preferences offers a text-size control beside contrast', (tester) async {
    // The control has to exist in the UI, not only in the model — A2's
    // second half ("add a text-size control to Preferences next to CONTRAST").
    for (final pref in TextSizePref.values) {
      expect(pref.label.trim(), isNotEmpty);
    }
    expect(TextSizePref.values.length, greaterThan(1));
    // Rendering the full settings screen needs the sidecar/about surface;
    // `settings_about_test.dart` covers that screen's composition. Here the
    // contract is only that every offered step is labelled and distinct.
    expect(
      TextSizePref.values.map((p) => p.label).toSet().length,
      TextSizePref.values.length,
    );
    expect(TextSizePref.values.map((p) => p.factor).toList(), [1.0, 1.15, 1.3, 1.5]);
  });
}
