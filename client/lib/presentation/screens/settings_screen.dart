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
import '../../domain/software_notice.dart';
import '../../state/current_trip_provider.dart';
import '../../state/providers.dart';
import '../../state/settings_provider.dart';
import 'privacy_screen.dart';
import 'software_notices_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      // Issue #314 — the two panes are a recessed content field so the
      // PlotCard groups within them read as their own plane rather than
      // merging into one unbroken sheet of canvas under a borderless header.
      backgroundColor: PlotColors.of(context).surfaceSunk,
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
        // Issue #465 / ARCH D24 (SPIKE-K #461 §6.3) — which Protomaps
        // flavour draws under the Author's maps. `matchAppearance` keeps
        // today's behaviour (mirrors APPEARANCE above) so nobody who never
        // opens this section sees a change.
        Text('BASEMAP STYLE', style: PlotTypography.eyebrow(c.textMuted)),
        const SizedBox(height: PlotSpacing.s2),
        PlotCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final pref in BasemapStylePref.values)
                RadioListTile<BasemapStylePref>(
                  title: Text(pref.label),
                  subtitle: pref == BasemapStylePref.grayscale
                      ? const Text('No points of interest on this style')
                      : null,
                  value: pref,
                  groupValue: settings.basemapStyle,
                  onChanged: (v) => v == null ? null : notifier.setBasemapStyle(v),
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
    final caps = ref.watch(sidecarManagerProvider).capabilities;

    return FutureBuilder<Map<String, dynamic>>(
      future: client.about(),
      builder: (context, snapshot) {
        final about = snapshot.data;
        final lines = attributionLinesFrom(about?['attributions']);
        final sidecarVersion = about?['sidecar_version'] as String?;
        final attributionComplete = about?['attribution_complete'] as bool? ?? true;
        final missing = (about?['missing_attribution'] as List?)?.cast<Object?>() ?? const [];
        final softwareNotices = softwareNoticesFrom(about?['software_notices']);
        final softwareNoticesAvailable = about?['software_notices_available'] as bool? ?? false;

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
            // Issue #367 — the mirror staleness monitor (#260) reaches this
            // surface: an advisory about data age, not an error state (D41/
            // D57, FR14/FR29a's advisory-not-constraint discipline), so it
            // never blocks planning and only appears when there is
            // something to say.
            if (_mirrorAdvisory(caps?.mirror) case final text?) ...[
              _DataFreshnessAdvisory(text: text),
              const SizedBox(height: PlotSpacing.s3),
            ],
            // Issue #454 — a refused third-party tile upstream (FR92/FR95)
            // reaching the same channel: the operator misconfigured
            // `--tiles-upstream`, not an Author-facing failure.
            if (_tilesUpstreamAdvisory(caps?.tilesUpstream) case final text?) ...[
              _DataFreshnessAdvisory(text: text),
              const SizedBox(height: PlotSpacing.s3),
            ],
            const SizedBox(height: PlotSpacing.s4),
            // Issue #314 — a bordered card on the pane, like the credits
            // above it, rather than a bare divider row on the raw field.
            PlotCard(
              padding: const EdgeInsets.symmetric(
                  horizontal: PlotSpacing.s4, vertical: PlotSpacing.s1),
              child: PlotListTile(
                title: 'Privacy & data',
                subtitle: 'What stays on this device, what reaches the server, '
                    'and what is never shared.',
                trailing: const Icon(Icons.chevron_right),
                divider: false,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const PrivacyScreen()),
                ),
              ),
            ),
            const SizedBox(height: PlotSpacing.s6),
            // Issue #267 — software notices are a distinct obligation from
            // the data credits above: the licence text owed for the code
            // Plotlines ships, not the data it displays. Two entry points
            // because they are two different dependency trees: the sidecar's
            // (a generated bundle, present only in a frozen build) and the
            // client app's own pub packages (Flutter's built-in
            // LicenseRegistry already covers those with no separate
            // generation step).
            Text('SOFTWARE NOTICES', style: PlotTypography.eyebrow(c.textMuted)),
            const SizedBox(height: PlotSpacing.s2),
            PlotCard(
              padding: const EdgeInsets.symmetric(
                  horizontal: PlotSpacing.s4, vertical: PlotSpacing.s1),
              child: Column(
                children: [
                  PlotListTile(
                    title: 'Sidecar & core licences',
                    subtitle: softwareNoticesAvailable
                        ? '${softwareNotices.length} third-party packages'
                        : 'Not available in this build (running from source)',
                    trailing: const Icon(Icons.chevron_right),
                    divider: true,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SoftwareNoticesScreen(
                          notices: softwareNotices,
                          available: softwareNoticesAvailable,
                        ),
                      ),
                    ),
                  ),
                  PlotListTile(
                    title: 'Plotlines app licences',
                    subtitle: 'Licences for the packages this client is built from.',
                    trailing: const Icon(Icons.chevron_right),
                    divider: false,
                    onTap: () => showLicensePage(
                      context: context,
                      applicationName: 'Plotlines',
                      applicationVersion: resolveClientVersion(),
                    ),
                  ),
                ],
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

/// #367 — a finished, honest sentence for the mirror staleness monitor
/// (#260), or null when there is nothing advisory to say. Checks [stale]
/// rather than `!configured`: "not configured" and "fresh" are different
/// states (§11.3 — a monitor nobody set up must never read as "up to
/// date"), and neither is loud here, only a genuinely stale pin is.
String? _mirrorAdvisory(MirrorCapability? mirror) {
  if (mirror == null || !mirror.configured || !mirror.stale) return null;
  if (mirror.error != null) {
    return "Couldn't check whether map data is up to date (${mirror.error}).";
  }
  final age = mirror.basemapAgeDays;
  final ageText = age == null ? '' : ' (basemap last refreshed ${age.round()} days ago)';
  return 'Map data may be out of date$ageText — trips still plan normally.';
}

/// #454 — only surfaces when `--tiles-upstream` was actually refused
/// (FR92/FR95); the ordinary local/mirror path has nothing to say here.
String? _tilesUpstreamAdvisory(TilesUpstreamCapability? upstream) {
  if (upstream == null || !upstream.refused) return null;
  return 'Basemap tile source was refused: '
      '${upstream.reason ?? 'not the Plotlines mirror'}.';
}

/// Shared shape for #367/#454's advisories — an icon + sentence, like
/// [_DegradedBanner] in `sidecar_gate.dart`, but scoped to one card rather
/// than a full-width banner: this is data-age/config context on the About
/// pane, not a state that blocks the app (D41/D57, FR14/FR29a).
class _DataFreshnessAdvisory extends StatelessWidget {
  const _DataFreshnessAdvisory({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return PlotCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: c.warning),
          const SizedBox(width: PlotSpacing.s2),
          Expanded(child: Text(text, style: PlotTypography.small(c.textSecondary))),
        ],
      ),
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
        'graph' => 'Routing graph',
        _ => 'Layer — $layer',
      };
}
