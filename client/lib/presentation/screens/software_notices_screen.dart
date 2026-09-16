// Issue #267, addendum L5 — the sidecar's third-party software notices, one
// tap from the About surface (`SettingsScreen`'s About pane), distinct from
// the FR101 data-attribution list shown there directly. Content comes from
// `GET /about`'s `software_notices` field, a static build artifact that only
// exists once a frozen sidecar has generated one
// (`packaging/generate_third_party_licenses.py`) — a source-run sidecar
// reports none, shown here as an explanatory empty state rather than an
// error.
//
// The client app's *own* pub dependencies are a separate obligation, already
// met with no extra generation step: Flutter's `LicenseRegistry` collects
// every pub package's licence file into the asset bundle at build time, and
// `showLicensePage` renders it. `AboutPane` links to that directly rather
// than duplicating it here.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/software_notice.dart';

class SoftwareNoticesScreen extends StatelessWidget {
  const SoftwareNoticesScreen({super.key, required this.notices, required this.available});

  final List<SoftwareNotice> notices;
  final bool available;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Scaffold(
      backgroundColor: c.surfaceSunk,
      appBar: AppBar(title: const Text('Sidecar & core licences')),
      body: !available
          ? Padding(
              padding: const EdgeInsets.all(PlotSpacing.s5),
              child: Text(
                'This build has no generated licence bundle — it only ships with a '
                'frozen sidecar (packaging/generate_third_party_licenses.py), not '
                'when running from source.',
                style: PlotTypography.body(c.textSecondary),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(PlotSpacing.s5),
              children: [
                Text(
                  '${notices.length} third-party packages',
                  style: PlotTypography.eyebrow(c.textMuted),
                ),
                const SizedBox(height: PlotSpacing.s3),
                for (final n in notices) ...[
                  Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: PlotCard(
                      padding: EdgeInsets.zero,
                      child: ExpansionTile(
                        title: Text('${n.name} ${n.version}',
                            style: PlotTypography.body(c.textPrimary)
                                .copyWith(fontWeight: FontWeight.w600)),
                        subtitle: Text(n.licence, style: PlotTypography.small(c.textMuted)),
                        childrenPadding: const EdgeInsets.symmetric(
                            horizontal: PlotSpacing.s4, vertical: PlotSpacing.s2),
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: SelectableText(
                              n.text,
                              style: PlotTypography.small(c.textSecondary).copyWith(
                                  fontFamily: 'monospace'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: PlotSpacing.s2),
                ],
              ],
            ),
    );
  }
}
