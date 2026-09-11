// FR26 / C10 (issue #46) — the permit/access-pass authoring surface on the
// Logistics tab: the empty state's next action, adding a permit through the
// dialog, the pre-trip checklist's status badges, and worst-first ordering.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/permit_section.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Trip _trip({List<Permit> permits = const [], List<Anchor> anchors = const []}) => Trip(
      id: 't1',
      title: 'Test',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      permits: permits,
      anchors: anchors,
    );

Future<ProviderContainer> _pump(WidgetTester tester, Trip trip) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(trip);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          // A `Consumer`, not a fixed snapshot — [PermitSection] takes `trip`
          // as a plain constructor argument (mirroring how `LogisticsTab`
          // hands it down), so the harness has to rebuild it itself when the
          // provider changes, the same as the real screen above it does.
          body: Consumer(
            builder: (context, ref, _) => SingleChildScrollView(
              child: PermitSection(trip: ref.watch(currentTripProvider)),
            ),
          ),
        ),
      ),
    ),
  );
  return container;
}

Trip _openedTrip(ProviderContainer c) => c.read(currentTripProvider);

void main() {
  testWidgets('empty state carries a next action', (tester) async {
    await _pump(tester, _trip());
    expect(find.textContaining('No permits yet'), findsOneWidget);
  });

  testWidgets('adding a permit through the dialog defaults to required', (tester) async {
    final c = await _pump(tester, _trip());

    await tester.tap(find.text('Add permit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Permit / pass'), 'Backcountry permit');
    await tester.tap(find.text('Add').last);
    await tester.pumpAndSettle();

    expect(_openedTrip(c).permits.single.title, 'Backcountry permit');
    expect(_openedTrip(c).permits.single.status, 'required');
    expect(find.text('Backcountry permit'), findsOneWidget);
    expect(find.text('REQUIRED'), findsOneWidget);
  });

  testWidgets('a denied permit sorts before a required one, both before confirmed', (tester) async {
    await _pump(tester, _trip(permits: [
      Permit(id: 'p1', title: 'Confirmed permit', status: 'confirmed'),
      Permit(id: 'p2', title: 'Denied permit', status: 'denied'),
      Permit(id: 'p3', title: 'Required permit', status: 'required'),
    ]));

    const wanted = {'Denied permit', 'Required permit', 'Confirmed permit'};
    final titles = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .where(wanted.contains)
        .toList();
    expect(titles, ['Denied permit', 'Required permit', 'Confirmed permit']);
  });

  testWidgets('needs-attention count excludes confirmed permits', (tester) async {
    await _pump(tester, _trip(permits: [
      Permit(id: 'p1', title: 'a', status: 'confirmed'),
      Permit(id: 'p2', title: 'b', status: 'required'),
    ]));
    expect(find.textContaining('1 permit needs attention'), findsOneWidget);
  });

  testWidgets('a permit can be attached to an existing anchor', (tester) async {
    final anchor = Anchor(
      id: 'a1', coord: const [0.0, 0.0], title: 'Trailhead',
      roles: [Role(id: 'r1', kind: RoleKind.provision)],
    );
    final c = await _pump(tester, _trip(anchors: [anchor]));

    await tester.tap(find.text('Add permit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Permit / pass'), 'Trailhead permit');
    await tester.tap(find.byType(DropdownButtonFormField<String?>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trailhead').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add').last);
    await tester.pumpAndSettle();

    expect(_openedTrip(c).permits.single.anchorId, 'a1');
    expect(find.textContaining('at Trailhead'), findsOneWidget);
  });
}
