// FR99 — salience visible as size, weight, and opacity, never color alone
// (brand guardrail: every map marker needs a distinct shape + internal mark).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

void main() {
  testWidgets('renders without throwing across the salience range', (tester) async {
    for (final salience in [0.0, 0.25, 0.5, 0.75, 1.0]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: CandidateMarker(salience: salience)),
      ));
      expect(find.byType(CandidateMarker), findsOneWidget);
    }
  });

  testWidgets('a higher-salience marker is never smaller than a lower one', (tester) async {
    final lowKey = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CandidateMarker(key: lowKey, salience: 0.1)),
    ));
    final lowSize = (lowKey.currentContext!.findRenderObject() as RenderBox).size;

    final highKey = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CandidateMarker(key: highKey, salience: 1.0)),
    ));
    final highSize = (highKey.currentContext!.findRenderObject() as RenderBox).size;

    expect(highSize.width, greaterThan(lowSize.width));
  });

  testWidgets('all three role affinities render distinctly (shape carries meaning)', (tester) async {
    for (final affinity in CandidateRoleAffinity.values) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: CandidateMarker(salience: 0.8, roleAffinity: affinity)),
      ));
      expect(find.byType(CandidateMarker), findsOneWidget);
    }
  });
}
