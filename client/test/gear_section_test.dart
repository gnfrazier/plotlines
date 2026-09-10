// FR24 / C8 (issue #44) — the gear checklist authoring surface on the
// Logistics tab: the empty state's next action, adding a line through the
// dialog, the mandatory/recommended treatment, scope grouping by mode and by
// station activity, and assigning Shared Group Gear to the roster.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/gear_section.dart';
import 'package:plotlines_client/state/current_roster_provider.dart';

Trip _trip({List<Anchor> anchors = const []}) => Trip(
      id: 't1',
      title: 'Test',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      declaredModes: const {'cycling', 'hiking'},
      anchors: anchors,
    );

Anchor _climbingAnchor() => Anchor(
      id: 'a1',
      coord: [40.0, -105.0],
      roles: [
        Role(
          id: 'r1',
          kind: RoleKind.station,
          activity: StationActivity(activityType: 'climbing'),
        ),
      ],
    );

Future<ProviderContainer> _pump(WidgetTester tester, Trip trip) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: GearSection(trip: trip)),
        ),
      ),
    ),
  );
  return container;
}

TripRoster _roster(ProviderContainer c) => c.read(currentRosterProvider);
CurrentRosterNotifier _notifier(ProviderContainer c) =>
    c.read(currentRosterProvider.notifier);

void main() {
  testWidgets('empty state carries a next action (FR142(c))', (tester) async {
    await _pump(tester, _trip());
    expect(find.textContaining('No gear yet'), findsOneWidget);
  });

  testWidgets('adding a line through the dialog lands it under EVERYONE, recommended by default',
      (tester) async {
    final c = await _pump(tester, _trip());

    await tester.tap(find.text('Add gear'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Item'), 'Bear canister');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(_roster(c).gear.single.label, 'Bear canister');
    expect(_roster(c).gear.single.necessity, GearNecessity.recommended);
    expect(_roster(c).gear.single.scope, const GearScope.trip());
    expect(find.text('EVERYONE'), findsOneWidget);
    expect(find.text('Bear canister'), findsOneWidget);
    expect(find.text('RECOMMENDED'), findsOneWidget);
  });

  testWidgets('a mandatory line renders the MANDATORY badge', (tester) async {
    final c = await _pump(tester, _trip());
    _notifier(c).addGearItem(
      const GearItem(id: 'g', label: 'Helmet', necessity: GearNecessity.mandatory),
    );
    await tester.pump();
    expect(find.text('MANDATORY'), findsOneWidget);
  });

  testWidgets('lines group by mode and by station activity', (tester) async {
    final c = await _pump(tester, _trip(anchors: [_climbingAnchor()]));
    _notifier(c).addGearItem(
      GearItem(id: 'm', label: 'Rain jacket', scope: GearScope.mode('cycling')),
    );
    _notifier(c).addGearItem(
      GearItem(id: 'a', label: 'Rope', scope: GearScope.stationActivity('climbing')),
    );
    await tester.pump();

    expect(find.text('RIDE'), findsOneWidget); // travelModeLabel('cycling')
    expect(find.text('CLIMBING'), findsOneWidget);
    expect(find.text('Rain jacket'), findsOneWidget);
    expect(find.text('Rope'), findsOneWidget);
  });

  testWidgets('Shared Group Gear can be assigned to a roster Character', (tester) async {
    final c = await _pump(tester, _trip());
    _notifier(c).addEntry('ann', 'Ann');
    _notifier(c).addGearItem(
      const GearItem(id: 'tent', label: 'Tent', shared: true),
    );
    await tester.pump();

    expect(find.text('SHARED'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'Ann'));
    await tester.pump();

    expect(_roster(c).gear.single.assigneeIds, {'ann'});
  });

  testWidgets('a shared line with an empty roster points at the Roster tab', (tester) async {
    final c = await _pump(tester, _trip());
    _notifier(c).addGearItem(const GearItem(id: 'tent', label: 'Tent', shared: true));
    await tester.pump();
    expect(find.textContaining('Add Characters on the Roster tab'), findsOneWidget);
  });
}
