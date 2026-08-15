import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

void main() => runApp(const DemoApp());

class DemoApp extends StatefulWidget {
  const DemoApp({super.key});
  @override
  State<DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<DemoApp> {
  int _mode = 0; // 0 light, 1 dark, 2 high-contrast

  ThemeData get _theme => switch (_mode) {
        1 => PlotTheme.dark(),
        2 => PlotTheme.highContrast(),
        _ => PlotTheme.light(),
      };

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Plotlines UI',
      debugShowCheckedModeBanner: false,
      theme: _theme,
      home: Builder(builder: (context) {
        final c = PlotColors.of(context);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Plotlines UI'),
            actions: [
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Light')),
                  ButtonSegment(value: 1, label: Text('Dark')),
                  ButtonSegment(value: 2, label: Text('HC')),
                ],
                selected: {_mode},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(width: 12),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(PlotSpacing.s5),
            children: [
              Text('Plot a trip', style: PlotTypography.display(c.textPrimary)),
              const SizedBox(height: PlotSpacing.s5),
              Wrap(spacing: 12, runSpacing: 12, children: [
                PlotButton(label: 'Plot a trip', onPressed: () {}),
                PlotButton(
                    label: 'Download offline',
                    variant: PlotButtonVariant.secondary,
                    onPressed: () {}),
                PlotButton(
                    label: 'Discard',
                    variant: PlotButtonVariant.ghost,
                    onPressed: () => PlotDialog.confirm(context,
                        title: 'Discard route?',
                        message: 'This trip has unsynced edits.',
                        confirmLabel: 'Discard',
                        destructive: true)),
              ]),
              const SizedBox(height: PlotSpacing.s5),
              TripCard(
                title: 'Cascade Loop · 4 days',
                offlineReady: true,
                stats: const ['178 MI', '↑ 9,400 FT'],
                modeTag: 'GRAVEL+PADDLE',
                onTap: () {},
              ),
              const SizedBox(height: PlotSpacing.s5),
              PlotCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Cue sheet', style: PlotTypography.title(c.textPrimary)),
                    const SizedBox(height: 8),
                    const CueSheetRow(
                        mile: 'MI 0.0',
                        turn: 'R',
                        instruction: 'Start · Riverside lot',
                        tag: 'PAVED'),
                    const CueSheetRow(
                        mile: 'MI 4.2',
                        turn: 'L',
                        instruction: 'CR-204 · gravel begins',
                        tag: 'GRAVEL'),
                    const CueSheetRow(
                        mile: 'MI 12.4',
                        turn: '◆',
                        instruction: 'Regroup · clock tower',
                        tag: 'REST',
                        divider: false),
                  ],
                ),
              ),
              const SizedBox(height: PlotSpacing.s5),
              PlotCard(
                child: ElevationProfile(
                  samples: const [0.1, 0.3, 0.25, 0.6, 0.5, 0.85, 0.6, 0.7],
                  startLabel: 'MI 0',
                  endLabel: 'MI 24',
                ),
              ),
              const SizedBox(height: PlotSpacing.s5),
              Wrap(spacing: 20, runSpacing: 12, children: const [
                NodeMarker(NodeMarkerType.waypoint),
                NodeMarker(NodeMarkerType.regroup),
                NodeMarker(NodeMarkerType.rest),
                NodeMarker(NodeMarkerType.hazard),
                NodeMarker(NodeMarkerType.portage),
                NodeMarker(NodeMarkerType.plot),
              ]),
            ],
          ),
        );
      }),
    );
  }
}
