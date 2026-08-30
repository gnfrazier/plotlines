import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/display_format.dart';
import 'providers.dart';

export '../domain/display_format.dart'
    show DateFormatPref, ClockPref, TemperatureUnit, DisplayFormat;

enum DistanceUnit { miles, km }

enum ContrastMode { indoor, outdoor, highContrast }

/// K5 / FR79 — the OS-derived starting point for every display preference.
///
/// FR79: "The initial value of every display preference is read from the
/// operating system … rather than starting at an application default." This
/// changes only the *starting* value, not the storage rule — once a user
/// makes an explicit choice it is persisted and synced like any other.
/// Date and time format start at `inherit`, which itself defers to the OS at
/// render time, so a fresh install on a metric machine shows kilometres and
/// the platform's own date pattern without anyone visiting settings.
@immutable
class PlatformDisplayDefaults {
  const PlatformDisplayDefaults({
    required this.unit,
    required this.temperatureUnit,
    required this.contrast,
  });

  final DistanceUnit unit;
  final TemperatureUnit temperatureUnit;
  final ContrastMode contrast;

  /// Read units and contrast from the host OS. Mobile defaults to the
  /// outdoor (high-contrast) surface, desktop to indoor (ARCH §9.4 / §10.5);
  /// US/Liberia/Myanmar locales get miles + °F, everyone else metric + °C.
  factory PlatformDisplayDefaults.detect() {
    final isMobile = !kIsWeb &&
        (_safePlatform(() => Platform.isAndroid) ||
            _safePlatform(() => Platform.isIOS));
    final country =
        ui.PlatformDispatcher.instance.locale.countryCode?.toUpperCase();
    final imperial = country == 'US' || country == 'LR' || country == 'MM';
    return PlatformDisplayDefaults(
      unit: imperial ? DistanceUnit.miles : DistanceUnit.km,
      temperatureUnit:
          imperial ? TemperatureUnit.fahrenheit : TemperatureUnit.celsius,
      contrast: isMobile ? ContrastMode.highContrast : ContrastMode.indoor,
    );
  }

  static const PlatformDisplayDefaults fallback = PlatformDisplayDefaults(
    unit: DistanceUnit.miles,
    temperatureUnit: TemperatureUnit.fahrenheit,
    contrast: ContrastMode.indoor,
  );
}

/// `Platform` throws on web; callers that reach this file are desktop/mobile,
/// but keep the guard so a test or a web build cannot crash on a probe.
bool _safePlatform(bool Function() probe) {
  try {
    return probe();
  } catch (_) {
    return false;
  }
}

/// K5 — units, theme, contrast, and (FR79) temperature scale plus date/time
/// format. Every field is a render-time transform: nothing here is stored on
/// a trip, an export, or a filename (ARCH D49).
@immutable
class DisplaySettings {
  const DisplaySettings({
    this.unit = DistanceUnit.miles,
    this.temperatureUnit = TemperatureUnit.fahrenheit,
    this.themeMode = ThemeMode.system,
    this.contrast = ContrastMode.indoor,
    this.dateFormat = DateFormatPref.inherit,
    this.clock = ClockPref.inherit,
    this.ttsReadout = false,
  });

  final DistanceUnit unit;
  final TemperatureUnit temperatureUnit;
  final ThemeMode themeMode;
  final ContrastMode contrast;

  /// Stored date preference: `inherit` or one of FR79's seven patterns.
  final DateFormatPref dateFormat;

  /// Stored clock preference: `inherit`, `hour12`, or `hour24`.
  final ClockPref clock;

  /// H2a / FR40a device-TTS readout toggle. **Per-device, never synced** — it
  /// depends on which voices are installed on the machine in front of the
  /// Character, so it is excluded from [syncedPreferences].
  final bool ttsReadout;

  DisplaySettings copyWith({
    DistanceUnit? unit,
    TemperatureUnit? temperatureUnit,
    ThemeMode? themeMode,
    ContrastMode? contrast,
    DateFormatPref? dateFormat,
    ClockPref? clock,
    bool? ttsReadout,
  }) =>
      DisplaySettings(
        unit: unit ?? this.unit,
        temperatureUnit: temperatureUnit ?? this.temperatureUnit,
        themeMode: themeMode ?? this.themeMode,
        contrast: contrast ?? this.contrast,
        dateFormat: dateFormat ?? this.dateFormat,
        clock: clock ?? this.clock,
        ttsReadout: ttsReadout ?? this.ttsReadout,
      );

  /// The preferences that travel with the user across machines (FR58/FR79).
  /// `inherit` syncs as the literal string and continues to resolve locally
  /// per device; the per-device TTS toggle is deliberately absent.
  Map<String, String> get syncedPreferences => {
        'unit': unit.name,
        'temperature_unit': temperatureUnit.name,
        'theme_mode': themeMode.name,
        'contrast': contrast.name,
        'date_format': dateFormat.name,
        'clock_format': clock.name,
      };

  /// Build the render-time [DisplayFormat] for this set of preferences.
  /// [platformDateFormatter] / [platformUses24Hour] are the device's *current*
  /// answers, consulted only where a field is left on `inherit`.
  DisplayFormat resolveFormat({
    String Function(DateTime)? platformDateFormatter,
    bool? platformUses24Hour,
  }) =>
      DisplayFormat(
        datePref: dateFormat,
        clockPref: clock,
        temperatureUnit: temperatureUnit,
        useMiles: unit == DistanceUnit.miles,
        platformDateFormatter: platformDateFormatter,
        platformUses24Hour: platformUses24Hour,
      );

  @override
  bool operator ==(Object other) =>
      other is DisplaySettings &&
      other.unit == unit &&
      other.temperatureUnit == temperatureUnit &&
      other.themeMode == themeMode &&
      other.contrast == contrast &&
      other.dateFormat == dateFormat &&
      other.clock == clock &&
      other.ttsReadout == ttsReadout;

  @override
  int get hashCode => Object.hash(unit, temperatureUnit, themeMode, contrast,
      dateFormat, clock, ttsReadout);
}

class SettingsNotifier extends StateNotifier<DisplaySettings> {
  SettingsNotifier(Ref ref, {PlatformDisplayDefaults? platformDefaults})
      : this._(ref, platformDefaults ?? _detectDefaults());

  SettingsNotifier._(this._ref, PlatformDisplayDefaults defaults)
      : _defaults = defaults,
        super(DisplaySettings(
          unit: defaults.unit,
          temperatureUnit: defaults.temperatureUnit,
          contrast: defaults.contrast,
        )) {
    _load();
  }

  final Ref _ref;
  final PlatformDisplayDefaults _defaults;

  static PlatformDisplayDefaults _detectDefaults() {
    try {
      return PlatformDisplayDefaults.detect();
    } catch (_) {
      return PlatformDisplayDefaults.fallback;
    }
  }

  Future<void> _load() async {
    final db = _ref.read(appDatabaseProvider);
    final unit = await db.getSetting('unit');
    final temp = await db.getSetting('temperature_unit');
    final theme = await db.getSetting('theme_mode');
    final contrast = await db.getSetting('contrast');
    final dateFormat = await db.getSetting('date_format');
    final clock = await db.getSetting('clock_format');
    final tts = await db.getSetting('tts_readout');
    state = DisplaySettings(
      // A stored value is an explicit choice; its absence falls back to the
      // OS-derived starting point (FR79), never to a hardcoded app default.
      unit: unit == null
          ? _defaults.unit
          : (unit == 'km' ? DistanceUnit.km : DistanceUnit.miles),
      temperatureUnit: temp == null
          ? _defaults.temperatureUnit
          : (temp == 'celsius'
              ? TemperatureUnit.celsius
              : TemperatureUnit.fahrenheit),
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == theme,
        orElse: () => ThemeMode.system,
      ),
      contrast: contrast == null
          ? _defaults.contrast
          : ContrastMode.values.firstWhere(
              (c) => c.name == contrast,
              orElse: () => _defaults.contrast,
            ),
      dateFormat: DateFormatPref.values.firstWhere(
        (d) => d.name == dateFormat,
        orElse: () => DateFormatPref.inherit,
      ),
      clock: ClockPref.values.firstWhere(
        (c) => c.name == clock,
        orElse: () => ClockPref.inherit,
      ),
      ttsReadout: tts == 'true',
    );
  }

  Future<void> setUnit(DistanceUnit unit) async {
    state = state.copyWith(unit: unit);
    await _ref.read(appDatabaseProvider).setSetting('unit', unit.name);
  }

  Future<void> setTemperatureUnit(TemperatureUnit unit) async {
    state = state.copyWith(temperatureUnit: unit);
    await _ref
        .read(appDatabaseProvider)
        .setSetting('temperature_unit', unit.name);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await _ref.read(appDatabaseProvider).setSetting('theme_mode', mode.name);
  }

  Future<void> setContrast(ContrastMode contrast) async {
    state = state.copyWith(contrast: contrast);
    await _ref.read(appDatabaseProvider).setSetting('contrast', contrast.name);
  }

  Future<void> setDateFormat(DateFormatPref pref) async {
    state = state.copyWith(dateFormat: pref);
    await _ref.read(appDatabaseProvider).setSetting('date_format', pref.name);
  }

  Future<void> setClock(ClockPref pref) async {
    state = state.copyWith(clock: pref);
    await _ref.read(appDatabaseProvider).setSetting('clock_format', pref.name);
  }

  /// Per-device only — persisted locally, excluded from the synced payload.
  Future<void> setTtsReadout(bool enabled) async {
    state = state.copyWith(ttsReadout: enabled);
    await _ref
        .read(appDatabaseProvider)
        .setSetting('tts_readout', enabled.toString());
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, DisplaySettings>(
        (ref) => SettingsNotifier(ref));
