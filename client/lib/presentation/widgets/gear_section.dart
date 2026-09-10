// FR24 / C8 (issue #44) — the gear checklist authoring surface, rendered on
// the Logistics tab under the day list.
//
// C8's AC: "Mandatory and recommended gear attachable per mode **and per
// station activity (O4)**; items designatable Shared Group Gear and
// assignable to Characters." This widget is that Author surface. The
// Character-facing half — a Character seeing their consolidated personal +
// assigned list and checking items off — is Epic H field runtime and has no
// client surface yet, so nothing here is Character-facing.
//
// The checklist lives in the roster layer (`domain/roster.dart`'s [GearItem],
// beside the payload) because its load-bearing half — Shared Group Gear and
// who carries it — is roster-scoped, and because a mode/activity gear list is
// no more a `trip_payload.schema.json` type than the roster itself is. A
// station role's own `activity.required_gear` (O4, in the payload) is a
// per-place jotting; this is the trip-level list.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:uuid/uuid.dart';

import '../../domain/domain.dart';
import '../../state/current_roster_provider.dart';

const _uuid = Uuid();

/// The GEAR block on the Logistics tab. Reads the roster layer for the open
/// trip and the trip's declared modes / station activities to offer a scope
/// for every line.
class GearSection extends ConsumerWidget {
  const GearSection({super.key, required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final roster = ref.watch(currentRosterProvider);
    final gear = roster.gear;
    final scopes = _orderedScopes(trip, gear);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('GEAR',
                style: PlotTypography.data(c.textMuted)
                    .copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            PlotButton(
              label: 'Add gear',
              variant: PlotButtonVariant.secondary,
              icon: Icons.add,
              onPressed: () => _addGear(context, ref, scopes),
            ),
          ],
        ),
        const SizedBox(height: PlotSpacing.s2),
        Text(
          'Kit by mode and by station activity — mandatory and recommended, '
          'personal and shared.',
          style: PlotTypography.small(c.textMuted),
        ),
        const SizedBox(height: PlotSpacing.s3),
        if (gear.isEmpty)
          Text(
            'No gear yet. Add the safety kit each mode needs, the shared items '
            'someone has to carry, and the personal things everyone packs.',
            style: PlotTypography.body(c.textMuted),
          )
        else
          for (final scope in scopes)
            if (_inScope(gear, scope).isNotEmpty)
              _GearGroup(
                heading: _scopeHeading(scope),
                items: _inScope(gear, scope),
                entries: roster.entries,
              ),
      ],
    );
  }

  /// Every scope worth offering, in reading order: the whole trip, then each
  /// declared travel mode, then each station-activity type the trip actually
  /// uses. Any scope already carried by an existing line is folded in even if
  /// it is no longer declared/used, so a line never becomes unreachable when
  /// a mode is dropped (FR142(b)).
  static List<GearScope> _orderedScopes(Trip trip, List<GearItem> gear) {
    final modes = trip.declaredModes.toList()..sort();
    final activities = <String>{
      for (final a in trip.anchors)
        for (final r in a.roles)
          if (r.activity != null) r.activity!.activityType,
    }.toList()
      ..sort();

    final ordered = <GearScope>[
      const GearScope.trip(),
      for (final m in modes) GearScope.mode(m),
      for (final a in activities) GearScope.stationActivity(a),
    ];
    for (final item in gear) {
      if (!ordered.contains(item.scope)) ordered.add(item.scope);
    }
    return ordered;
  }

  static List<GearItem> _inScope(List<GearItem> gear, GearScope scope) {
    final items = [for (final g in gear) if (g.scope == scope) g];
    items.sort((a, b) {
      if (a.isMandatory != b.isMandatory) return a.isMandatory ? -1 : 1;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    return items;
  }

  String _scopeHeading(GearScope scope) => switch (scope.kind) {
        GearScopeKind.trip => 'EVERYONE',
        GearScopeKind.mode => travelModeLabel(scope.key!).toUpperCase(),
        GearScopeKind.stationActivity =>
          stationActivityLabel(scope.key!).toUpperCase(),
      };

  Future<void> _addGear(
    BuildContext context,
    WidgetRef ref,
    List<GearScope> scopes,
  ) async {
    final draft = await showDialog<_GearDraft>(
      context: context,
      builder: (_) => _GearDialog(scopes: scopes, headingFor: _scopeHeading),
    );
    if (draft == null) return;
    ref.read(currentRosterProvider.notifier).addGearItem(
          GearItem(
            id: _uuid.v4(),
            label: draft.label,
            scope: draft.scope,
            necessity: draft.necessity,
            shared: draft.shared,
          ),
        );
  }
}

class _GearGroup extends StatelessWidget {
  const _GearGroup({
    required this.heading,
    required this.items,
    required this.entries,
  });

  final String heading;
  final List<GearItem> items;
  final List<RosterEntry> entries;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(heading, style: PlotTypography.small(c.textSecondary)),
          const SizedBox(height: PlotSpacing.s1),
          for (final item in items)
            _GearRow(key: ValueKey(item.id), item: item, entries: entries),
        ],
      ),
    );
  }
}

class _GearRow extends ConsumerWidget {
  const _GearRow({super.key, required this.item, required this.entries});

  final GearItem item;
  final List<RosterEntry> entries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final notifier = ref.read(currentRosterProvider.notifier);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: PlotSpacing.s1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: PlotSpacing.s2),
                child: item.isMandatory
                    ? const PlotBadge('MANDATORY',
                        tone: PlotBadgeTone.gold, solid: true)
                    : const PlotBadge('RECOMMENDED'),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(item.label,
                      style: PlotTypography.body(c.textPrimary)),
                ),
              ),
              if (item.shared)
                const Padding(
                  padding: EdgeInsets.only(left: PlotSpacing.s2),
                  child: PlotBadge('SHARED', tone: PlotBadgeTone.slate),
                ),
              _GearRowMenu(item: item, notifier: notifier),
            ],
          ),
          if (item.shared)
            Padding(
              padding: const EdgeInsets.only(
                  left: 2, top: PlotSpacing.s1, bottom: PlotSpacing.s1),
              child: entries.isEmpty
                  ? Text(
                      'Add Characters on the Roster tab to say who carries this.',
                      style: PlotTypography.small(c.textMuted),
                    )
                  : Wrap(
                      spacing: PlotSpacing.s2,
                      runSpacing: PlotSpacing.s1,
                      children: [
                        for (final e in entries)
                          FilterChip(
                            label: Text(e.name,
                                style: PlotTypography.small(c.textPrimary)),
                            selected: item.assigneeIds.contains(e.characterId),
                            onSelected: (sel) {
                              final next = {...item.assigneeIds};
                              if (sel) {
                                next.add(e.characterId);
                              } else {
                                next.remove(e.characterId);
                              }
                              notifier.setGearAssignees(item.id, next);
                            },
                          ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}

class _GearRowMenu extends StatelessWidget {
  const _GearRowMenu({required this.item, required this.notifier});

  final GearItem item;
  final CurrentRosterNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return PopupMenuButton<String>(
      tooltip: 'Gear options',
      icon: Icon(Icons.more_vert, color: c.textSecondary, size: 20),
      onSelected: (value) async {
        switch (value) {
          case 'necessity':
            notifier.updateGearItem(
              item.id,
              necessity: item.isMandatory
                  ? GearNecessity.recommended
                  : GearNecessity.mandatory,
            );
          case 'shared':
            notifier.updateGearItem(item.id, shared: !item.shared);
          case 'rename':
            final name = await _promptText(
              context,
              title: 'Rename gear',
              initial: item.label,
            );
            if (name != null && name.isNotEmpty) {
              notifier.updateGearItem(item.id, label: name);
            }
          case 'remove':
            notifier.removeGearItem(item.id);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'necessity',
          child: Text(item.isMandatory
              ? 'Mark recommended'
              : 'Mark mandatory'),
        ),
        PopupMenuItem(
          value: 'shared',
          child: Text(item.shared
              ? 'Make personal (not shared)'
              : 'Make Shared Group Gear'),
        ),
        const PopupMenuItem(value: 'rename', child: Text('Rename…')),
        const PopupMenuItem(value: 'remove', child: Text('Remove')),
      ],
    );
  }
}

/// The add-gear dialog's result.
class _GearDraft {
  const _GearDraft({
    required this.label,
    required this.scope,
    required this.necessity,
    required this.shared,
  });

  final String label;
  final GearScope scope;
  final GearNecessity necessity;
  final bool shared;
}

class _GearDialog extends StatefulWidget {
  const _GearDialog({required this.scopes, required this.headingFor});

  final List<GearScope> scopes;
  final String Function(GearScope) headingFor;

  @override
  State<_GearDialog> createState() => _GearDialogState();
}

class _GearDialogState extends State<_GearDialog> {
  final _label = TextEditingController();
  late GearScope _scope = widget.scopes.first;
  GearNecessity _necessity = GearNecessity.recommended;
  bool _shared = false;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return AlertDialog(
      title: Text('Add gear', style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _label,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Item',
                hintText: 'Bear canister, helmet, sat phone…',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: PlotSpacing.s3),
            Text('WHAT IT IS FOR', style: PlotTypography.data(c.textMuted)),
            const SizedBox(height: PlotSpacing.s1),
            DropdownButtonFormField<int>(
              initialValue: 0,
              isDense: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (var i = 0; i < widget.scopes.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(_scopeLabel(widget.scopes[i])),
                  ),
              ],
              onChanged: (i) =>
                  setState(() => _scope = widget.scopes[i ?? 0]),
            ),
            const SizedBox(height: PlotSpacing.s3),
            Text('NECESSITY', style: PlotTypography.data(c.textMuted)),
            const SizedBox(height: PlotSpacing.s1),
            SegmentedButton<GearNecessity>(
              segments: const [
                ButtonSegment(
                    value: GearNecessity.mandatory, label: Text('Mandatory')),
                ButtonSegment(
                    value: GearNecessity.recommended,
                    label: Text('Recommended')),
              ],
              selected: {_necessity},
              onSelectionChanged: (s) => setState(() => _necessity = s.first),
            ),
            const SizedBox(height: PlotSpacing.s1),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              value: _shared,
              onChanged: (v) => setState(() => _shared = v ?? false),
              title: Text('Shared Group Gear',
                  style: PlotTypography.body(c.textPrimary)),
              subtitle: Text(
                'One item the group splits — you assign who carries it.',
                style: PlotTypography.small(c.textMuted),
              ),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        PlotButton(
          label: 'Cancel',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(context),
        ),
        PlotButton(
          label: 'Add',
          onPressed: () {
            final label = _label.text.trim();
            if (label.isEmpty) return;
            Navigator.pop(
              context,
              _GearDraft(
                label: label,
                scope: _scope,
                necessity: _necessity,
                shared: _shared,
              ),
            );
          },
        ),
      ],
    );
  }

  String _scopeLabel(GearScope scope) => switch (scope.kind) {
        GearScopeKind.trip => 'Everyone, every day',
        GearScopeKind.mode => '${travelModeLabel(scope.key!)} legs',
        GearScopeKind.stationActivity => stationActivityLabel(scope.key!),
      };
}

Future<String?> _promptText(
  BuildContext context, {
  required String title,
  required String initial,
}) {
  final controller = TextEditingController(text: initial);
  final c = PlotColors.of(context);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: PlotTypography.title(c.textPrimary)),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        PlotButton(
          label: 'Cancel',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(ctx),
        ),
        PlotButton(
          label: 'Save',
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
        ),
      ],
    ),
  );
}
