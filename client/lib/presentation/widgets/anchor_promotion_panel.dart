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
import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
import '../../state/messages_provider.dart';
import '../map/tap_to_pick_map.dart';

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
                    _AnchorCard(anchor: anchor, previewAsCharacter: _previewAsCharacter),
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
  const _AnchorCard({required this.anchor, required this.previewAsCharacter});
  final Anchor anchor;
  final bool previewAsCharacter;

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
                    : _RoleChip(role: role, placeName: anchor.title),
            ],
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

class _RoleChip extends ConsumerWidget {
  const _RoleChip({required this.role, this.placeName});
  final Role role;

  /// The **anchor's** title (`Anchor.title`), which is what FR145's "a
  /// message about a role names it and states its type" means. Never
  /// `Role.title` — that is content, it belongs to [RevealResolver], and it
  /// never becomes part of a sentence (ARCH A30).
  final String? placeName;

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
        ],
      ),
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
