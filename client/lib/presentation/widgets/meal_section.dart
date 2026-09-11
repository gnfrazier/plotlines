// FR25 / C9 (issue #45) — the group-meal authoring surface, rendered on the
// Logistics tab under the day list, beside [GearSection].
//
// C9's AC: "group meals" with "meal responsibilities assignable." This
// widget is that Author surface — assigning who on the roster is responsible
// for a meal. The place-and-tag half of C9 (water/resupply anchors) lives on
// [AnchorPromotionPanel] instead, since a water source or a resupply point is
// a promoted place (a `provision`-kind role), not a roster assignment.
//
// Lives in the roster layer (`domain/roster.dart`'s [MealResponsibility],
// beside the payload) for the same reason [GearSection] does: the
// load-bearing half — who carries the responsibility — is roster-scoped, and
// a meal-responsibility list is no more a `trip_payload.schema.json` type
// than the roster itself is.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:uuid/uuid.dart';

import '../../domain/domain.dart';
import '../../state/current_roster_provider.dart';

const _uuid = Uuid();

/// The MEALS block on the Logistics tab. Reads the roster layer for the open
/// trip and the trip's days to offer a day pin for every meal.
class MealSection extends ConsumerWidget {
  const MealSection({super.key, required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final roster = ref.watch(currentRosterProvider);
    final meals = roster.meals;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('MEALS',
                style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            PlotButton(
              label: 'Add meal',
              variant: PlotButtonVariant.secondary,
              icon: Icons.add,
              onPressed: () => _addMeal(context, ref),
            ),
          ],
        ),
        const SizedBox(height: PlotSpacing.s2),
        Text(
          'Group meals and who is responsible for each — pin one to a day, '
          'or leave it trip-wide.',
          style: PlotTypography.small(c.textMuted),
        ),
        const SizedBox(height: PlotSpacing.s3),
        if (meals.isEmpty)
          Text(
            'No group meals yet. Add one and say who is bringing or cooking it.',
            style: PlotTypography.body(c.textMuted),
          )
        else
          for (final meal in meals)
            _MealRow(key: ValueKey(meal.id), meal: meal, trip: trip, entries: roster.entries),
      ],
    );
  }

  Future<void> _addMeal(BuildContext context, WidgetRef ref) async {
    final draft = await showDialog<_MealDraft>(
      context: context,
      builder: (_) => _MealDialog(days: trip.days),
    );
    if (draft == null) return;
    ref.read(currentRosterProvider.notifier).addMeal(
          MealResponsibility(id: _uuid.v4(), label: draft.label, dayId: draft.dayId),
        );
  }
}

/// A day's label for the pin dropdown/badge — `Day ${index}`, matching the
/// Logistics tab's own day cards rather than a second naming scheme.
String _dayLabel(Trip trip, String dayId) {
  final day = trip.days.where((d) => d.id == dayId).firstOrNull;
  return day == null ? 'Day (removed)' : 'Day ${day.index}';
}

class _MealRow extends ConsumerWidget {
  const _MealRow({super.key, required this.meal, required this.trip, required this.entries});

  final MealResponsibility meal;
  final Trip trip;
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
              Expanded(
                child: Text(meal.label, style: PlotTypography.body(c.textPrimary)),
              ),
              if (meal.dayId != null)
                Padding(
                  padding: const EdgeInsets.only(left: PlotSpacing.s2),
                  child: PlotBadge(_dayLabel(trip, meal.dayId!), tone: PlotBadgeTone.slate),
                ),
              _MealRowMenu(meal: meal, trip: trip, notifier: notifier),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: PlotSpacing.s1, bottom: PlotSpacing.s1),
            child: entries.isEmpty
                ? Text(
                    'Add Characters on the Roster tab to say who has this one.',
                    style: PlotTypography.small(c.textMuted),
                  )
                : Wrap(
                    spacing: PlotSpacing.s2,
                    runSpacing: PlotSpacing.s1,
                    children: [
                      for (final e in entries)
                        FilterChip(
                          label: Text(e.name, style: PlotTypography.small(c.textPrimary)),
                          selected: meal.cookIds.contains(e.characterId),
                          onSelected: (sel) {
                            final next = {...meal.cookIds};
                            if (sel) {
                              next.add(e.characterId);
                            } else {
                              next.remove(e.characterId);
                            }
                            notifier.setMealCooks(meal.id, next);
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

class _MealRowMenu extends StatelessWidget {
  const _MealRowMenu({required this.meal, required this.trip, required this.notifier});

  final MealResponsibility meal;
  final Trip trip;
  final CurrentRosterNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return PopupMenuButton<String>(
      tooltip: 'Meal options',
      icon: Icon(Icons.more_vert, color: c.textSecondary, size: 20),
      onSelected: (value) async {
        switch (value) {
          case 'rename':
            final name = await _promptMealText(context, title: 'Rename meal', initial: meal.label);
            if (name != null && name.isNotEmpty) notifier.updateMeal(meal.id, label: name);
          case 'pin_day':
            final dayId = await _promptDay(context, trip: trip, current: meal.dayId);
            if (dayId != null) {
              if (dayId.isEmpty) {
                notifier.updateMeal(meal.id, clearDayId: true);
              } else {
                notifier.updateMeal(meal.id, dayId: dayId);
              }
            }
          case 'remove':
            notifier.removeMeal(meal.id);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'rename', child: Text('Rename…')),
        PopupMenuItem(value: 'pin_day', child: Text(meal.dayId == null ? 'Pin to a day…' : 'Change day…')),
        const PopupMenuItem(value: 'remove', child: Text('Remove')),
      ],
    );
  }
}

/// The add-meal dialog's result.
class _MealDraft {
  const _MealDraft({required this.label, this.dayId});
  final String label;
  final String? dayId;
}

class _MealDialog extends StatefulWidget {
  const _MealDialog({required this.days});
  final List<Day> days;

  @override
  State<_MealDialog> createState() => _MealDialogState();
}

class _MealDialogState extends State<_MealDialog> {
  final _label = TextEditingController();
  String? _dayId;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return AlertDialog(
      title: Text('Add meal', style: PlotTypography.title(c.textPrimary)),
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
                labelText: 'Meal',
                hintText: 'Night 2 dinner, trailhead breakfast…',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: PlotSpacing.s3),
            Text('DAY (OPTIONAL)', style: PlotTypography.data(c.textMuted)),
            const SizedBox(height: PlotSpacing.s1),
            DropdownButtonFormField<String?>(
              initialValue: _dayId,
              isDense: true,
              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
              items: [
                const DropdownMenuItem(value: null, child: Text('Trip-wide')),
                for (final day in widget.days)
                  DropdownMenuItem(value: day.id, child: Text('Day ${day.index}')),
              ],
              onChanged: (v) => setState(() => _dayId = v),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        PlotButton(label: 'Cancel', variant: PlotButtonVariant.ghost, onPressed: () => Navigator.pop(context)),
        PlotButton(
          label: 'Add',
          onPressed: () {
            final label = _label.text.trim();
            if (label.isEmpty) return;
            Navigator.pop(context, _MealDraft(label: label, dayId: _dayId));
          },
        ),
      ],
    );
  }
}

Future<String?> _promptMealText(BuildContext context, {required String title, required String initial}) {
  final controller = TextEditingController(text: initial);
  final c = PlotColors.of(context);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: PlotTypography.title(c.textPrimary)),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        PlotButton(label: 'Cancel', variant: PlotButtonVariant.ghost, onPressed: () => Navigator.pop(ctx)),
        PlotButton(label: 'Save', onPressed: () => Navigator.pop(ctx, controller.text.trim())),
      ],
    ),
  );
}

/// `''` means "clear the day pin" (trip-wide); `null` means the Author
/// cancelled and nothing should change.
Future<String?> _promptDay(BuildContext context, {required Trip trip, required String? current}) {
  final c = PlotColors.of(context);
  var selected = current;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text('Pin to a day', style: PlotTypography.title(c.textPrimary)),
        content: SizedBox(
          width: 320,
          child: DropdownButtonFormField<String?>(
            initialValue: selected,
            isDense: true,
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
            items: [
              const DropdownMenuItem(value: null, child: Text('Trip-wide')),
              for (final day in trip.days)
                DropdownMenuItem(value: day.id, child: Text('Day ${day.index}')),
            ],
            onChanged: (v) => setState(() => selected = v),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          PlotButton(label: 'Cancel', variant: PlotButtonVariant.ghost, onPressed: () => Navigator.pop(ctx)),
          PlotButton(label: 'Save', onPressed: () => Navigator.pop(ctx, selected ?? '')),
        ],
      ),
    ),
  );
}
