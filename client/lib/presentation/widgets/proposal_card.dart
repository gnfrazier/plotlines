// FR102–FR105a (Story N4a) — "A proposal is a reviewable object, not a map
// pin." One card per [ClusterProposal], carrying a generated name, its
// contributing features listed individually with type / name / salience, the
// suggested role set with the affinity that produced it, the cluster's
// extent + tightness, its distance from the current route where one exists,
// and the three one-gesture actions: Promote, Reject, Defer.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/candidate.dart' show RoleAffinity;
import '../../domain/cluster_proposal.dart';

String roleAffinityLabel(RoleAffinity a) => switch (a) {
      RoleAffinity.narrative => 'narrative',
      RoleAffinity.provision => 'provision',
      RoleAffinity.station => 'station',
    };

PlotBadgeTone _roleTone(RoleAffinity a) => switch (a) {
      RoleAffinity.narrative => PlotBadgeTone.blaze,
      RoleAffinity.provision => PlotBadgeTone.slate,
      RoleAffinity.station => PlotBadgeTone.spruce,
    };

class ProposalCard extends StatelessWidget {
  const ProposalCard({
    super.key,
    required this.proposal,
    required this.selected,
    required this.deferred,
    this.onSelect,
    this.onPromote,
    this.onReject,
    this.onDefer,
  });

  final ClusterProposal proposal;
  final bool selected;
  final bool deferred;
  final VoidCallback? onSelect;
  final VoidCallback? onPromote;
  final VoidCallback? onReject;
  final VoidCallback? onDefer;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final p = proposal;

    return Opacity(
      opacity: deferred ? 0.6 : 1.0,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(PlotRadii.lg),
          border: Border.all(
            color: selected ? c.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: PlotCard(
          onTap: onSelect,
          padding: const EdgeInsets.all(PlotSpacing.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(p.name, style: PlotTypography.title(c.textPrimary)),
                  ),
                  if (p.isNew)
                    const Padding(
                      padding: EdgeInsets.only(left: PlotSpacing.s2),
                      child: PlotBadge('NEW', tone: PlotBadgeTone.spruce),
                    ),
                ],
              ),
              const SizedBox(height: PlotSpacing.s2),
              // Suggested role set + the affinity that produced it.
              Wrap(
                spacing: PlotSpacing.s2,
                runSpacing: PlotSpacing.s1,
                children: [
                  for (final a in p.roleAffinities)
                    PlotBadge(roleAffinityLabel(a).toUpperCase(), tone: _roleTone(a)),
                ],
              ),
              const SizedBox(height: PlotSpacing.s3),
              _MetricsLine(proposal: p),
              const SizedBox(height: PlotSpacing.s3),
              // Contributing features, listed individually.
              Text('CONTRIBUTING (${p.members.length})',
                  style: PlotTypography.small(c.textMuted)),
              const SizedBox(height: PlotSpacing.s1),
              for (final m in p.members) _MemberRow(member: m),
              const SizedBox(height: PlotSpacing.s3),
              Row(
                children: [
                  PlotButton(label: 'Promote', onPressed: onPromote),
                  const SizedBox(width: PlotSpacing.s2),
                  TextButton(
                    onPressed: onReject,
                    child: const Text('Reject'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: onDefer,
                    child: Text(deferred ? 'Deferred' : 'Defer'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricsLine extends StatelessWidget {
  const _MetricsLine({required this.proposal});
  final ClusterProposal proposal;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final p = proposal;
    final parts = <String>[
      'SALIENCE ${(p.salienceScore * 100).round()}%',
      'TIGHTNESS ${(p.tightness * 100).round()}%',
      'EXTENT ${p.extentM.round()} M',
      if (p.distanceToRouteM != null)
        'OFF ROUTE ${_dist(p.distanceToRouteM!)}',
    ];
    // Data is always mono so it "looks accountable" (brand rule).
    return Text(parts.join('   ·   '), style: PlotTypography.data(c.textSecondary));
  }

  static String _dist(double m) =>
      m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} KM' : '${m.round()} M';
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member});
  final ClusterMember member;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              member.title?.isNotEmpty == true
                  ? '${member.title}  ·  ${member.type}'
                  : member.type,
              style: PlotTypography.small(c.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: PlotSpacing.s2),
          Text('${(member.salience * 100).round()}%',
              style: PlotTypography.data(c.textMuted)),
        ],
      ),
    );
  }
}
