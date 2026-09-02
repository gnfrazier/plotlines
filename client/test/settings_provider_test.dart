// K5 / FR79 — the storage rule. Display preferences start from the OS, an
// explicit choice persists and syncs, `inherit` syncs as the literal and
// keeps resolving per device, and the H2a TTS toggle never joins the synced
// payload.

import 'package:drift/native.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/settings_provider.dart';

ProviderContainer _container(AppDatabase db) {
  final c = ProviderContainer(
    overrides: [appDatabaseProvider.overrideWithValue(db)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsNotifier persistence and OS-derived starting point', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('a fresh install with nothing stored takes the platform defaults', () async {
      final c = _container(db);
      final notifier = SettingsNotifier(
        c.read(_refProbe),
        platformDefaults: const PlatformDisplayDefaults(
          unit: DistanceUnit.km,
          temperatureUnit: TemperatureUnit.celsius,
          contrast: ContrastMode.highContrast,
        ),
      );
      addTearDown(notifier.dispose);
      await Future<void>.delayed(Duration.zero); // let _load() settle

      expect(notifier.state.unit, DistanceUnit.km);
      expect(notifier.state.temperatureUnit, TemperatureUnit.celsius);
      expect(notifier.state.contrast, ContrastMode.highContrast);
      // Date/time still start on inherit — that *is* reading from the OS.
      expect(notifier.state.dateFormat, DateFormatPref.inherit);
      expect(notifier.state.clock, ClockPref.inherit);
    });

    test('a stored explicit choice overrides the platform default on load', () async {
      await db.setSetting('unit', 'miles');
      await db.setSetting('date_format', 'europeanDot');
      await db.setSetting('clock_format', 'hour24');
      await db.setSetting('temperature_unit', 'fahrenheit');

      final c = _container(db);
      final notifier = SettingsNotifier(
        c.read(_refProbe),
        platformDefaults: const PlatformDisplayDefaults(
          unit: DistanceUnit.km,
          temperatureUnit: TemperatureUnit.celsius,
          contrast: ContrastMode.indoor,
        ),
      );
      addTearDown(notifier.dispose);
      await Future<void>.delayed(Duration.zero);

      expect(notifier.state.unit, DistanceUnit.miles);
      expect(notifier.state.dateFormat, DateFormatPref.europeanDot);
      expect(notifier.state.clock, ClockPref.hour24);
      expect(notifier.state.temperatureUnit, TemperatureUnit.fahrenheit);
    });

    test('setters write through to the settings store', () async {
      final c = _container(db);
      final notifier = SettingsNotifier(c.read(_refProbe));
      addTearDown(notifier.dispose);
      await Future<void>.delayed(Duration.zero);

      await notifier.setDateFormat(DateFormatPref.iso8601);
      await notifier.setClock(ClockPref.hour12);
      await notifier.setTemperatureUnit(TemperatureUnit.celsius);
      await notifier.setTtsReadout(true);

      expect(await db.getSetting('date_format'), 'iso8601');
      expect(await db.getSetting('clock_format'), 'hour12');
      expect(await db.getSetting('temperature_unit'), 'celsius');
      expect(await db.getSetting('tts_readout'), 'true');
    });
  });

  group('sync boundary (FR58 / FR79)', () {
    test('explicit choices are in the synced payload', () {
      const s = DisplaySettings(
        unit: DistanceUnit.km,
        temperatureUnit: TemperatureUnit.celsius,
        themeMode: ThemeMode.dark,
        contrast: ContrastMode.indoor,
        dateFormat: DateFormatPref.us,
        clock: ClockPref.hour12,
        textSize: TextSizePref.larger,
        ttsReadout: true,
      );
      expect(s.syncedPreferences, {
        'unit': 'km',
        'temperature_unit': 'celsius',
        'theme_mode': 'dark',
        'contrast': 'indoor',
        'date_format': 'us',
        'clock_format': 'hour12',
        // Issue #230 A2 — the text-size preference travels with the user
        // like every other display choice; only the per-device TTS toggle
        // is excluded.
        'text_size': 'larger',
      });
    });

    test('inherit syncs as the literal and resolves per device', () {
      const s = DisplaySettings(
        dateFormat: DateFormatPref.inherit,
        clock: ClockPref.inherit,
      );
      expect(s.syncedPreferences['date_format'], 'inherit');
      expect(s.syncedPreferences['clock_format'], 'inherit');

      // Same synced value, two devices, two different resolved answers.
      final onIso = s.resolveFormat(
        platformDateFormatter: (d) => '2026-08-20',
        platformUses24Hour: true,
      );
      final onUs = s.resolveFormat(
        platformDateFormatter: (d) => '08/20/2026',
        platformUses24Hour: false,
      );
      final when = DateTime(2026, 8, 20, 15, 7);
      expect(onIso.formatDate(when), '2026-08-20');
      expect(onUs.formatDate(when), '08/20/2026');
      expect(onIso.formatTime(when), '15:07');
      expect(onUs.formatTime(when), '3:07 PM');
    });

    test('the H2a TTS readout toggle is never synced', () {
      const on = DisplaySettings(ttsReadout: true);
      const off = DisplaySettings(ttsReadout: false);
      expect(on.syncedPreferences.containsKey('tts_readout'), isFalse);
      expect(on.syncedPreferences, off.syncedPreferences);
    });
  });
}

/// Minimal `Ref` handle: `SettingsNotifier` only ever calls
/// `ref.read(appDatabaseProvider)`, so any provider's ref will do.
final _refProbe = Provider<Ref>((ref) => ref);
