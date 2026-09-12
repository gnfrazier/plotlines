// FR26 / C10 (issue #46) — the permit/access-pass authoring surface,
// rendered on the Logistics tab under the day list, beside [GearSection] and
// [MealSection].
//
// C10's AC: "Permit status tags; confirmation numbers, documents, or links
// attachable; Characters get a pre-trip permit/pass checklist." This widget
// is the Author's authoring surface *and* the checklist itself — FR26 asks
// for a checklist "Characters" see, and since Plotlines has no separate
// Character-facing reading surface on desktop yet (FR132's web/print
// readers are a later leg), the Logistics tab's own read of
// `PermitChecklist.fromTrip` is where that checklist lives today: ordered
// worst-first (denied, then required, then applied, then confirmed) exactly
// as `plotlines_core.trips.permits.permit_checklist` orders it.
//
// Trip-scoped (`Trip.permits`), not roster-scoped — a permit is trip content
// (it belongs to the payload, travels with an authored-trip clone, and
// exports with the trip) rather than an assignment to a person, which is
// what puts [GearSection]/[MealSection] in the roster layer instead.
//
// Attaching a permit to a specific passage is not built here (`Permit
// .segmentId` exists on the model; there is no segment picker in this
// dialog yet) — most permits pin to a place or nowhere in particular, and a
// segment picker is a follow-on, not a model change, when a story needs it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:uuid/uuid.dart';

import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';

const _uuid = Uuid();

/// Public — `anchor_promotion_panel.dart`'s anchor card shares this vocabulary
/// for the reverse "a permit references this place" badge, so the same status
/// never reads as two different labels on two different surfaces.
String permitStatusLabel(String status) => switch (status) {
      'required' => 'Required',
      'applied' => 'Applied',
      'confirmed' => 'Confirmed',
      'denied' => 'Denied',
      _ => status,
    };

PlotBadgeTone permitStatusTone(String status) => switch (status) {
      'denied' => PlotBadgeTone.ember,
      'required' => PlotBadgeTone.gold,
      'applied' => PlotBadgeTone.slate,
      'confirmed' => PlotBadgeTone.spruce,
      _ => PlotBadgeTone.slate,
    };

/// The PERMITS block on the Logistics tab: every permit on the trip, ordered
/// worst-first by [PermitChecklist.fromTrip] — the same order
/// `permit_checklist` uses server-side.
class PermitSection extends ConsumerWidget {
  const PermitSection({super.key, required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final checklist = PermitChecklist.fromTrip(trip);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('PERMITS',
                style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            PlotButton(
              label: 'Add permit',
              variant: PlotButtonVariant.secondary,
              icon: Icons.add,
              onPressed: () => _addPermit(context, ref),
            ),
          ],
        ),
        const SizedBox(height: PlotSpacing.s2),
        Text(
          'Permits, land-access rules, and parking passes — the pre-trip '
          'checklist Characters see before departure.',
          style: PlotTypography.small(c.textMuted),
        ),
        const SizedBox(height: PlotSpacing.s3),
        if (checklist.permits.isEmpty)
          Text(
            'No permits yet. Add one for any land-access rule, backcountry '
            'permit, or parking pass this trip needs.',
            style: PlotTypography.body(c.textMuted),
          )
        else ...[
          if (checklist.needsAttentionCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
              child: Text(
                '${checklist.needsAttentionCount} '
                '${checklist.needsAttentionCount == 1 ? 'permit needs' : 'permits need'} attention',
                style: PlotTypography.small(c.warning),
              ),
            ),
          for (final located in checklist.permits)
            _PermitRow(key: ValueKey(located.permit.id), located: located, trip: trip),
        ],
      ],
    );
  }

  Future<void> _addPermit(BuildContext context, WidgetRef ref) async {
    final draft = await showDialog<Permit>(
      context: context,
      builder: (_) => _PermitDialog(trip: trip),
    );
    if (draft == null) return;
    ref.read(currentTripProvider.notifier).addPermit(draft);
  }
}

class _PermitRow extends ConsumerWidget {
  const _PermitRow({super.key, required this.located, required this.trip});

  final LocatedPermit located;
  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final permit = located.permit;
    final meta = <String>[
      if (located.anchorTitle != null) 'at ${located.anchorTitle}',
      if (permit.confirmationNumber != null) '# ${permit.confirmationNumber}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: PlotSpacing.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: PlotSpacing.s2),
            child: PlotBadge(permitStatusLabel(permit.status).toUpperCase(),
                tone: permitStatusTone(permit.status), solid: permit.status == 'denied'),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(permit.title, style: PlotTypography.body(c.textPrimary)),
                if (meta.isNotEmpty)
                  Text(meta.join(' · '), style: PlotTypography.small(c.textMuted)),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Permit options',
            icon: Icon(Icons.more_vert, color: c.textSecondary, size: 20),
            onSelected: (value) async {
              final notifier = ref.read(currentTripProvider.notifier);
              switch (value) {
                case 'edit':
                  final edited = await showDialog<Permit>(
                    context: context,
                    builder: (_) => _PermitDialog(trip: trip, existing: permit),
                  );
                  if (edited != null) notifier.updatePermit(edited);
                case 'remove':
                  notifier.removePermit(permit.id);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit…')),
              PopupMenuItem(value: 'remove', child: Text('Remove')),
            ],
          ),
        ],
      ),
    );
  }
}

class _PermitDialog extends StatefulWidget {
  const _PermitDialog({required this.trip, this.existing});

  final Trip trip;
  final Permit? existing;

  @override
  State<_PermitDialog> createState() => _PermitDialogState();
}

class _PermitDialogState extends State<_PermitDialog> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _confirmationNumber =
      TextEditingController(text: widget.existing?.confirmationNumber ?? '');
  late final _link = TextEditingController(text: widget.existing?.link ?? '');
  late final _note = TextEditingController(text: widget.existing?.note ?? '');
  late String _status = widget.existing?.status ?? 'required';
  late String? _anchorId = widget.existing?.anchorId;

  @override
  void dispose() {
    _title.dispose();
    _confirmationNumber.dispose();
    _link.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final confirmationNumber = _confirmationNumber.text.trim();
    final link = _link.text.trim();
    final note = _note.text.trim();
    Navigator.pop(
      context,
      Permit(
        id: widget.existing?.id ?? _uuid.v4(),
        title: title,
        status: _status,
        confirmationNumber: confirmationNumber.isEmpty ? null : confirmationNumber,
        link: link.isEmpty ? null : link,
        note: note.isEmpty ? null : note,
        anchorId: _anchorId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add permit' : 'Edit permit',
          style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Permit / pass',
                  hintText: 'Backcountry permit, put-in permit, parking pass…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: PlotSpacing.s3),
              Text('STATUS', style: PlotTypography.data(c.textMuted)),
              const SizedBox(height: PlotSpacing.s1),
              DropdownButtonFormField<String>(
                initialValue: _status,
                isDense: true,
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                items: [
                  for (final status in kPermitStatuses)
                    DropdownMenuItem(value: status, child: Text(permitStatusLabel(status))),
                ],
                onChanged: (v) => setState(() => _status = v ?? 'required'),
              ),
              const SizedBox(height: PlotSpacing.s3),
              TextField(
                controller: _confirmationNumber,
                decoration: const InputDecoration(
                  labelText: 'Confirmation number (optional)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: PlotSpacing.s2),
              TextField(
                controller: _link,
                decoration: const InputDecoration(
                  labelText: 'Link (optional)',
                  hintText: 'https://…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: PlotSpacing.s2),
              TextField(
                controller: _note,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (widget.trip.anchors.isNotEmpty) ...[
                const SizedBox(height: PlotSpacing.s3),
                Text('ATTACH TO (OPTIONAL)', style: PlotTypography.data(c.textMuted)),
                const SizedBox(height: PlotSpacing.s1),
                DropdownButtonFormField<String?>(
                  initialValue: _anchorId,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Nothing in particular')),
                    for (final anchor in widget.trip.anchors)
                      DropdownMenuItem(
                        value: anchor.id,
                        child: Text(anchor.title ?? 'Untitled anchor', overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _anchorId = v),
                ),
              ],
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        PlotButton(label: 'Cancel', variant: PlotButtonVariant.ghost, onPressed: () => Navigator.pop(context)),
        PlotButton(label: widget.existing == null ? 'Add' : 'Save', onPressed: _save),
      ],
    );
  }
}
