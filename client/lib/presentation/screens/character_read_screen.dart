// H13 (FR132, FR116) — "Read my trip": the Character-facing reading surface,
// equivalent in content to the Author's own itinerary/cue-sheet views (F1/F2,
// issues #67/#68) but built for someone reading the finished journey rather
// than authoring it — no MASTER/INDIVIDUAL toggle, no attendance picker, no
// export controls. Read-only content plus one Print action.
//
// **What FR132's "three surfaces" this delivers, and what it does not.**
// FR132 names the mobile app, a web view, and print, "with equivalent
// content." This screen (and the print document it builds) is the app
// surface; `showPrintPreview` below is the print surface. **The web
// surface — an accountless reader opening `GET /read/{share_token}`
// (ARCH §8.2, §10.3) — is not built here.** That endpoint, the hosted
// Postgres tables it would read from (ARCH §11.1, "hosted mode only"), and
// the `/auth`/`/shares` endpoints it depends on do not exist anywhere in
// this codebase yet — there is no hosted-mode FastAPI deployment at all, only
// the desktop sidecar. Per the issue's own PRD note this is explicitly **"not
// an MVP blocker; gated to the web/hosted leg"** (SPIKE-F, ARCH D59): the
// *policy* for that surface is decided (an accountless reader gets the
// permanently-empty revealed set this screen's own [buildPlotPoints] already
// implements — see that file's doc comment), but standing up the hosted
// leg itself is a separate, much larger piece of work this story does not
// invent speculatively.
//
// **Reveal is real here, not a no-op.** F1/F2/F3's print previews (issues
// #67-#69) deliberately do not apply reveal — they are the Author looking at
// their own trip, where nothing is hidden from them. This screen is the
// first real Character-facing consumer of [RevealResolver]/[buildPlotPoints]
// in the Presentation layer: a plot point the Character has not "arrived" at
// (no live arrival signal exists yet — see `data/character_journey.dart`)
// renders as a placeholder, never its title or note.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/character_journey.dart';
import '../../domain/domain.dart';
import '../../state/providers.dart';
import '../../state/settings_provider.dart';
import '../widgets/print_preview.dart';
import 'plan_tabs/export_tab.dart' show DayCueSection;

class CharacterReadScreen extends ConsumerWidget {
  const CharacterReadScreen({super.key, required this.trip});
  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final itinerary = buildItinerary(
      trip,
      format: ref.watch(displayFormatProvider),
      // No `hasArrived` override here — same "never arrived" placeholder
      // policy `buildPlotPoints` below already applies for this Character
      // surface (issue #101 owns the real arrival signal).
      anchorTitlesByDayId: revealedAnchorTitlesByDay(trip),
    );
    final plotPoints = buildPlotPoints(trip);

    // No Scaffold/AppBar of its own — this mounts as a Trip Shell tab
    // (`trip_shell_screen.dart`'s READ tab), inside the shell's single
    // Scaffold, matching every sibling tab (`ExportTab` et al.).
    return ListView(
      padding: const EdgeInsets.all(PlotSpacing.s5),
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: PlotButton(
            label: 'Print',
            variant: PlotButtonVariant.secondary,
            onPressed: () => _showPrintPreview(context, ref, itinerary, plotPoints),
          ),
        ),
        const SizedBox(height: PlotSpacing.s3),
        Text('ITINERARY',
            style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: PlotSpacing.s2),
        PlotCard(
          padding: const EdgeInsets.all(PlotSpacing.s4),
          child: itinerary.days.isEmpty
              ? Text('No days on this trip yet.', style: PlotTypography.body(c.textMuted))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in itinerary.days) ...[
                      Text(entry.heading, style: PlotTypography.title(c.textPrimary)),
                      const SizedBox(height: PlotSpacing.s1),
                      for (final paragraph in entry.paragraphs)
                        Padding(
                          padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
                          child: Text(paragraph, style: PlotTypography.body(c.textSecondary)),
                        ),
                      const SizedBox(height: PlotSpacing.s2),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: PlotSpacing.s5),
        if (plotPoints.isNotEmpty) ...[
          Text('PLOT POINTS',
              style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: PlotSpacing.s2),
          PlotCard(
            padding: const EdgeInsets.all(PlotSpacing.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final point in plotPoints) _PlotPointRow(point: point),
              ],
            ),
          ),
          const SizedBox(height: PlotSpacing.s5),
        ],
        for (final day in trip.days)
          DayCueSection(key: ValueKey(day.id), day: day, trip: trip),
      ],
    );
  }

  Future<void> _showPrintPreview(
    BuildContext context,
    WidgetRef ref,
    Itinerary itinerary,
    List<PlotPointEntry> plotPoints,
  ) async {
    final attribution = await fetchPrintAttribution(ref.read(routingClientProvider));
    if (!context.mounted) return;
    await showPrintPreview(
      context,
      document: ItineraryPrintDocument(
        title: trip.title,
        sections: [
          for (final entry in itinerary.days)
            ProseSection(heading: entry.heading, paragraphs: entry.paragraphs),
        ],
        plotPoints: plotPoints,
      ),
      staleItems: tripStaleItems(trip),
      attribution: attribution,
    );
  }
}

/// One [PlotPointEntry] on screen — never reads a [Role] directly (gate 1 of
/// `tools/ci/reveal_gate_lint.sh`), only the already-resolved entry.
class _PlotPointRow extends StatelessWidget {
  const _PlotPointRow({required this.point});
  final PlotPointEntry point;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  point.visible ? (point.title ?? 'Plot point') : 'Held for arrival',
                  style: PlotTypography.body(c.textPrimary),
                ),
              ),
              if (point.arcStage != null)
                Padding(
                  padding: const EdgeInsets.only(left: PlotSpacing.s2),
                  child: Text(_arcStageLabel(point.arcStage!),
                      style: PlotTypography.small(c.textMuted)),
                ),
              if (point.hazard)
                Padding(
                  padding: const EdgeInsets.only(left: PlotSpacing.s2),
                  child: Text('HAZARD',
                      style: PlotTypography.small(c.danger).copyWith(fontWeight: FontWeight.w700)),
                ),
            ],
          ),
          if (point.visible && point.note != null)
            Padding(
              padding: const EdgeInsets.only(top: PlotSpacing.s1),
              child: Text(point.note!, style: PlotTypography.body(c.textSecondary)),
            ),
        ],
      ),
    );
  }
}

String _arcStageLabel(ArcStage stage) => switch (stage) {
      ArcStage.exposition => 'exposition',
      ArcStage.rising => 'rising action',
      ArcStage.crux => 'crux',
      ArcStage.climax => 'climax',
      ArcStage.resolution => 'resolution',
    };
