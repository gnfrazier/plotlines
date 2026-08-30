// Wireframe screen "06 Preferences & About" — K5's display & measurement
// preferences plus K8's reset-planning-controls affordance (left column)
// merged with the former `about_screen.dart`'s attribution/version surface
// (right column), matching the wireframe's two-column layout rather than
// two separate routes the way this was built before the 2026-08-17
// wireframe reconciliation. K10 (PRD FR86, FR95; ARCH §11.2, §12.4) still
// applies: a missing credit here is a build failure, not a polish item.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/sidecar_manager.dart';
import '../../state/current_trip_provider.dart';
import '../../state/providers.dart';
import '../../state/settings_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Preferences')),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const [
          Expanded(child: _DisplayAndMeasurement()),
          VerticalDivider(width: 1),
          Expanded(child: _AboutPane()),
        ],
      ),
    );
  }
}

class _DisplayAndMeasurement extends ConsumerWidget {
  const _DisplayAndMeasurement();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return ListView(
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
        Text('TEMPERATURE', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: PlotSpacing.s2),
        PlotCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              RadioListTile<TemperatureUnit>(
                title: const Text('Fahrenheit (°F)'),
                value: TemperatureUnit.fahrenheit,
                groupValue: settings.temperatureUnit,
                onChanged: (v) => v == null ? null : notifier.setTemperatureUnit(v),
              ),
              RadioListTile<TemperatureUnit>(
                title: const Text('Celsius (°C)'),
                value: TemperatureUnit.celsius,
                groupValue: settings.temperatureUnit,
                onChanged: (v) => v == null ? null : notifier.setTemperatureUnit(v),
              ),
            ],
          ),
        ),
        const SizedBox(height: PlotSpacing.s5),
        Text('DATE & TIME', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: PlotSpacing.s2),
        PlotCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              RadioListTile<ClockPref>(
                title: const Text('Match device clock'),
                value: ClockPref.inherit,
                groupValue: settings.clock,
                onChanged: (v) => v == null ? null : notifier.setClock(v),
              ),
              RadioListTile<ClockPref>(
                title: const Text('12-hour (3:07 PM)'),
                value: ClockPref.hour12,
                groupValue: settings.clock,
                onChanged: (v) => v == null ? null : notifier.setClock(v),
              ),
              RadioListTile<ClockPref>(
                title: const Text('24-hour (15:07)'),
                value: ClockPref.hour24,
                groupValue: settings.clock,
                onChanged: (v) => v == null ? null : notifier.setClock(v),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: DropdownButton<DateFormatPref>(
                    value: settings.dateFormat,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    onChanged: (v) => v == null ? null : notifier.setDateFormat(v),
                    items: const [
                      DropdownMenuItem(value: DateFormatPref.inherit, child: Text('Match device date format')),
                      DropdownMenuItem(value: DateFormatPref.iso8601, child: Text('2026-08-20  (ISO 8601)')),
                      DropdownMenuItem(value: DateFormatPref.us, child: Text('08/20/2026  (US)')),
                      DropdownMenuItem(value: DateFormatPref.uk, child: Text('20/08/2026  (UK, Europe, India)')),
                      DropdownMenuItem(value: DateFormatPref.europeanDot, child: Text('20.08.2026  (Germany, Nordics)')),
                      DropdownMenuItem(value: DateFormatPref.eastAsia, child: Text('2026/08/20  (East Asia)')),
                      DropdownMenuItem(value: DateFormatPref.dayMonYear, child: Text('20 Aug 2026')),
                      DropdownMenuItem(value: DateFormatPref.monDayYear, child: Text('Aug 20, 2026')),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'Stored dates stay ISO 8601 — this only changes how they read.',
                  style: PlotTypography.small(c.textMuted),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: PlotSpacing.s5),
        Text('READOUT', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: PlotSpacing.s2),
        PlotCard(
          padding: EdgeInsets.zero,
          child: SwitchListTile(
            title: const Text('Spoken readout on this device'),
            subtitle: const Text('H2a — uses the voices installed here; not synced to other devices'),
            value: settings.ttsReadout,
            onChanged: notifier.setTtsReadout,
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
    );
  }
}

class _AboutPane extends ConsumerWidget {
  const _AboutPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final client = ref.watch(routingClientProvider);

    return ListView(
      padding: const EdgeInsets.all(PlotSpacing.s5),
      children: [
        Text('ABOUT PLOTLINES', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: PlotSpacing.s3),
        Text('Plotlines', style: PlotTypography.display(c.textPrimary).copyWith(fontSize: 32)),
        const SizedBox(height: PlotSpacing.s2),
        Text('App version ${resolveClientVersion()}', style: PlotTypography.data(c.textSecondary)),
        const SizedBox(height: PlotSpacing.s1),
        FutureBuilder<Map<String, dynamic>>(
          future: client.health(),
          builder: (context, snapshot) {
            final version = snapshot.data?['sidecar_version'] as String?;
            return Text(
              version == null ? 'Sidecar version: checking…' : 'Sidecar version $version',
              style: PlotTypography.data(c.textSecondary),
            );
          },
        ),
        const SizedBox(height: PlotSpacing.s6),
        Text('DATA & ATTRIBUTION', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: PlotSpacing.s2),
        const _AttributionCard(
          source: 'Elevation — GEDTM30',
          credit: 'GEDTM30 via OpenTopography, CC BY 4.0',
          detail: 'Global Elevation Digital Terrain Model, 30 m resolution.',
        ),
        const SizedBox(height: PlotSpacing.s3),
        const _AttributionCard(
          source: 'Basemap — Protomaps Basemap',
          credit: '© OpenStreetMap contributors, ODbL',
          detail: 'Vector tiles built from OpenStreetMap data.',
        ),
        const SizedBox(height: PlotSpacing.s6),
        Text(
          'Plotlines runs entirely on your device. No accounts, no telemetry, '
          'no hosted service for the desktop app.',
          style: PlotTypography.small(c.textSecondary),
        ),
      ],
    );
  }
}

class _AttributionCard extends StatelessWidget {
  const _AttributionCard({required this.source, required this.credit, required this.detail});
  final String source;
  final String credit;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return PlotCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(source, style: PlotTypography.body(c.textPrimary).copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(credit, style: PlotTypography.small(c.textSecondary)),
          const SizedBox(height: 2),
          Text(detail, style: PlotTypography.small(c.textMuted)),
        ],
      ),
    );
  }
}
