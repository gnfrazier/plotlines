// FR106, FR107, FR110 (Stories O1, O2) — the promotion interaction: turn a
// hand-placed coordinate into an Anchor and assign its role set (narrative /
// provision / station), each with an optional geometry offset (FR107), in
// one interaction. Trip-scoped (`Trip.anchors`), so this panel does not
// require a segment to be selected — unlike the Content tab's existing
// per-segment node editor it sits beside.
//
// FR114, FR115, FR116 (Story O5) — reveal policy: the role-set checkboxes
// default their reveal per `RoleKind.defaultReveal` when checked, a hazard
// `Switch` per role locks reveal to always-visible (FR115's hard constraint,
// unrepresentable otherwise — see `Role`'s constructor), and the panel's own
// "Preview as Character" toggle renders every anchor card through
// `RevealResolver.resolve(..., hasArrived: false)` — the AC's "preview the
// trip as a Character would see it before departure."
//
// Candidate- and cluster-proposal-sourced promotion (the other two AC
// sources) reuse the same domain call (`CurrentTripNotifier.promoteAnchor`,
// `domain/promote.dart`'s `provenanceFromCandidate`) once N3's candidate map
// and N4a's proposal review (both [P1] — MVP punchlist §2) have a selected
// candidate/proposal to hand this panel; this dialog's coordinate field is
// the hand-placed path, MVP's "promote directly" branch (Flow 2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:uuid/uuid.dart';

import '../../data/reveal_resolver.dart';
import '../../data/role_content.dart';
import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
import '../../state/messages_provider.dart';
import '../map/tap_to_pick_map.dart';
import 'note_media_editor.dart';
import 'permit_section.dart' show permitStatusLabel, permitStatusTone;
import 'teaching_block.dart';

const _resolver = RevealResolver();

const _uuid = Uuid();

/// FR108 / O3 — parses the promotion dialog's boundary text field: one
/// "lat, lon" pair per line, at least 3 distinct vertices. Closes the ring by
/// repeating the first vertex if the Author didn't already, since asking an
/// Author to type a closed ring by hand is the kind of bookkeeping [Area]'s
/// own [checkRing] already does for every other producer.
List<Coord> _parseAreaVertices(String text) {
  final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (lines.length < 3) {
    throw const FormatException('An area needs at least 3 boundary vertices.');
  }
  final vertices = <Coord>[];
  for (final line in lines) {
    final parts = line.split(',').map((p) => p.trim()).toList();
    if (parts.length != 2) {
      throw FormatException('"$line" isn\'t a "lat, lon" pair.');
    }
    final lat = double.tryParse(parts[0]);
    final lon = double.tryParse(parts[1]);
    if (lat == null || lon == null) {
      throw FormatException('"$line" isn\'t a "lat, lon" pair.');
    }
    vertices.add([lon, lat]);
  }
  if (vertices.first[0] != vertices.last[0] || vertices.first[1] != vertices.last[1]) {
    vertices.add(vertices.first);
  }
  return vertices;
}

class AnchorPromotionPanel extends ConsumerStatefulWidget {
  const AnchorPromotionPanel({super.key, required this.trip});
  final Trip trip;

  @override
  ConsumerState<AnchorPromotionPanel> createState() => _AnchorPromotionPanelState();
}

class _AnchorPromotionPanelState extends ConsumerState<AnchorPromotionPanel> {
  // O5's AC — "the Author can preview the trip as a Character would see it
  // before departure." `hasArrived: false` is exactly that pre-departure
  // view: on_arrival roles read withheld, hazards/provisions/always-visible
  // roles read through, same as what a Character's offline package holds
  // the moment it downloads.
  bool _previewAsCharacter = false;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Container(
      padding: const EdgeInsets.all(PlotSpacing.s4),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Anchors', style: PlotTypography.h2(c.textPrimary).copyWith(fontSize: 18)),
              ),
              Text('Preview as Character', style: PlotTypography.data(c.textMuted)),
              Switch(
                value: _previewAsCharacter,
                onChanged: (value) => setState(() => _previewAsCharacter = value),
              ),
              const SizedBox(width: PlotSpacing.s2),
              PlotButton(
                label: 'Promote a place',
                variant: PlotButtonVariant.secondary,
                icon: Icons.add_location_alt_outlined,
                onPressed: () => _openPromotionDialog(context),
              ),
            ],
          ),
          if (widget.trip.anchors.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: PlotSpacing.s2),
              child: Text(
                'No anchors yet — promote a candidate or a hand-placed spot to give it a role.',
                style: PlotTypography.body(c.textMuted),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: PlotSpacing.s3),
              child: Wrap(
                spacing: PlotSpacing.s2,
                runSpacing: PlotSpacing.s2,
                children: [
                  for (final anchor in widget.trip.anchors)
                    _AnchorCard(
                      anchor: anchor,
                      previewAsCharacter: _previewAsCharacter,
                      // FR26 / C10 — the reverse link: a permit is authored
                      // from the PERMITS section with the anchor it pins to
                      // picked from a dropdown, so nothing on the anchor's
                      // own card said one pointed back at it until now.
                      permits: [
                        for (final p in widget.trip.permits)
                          if (p.anchorId == anchor.id) p,
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openPromotionDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const _PromoteAnchorDialog(),
    );
  }
}

class _AnchorCard extends ConsumerWidget {
  const _AnchorCard({required this.anchor, required this.previewAsCharacter, this.permits = const []});
  final Anchor anchor;
  final bool previewAsCharacter;

  /// FR26 / C10 — every `Trip.permits` entry whose `anchorId` points at this
  /// anchor, so the Author can see "a permit references this place" from the
  /// place itself, not only from the PERMITS section's own list.
  final List<Permit> permits;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final messages = ref.watch(messagesProvider);
    return Container(
      padding: const EdgeInsets.all(PlotSpacing.s3),
      constraints: const BoxConstraints(maxWidth: 260),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        border: Border.all(color: c.border),
        borderRadius: PlotRadii.controlShape,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  anchor.title ?? 'Untitled anchor',
                  style: PlotTypography.body(c.textPrimary).copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              if (!previewAsCharacter)
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: 'Remove anchor',
                  onPressed: () => ref.read(currentTripProvider.notifier).removeAnchor(anchor.id),
                ),
            ],
          ),
          Text(
            '${anchor.coord[1].toStringAsFixed(5)}, ${anchor.coord[0].toStringAsFixed(5)}',
            style: PlotTypography.data(c.textMuted),
          ),
          // FR108 / O3 — an area anchor renders its boundary on the map
          // (the AC's own wording), not just a vertex count: a historic
          // district is a shape, and a shape reads as a shape.
          if (anchor.area != null) ...[
            const SizedBox(height: PlotSpacing.s2),
            Text(
              'Area · ${anchor.area!.rings.first.length - 1}-point boundary',
              style: PlotTypography.data(c.textMuted),
            ),
            const SizedBox(height: PlotSpacing.s1),
            ClipRRect(
              borderRadius: PlotRadii.controlShape,
              child: SizedBox(
                height: 100,
                child: TapToPickMap(
                  outline: [for (final v in anchor.area!.rings.first) [v[0], v[1]]],
                  center: [anchor.coord[0], anchor.coord[1]],
                  initialZoom: 14,
                ),
              ),
            ),
          ],
          const SizedBox(height: PlotSpacing.s2),
          Wrap(
            spacing: PlotSpacing.s1,
            runSpacing: PlotSpacing.s1,
            children: [
              for (final role in anchor.roles)
                previewAsCharacter
                    ? _PreviewRoleChip(
                        revealed: _resolver.resolve(role, hasArrived: false, anchorCoord: anchor.coord))
                    : _RoleChip(anchorId: anchor.id, role: role, placeName: anchor.title),
            ],
          ),
          // FR26 / C10 — a permit pinned to this anchor, never gated by
          // preview mode: a permit carries no reveal field (mirrors
          // `Hazard`), so there is no policy to withhold it under.
          if (permits.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: PlotSpacing.s1),
              child: Wrap(
                spacing: PlotSpacing.s1,
                runSpacing: PlotSpacing.s1,
                children: [
                  for (final permit in permits)
                    Tooltip(
                      message: permit.confirmationNumber == null
                          ? permit.title
                          : '${permit.title} · # ${permit.confirmationNumber}',
                      child: PlotBadge(
                        '${permit.title} · ${permitStatusLabel(permit.status)}',
                        tone: permitStatusTone(permit.status),
                        solid: permit.status == 'denied',
                      ),
                    ),
                ],
              ),
            ),
          // FR107 / O2 — a role offset renders as its own line so it reads
          // as a distinct place on the ground, not a property of the pin;
          // an anchor with no offsets (O2's AC) adds nothing here. Withheld
          // in preview mode along with everything else content-shaped —
          // where the offset itself would spoil an unrevealed plot point's
          // whereabouts is exactly the kind of leak P11 exists to close.
          if (!previewAsCharacter)
            for (final role in anchor.roles.where((r) => r.coord != null))
              Padding(
                padding: const EdgeInsets.only(top: PlotSpacing.s1),
                // FR145 / M14 — a template with typed slots, not a composed
                // sentence: the coordinate arrives as a [CoordinateSlot] and
                // is rendered by the locale's number format, not by
                // `toStringAsFixed`, which writes an English decimal point
                // wherever it runs.
                child: Text(
                  messages.resolve(MessageId.roleOffsetLine, {
                    'type': TermSlot(messages.roleKindTerm(role.kind)),
                    'at': CoordinateSlot(lat: role.coord![1], lon: role.coord![0]),
                  }),
                  style: PlotTypography.data(c.textMuted),
                ),
              ),
        ],
      ),
    );
  }
}

/// FR37 / E1 — the role-content editor: rich note + media, gated on read by
/// [RevealResolver] wherever it's shown to a Character (never here — this is
/// the Author's own authoring surface). A dialog, not an inline expansion,
/// because the anchor card's width is already tight (FR108's boundary
/// preview map) and a multiline note field needs room to breathe.
Future<void> _editRoleContent(
  BuildContext context,
  WidgetRef ref, {
  required String anchorId,
  required Role role,
}) async {
  final draft = loadRoleContent(role);
  var note = draft.note;
  var media = draft.media;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Role content'),
        content: SizedBox(
          width: 420,
          child: NoteMediaEditor(
            note: note,
            media: media,
            noteLabel: 'Rich note',
            onNoteChanged: (v) => note = v,
            onMediaChanged: (v) => setState(() => media = v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final trimmed = note?.trim();
              ref.read(currentTripProvider.notifier).updateRole(
                    anchorId,
                    role.id,
                    note: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
                    clearNote: trimmed == null || trimmed.isEmpty,
                    media: media,
                  );
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

/// FR109 / O4 — the station-activity badge label: the registry label for a
/// known type (falling through to the raw key for a plugin activity, same as
/// `disciplineLabel`), plus a compact duration when one is set. Neither piece
/// is authored content — the type is a wire key, the duration a number — so
/// this is a plain label, like the arc badge's `wireValue`.
String _stationActivityBadge(StationActivity activity) {
  final label = stationActivityLabel(activity.activityType);
  final secs = activity.durationS;
  if (secs == null) return label;
  final minutes = (secs / 60).round();
  final text = minutes >= 60
      ? (minutes % 60 == 0
          ? '${minutes ~/ 60} h'
          : '${minutes ~/ 60} h ${minutes % 60} m')
      : '$minutes m';
  return '$label · $text';
}

/// FR109, FR16b, FR24 / O4 — set or edit a station role's [StationActivity]
/// after promotion (O1's AC: "set here or later"). Mirrors [_editRoleContent]:
/// a dialog rather than an inline expansion, since the anchor card is tight.
Future<void> _editStationActivity(
  BuildContext context,
  WidgetRef ref, {
  required String anchorId,
  required Role role,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _StationActivityDialog(anchorId: anchorId, role: role),
  );
}

/// A [StatefulWidget] rather than a `StatefulBuilder`, so its controllers
/// outlive the dialog's pop animation and are disposed exactly once, by the
/// framework (the difficulty/gear fields are the Author's own free text and
/// are written as data, never composed into a message — FR145).
class _StationActivityDialog extends ConsumerStatefulWidget {
  const _StationActivityDialog({required this.anchorId, required this.role});
  final String anchorId;
  final Role role;

  @override
  ConsumerState<_StationActivityDialog> createState() => _StationActivityDialogState();
}

class _StationActivityDialogState extends ConsumerState<_StationActivityDialog> {
  late String? _type = widget.role.activity?.activityType;
  late final _duration = TextEditingController(
    text: widget.role.activity?.durationS == null
        ? ''
        : (widget.role.activity!.durationS! / 60).round().toString(),
  );
  late final _difficulty =
      TextEditingController(text: widget.role.activity?.difficulty ?? '');
  late final _gear = TextEditingController(
      text: widget.role.activity?.requiredGear.join('\n') ?? '');

  @override
  void dispose() {
    _duration.dispose();
    _difficulty.dispose();
    _gear.dispose();
    super.dispose();
  }

  void _save() {
    final chosen = _type;
    final notifier = ref.read(currentTripProvider.notifier);
    if (chosen == null) {
      notifier.updateRole(widget.anchorId, widget.role.id, clearActivity: true);
    } else {
      final minutes = double.tryParse(_duration.text.trim());
      final gear = [
        for (final line in _gear.text.split('\n').map((l) => l.trim()))
          if (line.isNotEmpty) line,
      ];
      final difficulty = _difficulty.text.trim();
      notifier.updateRole(
        widget.anchorId,
        widget.role.id,
        activity: StationActivity(
          activityType: chosen,
          durationS: minutes == null ? null : minutes * 60,
          requiredGear: gear,
          difficulty: difficulty.isEmpty ? null : difficulty,
        ),
      );
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Station activity'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButton<String?>(
                isDense: true,
                isExpanded: true,
                value: _type,
                items: [
                  const DropdownMenuItem(value: null, child: Text('Activity: none yet')),
                  for (final a in kStationActivityTypes.values)
                    DropdownMenuItem(value: a.key, child: Text(a.label)),
                ],
                onChanged: (key) => setState(() {
                  _type = key;
                  if (key != null && _duration.text.trim().isEmpty) {
                    final secs = defaultStationActivityDurationS(key);
                    if (secs != null) _duration.text = (secs / 60).round().toString();
                  }
                }),
              ),
              if (_type != null) ...[
                const SizedBox(height: PlotSpacing.s2),
                TextField(
                  controller: _duration,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Expected duration (minutes)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: PlotSpacing.s2),
                TextField(
                  controller: _difficulty,
                  decoration: const InputDecoration(
                    labelText: 'Difficulty — your call (optional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: PlotSpacing.s2),
                TextField(
                  controller: _gear,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Gear — one item per line (optional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// FR25 / C9 — the provision-detail badge label: what a water/resupply role
/// carries, in the fewest words that still say something ("Potable" reads
/// differently from "Filter required," and both differ from a resupply-only
/// stop that carries no water tag at all).
String _provisionDetailBadge(ProvisionDetail detail) {
  final parts = <String>[
    if (detail.water != null) (detail.water!.potable ? 'Potable' : 'Filter required'),
    if (detail.resupply != null) 'Resupply',
  ];
  return parts.join(' · ');
}

/// FR25 / C9 — set or edit a provision role's [ProvisionDetail] after
/// promotion (O1's AC: "set here or later"). Mirrors [_editStationActivity].
Future<void> _editProvisionDetail(
  BuildContext context,
  WidgetRef ref, {
  required String anchorId,
  required Role role,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ProvisionDetailDialog(anchorId: anchorId, role: role),
  );
}

class _ProvisionDetailDialog extends ConsumerStatefulWidget {
  const _ProvisionDetailDialog({required this.anchorId, required this.role});
  final String anchorId;
  final Role role;

  @override
  ConsumerState<_ProvisionDetailDialog> createState() => _ProvisionDetailDialogState();
}

class _ProvisionDetailDialogState extends ConsumerState<_ProvisionDetailDialog> {
  late bool _hasWater = widget.role.provision?.water != null;
  late bool _potable = widget.role.provision?.water?.potable ?? true;
  late bool _hasResupply = widget.role.provision?.resupply != null;
  late final _hours = TextEditingController(text: widget.role.provision?.resupply?.hours ?? '');
  late final _notes = TextEditingController(text: widget.role.provision?.resupply?.notes ?? '');

  @override
  void dispose() {
    _hours.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    final notifier = ref.read(currentTripProvider.notifier);
    ResupplyInfo? resupply;
    if (_hasResupply) {
      final hours = _hours.text.trim();
      final notes = _notes.text.trim();
      if (hours.isNotEmpty || notes.isNotEmpty) {
        resupply = ResupplyInfo(
          hours: hours.isEmpty ? null : hours,
          notes: notes.isEmpty ? null : notes,
        );
      }
    }
    final water = _hasWater ? WaterSource(potable: _potable) : null;
    if (water == null && resupply == null) {
      notifier.updateRole(widget.anchorId, widget.role.id, clearProvision: true);
    } else {
      notifier.updateRole(
        widget.anchorId, widget.role.id,
        provision: ProvisionDetail(water: water, resupply: resupply),
      );
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Water & resupply'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Water source'),
                value: _hasWater,
                onChanged: (v) => setState(() => _hasWater = v ?? false),
              ),
              if (_hasWater)
                Padding(
                  padding: const EdgeInsets.only(left: PlotSpacing.s6, bottom: PlotSpacing.s2),
                  child: DropdownButton<bool>(
                    isDense: true,
                    isExpanded: true,
                    value: _potable,
                    items: const [
                      DropdownMenuItem(value: true, child: Text('Potable')),
                      DropdownMenuItem(value: false, child: Text('Filter/treatment required')),
                    ],
                    onChanged: (v) => setState(() => _potable = v ?? true),
                  ),
                ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Resupply point'),
                value: _hasResupply,
                onChanged: (v) => setState(() => _hasResupply = v ?? false),
              ),
              if (_hasResupply) ...[
                TextField(
                  controller: _hours,
                  decoration: const InputDecoration(
                    labelText: 'Hours (optional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: PlotSpacing.s2),
                TextField(
                  controller: _notes,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _RoleChip extends ConsumerWidget {
  const _RoleChip({required this.anchorId, required this.role, this.placeName});

  /// FR37 / E1 — needed to route a content edit back through
  /// `CurrentTripNotifier.updateRole(anchorId, roleId, ...)`.
  final String anchorId;
  final Role role;

  /// The **anchor's** title (`Anchor.title`), which is what FR145's "a
  /// message about a role names it and states its type" means. Never
  /// `Role.title` — that is content, it belongs to [RevealResolver], and it
  /// never becomes part of a sentence (ARCH A30).
  final String? placeName;

  bool get _hasContent => loadRoleContent(role).hasContent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final messages = ref.watch(messagesProvider);
    final effective = _resolver.effectivePolicy(role);
    // FR114 / O5 — an undecided role's *effective* policy (provision's
    // default, or nothing for narrative/station) is what the tooltip states,
    // not the raw `role.reveal`, so "undecided" never reads as a fourth
    // state the Author has to mentally resolve themselves.
    final revealTerm = switch ((role.reveal, effective)) {
      (null, RevealPolicy.alwaysVisible) => MessageId.termRevealAlwaysVisibleByDefault,
      (_, RevealPolicy.alwaysVisible) => MessageId.termRevealAlwaysVisible,
      (_, RevealPolicy.onArrival) => MessageId.termRevealOnArrival,
      (_, null) => MessageId.termRevealNotSet,
    };
    // FR145 / M14 — four independent templates, joined by the locale's own
    // facet separator. The tooltip is a *list of facts about this role*, not
    // a sentence built out of them: each facet is separately enumerable,
    // separately translatable, and carries no authored content at all.
    //
    // FR107 / O2 — the offset is a facet rather than a chip label so an
    // anchor with no offsets (the common case, O2's AC) costs no extra chip
    // width; it is exactly where a trigger for this role will fire.
    final tooltip = messages.joinFacets([
      messages.resolve(MessageId.roleReveal, {
        'role': RoleRefSlot(kind: role.kind, placeName: placeName),
        'reveal': TermSlot(revealTerm),
      }),
      if (role.coord != null)
        messages.resolve(MessageId.roleOffset, {
          'at': CoordinateSlot(lat: role.coord![1], lon: role.coord![0]),
        }),
      if (role.hazard) messages.resolve(MessageId.roleHazardAlwaysVisible),
      if (role.arc != null)
        messages.resolve(MessageId.roleArcStage, {'arc': TermSlot(messages.arcStageTerm(role.arc!))}),
    ]);
    return Tooltip(
      message: tooltip,
      // A nested `Wrap`, not a `Row`: the outer anchor card constrains width
      // tightly (FR108's boundary preview map above it), and a hazard role's
      // chip-plus-badge pair must reflow rather than overflow when it
      // doesn't fit the remaining line.
      child: Wrap(
        spacing: PlotSpacing.s1,
        runSpacing: PlotSpacing.s1,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Chip(
            label: Text(messages.term(messages.roleKindTerm(role.kind))),
            labelStyle: PlotTypography.small(c.textPrimary),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          // FR115 / O5 — a hazard/technical-crux role always carries this
          // badge: the one visual cue that this role's reveal cannot be
          // hidden by any setting, on any trip, under any role.
          if (role.hazard) const PlotBadge('Hazard', tone: PlotBadgeTone.ember, solid: true),
          // FR38 / O6 — this role's stage in the day's story, distinguished
          // from a plain content chip so it reads as structure, not a label.
          if (role.arc != null) PlotBadge(role.arc!.wireValue, tone: PlotBadgeTone.slate),
          // FR109, FR16b, FR24 / O4 — a station role that carries an activity
          // shows its type (from the registry, so a plugin activity still
          // reads as its raw key) and duration. Logistics, not reveal-gated
          // content — Character-facing surfacing of the packable list is C8.
          if (role.activity != null)
            PlotBadge(_stationActivityBadge(role.activity!), tone: PlotBadgeTone.spruce),
          // FR109 / O4 — set or edit the station role's activity.
          if (role.kind == RoleKind.station)
            IconButton(
              tooltip: role.activity == null ? 'Add activity' : 'Edit activity',
              icon: Icon(
                role.activity == null ? Icons.terrain_outlined : Icons.terrain,
                size: 16,
                color: c.textMuted,
              ),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              onPressed: () => _editStationActivity(context, ref, anchorId: anchorId, role: role),
            ),
          // FR25 / C9 — a provision role that carries structured detail
          // shows what it is (water tag, resupply, or both).
          if (role.provision != null)
            PlotBadge(_provisionDetailBadge(role.provision!), tone: PlotBadgeTone.spruce),
          // FR25 / C9 — set or edit the provision role's water/resupply detail.
          if (role.kind == RoleKind.provision)
            IconButton(
              tooltip: role.provision == null ? 'Add water/resupply detail' : 'Edit water/resupply detail',
              icon: Icon(
                role.provision == null ? Icons.water_drop_outlined : Icons.water_drop,
                size: 16,
                color: c.textMuted,
              ),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              onPressed: () => _editProvisionDetail(context, ref, anchorId: anchorId, role: role),
            ),
          // FR37 / E1 — content (note/media) may be left unset at promotion
          // and decided later (O1's AC); this is that "later." A filled icon
          // marks a role that already carries a note or media so the Author
          // can tell content apart from an empty role at a glance.
          IconButton(
            tooltip: _hasContent ? 'Edit content' : 'Add content',
            icon: Icon(
              _hasContent ? Icons.notes : Icons.notes_outlined,
              size: 16,
              color: c.textMuted,
            ),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            onPressed: () => _editRoleContent(context, ref, anchorId: anchorId, role: role),
          ),
        ],
      ),
    );
  }
}

/// O5's "preview as a Character would see it" — renders exactly what
/// [RevealResolver] released for this role and nothing else: a withheld
/// role shows only that something is here (PRD P1's AC), never its title,
/// note, or which reveal policy is set — that would defeat the preview.
class _PreviewRoleChip extends ConsumerWidget {
  const _PreviewRoleChip({required this.revealed});
  final RevealedRole revealed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final messages = ref.watch(messagesProvider);
    final kind = messages.term(messages.roleKindTerm(revealed.kind));
    final label = revealed.visible ? kind : messages.joinFacets([kind, messages.term(MessageId.termHidden)]);
    // FR145 / M14 — the withheld branch resolves a template that names the
    // role by *type* and nothing else; the released branch renders the
    // content [RevealResolver] handed over **as content**, never
    // interpolated into a sentence. That is the same separation the TTS path
    // makes explicit (`data/speech.dart`), for the same reason: a composed
    // sentence is downstream of every byte assertion (ARCH A30).
    //
    // No `placeName` here, deliberately — this is the preview-as-Character
    // path, and the anchor's name is not this chip's to state.
    return Tooltip(
      message: revealed.visible
          ? (revealed.title ?? revealed.note ?? messages.resolve(MessageId.roleVisibleBeforeDeparture))
          : messages.resolve(MessageId.roleWithheldUntilArrival, {
              'role': RoleRefSlot(kind: revealed.kind, placeName: null),
            }),
      child: Chip(
        avatar: revealed.visible ? null : Icon(Icons.lock_outline, size: 14, color: c.textMuted),
        label: Text(label),
        labelStyle: PlotTypography.small(revealed.visible ? c.textPrimary : c.textMuted),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// FR110 — promotion as a single interaction: name the place, place it, and
/// assign its role set (with each role's reveal policy, optional — O1's AC
/// allows content/reveal to be "set here or later") all in one dialog.
class _PromoteAnchorDialog extends ConsumerStatefulWidget {
  const _PromoteAnchorDialog();

  @override
  ConsumerState<_PromoteAnchorDialog> createState() => _PromoteAnchorDialogState();
}

class _PromoteAnchorDialogState extends ConsumerState<_PromoteAnchorDialog> {
  final _title = TextEditingController();
  final _lat = TextEditingController();
  final _lon = TextEditingController();
  final Map<RoleKind, RevealPolicy?> _selectedRoles = {};
  // FR115 / O5 — per-role-kind hazard/technical-crux flag. Off by default;
  // when on, the role's reveal is forced to always-visible (see
  // `_roleRow`'s hazard `Switch` handler) and cannot be set otherwise.
  final Map<RoleKind, bool> _hazard = {};
  // FR107 / O2 — one optional offset lat/lon pair per role kind, blank by
  // default: leaving both blank is the "no offset" case, which O2's AC
  // requires to cost nothing (the anchor's own coord is used).
  final Map<RoleKind, TextEditingController> _offsetLat = {
    for (final kind in RoleKind.values) kind: TextEditingController(),
  };
  final Map<RoleKind, TextEditingController> _offsetLon = {
    for (final kind in RoleKind.values) kind: TextEditingController(),
  };
  // FR38 / O6 — one optional arc stage per role kind, `null` (no arc beat) by
  // default: most promoted places carry no arc at all.
  final Map<RoleKind, ArcStage?> _arc = {};
  // FR109, FR16b, FR24 / O4 — the station role's activity. `null` type means
  // "no activity detail yet" (O1's AC — set at promotion or later). Only the
  // station role reads these; kept as plain fields, not a per-kind map,
  // because FR109 puts an activity on a station role and nowhere else.
  String? _stationActivityType;
  final _stationDurationMin = TextEditingController();
  final _stationDifficulty = TextEditingController();
  final _stationGear = TextEditingController();
  // FR25 / C9 — the provision role's water/resupply detail. Plain fields,
  // not a per-kind map, for the same reason the station fields above are:
  // FR25 puts this on a provision role and nowhere else.
  bool _provisionHasWater = false;
  bool _provisionPotable = true;
  bool _provisionHasResupply = false;
  final _provisionHours = TextEditingController();
  final _provisionNotes = TextEditingController();
  // FR108 / O3 — Flow 3's "Role geometry: point, offset, or area": whether
  // this anchor is a district/block/reserve rather than a pin. Off by
  // default, since most promoted places remain points (O2's AC extended).
  bool _hasArea = false;
  final _areaVertices = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _lat.dispose();
    _lon.dispose();
    _areaVertices.dispose();
    _stationDurationMin.dispose();
    _stationDifficulty.dispose();
    _stationGear.dispose();
    _provisionHours.dispose();
    _provisionNotes.dispose();
    for (final controller in _offsetLat.values) {
      controller.dispose();
    }
    for (final controller in _offsetLon.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return AlertDialog(
      title: const Text('Promote a place'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder()),
              ),
              const SizedBox(height: PlotSpacing.s3),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _lat,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      decoration: const InputDecoration(labelText: 'Latitude', border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: PlotSpacing.s2),
                  Expanded(
                    child: TextField(
                      controller: _lon,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      decoration: const InputDecoration(labelText: 'Longitude', border: OutlineInputBorder()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: PlotSpacing.s4),
              Text('ROLE SET (narrative, provision, station — FR106)',
                  style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: PlotSpacing.s2),
              for (final kind in RoleKind.values) _roleRow(c, kind),
              // K12a / FR114 — each role row above sets its own reveal; this
              // is the only place reveal is set, so it is where the "reveal
              // is a role's property, not the place's" model needs saying.
              // Placed (help icon included) after the role rows, not before,
              // for the same reason the area-geometry section below is:
              // `find.byType(Checkbox)` indices for the role set must stay
              // put, and the header text above must keep its own wrap.
              Align(
                alignment: Alignment.centerLeft,
                child: TeachingHelpIcon(moment: TeachingMoment.revealIsRoleProperty),
              ),
              TeachingBlock(
                tripId: ref.read(currentTripProvider).id,
                moment: TeachingMoment.revealIsRoleProperty,
              ),
              const SizedBox(height: PlotSpacing.s2),
              // FR108 / O3 — Flow 3's "Role geometry: point, offset, or
              // area." Placed after the role checkboxes (not before) so
              // `find.byType(Checkbox)` indices for the role set stay put —
              // this is the anchor's own area, not a role's.
              Row(
                children: [
                  Checkbox(
                    value: _hasArea,
                    onChanged: (checked) => setState(() => _hasArea = checked ?? false),
                  ),
                  const Expanded(
                    child: Text('This place is an area, not just a point (FR108)'),
                  ),
                ],
              ),
              if (_hasArea) ...[
                TextField(
                  controller: _areaVertices,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Boundary vertices — one "lat, lon" per line (3+)',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}), // refreshes the preview map below
                ),
                const SizedBox(height: PlotSpacing.s2),
                ClipRRect(
                  borderRadius: PlotRadii.controlShape,
                  child: SizedBox(
                    height: 140,
                    child: TapToPickMap(outline: _previewOutline(), center: _previewCenter(), initialZoom: 14),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: PlotSpacing.s2),
                Text(_error!, style: PlotTypography.small(c.danger)),
              ],
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
        PlotButton(label: 'Promote', onPressed: _submit),
      ],
    );
  }

  Widget _roleRow(PlotColors c, RoleKind kind) {
    final selected = _selectedRoles.containsKey(kind);
    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: (checked) => setState(() {
                  if (checked ?? false) {
                    // FR114 / O5 — a freshly-checked role starts at its kind's
                    // engine default: always-visible for provision, `null`
                    // ("the Author's choice," left open) for narrative/station.
                    _selectedRoles[kind] = kind.defaultReveal;
                  } else {
                    _selectedRoles.remove(kind);
                    _hazard.remove(kind);
                    _arc.remove(kind);
                    if (kind == RoleKind.station) {
                      _stationActivityType = null;
                      _stationDurationMin.clear();
                      _stationDifficulty.clear();
                      _stationGear.clear();
                    }
                    if (kind == RoleKind.provision) {
                      _provisionHasWater = false;
                      _provisionPotable = true;
                      _provisionHasResupply = false;
                      _provisionHours.clear();
                      _provisionNotes.clear();
                    }
                  }
                }),
              ),
              Expanded(child: Text(kind.wireValue)),
              // FR115 / O5 — hazard/technical-crux flag, orthogonal to
              // reveal: on, it forces the reveal row below to always-visible
              // and locks it, so the hard constraint ("cannot be set
              // otherwise by any Author") is enforced in the widget, not
              // just in the domain layer beneath it. Kept on the header row
              // rather than a row of its own so selecting a role doesn't
              // shift every row beneath it.
              if (selected) ...[
                Text('Hazard', style: PlotTypography.small(c.textMuted)),
                Switch(
                  value: _hazard[kind] ?? false,
                  onChanged: (value) => setState(() {
                    _hazard[kind] = value;
                    _selectedRoles[kind] = value ? RevealPolicy.alwaysVisible : kind.defaultReveal;
                  }),
                ),
              ],
            ],
          ),
          if (selected && !(_hazard[kind] ?? false))
            Padding(
              padding: const EdgeInsets.only(left: PlotSpacing.s6, bottom: PlotSpacing.s2),
              child: DropdownButton<RevealPolicy?>(
                isDense: true,
                isExpanded: true,
                value: _selectedRoles[kind],
                items: const [
                  DropdownMenuItem(value: null, child: Text('Reveal: decide later')),
                  DropdownMenuItem(value: RevealPolicy.alwaysVisible, child: Text('Always visible')),
                  DropdownMenuItem(value: RevealPolicy.onArrival, child: Text('On arrival')),
                ],
                onChanged: (policy) => setState(() => _selectedRoles[kind] = policy),
              ),
            )
          else if (selected)
            Padding(
              padding: const EdgeInsets.only(left: PlotSpacing.s6, bottom: PlotSpacing.s2),
              child: Text(
                'Reveal: always visible — hazards cannot be hidden (FR115)',
                style: PlotTypography.small(c.textMuted),
              ),
            ),
          // FR107 / O2 — optional per-role geometry offset. Left blank, the
          // role sits at the anchor's own coord; the overlook 400 m up the
          // spur is the reason this exists at all.
          if (selected)
            Padding(
              padding: const EdgeInsets.only(left: PlotSpacing.s6, bottom: PlotSpacing.s2),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _offsetLat[kind],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      decoration: const InputDecoration(
                        labelText: 'Offset latitude (optional)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: PlotSpacing.s2),
                  Expanded(
                    child: TextField(
                      controller: _offsetLon[kind],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      decoration: const InputDecoration(
                        labelText: 'Offset longitude (optional)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // FR38 / O6 — this role's optional stage in the day's story.
          // "No arc" is the common case and stays selected by default; the
          // Dropdown offers it explicitly rather than only via a clear icon,
          // matching the reveal dropdown's "decide later" entry above.
          if (selected)
            Padding(
              padding: const EdgeInsets.only(left: PlotSpacing.s6, bottom: PlotSpacing.s2),
              child: DropdownButton<ArcStage?>(
                isDense: true,
                isExpanded: true,
                value: _arc[kind],
                items: const [
                  DropdownMenuItem(value: null, child: Text('Arc: none')),
                  DropdownMenuItem(value: ArcStage.exposition, child: Text('Exposition')),
                  DropdownMenuItem(value: ArcStage.rising, child: Text('Rising action')),
                  DropdownMenuItem(value: ArcStage.crux, child: Text('Crux')),
                  DropdownMenuItem(value: ArcStage.climax, child: Text('Climax')),
                  DropdownMenuItem(value: ArcStage.resolution, child: Text('Resolution')),
                ],
                onChanged: (stage) => setState(() => _arc[kind] = stage),
              ),
            ),
          // FR109, FR16b, FR24 / O4 — the station role's activity: type,
          // expected duration (feeds day timing), Author-declared difficulty,
          // and gear (feeds the C8 checklist). Only shown for the station
          // role; deliberately no Checkbox here — the area checkbox below is
          // found by index.
          if (selected && kind == RoleKind.station) _stationActivityFields(c),
          // FR25 / C9 — the provision role's water/resupply detail: a
          // potable/filter-required tag, and hours/notes for a resupply
          // point. Only shown for the provision role.
          if (selected && kind == RoleKind.provision) _provisionDetailFields(c),
        ],
      ),
    );
  }

  Widget _provisionDetailFields(PlotColors c) {
    return Padding(
      padding: const EdgeInsets.only(left: PlotSpacing.s6, bottom: PlotSpacing.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('WATER & RESUPPLY (FR25)', style: PlotTypography.small(c.textMuted)),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            title: const Text('Water source'),
            value: _provisionHasWater,
            onChanged: (v) => setState(() => _provisionHasWater = v ?? false),
          ),
          if (_provisionHasWater)
            DropdownButton<bool>(
              isDense: true,
              isExpanded: true,
              value: _provisionPotable,
              items: const [
                DropdownMenuItem(value: true, child: Text('Potable')),
                DropdownMenuItem(value: false, child: Text('Filter/treatment required')),
              ],
              onChanged: (v) => setState(() => _provisionPotable = v ?? true),
            ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            title: const Text('Resupply point'),
            value: _provisionHasResupply,
            onChanged: (v) => setState(() => _provisionHasResupply = v ?? false),
          ),
          if (_provisionHasResupply) ...[
            TextField(
              controller: _provisionHours,
              decoration: const InputDecoration(
                labelText: 'Hours (optional)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: PlotSpacing.s2),
            TextField(
              controller: _provisionNotes,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// FR25 / C9 — build the provision role's [ProvisionDetail] from the
  /// fields above, or `null` when the Author picked neither water nor
  /// resupply (O1's AC — a provision role may carry no structured detail
  /// yet).
  ProvisionDetail? _buildProvisionDetail() {
    ResupplyInfo? resupply;
    if (_provisionHasResupply) {
      final hours = _provisionHours.text.trim();
      final notes = _provisionNotes.text.trim();
      if (hours.isNotEmpty || notes.isNotEmpty) {
        resupply = ResupplyInfo(hours: hours.isEmpty ? null : hours, notes: notes.isEmpty ? null : notes);
      }
    }
    final water = _provisionHasWater ? WaterSource(potable: _provisionPotable) : null;
    if (water == null && resupply == null) return null;
    return ProvisionDetail(water: water, resupply: resupply);
  }

  Widget _stationActivityFields(PlotColors c) {
    return Padding(
      padding: const EdgeInsets.only(left: PlotSpacing.s6, bottom: PlotSpacing.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('STATION ACTIVITY (FR109)', style: PlotTypography.small(c.textMuted)),
          DropdownButton<String?>(
            isDense: true,
            isExpanded: true,
            value: _stationActivityType,
            items: [
              const DropdownMenuItem(value: null, child: Text('Activity: none yet')),
              for (final a in kStationActivityTypes.values)
                DropdownMenuItem(value: a.key, child: Text(a.label)),
            ],
            onChanged: (key) => setState(() {
              _stationActivityType = key;
              // Seed the duration from the registry default when the Author
              // picks a type and hasn't typed one — never overwrite a value
              // they entered.
              if (key != null && _stationDurationMin.text.trim().isEmpty) {
                final secs = defaultStationActivityDurationS(key);
                if (secs != null) {
                  _stationDurationMin.text = (secs / 60).round().toString();
                }
              }
            }),
          ),
          if (_stationActivityType != null) ...[
            TextField(
              controller: _stationDurationMin,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Expected duration (minutes)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: PlotSpacing.s2),
            TextField(
              controller: _stationDifficulty,
              decoration: const InputDecoration(
                labelText: 'Difficulty — your call (optional)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: PlotSpacing.s2),
            TextField(
              controller: _stationGear,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Gear — one item per line (optional)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// FR109 / O4 — build the station role's [StationActivity] from the fields
  /// above, or `null` when the Author picked no activity type (O1's AC — a
  /// station role may carry no activity detail yet).
  StationActivity? _buildStationActivity() {
    final type = _stationActivityType;
    if (type == null) return null;
    final minutes = double.tryParse(_stationDurationMin.text.trim());
    final gear = [
      for (final line in _stationGear.text.split('\n').map((l) => l.trim()))
        if (line.isNotEmpty) line,
    ];
    final difficulty = _stationDifficulty.text.trim();
    return StationActivity(
      activityType: type,
      durationS: minutes == null ? null : minutes * 60,
      requiredGear: gear,
      difficulty: difficulty.isEmpty ? null : difficulty,
    );
  }

  /// A best-effort outline for the live preview map: `null` while the
  /// boundary text is empty or doesn't parse yet, never an error the Author
  /// has to dismiss just for typing the second of three vertices.
  List<LatLonPoint>? _previewOutline() {
    try {
      return _parseAreaVertices(_areaVertices.text);
    } on FormatException {
      return null;
    }
  }

  LatLonPoint? _previewCenter() {
    final lat = double.tryParse(_lat.text);
    final lon = double.tryParse(_lon.text);
    return lat == null || lon == null ? null : [lon, lat];
  }

  void _submit() {
    final lat = double.tryParse(_lat.text);
    final lon = double.tryParse(_lon.text);
    if (lat == null || lon == null) {
      setState(() => _error = 'Latitude and longitude must both be numbers.');
      return;
    }
    if (_selectedRoles.isEmpty) {
      setState(() => _error = 'Assign at least one role (FR106).');
      return;
    }
    // FR108 / O3 — the anchor's own area, drawn by the Author as a list of
    // boundary vertices. Rejected rather than silently ignored on a parse
    // failure, the same treatment every other field in this dialog gets.
    Area? area;
    if (_hasArea) {
      try {
        area = Area(rings: [_parseAreaVertices(_areaVertices.text)]);
      } on FormatException catch (e) {
        setState(() => _error = e.message);
        return;
      }
    }
    // FR107 / O2 — an offset is optional per role, but not half-optional:
    // one coordinate without the other is neither "no offset" nor a valid
    // point, so it's rejected rather than silently dropped or defaulted.
    final offsets = <RoleKind, Coord?>{};
    for (final kind in _selectedRoles.keys) {
      final latText = _offsetLat[kind]!.text.trim();
      final lonText = _offsetLon[kind]!.text.trim();
      if (latText.isEmpty && lonText.isEmpty) {
        offsets[kind] = null;
        continue;
      }
      final lat = double.tryParse(latText);
      final lon = double.tryParse(lonText);
      if (lat == null || lon == null) {
        setState(() => _error =
            'The ${kind.wireValue} role\'s offset needs both latitude and longitude, or neither.');
        return;
      }
      offsets[kind] = [lon, lat];
    }
    final roles = [
      for (final entry in _selectedRoles.entries)
        Role(
          id: _uuid.v4(),
          kind: entry.key,
          coord: offsets[entry.key],
          reveal: entry.value,
          hazard: _hazard[entry.key] ?? false,
          arc: _arc[entry.key],
          activity: entry.key == RoleKind.station ? _buildStationActivity() : null,
          provision: entry.key == RoleKind.provision ? _buildProvisionDetail() : null,
        ),
    ];
    // Hand-placed provenance carries no `sourceId`, so `promoteAnchor`'s
    // duplicate-source check (FR106) never applies on this path — that
    // check only matters once a candidate/proposal feeds this dialog.
    ref.read(currentTripProvider.notifier).promoteAnchor(
          coord: [lon, lat],
          roles: roles,
          title: _title.text.trim().isEmpty ? null : _title.text.trim(),
          area: area,
          provenance: const AnchorProvenance(kind: AnchorSourceKind.handPlaced),
        );
    Navigator.pop(context);
  }
}
