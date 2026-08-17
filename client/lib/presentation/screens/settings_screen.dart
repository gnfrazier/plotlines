// K5 — display & measurement preferences, plus K8's reset-planning-controls
// affordance (surfaced here since it acts on the currently open trip).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../state/current_trip_provider.dart';
import '../../state/settings_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(PlotSpacing.s5),
        children: [
          Text('UNITS', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: PlotSpacing.s2),
          PlotCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                RadioListTile<DistanceUnit>(
                  title: const Text('Miles / feet'),
                  value: DistanceUnit.miles,
                  groupValue: settings.unit,
                  onChanged: (v) => v == null ? null : notifier.setUnit(v),
                ),
                RadioListTile<DistanceUnit>(
                  title: const Text('Kilometres / metres'),
                  value: DistanceUnit.km,
                  groupValue: settings.unit,
                  onChanged: (v) => v == null ? null : notifier.setUnit(v),
                ),
              ],
            ),
          ),
          const SizedBox(height: PlotSpacing.s5),
          Text('APPEARANCE', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: PlotSpacing.s2),
          PlotCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final mode in ThemeMode.values)
                  RadioListTile<ThemeMode>(
                    title: Text(switch (mode) {
                      ThemeMode.system => 'Match system',
                      ThemeMode.light => 'Light (canvas)',
                      ThemeMode.dark => 'Dark (dusk)',
                    }),
                    value: mode,
                    groupValue: settings.themeMode,
                    onChanged: (v) => v == null ? null : notifier.setThemeMode(v),
                  ),
              ],
            ),
          ),
          const SizedBox(height: PlotSpacing.s5),
          Text('CONTRAST', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: PlotSpacing.s2),
          PlotCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                RadioListTile<ContrastMode>(
                  title: const Text('Indoor (default on desktop)'),
                  value: ContrastMode.indoor,
                  groupValue: settings.contrast,
                  onChanged: (v) => v == null ? null : notifier.setContrast(v),
                ),
                RadioListTile<ContrastMode>(
                  title: const Text('Outdoor high-contrast'),
                  subtitle: const Text('Black field, white strokes, saturated accents'),
                  value: ContrastMode.highContrast,
                  groupValue: settings.contrast,
                  onChanged: (v) => v == null ? null : notifier.setContrast(v),
                ),
              ],
            ),
          ),
          const SizedBox(height: PlotSpacing.s5),
          Text('PLANNING', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: PlotSpacing.s2),
          PlotCard(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Reset planning controls', style: PlotTypography.body(c.textPrimary).copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text('K8 — one action, no per-control hunting: reverts weights, '
                          'bands, and via-nodes, and clears the generated route.',
                          style: PlotTypography.small(c.textSecondary)),
                    ],
                  ),
                ),
                PlotButton(
                  label: 'Reset',
                  variant: PlotButtonVariant.danger,
                  onPressed: () => ref.read(currentTripProvider.notifier).reset(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
