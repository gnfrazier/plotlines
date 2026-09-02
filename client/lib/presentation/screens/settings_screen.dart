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
import '../../domain/attribution_line.dart';
import '../../state/current_trip_provider.dart';
import '../../state/providers.dart';
import '../../state/settings_provider.dart';
import 'privacy_screen.dart';

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
          Expanded(child: AboutPane()),
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
        Text('UNITS', style: PlotTypography.eyebrow(c.textMuted)),
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
        Text('TEMPERATURE', style: PlotTypography.eyebrow(c.textMuted)),
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
        Text('DATE & TIME', style: PlotTypography.eyebrow(c.textMuted)),
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
        Text('READOUT', style: PlotTypography.eyebrow(c.textMuted)),
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
        Text('APPEARANCE', style: PlotTypography.eyebrow(c.textMuted)),
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
        // Issue #230 A2 / WCAG 1.4.4 — a text-size control beside CONTRAST.
        // It multiplies whatever the OS already reports (see `_TextScale` in
        // `main.dart`), so this is "more than my desktop already gives me",
        // not a second, competing source of truth for scale.
        Text('TEXT SIZE',
            style: PlotTypography.eyebrow(c.textMuted)),
        const SizedBox(height: PlotSpacing.s2),
        PlotCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final pref in TextSizePref.values)
                RadioListTile<TextSizePref>(
                  title: Text(pref.label),
                  value: pref,
                  groupValue: settings.textSize,
                  onChanged: (v) => v == null ? null : notifier.setTextSize(v),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Applied on top of your operating system\'s own text scaling, '
                    'not instead of it.',
                    style: PlotTypography.small(c.textMuted),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: PlotSpacing.s5),
        Text('CONTRAST', style: PlotTypography.eyebrow(c.textMuted)),
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
        Text('PLANNING', style: PlotTypography.eyebrow(c.textMuted)),
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

/// K10 (FR86, FR95, FR101) + K11 (FR138). Attribution is **derived from the
/// loaded layer set** (`GET /about`), never hardcoded — the two static credits
/// (elevation CC BY, basemap ODbL) fall back to [aboutStaticAttribution] only
/// when no sidecar is reachable, so the obligation is met even on the lightest
/// surface. `attribution_complete: false` from the service is a build failure;
/// it is surfaced here rather than hidden. The privacy statement (K11) is one
/// tap away via `/privacy`, reachable on every platform.
class AboutPane extends ConsumerWidget {
  const AboutPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final client = ref.watch(routingClientProvider);

    return FutureBuilder<Map<String, dynamic>>(
      future: client.about(),
      builder: (context, snapshot) {
        final about = snapshot.data;
        final lines = attributionLinesFrom(about?['attributions']);
        final sidecarVersion = about?['sidecar_version'] as String?;
        final attributionComplete = about?['attribution_complete'] as bool? ?? true;
        final missing = (about?['missing_attribution'] as List?)?.cast<Object?>() ?? const [];

        return ListView(
          padding: const EdgeInsets.all(PlotSpacing.s5),
          children: [
            Text('ABOUT PLOTLINES', style: PlotTypography.eyebrow(c.textMuted)),
            const SizedBox(height: PlotSpacing.s3),
            Text('Plotlines', style: PlotTypography.display(c.textPrimary).copyWith(fontSize: 32)),
            const SizedBox(height: PlotSpacing.s2),
            Text('App version ${resolveClientVersion()}', style: PlotTypography.data(c.textSecondary)),
            const SizedBox(height: PlotSpacing.s1),
            Text(
              switch (snapshot.connectionState == ConnectionState.done) {
                false => 'Sidecar version: checking…',
                true => sidecarVersion == null
                    ? 'Sidecar version: unavailable'
                    : 'Sidecar version $sidecarVersion',
              },
              style: PlotTypography.data(c.textSecondary),
            ),
            const SizedBox(height: PlotSpacing.s6),
            Text('DATA & ATTRIBUTION', style: PlotTypography.eyebrow(c.textMuted)),
            const SizedBox(height: PlotSpacing.s2),
            if (!attributionComplete)
              Padding(
                padding: const EdgeInsets.only(bottom: PlotSpacing.s3),
                child: PlotCard(
                  child: Text(
                    'Attribution incomplete for: ${missing.join(', ')}. '
                    'This is a build failure — the release is gated on it.',
                    style: PlotTypography.small(c.danger),
                  ),
                ),
              ),
            for (final line in lines) ...[
              _AttributionCard(line: line),
              const SizedBox(height: PlotSpacing.s3),
            ],
            const SizedBox(height: PlotSpacing.s4),
            PlotListTile(
              title: 'Privacy & data',
              subtitle: 'What stays on this device, what reaches the server, '
                  'and what is never shared.',
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const PrivacyScreen()),
              ),
            ),
            const SizedBox(height: PlotSpacing.s5),
            Text(
              'Plotlines runs entirely on your device. No accounts, no telemetry, '
              'no hosted service for the desktop app.',
              style: PlotTypography.small(c.textSecondary),
            ),
          ],
        );
      },
    );
  }
}

class _AttributionCard extends StatelessWidget {
  const _AttributionCard({required this.line});
  final AttributionLine line;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return PlotCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_sourceLabel(line.layer),
              style: PlotTypography.body(c.textPrimary).copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(line.attribution, style: PlotTypography.small(c.textSecondary)),
          const SizedBox(height: 2),
          Text(line.licence, style: PlotTypography.small(c.textMuted)),
        ],
      ),
    );
  }

  static String _sourceLabel(String layer) => switch (layer) {
        'elevation' => 'Elevation',
        'basemap' => 'Basemap',
        _ => 'Layer — $layer',
      };
}
