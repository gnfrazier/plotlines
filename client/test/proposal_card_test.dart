// FR102–FR105a (Story N4a) — the proposal card renders as a reviewable
// object (name, members with type/name/salience, role set, extent/tightness,
// off-route distance) and offers the three one-gesture actions.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/domain/cluster_proposal.dart';
import 'package:plotlines_client/presentation/widgets/proposal_card.dart';

ClusterProposal _proposal() => ClusterProposal.fromJson({
      'id': 'cl_abc',
      'name': 'Ridge Overlook',
      'kind': 'narrative+provision',
      'role_affinities': ['narrative', 'provision'],
      'members': [
        {
          'candidate_id': 'osm/vp',
          'layer': 'sight',
          'type': 'tourism=viewpoint',
          'salience': 0.72,
          'role_affinity': 'narrative',
          'title': 'Ridge Overlook',
        },
        {
          'candidate_id': 'osm/water',
          'layer': 'amenity',
          'type': 'amenity=drinking_water',
          'salience': 0.5,
          'role_affinity': 'provision',
          'title': null,
        },
      ],
      'centroid': [-82.0, 36.0],
      'extent_m': 42.0,
      'tightness': 0.81,
      'salience_score': 0.86,
      'rank_score': 0.7,
      'distance_to_route_m': 1450.0,
      'is_new': true,
    });

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(theme: PlotTheme.light(), home: Scaffold(body: SingleChildScrollView(child: child))),
    );

void main() {
  testWidgets('renders the generated name, role set, metrics and every member', (tester) async {
    await _pump(tester, ProposalCard(proposal: _proposal(), selected: false, deferred: false));

    expect(find.text('Ridge Overlook'), findsWidgets);
    expect(find.text('NARRATIVE'), findsOneWidget);
    expect(find.text('PROVISION'), findsOneWidget);
    expect(find.textContaining('SALIENCE 86%'), findsOneWidget);
    expect(find.textContaining('TIGHTNESS 81%'), findsOneWidget);
    expect(find.textContaining('EXTENT 42 M'), findsOneWidget);
    expect(find.textContaining('OFF ROUTE 1.'), findsOneWidget);
    // members listed individually, with type and salience
    expect(find.textContaining('tourism=viewpoint'), findsOneWidget);
    expect(find.textContaining('amenity=drinking_water'), findsOneWidget);
    expect(find.text('72%'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('NEW'), findsOneWidget);
  });

  testWidgets('the three actions each fire in one gesture', (tester) async {
    var promoted = 0, rejected = 0, deferred = 0;
    await _pump(
      tester,
      ProposalCard(
        proposal: _proposal(),
        selected: false,
        deferred: false,
        onPromote: () => promoted++,
        onReject: () => rejected++,
        onDefer: () => deferred++,
      ),
    );

    await tester.tap(find.text('Promote'));
    await tester.tap(find.text('Reject'));
    await tester.tap(find.text('Defer'));
    await tester.pump();
    expect((promoted, rejected, deferred), (1, 1, 1));
  });

  testWidgets('a deferred card reads "Deferred" and dims', (tester) async {
    await _pump(tester,
        ProposalCard(proposal: _proposal(), selected: false, deferred: true, onDefer: () {}));
    expect(find.text('Deferred'), findsOneWidget);
    final opacity = tester.widget<Opacity>(find.byType(Opacity).first);
    expect(opacity.opacity, lessThan(1.0));
  });

  testWidgets('selecting the card is reported for list<->map sync', (tester) async {
    var selected = 0;
    await _pump(tester,
        ProposalCard(proposal: _proposal(), selected: false, deferred: false, onSelect: () => selected++));
    await tester.tap(find.text('Ridge Overlook').first);
    await tester.pump();
    expect(selected, 1);
  });
}
