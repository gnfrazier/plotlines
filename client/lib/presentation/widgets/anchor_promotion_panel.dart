// FR106, FR107, FR110 (Stories O1, O2) — the promotion interaction: turn a
// hand-placed coordinate into an Anchor and assign its role set (narrative /
// provision / station), each with an optional geometry offset (FR107), in
// one interaction. Trip-scoped (`Trip.anchors`), so this panel does not
// require a segment to be selected — unlike the Content tab's existing
// per-segment node editor it sits beside.
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

import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';

const _uuid = Uuid();

class AnchorPromotionPanel extends ConsumerWidget {
  const AnchorPromotionPanel({super.key, required this.trip});
  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              PlotButton(
                label: 'Promote a place',
                variant: PlotButtonVariant.secondary,
                icon: Icons.add_location_alt_outlined,
                onPressed: () => _openPromotionDialog(context, ref),
              ),
            ],
          ),
          if (trip.anchors.isEmpty)
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
                children: [for (final anchor in trip.anchors) _AnchorCard(anchor: anchor)],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openPromotionDialog(BuildContext context, WidgetRef ref) {
    return showDialog<void>(
      context: context,
      builder: (_) => const _PromoteAnchorDialog(),
    );
  }
}

class _AnchorCard extends ConsumerWidget {
  const _AnchorCard({required this.anchor});
  final Anchor anchor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
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
          const SizedBox(height: PlotSpacing.s2),
          Wrap(
            spacing: PlotSpacing.s1,
            runSpacing: PlotSpacing.s1,
            children: [for (final role in anchor.roles) _RoleChip(role: role)],
          ),
          // FR107 / O2 — a role offset renders as its own line so it reads
          // as a distinct place on the ground, not a property of the pin;
          // an anchor with no offsets (O2's AC) adds nothing here.
          for (final role in anchor.roles.where((r) => r.coord != null))
            Padding(
              padding: const EdgeInsets.only(top: PlotSpacing.s1),
              child: Text(
                '${role.kind.wireValue} offset: ${role.coord![1].toStringAsFixed(5)}, ${role.coord![0].toStringAsFixed(5)}',
                style: PlotTypography.data(c.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.role});
  final Role role;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final reveal = switch (role.reveal) {
      RevealPolicy.alwaysVisible => 'always visible',
      RevealPolicy.onArrival => 'on arrival',
      null => 'reveal undecided',
    };
    // FR107 / O2 — surfaced in the tooltip rather than the chip label so an
    // anchor with no offsets (the common case, O2's AC) costs no extra chip
    // width; the offset is exactly where a trigger for this role will fire.
    final geometry = role.coord == null
        ? reveal
        : '$reveal · offset ${role.coord![1].toStringAsFixed(5)}, ${role.coord![0].toStringAsFixed(5)}';
    return Tooltip(
      message: geometry,
      child: Chip(
        label: Text(role.kind.wireValue),
        labelStyle: PlotTypography.small(c.textPrimary),
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
  // FR107 / O2 — one optional offset lat/lon pair per role kind, blank by
  // default: leaving both blank is the "no offset" case, which O2's AC
  // requires to cost nothing (the anchor's own coord is used).
  final Map<RoleKind, TextEditingController> _offsetLat = {
    for (final kind in RoleKind.values) kind: TextEditingController(),
  };
  final Map<RoleKind, TextEditingController> _offsetLon = {
    for (final kind in RoleKind.values) kind: TextEditingController(),
  };
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _lat.dispose();
    _lon.dispose();
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
                    _selectedRoles[kind] = null;
                  } else {
                    _selectedRoles.remove(kind);
                  }
                }),
              ),
              Expanded(child: Text(kind.wireValue)),
            ],
          ),
          if (selected)
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
        ],
      ),
    );
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
        Role(id: _uuid.v4(), kind: entry.key, coord: offsets[entry.key], reveal: entry.value),
    ];
    // Hand-placed provenance carries no `sourceId`, so `promoteAnchor`'s
    // duplicate-source check (FR106) never applies on this path — that
    // check only matters once a candidate/proposal feeds this dialog.
    ref.read(currentTripProvider.notifier).promoteAnchor(
          coord: [lon, lat],
          roles: roles,
          title: _title.text.trim().isEmpty ? null : _title.text.trim(),
          provenance: const AnchorProvenance(kind: AnchorSourceKind.handPlaced),
        );
    Navigator.pop(context);
  }
}
