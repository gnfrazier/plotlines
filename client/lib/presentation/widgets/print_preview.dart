// Issue #326 — one print previewer, not two. The Export tab used to open two
// near-identical `Dialog`s (itinerary and per-day cue sheet), each echoing
// its export writer's raw source — Markdown syntax, a literal `[PROVISION]`
// tag — in an unpaginated 640×800 box with no attribution and no print
// action. This is the shared surface both entry points now call instead:
// a real, paginated page (`package:pdf`'s `MultiPage`, header + footer with
// page numbers), rendered content rather than echoed source, attribution on
// every page from `GET /about` (never hardcoded), and an actual Print button
// (`package:printing`'s `PdfPreview`, which also gives Print for free).
//
// The two documents stay two documents — `ItineraryPrintDocument` and
// `CueSheetPrintDocument` — because F1/F2/F3/H13 (issues #67, #68, #69, #87)
// are the still-open, unstarted stories that will eventually feed this
// previewer richer content. This file only decides the shared shape so that
// when they land, the answer to "two previews?" stays one previewer, several
// documents, rather than a third dialog appearing beside a rebuilt first two.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:printing/printing.dart';

import '../../data/character_journey.dart';
import '../../data/routing_client.dart';
import '../../domain/attribution_line.dart';
import '../../domain/domain.dart' show ArcStage;
import '../../domain/stale_work.dart';

/// The vendored brand faces (`plotlines_ui`'s own asset registration —
/// `packages/plotlines_ui/pubspec.yaml`'s `fonts:` list), reused here rather
/// than the `pdf` package's core-14 default: Helvetica has no Unicode
/// support at all — it can't even draw an em dash, let alone a cue glyph —
/// so a printed heading like "Day 1 — To the Gap" would silently drop the
/// dash. Archivo carries prose/headings (matches `PlotTypography.body`/
/// `.title` on screen); JetBrains Mono carries cue-sheet rows (matches
/// `PlotTypography.data`, the same family `CueSheetRow` renders in).
Future<pw.Font> _loadFont(String assetPath) async {
  final data = await rootBundle.load(assetPath);
  return pw.Font.ttf(data);
}

/// Three of the on-screen cue glyphs (`_modeChangeEntry`'s `⇄`, the surfaced-
/// constraint `⚑`, the event `◷`) fall outside both vendored fonts' Unicode
/// coverage — checked directly against each font's cmap, not guessed — so
/// they'd draw as a missing-glyph box on paper. A short print-safe stand-in
/// beats a blank tofu square on a document meant to be read off-screen;
/// every other glyph this app uses (turns are already ASCII letters; hazard
/// `⚠`, portage `▲`, regroup `◆`, the plain waypoint `●` all live in
/// JetBrains Mono) prints as drawn on screen.
const _printSafeGlyph = {
  '⇄': '<>',
  '⚑': '!',
  '◷': 'o',
};

String _glyphForPrint(String glyph) => _printSafeGlyph[glyph] ?? glyph;

/// One line of a cue sheet — the previewer's rendering of a `CueSheetRow`
/// (`plotlines_ui`'s on-screen widget), so a printed page shows the same
/// glyph/tag styling the screen does rather than a literal `[TAG]` echo.
class CueLine {
  const CueLine({
    required this.distance,
    required this.glyph,
    required this.label,
    this.tag,
  });

  final String distance;
  final String glyph;
  final String label;
  final String? tag;
}

/// One heading's worth of prose — the previewer's rendering of an
/// `ItineraryDayEntry` (`domain/itinerary.dart`), so a printed page shows
/// formatted narrative rather than the Markdown source `itineraryToMarkdown`
/// writes for export.
class ProseSection {
  const ProseSection({required this.heading, required this.paragraphs});

  final String heading;
  final List<String> paragraphs;
}

/// A document the previewer can render. Both entry points build one of these
/// rather than a `Dialog` of their own; the previewer that renders them is
/// the part this issue actually unifies.
sealed class PrintDocument {
  const PrintDocument({required this.title});

  final String title;
}

/// F2 (FR48) — the master or an individual itinerary, in the same
/// narrative-register paragraphs the on-screen preview and the Markdown
/// export both read from (`domain/itinerary.dart`'s `Itinerary`).
///
/// [plotPoints] (H13, FR132/FR116) is the reading surface's reveal-gated
/// "plot points" list — [CharacterJourney] builds it via
/// [buildPlotPoints]/[PlotPointEntry], never a raw [Role], so a withheld
/// plot point prints as a placeholder rather than as whatever it holds.
/// Empty by default: the itinerary's other two callers (F2's Author preview
/// and export) carry no plot points at all.
class ItineraryPrintDocument extends PrintDocument {
  const ItineraryPrintDocument({
    required super.title,
    required this.sections,
    this.plotPoints = const [],
  });

  final List<ProseSection> sections;
  final List<PlotPointEntry> plotPoints;
}

/// F1 (FR46) — one day's cue sheet, in the same reveal-safe `entries` the
/// on-screen `CueSheetRow` list reads (`export_tab.dart`'s `_CueEntry`) —
/// FR116 is satisfied by construction because this previewer takes exactly
/// that list, never a second unguarded read.
class CueSheetPrintDocument extends PrintDocument {
  const CueSheetPrintDocument({required super.title, required this.lines});

  final List<CueLine> lines;
}

/// The one call both `export_tab.dart` print-preview buttons make.
///
/// FR140/Flow 9 — "print blocks with no override": unlike export's
/// `ensureNoStaleWork` (which opens the resolvable stale list and lets the
/// Author proceed once it's cleared), a stale printed page is believed for
/// hours with nothing to re-check it against, so [staleItems] non-empty
/// blocks outright here rather than routing through that dialog.
Future<void> showPrintPreview(
  BuildContext context, {
  required PrintDocument document,
  required List<StaleItem> staleItems,
  required List<AttributionLine> attribution,
}) async {
  if (staleItems.isNotEmpty) {
    await _showStaleBlock(context, staleItems);
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _PrintPreviewScreen(document: document, attribution: attribution),
    ),
  );
}

/// K10/K11 (FR86, FR95, FR101) — attribution for the printed page comes from
/// the same `GET /about` list the About pane shows, falling back to the
/// bundled [aboutStaticAttribution] when no sidecar is reachable, so a print
/// preview never ships with an empty credit line.
Future<List<AttributionLine>> fetchPrintAttribution(RoutingClient client) async {
  try {
    final about = await client.about();
    return attributionLinesFrom(about['attributions']);
  } catch (_) {
    return aboutStaticAttribution;
  }
}

Future<void> _showStaleBlock(BuildContext context, List<StaleItem> staleItems) {
  final n = staleItems.length;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('$n stale ${n == 1 ? 'item needs' : 'items need'} re-solving'),
      content: Text(
        "An edit changed what ${n == 1 ? 'this was' : 'these were'} asked to solve for. "
        "This can't be printed until every stale item is re-solved — open the stale list "
        'from Export and resolve or drop each one, then print again.',
      ),
      actions: [
        PlotButton(
          label: 'Close',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(dialogContext),
        ),
      ],
    ),
  );
}

class _PrintPreviewScreen extends StatelessWidget {
  const _PrintPreviewScreen({required this.document, required this.attribution});

  final PrintDocument document;
  final List<AttributionLine> attribution;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(document.title)),
      body: PdfPreview(
        build: (format) => _buildPdf(format, document, attribution),
        // A fixed letter page at a Plotlines-authored layout, not a general
        // document editor — page format/orientation and the debug panel stay
        // off; sharing is out of scope here (issue #326 is print, not export).
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
        allowSharing: false,
        pdfFileName: '${_safeFileName(document.title)}.pdf',
      ),
    );
  }
}

String _safeFileName(String title) {
  final safe = title.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
  return safe.isEmpty ? 'plotlines' : safe;
}

Future<Uint8List> _buildPdf(
  PdfPageFormat format,
  PrintDocument document,
  List<AttributionLine> attribution,
) async {
  final archivo =
      await _loadFont('packages/plotlines_ui/assets/fonts/Archivo-Variable.ttf');
  final mono =
      await _loadFont('packages/plotlines_ui/assets/fonts/JetBrainsMono-Variable.ttf');
  // Both TTFs are variable fonts loaded at their default instance (`pw.Font`
  // has no axis support), so there is no separate bold weight to hand
  // `ThemeData` — reusing the one instance for `bold` keeps every `pw.Text`
  // on a font that actually covers an em dash, rather than letting a bold
  // request fall back to core Helvetica and lose it again.
  final theme = pw.ThemeData.withFont(base: archivo, bold: archivo);
  final doc = pw.Document(title: document.title, theme: theme);
  final attributionText = attribution.map((a) => a.attribution).join('   ·   ');
  doc.addPage(
    pw.MultiPage(
      pageFormat: format,
      // A long multi-day itinerary or cue sheet can run well past the
      // package's 20-page default; this is a real document, not a preview
      // snippet.
      maxPages: 200,
      header: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(document.title, style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          pw.SizedBox(height: 4),
          pw.Divider(color: PdfColors.grey400, height: 1),
        ],
      ),
      footer: (context) => pw.Column(
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          pw.Divider(color: PdfColors.grey400, height: 1),
          pw.SizedBox(height: 2),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Expanded(
                child: pw.Text(attributionText,
                    style: pw.TextStyle(fontSize: 7, color: PdfColors.grey600)),
              ),
              pw.SizedBox(width: 12),
              pw.Text('Page ${context.pageNumber} of ${context.pagesCount}',
                  style: pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
            ],
          ),
        ],
      ),
      build: (context) => _content(document, mono: mono, fallback: archivo),
    ),
  );
  return doc.save();
}

List<pw.Widget> _content(
  PrintDocument document, {
  required pw.Font mono,
  required pw.Font fallback,
}) =>
    switch (document) {
      ItineraryPrintDocument(:final sections, :final plotPoints) => [
          for (final section in sections) ...[
            pw.Text(section.heading, style: const pw.TextStyle(fontSize: 14)),
            pw.SizedBox(height: 6),
            for (final paragraph in section.paragraphs)
              pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 8),
                child: pw.Text(paragraph, style: const pw.TextStyle(fontSize: 11)),
              ),
            pw.SizedBox(height: 10),
          ],
          if (plotPoints.isNotEmpty) ..._plotPointsSection(plotPoints),
        ],
      CueSheetPrintDocument(:final lines) => [
          for (var i = 0; i < lines.length; i++)
            _cueLineRow(lines[i], mono: mono, fallback: fallback, divider: i < lines.length - 1),
        ],
    };

/// H13 (FR132, FR116) — the plot-points section: arc stage always shown (it
/// is never withheld), title/note shown only when [PlotPointEntry.visible] —
/// a held one prints as "Held for arrival," never its title or note, which
/// is what "the paper copy cannot spoil the trip" means on paper.
List<pw.Widget> _plotPointsSection(List<PlotPointEntry> plotPoints) => [
      pw.Text('Plot points', style: const pw.TextStyle(fontSize: 14)),
      pw.SizedBox(height: 6),
      for (final point in plotPoints)
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 8),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                children: [
                  pw.Text(
                    point.visible ? (point.title ?? 'Plot point') : 'Held for arrival',
                    style: const pw.TextStyle(fontSize: 11),
                  ),
                  if (point.arcStage != null) ...[
                    pw.SizedBox(width: 8),
                    pw.Text('(${_arcStageLabel(point.arcStage!)})',
                        style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
                  ],
                  if (point.hazard) ...[
                    pw.SizedBox(width: 8),
                    pw.Text('HAZARD',
                        style: pw.TextStyle(
                            fontSize: 9, color: PdfColors.red800, fontWeight: pw.FontWeight.bold)),
                  ],
                ],
              ),
              if (point.visible && point.note != null)
                pw.Text(point.note!, style: const pw.TextStyle(fontSize: 10)),
            ],
          ),
        ),
      pw.SizedBox(height: 10),
    ];

String _arcStageLabel(ArcStage stage) => switch (stage) {
      ArcStage.exposition => 'exposition',
      ArcStage.rising => 'rising action',
      ArcStage.crux => 'crux',
      ArcStage.climax => 'climax',
      ArcStage.resolution => 'resolution',
    };

pw.Widget _cueLineRow(
  CueLine line, {
  required pw.Font mono,
  required pw.Font fallback,
  required bool divider,
}) {
  final style = pw.TextStyle(font: mono, fontFallback: [fallback], fontSize: 10);
  return pw.Column(
    children: [
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 6),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(width: 48, child: pw.Text(line.distance, style: style)),
            pw.SizedBox(width: 24, child: pw.Text(_glyphForPrint(line.glyph), style: style)),
            pw.Expanded(child: pw.Text(line.label, style: style)),
            if (line.tag != null)
              pw.Text(line.tag!, style: style.copyWith(color: PdfColors.green800, fontSize: 9)),
          ],
        ),
      ),
      if (divider) pw.Divider(height: 1, thickness: 0.5, color: PdfColors.grey300),
    ],
  );
}
