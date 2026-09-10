// FR20 [AMENDED v2.0] / C4, Flow 11 — the alternate card, and the naming
// moment that opens it.
//
// Both moved here from `logistics_tab.dart` under issue #324, because the card
// now has two callers: the Route tab opens it the instant a divergence has
// been drawn, and the Logistics list opens it afterwards to inspect one.
//
// **The card is an inspector, not a form for an abstraction.** It used to open
// on an alternate with no geometry — its own status line read `EXTENSION · not
// drawn` — and asked the Author to name, shape, describe, attach plot points
// to, narrate and set the reveal of a path that did not exist and whose extent
// they could not see. Nothing in it could answer where the alternate went,
// because none of that had been decided yet. Now the gesture comes first
// (`domain/alternate_draft.dart`), and this opens on something real: it leads
// with where the path leaves the day, where it comes back, and what that costs
// against the day as written.
//
// The five blocks of standing prose that explained the *model* rather than the
// alternate are gone with it. The by-reference rule is a first-run teaching
// moment (`domain/teaching.dart`), the hazard invariant is on the reveal
// control it qualifies, the intent descriptions are one line plus a tooltip,
// and both empty states are one line plus their next action
// (`domain/empty_state.dart`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
import '../../state/settings_provider.dart';
import 'teaching_block.dart';

/// PRD §1.4–1.5, and the model itself: no Author setting hides a hazard. Said
/// at the reveal control, which is the only place an Author could reasonably
/// expect otherwise.
const String kBranchRevealHazardNote =
    'The fork stays visible — only its content waits. Hazards on this path are '
    'shown to everyone before the fork, whatever the reveal says.';

/// What [showAlternateNamingDialog] returns: the vocabulary, said in words,
/// over a path that has already been drawn.
class AlternateNaming {
  const AlternateNaming({required this.intent, required this.kind, required this.label});
  final String intent;
  final String kind;
  final String label;
}

/// The naming moment, over a finished [draft]. Returns null if the Author backs
/// out — the draft is theirs to keep drawing or discard, and nothing has been
/// added to the trip.
Future<AlternateNaming?> showAlternateNamingDialog(
  BuildContext context, {
  required AlternateDraft draft,
}) =>
    showDialog<AlternateNaming>(
      context: context,
      builder: (_) => _NameAlternateDialog(draft: draft),
    );

/// The card for one alternate that already exists on [segmentId].
Future<void> showAlternateCard(
  BuildContext context, {
  required String dayId,
  required String segmentId,
  required String alternateId,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => AlternateCard(
        dayId: dayId,
        segmentId: segmentId,
        alternateId: alternateId,
      ),
    );

// ---------------------------------------------------------------------------
// Naming
// ---------------------------------------------------------------------------

class _NameAlternateDialog extends ConsumerStatefulWidget {
  const _NameAlternateDialog({required this.draft});
  final AlternateDraft draft;

  @override
  ConsumerState<_NameAlternateDialog> createState() => _NameAlternateDialogState();
}

class _NameAlternateDialogState extends ConsumerState<_NameAlternateDialog> {
  final _name = TextEditingController();
  String _intent = 'accommodation';
  late String _kind = widget.draft.impliedKind;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final df = ref.watch(displayFormatProvider);
    final named = _name.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text('Name this alternate', style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The path first: it exists, it was just drawn, and the card
              // opening next describes it. Nothing here is hypothetical.
              _DivergenceReadout(
                divergesAtM: widget.draft.divergesAtM,
                rejoinsAtM: widget.draft.rejoinsAtM,
                pathDistanceM: widget.draft.alternateDistanceM,
                deltaM: widget.draft.deltaM,
                solved: false,
                displayFormat: df,
              ),
              const SizedBox(height: PlotSpacing.s3),
              Text('What kind of alternate is this?', style: PlotTypography.body(c.textSecondary)),
              const SizedBox(height: PlotSpacing.s2),
              _IntentChoice(
                selected: _intent == 'accommodation',
                title: 'Accommodation',
                line: 'The same day at a different effort.',
                tooltip: 'A bypass takes the easiest line; an extension adds work. '
                    'A Character can take it on their own copy without changing '
                    'anyone else’s day. It carries shape, label, geometry and '
                    'metrics — nothing of its own.',
                onTap: () => setState(() => _intent = 'accommodation'),
              ),
              const SizedBox(height: PlotSpacing.s2),
              _IntentChoice(
                selected: _intent == 'branch',
                title: 'Branch',
                line: 'A choice that changes what the day contains.',
                tooltip: 'The path carries its own plot points, its own narration '
                    'and its own reveal — the long way past the mine, or the '
                    'direct way home. A branch is chosen in the field, at the '
                    'fork, never as an effort toggle.',
                onTap: () => setState(() => _intent = 'branch'),
              ),
              const SizedBox(height: PlotSpacing.s3),
              // Defaulted from the line that was drawn: it is already known
              // whether this path is shorter or longer than what it replaces.
              Text('SHAPE', style: PlotTypography.data(c.textMuted)),
              const SizedBox(height: PlotSpacing.s1),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'bypass', label: Text('The direct way')),
                  ButtonSegment(value: 'extension', label: Text('The long way round')),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: PlotSpacing.s3),
              TextField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name this alternate',
                  hintText: 'A short name the group will recognise',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
        ),
      ),
      actions: [
        PlotButton(
          label: 'Cancel',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(context),
        ),
        PlotButton(
          label: _intent == 'branch' ? 'Create branch' : 'Create alternate',
          onPressed: named
              ? () => Navigator.pop(
                    context,
                    AlternateNaming(
                      intent: _intent,
                      kind: _kind,
                      label: _name.text.trim(),
                    ),
                  )
              : null,
        ),
      ],
    );
  }
}

class _IntentChoice extends StatelessWidget {
  const _IntentChoice({
    required this.selected,
    required this.title,
    required this.line,
    required this.tooltip,
    required this.onTap,
  });
  final bool selected;
  final String title;

  /// One line. What the choice is; not a paragraph about the model.
  final String line;

  /// The rest of it, on the control it describes.
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: PlotRadii.controlShape,
        child: Container(
          padding: const EdgeInsets.all(PlotSpacing.s3),
          decoration: BoxDecoration(
            borderRadius: PlotRadii.controlShape,
            border: Border.all(
              color: selected ? c.primary : c.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 18,
                color: selected ? c.primary : c.textMuted,
              ),
              const SizedBox(width: PlotSpacing.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: PlotTypography.body(c.textPrimary)
                            .copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(line, style: PlotTypography.small(c.textSecondary)),
                  ],
                ),
              ),
              Icon(Icons.help_outline, size: 14, color: c.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The card
// ---------------------------------------------------------------------------

/// Flow 11 §03/§04 — one card, longer for a branch. The four branch fields
/// (note, anchors, narration, reveal) are simply absent while the alternate is
/// an accommodation: the model has no place to put them.
class AlternateCard extends ConsumerStatefulWidget {
  const AlternateCard({
    super.key,
    required this.dayId,
    required this.segmentId,
    required this.alternateId,
  });
  final String dayId;
  final String segmentId;
  final String alternateId;

  @override
  ConsumerState<AlternateCard> createState() => _AlternateCardState();
}

class _AlternateCardState extends ConsumerState<AlternateCard> {
  late final TextEditingController _name;
  late final TextEditingController _note;

  Alternate? _find(Trip trip) {
    for (final day in trip.days) {
      if (day.id != widget.dayId) continue;
      for (final s in day.segments) {
        if (s.id != widget.segmentId) continue;
        for (final a in s.alternates) {
          if (a.id == widget.alternateId) return a;
        }
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final a = _find(ref.read(currentTripProvider));
    _name = TextEditingController(text: a?.label ?? '');
    _note = TextEditingController(text: a?.note ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  CurrentTripNotifier get _notifier => ref.read(currentTripProvider.notifier);

  void _patch(Alternate Function(Alternate) f) {
    final current = _find(ref.read(currentTripProvider));
    if (current == null) return;
    _notifier.updateAlternateInSegment(widget.dayId, widget.segmentId, f(current));
  }

  Future<void> _toAccommodation(Alternate a) async {
    if (a.hasBranchContent) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlternateConvertPrompt(alternate: a),
      );
      if (ok != true) return;
    }
    _notifier.convertAlternateIntent(
        widget.dayId, widget.segmentId, a.id, 'accommodation');
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final trip = ref.watch(currentTripProvider);
    final df = ref.watch(displayFormatProvider);
    final a = _find(trip);
    if (a == null) {
      // Deleted underneath the open card — nothing to inspect.
      return const SizedBox.shrink();
    }

    return AlertDialog(
      title: Row(
        children: [
          PlotBadge(a.isBranch ? 'BRANCH' : 'ACCOMMODATION',
              tone: a.isBranch ? PlotBadgeTone.gold : PlotBadgeTone.slate),
          const SizedBox(width: PlotSpacing.s2),
          Flexible(
            child: Text(a.label ?? 'Untitled alternate',
                style: PlotTypography.title(c.textPrimary), overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // What this alternate *is*, first: where it leaves the day,
              // where it comes back, and what it costs against the route as
              // written.
              _DivergenceReadout(
                divergesAtM: a.divergesAtM,
                rejoinsAtM: a.rejoinsAtM,
                pathDistanceM: a.drawnDistanceM,
                deltaM: a.distanceDeltaM,
                solved: a.metrics?.distanceM != null,
                displayFormat: df,
              ),
              const SizedBox(height: PlotSpacing.s3),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name', isDense: true),
                onChanged: (v) => _patch((cur) => v.trim().isEmpty
                    ? cur.copyWith(clearLabel: true)
                    : cur.copyWith(label: v.trim())),
              ),
              const SizedBox(height: PlotSpacing.s3),
              Text('SHAPE', style: PlotTypography.data(c.textMuted)),
              const SizedBox(height: PlotSpacing.s1),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'bypass', label: Text('Bypass')),
                  ButtonSegment(value: 'extension', label: Text('Extension')),
                ],
                selected: {a.kind},
                onSelectionChanged: (s) => _patch((cur) => cur.copyWith(kind: s.first)),
              ),
              if (a.isBranch) ...[
                const SizedBox(height: PlotSpacing.s3),
                Text('WHAT IS DIFFERENT ON THIS PATH', style: PlotTypography.data(c.textMuted)),
                const SizedBox(height: PlotSpacing.s1),
                TextField(
                  controller: _note,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    hintText: 'What this path adds or avoids, in a sentence',
                    isDense: true,
                  ),
                  onChanged: (v) => _patch((cur) => v.trim().isEmpty
                      ? cur.copyWith(clearNote: true)
                      : cur.copyWith(note: v)),
                ),
                const SizedBox(height: PlotSpacing.s3),
                _BranchAnchors(
                  tripId: trip.id,
                  anchors: trip.anchors,
                  attached: a.anchorIds,
                  onToggle: (id) => _patch((cur) {
                    final next = [...cur.anchorIds];
                    next.contains(id) ? next.remove(id) : next.add(id);
                    return cur.copyWith(anchorIds: next);
                  }),
                ),
                const SizedBox(height: PlotSpacing.s3),
                Text('NARRATION ON THIS BRANCH', style: PlotTypography.data(c.textMuted)),
                const SizedBox(height: PlotSpacing.s1),
                if (a.narration == null)
                  const _EmptyLine(EmptyStateContext.branchNoNarration)
                else
                  Text('Narration attached.', style: PlotTypography.small(c.textSecondary)),
                const SizedBox(height: PlotSpacing.s3),
                Row(
                  children: [
                    Text('REVEAL FOR THIS BRANCH', style: PlotTypography.data(c.textMuted)),
                    const SizedBox(width: PlotSpacing.s1),
                    // The invariant, on the control it qualifies — reachable,
                    // and no longer four lines of standing body copy.
                    Tooltip(
                      message: kBranchRevealHazardNote,
                      child: Icon(Icons.help_outline, size: 14, color: c.textMuted),
                    ),
                  ],
                ),
                const SizedBox(height: PlotSpacing.s1),
                Tooltip(
                  message: kBranchRevealHazardNote,
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: '', label: Text('Not set')),
                      ButtonSegment(value: 'always_visible', label: Text('Always visible')),
                      ButtonSegment(value: 'on_arrival', label: Text('On arrival')),
                    ],
                    selected: {a.reveal ?? ''},
                    onSelectionChanged: (s) => _patch((cur) => s.first.isEmpty
                        ? cur.copyWith(clearReveal: true)
                        : cur.copyWith(reveal: s.first)),
                  ),
                ),
              ] else ...[
                const SizedBox(height: PlotSpacing.s3),
                Text(
                  'This alternate carries nothing of its own — the same day at a '
                  'different effort.',
                  style: PlotTypography.small(c.textMuted),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (a.isBranch)
          PlotButton(
            label: 'Make this an accommodation',
            variant: PlotButtonVariant.ghost,
            onPressed: () => _toAccommodation(a),
          )
        else
          PlotButton(
            label: 'Make this a branch',
            variant: PlotButtonVariant.ghost,
            onPressed: () => _notifier.convertAlternateIntent(
                widget.dayId, widget.segmentId, a.id, 'branch'),
          ),
        PlotButton(label: 'Done', onPressed: () => Navigator.pop(context)),
      ],
    );
  }
}

/// Where the path leaves the day and where it comes back, and what it costs
/// against the day as written. The block that replaced `not drawn`.
///
/// [solved] says which kind of number this is: a solved distance from the
/// engine, or the length of the line the Author drew. Numbers are never fudged
/// and a drawn line does not get to wear a solved line's authority, so the two
/// are labelled differently rather than merged.
class _DivergenceReadout extends StatelessWidget {
  const _DivergenceReadout({
    required this.divergesAtM,
    required this.rejoinsAtM,
    required this.pathDistanceM,
    required this.deltaM,
    required this.solved,
    required this.displayFormat,
  });

  final double? divergesAtM;
  final double? rejoinsAtM;
  final double? pathDistanceM;
  final double? deltaM;
  final bool solved;
  final DisplayFormat displayFormat;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final d = deltaM;
    return PlotCard(
      sunk: true,
      padding: const EdgeInsets.all(PlotSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('WHERE IT LEAVES AND REJOINS', style: PlotTypography.data(c.textMuted)),
          const SizedBox(height: PlotSpacing.s2),
          Row(
            children: [
              Expanded(
                child: _Stat(
                  label: 'LEAVES',
                  value: divergesAtM == null ? '—' : displayFormat.formatDistance(divergesAtM!),
                ),
              ),
              Expanded(
                child: _Stat(
                  label: 'REJOINS',
                  value: rejoinsAtM == null ? '—' : displayFormat.formatDistance(rejoinsAtM!),
                ),
              ),
            ],
          ),
          const SizedBox(height: PlotSpacing.s3),
          Row(
            children: [
              Expanded(
                child: _Stat(
                  label: 'THIS PATH',
                  value:
                      pathDistanceM == null ? '—' : displayFormat.formatDistance(pathDistanceM!),
                ),
              ),
              Expanded(
                child: _Stat(
                  label: 'DIFFERENCE',
                  value: d == null
                      ? '—'
                      : '${d < 0 ? '−' : '+'}${displayFormat.formatDistance(d.abs())}',
                ),
              ),
            ],
          ),
          if (!solved) ...[
            const SizedBox(height: PlotSpacing.s2),
            Text(
              'Measured off the line as drawn, not solved.',
              style: PlotTypography.small(c.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: PlotTypography.data(c.textMuted)),
        const SizedBox(height: 2),
        Text(value, style: PlotTypography.data(c.textPrimary).copyWith(fontSize: 15)),
      ],
    );
  }
}

/// FR142(c) / K12 — an empty state as one line plus its next action, from the
/// registry rather than written inline at each surface.
class _EmptyLine extends StatelessWidget {
  const _EmptyLine(this.context_);
  final EmptyStateContext context_;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final copy = emptyStateRegistry[context_]!;
    return Text('${copy.message} ${copy.nextAction}',
        style: PlotTypography.small(c.textMuted));
  }
}

class _BranchAnchors extends StatelessWidget {
  const _BranchAnchors({
    required this.tripId,
    required this.anchors,
    required this.attached,
    required this.onToggle,
  });
  final String tripId;
  final List<Anchor> anchors;
  final List<String> attached;
  final void Function(String anchorId) onToggle;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('PLOT POINTS ON THIS BRANCH', style: PlotTypography.data(c.textMuted)),
            const SizedBox(width: PlotSpacing.s1),
            const TeachingHelpIcon(moment: TeachingMoment.branchAnchorsByReference),
          ],
        ),
        const SizedBox(height: PlotSpacing.s1),
        if (anchors.isEmpty)
          const _EmptyLine(EmptyStateContext.branchNoAnchors)
        else
          for (final anchor in anchors)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: attached.contains(anchor.id),
              onChanged: (_) => onToggle(anchor.id),
              title: Text(anchor.title ?? 'Untitled anchor',
                  style: PlotTypography.body(c.textSecondary)),
            ),
        // The by-reference rule is first-run teaching, not standing body copy:
        // it explains the model, is true everywhere anchors are attached, and
        // stays reachable from the help affordance above once dismissed.
        TeachingBlock(
          tripId: tripId,
          moment: TeachingMoment.branchAnchorsByReference,
        ),
      ],
    );
  }
}

/// Flow 11 §06 (middle) — turning a branch into an effort option destroys
/// authored work, so it asks first and states the scope. Deliberateness is
/// reserved for destruction (the same shape as `showDayRemovalPrompt`).
class AlternateConvertPrompt extends StatelessWidget {
  const AlternateConvertPrompt({super.key, required this.alternate});
  final Alternate alternate;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final goes = <String>[
      if (alternate.note != null) 'the note about what is different on this path',
      if (alternate.narration != null) 'the narration on the branch',
      if (alternate.reveal != null) 'the reveal set for this branch',
    ];
    final anchors = alternate.anchorIds.length;
    return AlertDialog(
      title: Text('Turn this branch into an effort option?',
          style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'An accommodation alternate has nowhere to keep what this one is '
              'holding. This goes: ${_join(goes)}.',
              style: PlotTypography.body(c.textSecondary),
            ),
            if (anchors > 0) ...[
              const SizedBox(height: PlotSpacing.s2),
              Text(
                '$anchors ${anchors == 1 ? 'anchor stays' : 'anchors stay'} in the trip, '
                'unattached, and stay findable in the anchors view.',
                style: PlotTypography.small(c.textMuted),
              ),
            ],
          ],
        ),
      ),
      actions: [
        PlotButton(
          label: 'Keep it a branch',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(context, false),
        ),
        PlotButton(
          label: 'Give up the content and convert',
          variant: PlotButtonVariant.danger,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
  }

  static String _join(List<String> parts) {
    if (parts.isEmpty) return 'nothing';
    if (parts.length == 1) return parts.single;
    if (parts.length == 2) return '${parts[0]} and ${parts[1]}';
    return '${parts.sublist(0, parts.length - 1).join(', ')}, and ${parts.last}';
  }
}
