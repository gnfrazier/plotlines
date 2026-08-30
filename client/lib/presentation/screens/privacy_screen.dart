// K11 / FR138 (issue #117) — the privacy statement screen, reached from the
// About surface (`SettingsScreen`'s About pane) and from the same route on
// every platform, including Web guest and the share-token reading view.
//
// Content comes from `GET /about` when a sidecar is reachable and from the
// bundled `privacyStatement` constant otherwise, so the lightest surfaces
// always have something true to show. It is not legal boilerplate — it reads
// in the app's own voice.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/privacy_statement.dart';
import '../../state/providers.dart';

class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(routingClientProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & data')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: client.about(),
        builder: (context, snapshot) {
          final points = privacyPointsFrom(snapshot.data?['privacy']);
          return PrivacyStatementView(points: points);
        },
      ),
    );
  }
}

/// The rendered statement, split out so it can be shown in a screen, a dialog,
/// or a test with no providers.
class PrivacyStatementView extends StatelessWidget {
  const PrivacyStatementView({super.key, required this.points});

  final List<PrivacyPoint> points;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return ListView(
      padding: const EdgeInsets.all(PlotSpacing.s5),
      children: [
        Text(
          'What Plotlines knows and shares',
          style: PlotTypography.display(c.textPrimary).copyWith(fontSize: 26),
        ),
        const SizedBox(height: PlotSpacing.s2),
        Text(
          'Plain terms, no lawyer-speak. This is what is true.',
          style: PlotTypography.small(c.textMuted),
        ),
        const SizedBox(height: PlotSpacing.s5),
        for (final point in points) ...[
          Text(
            point.title,
            style: PlotTypography.body(c.textPrimary)
                .copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: PlotSpacing.s1),
          Text(point.body, style: PlotTypography.body(c.textSecondary)),
          const SizedBox(height: PlotSpacing.s4),
        ],
      ],
    );
  }
}
