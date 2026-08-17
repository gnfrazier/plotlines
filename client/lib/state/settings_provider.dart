import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

enum DistanceUnit { miles, km }

enum ContrastMode { indoor, outdoor, highContrast }

/// K5 — units, theme, contrast. Desktop defaults to Indoor contrast (ARCH §9.4).
class DisplaySettings {
  const DisplaySettings({
    this.unit = DistanceUnit.miles,
    this.themeMode = ThemeMode.system,
    this.contrast = ContrastMode.indoor,
  });

  final DistanceUnit unit;
  final ThemeMode themeMode;
  final ContrastMode contrast;

  DisplaySettings copyWith({
    DistanceUnit? unit,
    ThemeMode? themeMode,
    ContrastMode? contrast,
  }) =>
      DisplaySettings(
        unit: unit ?? this.unit,
        themeMode: themeMode ?? this.themeMode,
        contrast: contrast ?? this.contrast,
      );
}

class SettingsNotifier extends StateNotifier<DisplaySettings> {
  SettingsNotifier(this._ref) : super(const DisplaySettings()) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    final db = _ref.read(appDatabaseProvider);
    final unit = await db.getSetting('unit');
    final theme = await db.getSetting('theme_mode');
    final contrast = await db.getSetting('contrast');
    state = DisplaySettings(
      unit: unit == 'km' ? DistanceUnit.km : DistanceUnit.miles,
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == theme,
        orElse: () => ThemeMode.system,
      ),
      contrast: ContrastMode.values.firstWhere(
        (c) => c.name == contrast,
        orElse: () => ContrastMode.indoor,
      ),
    );
  }

  Future<void> setUnit(DistanceUnit unit) async {
    state = state.copyWith(unit: unit);
    await _ref.read(appDatabaseProvider).setSetting('unit', unit.name);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await _ref.read(appDatabaseProvider).setSetting('theme_mode', mode.name);
  }

  Future<void> setContrast(ContrastMode contrast) async {
    state = state.copyWith(contrast: contrast);
    await _ref.read(appDatabaseProvider).setSetting('contrast', contrast.name);
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, DisplaySettings>(
        (ref) => SettingsNotifier(ref));

/// A10 — set once, on first run. Absent means the Author has never been
/// asked. `value` is a free-text description of what was chosen (city/zip/
/// country, or the Buncombe County default) — the real region-download
/// pipeline this should trigger does not exist yet (open question).
final startingLocationSetProvider = FutureProvider<String?>((ref) {
  return ref.read(appDatabaseProvider).getSetting('starting_location');
});
