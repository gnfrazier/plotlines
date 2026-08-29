// FR102–FR105a / FR110 (Story N4a) — "Review and act on proposals".
//
// The list is the primary surface; the map is synchronized to it (selecting
// a card highlights its extent, tapping a cluster selects its card). Every
// card carries the three one-gesture actions — Promote / Reject / Defer —
// plus bulk reject by filter, explicit ordering + paging (the cap is stated
// with the count beyond it, never a silent truncation), and specified empty
// and dense states.
//
// Nothing here writes canon except Promote, which goes through
// `currentTripProvider.promoteAnchor` with the cluster's affinity-union role
// set pre-filled (O1); the roles are then editable on the Content tab.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:uuid/uuid.dart';

import '../../../domain/anchor.dart';
import '../../../domain/candidate.dart' show RoleAffinity;
import '../../../domain/cluster_proposal.dart';
import '../../../domain/promote.dart' show roleKindFromAffinity, DuplicatePromotionException;
import '../../../domain/trip.dart';
import '../../../state/current_trip_provider.dart';
import '../../../state/proposals_provider.dart';
import '../../../state/trip_bbox_provider.dart';
import '../../map/candidate_map.dart';
import '../../widgets/proposal_card.dart';

const _uuid = Uuid();

class ProposalsView extends ConsumerWidget {
  const ProposalsView({super.key, required this.trip, required this.liveLayers});

  final Trip trip;
  final Set<String> liveLayers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final bbox = ref.watch(tripBboxProvider);
    final state = ref.watch(proposalsProvider);
    final notifier = ref.read(proposalsProvider.notifier);

    return Row(
      children: [
        Expanded(
          child: CandidateMap(
            candidates: const [],
            bbox: bbox,
            proposals: state.visible,
            selectedProposalId: state.selectedId,
            onProposalTap: (p) => notifier.select(p.id),
          ),
        ),
        Container(
          width: 420,
          decoration: BoxDecoration(border: Border(left: BorderSide(color: c.border))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Toolbar(
                trip: trip,
                liveLayers: liveLayers,
                canRun: bbox != null && !state.loading,
              ),
              const Divider(height: 1),
              Expanded(child: _Body(trip: trip)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Toolbar extends ConsumerWidget {
  const _Toolbar({required this.trip, required this.liveLayers, required this.canRun});
  final Trip trip;
  final Set<String> liveLayers;
  final bool canRun;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final state = ref.watch(proposalsProvider);
    final notifier = ref.read(proposalsProvider.notifier);
    final bbox = ref.watch(tripBboxProvider);

    Future<void> run() async {
      if (bbox == null) return;
      await notifier.analyze(bbox: bbox, liveLayers: liveLayers);
    }

    return Padding(
      padding: const EdgeInsets.all(PlotSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: PlotButton(
                  label: state.hasRun ? 'Run again' : 'Find the good spots',
                  icon: Icons.travel_explore,
                  onPressed: canRun ? run : null,
                ),
              ),
              if (state.loading) ...[
                const SizedBox(width: PlotSpacing.s3),
                const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ],
          ),
          if (state.error != null) ...[
            const SizedBox(height: PlotSpacing.s2),
            Text(state.error!, style: PlotTypography.small(c.danger)),
          ],
          if (state.hasRun) ...[
            const SizedBox(height: PlotSpacing.s3),
            Row(
              children: [
                Text('SORT', style: PlotTypography.small(c.textMuted)),
                const SizedBox(width: PlotSpacing.s2),
                DropdownButton<ProposalSort>(
                  value: state.sort,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  onChanged: (v) => v == null ? null : notifier.setSort(v),
                  items: const [
                    DropdownMenuItem(value: ProposalSort.rank, child: Text('Salience × tightness')),
                    DropdownMenuItem(
                        value: ProposalSort.distanceFromRoute, child: Text('Distance from route')),
                    DropdownMenuItem(value: ProposalSort.layer, child: Text('Layer')),
                  ],
                ),
                const Spacer(),
                _BulkRejectMenu(),
              ],
            ),
            const SizedBox(height: PlotSpacing.s1),
            _CountLine(),
            _FilterRow(),
          ],
        ],
      ),
    );
  }
}

class _CountLine extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final state = ref.watch(proposalsProvider);
    final shown = state.visible.length;
    final beyond = state.nBeyondCap;
    final rejected = state.rejectedIds.length;
    final parts = <String>[
      '$shown SHOWN',
      if (rejected > 0) '$rejected REJECTED',
      if (beyond > 0) '+$beyond BEYOND THE CAP',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: PlotSpacing.s1),
      child: Text(parts.join('   ·   '), style: PlotTypography.data(c.textMuted)),
    );
  }
}

class _FilterRow extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(proposalsProvider);
    final notifier = ref.read(proposalsProvider.notifier);
    final f = state.filter;
    final layers = <String>{
      for (final p in state.result?.proposals ?? const <ClusterProposal>[])
        for (final m in p.members) m.layer,
    }.toList()
      ..sort();

    return Padding(
      padding: const EdgeInsets.only(top: PlotSpacing.s2),
      child: Wrap(
        spacing: PlotSpacing.s2,
        runSpacing: PlotSpacing.s1,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final role in RoleAffinity.values)
            FilterChip(
              label: Text(roleAffinityLabel(role)),
              selected: f.role == role,
              onSelected: (sel) =>
                  notifier.setFilter(f.copyWith(role: sel ? role : null)),
            ),
          for (final layer in layers)
            FilterChip(
              label: Text(layer),
              selected: f.layer == layer,
              onSelected: (sel) =>
                  notifier.setFilter(f.copyWith(layer: sel ? layer : null)),
            ),
          if (f.isActive)
            TextButton(onPressed: notifier.clearFilter, child: const Text('Clear filters')),
        ],
      ),
    );
  }
}

class _BulkRejectMenu extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(proposalsProvider);
    final notifier = ref.read(proposalsProvider.notifier);
    final layers = <String>{
      for (final p in state.visible)
        for (final m in p.members) m.layer,
    }.toList()
      ..sort();

    Future<void> apply({RoleAffinity? role, String? layer, double? below}) async {
      final ids = await notifier.bulkReject(byRole: role, byLayer: layer, belowSalience: below);
      if (ids.isEmpty || !context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Rejected ${ids.length} proposals'),
        action: SnackBarAction(label: 'Undo', onPressed: () => notifier.undoBulk(ids)),
      ));
    }

    return PopupMenuButton<void>(
      enabled: state.visible.isNotEmpty,
      icon: const Icon(Icons.playlist_remove, size: 20),
      tooltip: 'Bulk reject by filter',
      itemBuilder: (_) => [
        const PopupMenuItem<void>(enabled: false, child: Text('Bulk reject…')),
        PopupMenuItem<void>(
          child: const Text('Below 20% salience'),
          onTap: () => apply(below: 0.2),
        ),
        for (final role in RoleAffinity.values)
          PopupMenuItem<void>(
            child: Text('All ${roleAffinityLabel(role)}'),
            onTap: () => apply(role: role),
          ),
        for (final layer in layers)
          PopupMenuItem<void>(
            child: Text('All from "$layer"'),
            onTap: () => apply(layer: layer),
          ),
      ],
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.trip});
  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final state = ref.watch(proposalsProvider);
    final notifier = ref.read(proposalsProvider.notifier);

    if (!state.hasRun) {
      return _Hint(
        title: 'No analysis yet',
        body: 'Run "find the good spots" to cluster the candidates in this trip '
            'area into reviewable proposals.',
      );
    }
    if (state.isEmptyResult) {
      // N4a — "no clusters found says so and suggests widening layers or the bbox."
      return _Hint(
        title: 'No clusters found',
        body: 'Nothing in this area clustered tightly enough to propose. Try '
            'turning on more layers, or widening the trip area, then run again.',
      );
    }

    final visible = state.visible;
    return ListView.separated(
      padding: const EdgeInsets.all(PlotSpacing.s3),
      itemCount: visible.length + (state.nBeyondCap > 0 ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: PlotSpacing.s3),
      itemBuilder: (context, i) {
        if (i == visible.length) {
          // Dense state — the cap is stated with the count beyond it (FR105a).
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: PlotSpacing.s3),
            child: Text(
              '+${state.nBeyondCap} more proposals beyond the reviewable cap of '
              '${state.result!.cap}. Narrow with a filter, or reject in bulk, then '
              'run again to see the next set.',
              style: PlotTypography.small(c.textMuted),
            ),
          );
        }
        final p = visible[i];
        return ProposalCard(
          proposal: p,
          selected: state.selectedId == p.id,
          deferred: state.deferredIds.contains(p.id),
          onSelect: () => notifier.select(p.id),
          onDefer: () => state.deferredIds.contains(p.id)
              ? notifier.undefer(p.id)
              : notifier.defer(p.id),
          onReject: () async {
            await notifier.reject(p.id);
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Rejected "${p.name}"'),
              action: SnackBarAction(
                  label: 'Undo', onPressed: () => notifier.undoReject(p.id)),
            ));
          },
          onPromote: () => _promote(context, ref, p),
        );
      },
    );
  }

  void _promote(BuildContext context, WidgetRef ref, ClusterProposal p) {
    // O1 — promotion with the cluster's affinity-union role set pre-filled,
    // editable afterwards on the Content tab. FR105's "system proposes, the
    // Author decides".
    final roles = [
      for (final a in p.roleAffinities)
        Role(id: _uuid.v4(), kind: roleKindFromAffinity(a)),
    ];
    if (roles.isEmpty) return;
    final top = p.members.first;
    try {
      ref.read(currentTripProvider.notifier).promoteAnchor(
            coord: p.centroid,
            roles: roles,
            title: p.name,
            provenance: AnchorProvenance(
              kind: AnchorSourceKind.candidate,
              sourceId: top.candidateId,
              layer: top.layer,
            ),
          );
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Promoted "${p.name}" with roles: '
            '${p.roleAffinities.map(roleAffinityLabel).join(", ")} — edit on Content'),
      ));
    } on DuplicatePromotionException {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('One of these features is already an anchor — edit it on Content')),
      );
    }
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(PlotSpacing.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: PlotTypography.title(c.textPrimary)),
            const SizedBox(height: PlotSpacing.s2),
            Text(body, style: PlotTypography.body(c.textMuted), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
