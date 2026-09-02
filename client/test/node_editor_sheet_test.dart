// Wireframe "03 Node & Narrative" — the node editor form and its modal
// container.
//
// #235 B5. `node_editor_sheet.dart` shipped at 0% coverage while being reachable
// from `route_tab.dart:80`. `NodeEditorForm` is the shared body behind two
// containers (this modal, and the Content tab's drawer), so a defect here shows
// up in both — and it writes authored content, which is the class of data the
// project treats as unrecoverable.
//
// The assertions concentrate on the save path: what a blank field becomes, that
// an edit revises rather than duplicates, and that `didUpdateWidget` re-seeds
// when the drawer is pointed at a different node.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/node_editor_sheet.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

const Coord _coord = [-105.2797, 40.0175];

Trip _trip({List<Node> nodes = const []}) => Trip(
      id: 't1',
      title: 'Trip',
      createdAt: '2026-09-02T00:00:00Z',
      updatedAt: '2026-09-02T00:00:00Z',
      days: [
        Day(id: 'd1', index: 1, segments: [
          Segment(
            id: 's1',
            mode: 'cycling',
            shape: 'loop',
            start: const [-105.27, 40.02],
            nodes: nodes,
          ),
        ]),
      ],
    );

/// Pumps the form directly (not the sheet) with a live trip provider, and
/// returns the container plus the nodes the form reports as saved.
Future<(ProviderContainer, List<Node>)> _pumpForm(
  WidgetTester tester, {
  Node? existing,
  List<Node> nodes = const [],
}) async {
  _useTallWindow(tester);
  final container = ProviderContainer();
  container.read(currentTripProvider.notifier).open(_trip(nodes: nodes));
  final saved = <Node>[];

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: NodeEditorForm(
          dayId: 'd1',
          segmentId: 's1',
          coord: _coord,
          existing: existing,
          onSaved: saved.add,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return (container, saved);
}

List<Node> _nodesOf(ProviderContainer container) =>
    container.read(currentTripProvider).days.single.segments.single.nodes;

/// Give the test a window tall enough to hold the whole form.
///
/// The form is a lazily-built `ListView`, so on the 800x600 default surface
/// the amenity chips and `Save node` are not merely off-screen — they are not
/// in the tree, and neither `find` nor `ensureVisible` can reach them. This is
/// a desktop editor; a desktop-sized window is the honest surface to test it
/// on, and it keeps every assertion about one scroll position.
void _useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('the form as opened', () {
    testWidgets('a new node opens blank, on the coordinate that was tapped',
        (tester) async {
      final (container, _) = await _pumpForm(tester);
      addTearDown(container.dispose);

      expect(find.text('New node'), findsOneWidget);
      // lat, lon — the order a map surface reads them in.
      expect(find.text('40.01750, -105.27970'), findsOneWidget);
    });

    testWidgets('an existing node opens on its own values', (tester) async {
      final existing = Node(
        id: 'n1',
        kind: NodeKind.restStop,
        coord: _coord,
        title: 'Overlook Camp',
        note: 'Water from the spring, not the creek.',
        poiType: 'viewpoint',
        amenities: const ['water'],
        arcStage: 'rising',
        narration: Narration(triggerDistanceM: 120.0),
      );
      final (container, _) = await _pumpForm(tester, existing: existing, nodes: [existing]);
      addTearDown(container.dispose);

      expect(find.text('Edit node'), findsOneWidget);
      expect(find.text('Overlook Camp'), findsOneWidget);
      expect(find.text('Water from the spring, not the creek.'), findsOneWidget);
      expect(find.text('viewpoint'), findsOneWidget);
      expect(find.text('120.0'), findsOneWidget);
    });

    testWidgets('every node kind is offered', (tester) async {
      // The kind list is enumerated from `NodeKind.values` rather than written
      // out, so a new kind cannot be added to the domain and forgotten here.
      final (container, _) = await _pumpForm(tester);
      addTearDown(container.dispose);

      for (final kind in NodeKind.values) {
        expect(find.text(kind.wireValue.replaceAll('_', ' ')), findsOneWidget,
            reason: '${kind.wireValue} is missing from the kind chips');
      }
    });

    testWidgets('the amenity choices come from C5\'s seed set', (tester) async {
      final (container, _) = await _pumpForm(tester);
      addTearDown(container.dispose);

      for (final amenity in kKnownAmenities) {
        expect(find.widgetWithText(FilterChip, amenity), findsOneWidget);
      }
    });

    testWidgets('narration is labelled as authoring-only', (tester) async {
      // E4: playback is field execution and out of desktop MVP. The label is
      // what stops an Author expecting the desktop build to read it aloud.
      final (container, _) = await _pumpForm(tester);
      addTearDown(container.dispose);

      expect(find.textContaining('authoring only'), findsOneWidget);
      expect(find.textContaining('Playback is field execution'), findsOneWidget);
    });
  });

  group('saving a new node', () {
    testWidgets('adds it to the segment with what was typed', (tester) async {
      final (container, saved) = await _pumpForm(tester);
      addTearDown(container.dispose);

      await tester.enterText(
          find.widgetWithText(TextField, 'Title'), 'Overlook Camp');
      await tester.enterText(
          find.widgetWithText(TextField, 'Note (Markdown)'), 'Worth the stop.');
      await _tap(tester, find.text('Save node'));

      final nodes = _nodesOf(container);
      expect(nodes, hasLength(1));
      expect(nodes.single.title, 'Overlook Camp');
      expect(nodes.single.note, 'Worth the stop.');
      expect(nodes.single.coord, _coord);
      expect(saved, hasLength(1));
      expect(saved.single.id, nodes.single.id);
    });

    testWidgets('a blank field is stored as absent, not as an empty string',
        (tester) async {
      // Absence and emptiness are different in the payload — `pruneJson` drops
      // one and carries the other, and an empty title would render as a
      // titled node with no title.
      final (container, _) = await _pumpForm(tester);
      addTearDown(container.dispose);

      await tester.enterText(find.widgetWithText(TextField, 'Title'), '   ');
      await _tap(tester, find.text('Save node'));

      final node = _nodesOf(container).single;
      expect(node.title, isNull);
      expect(node.note, isNull);
      expect(node.poiType, isNull);
      expect(node.narration, isNull);
    });

    testWidgets('the selected kind, amenities and arc stage are carried',
        (tester) async {
      final (container, _) = await _pumpForm(tester);
      addTearDown(container.dispose);

      await _tap(tester, find.widgetWithText(ChoiceChip, 'rest stop'));
      await _tap(tester, find.widgetWithText(FilterChip, 'water'));
      await _tap(tester, find.widgetWithText(FilterChip, 'toilets'));
      await _tap(tester, find.widgetWithText(ChoiceChip, 'crux'));
      await _tap(tester, find.text('Save node'));

      final node = _nodesOf(container).single;
      expect(node.kind, NodeKind.restStop);
      expect(node.amenities, containsAll(['water', 'toilets']));
      expect(node.arcStage, 'crux');
    });

    testWidgets('an amenity can be unselected again', (tester) async {
      final (container, _) = await _pumpForm(tester);
      addTearDown(container.dispose);

      await _tap(tester, find.widgetWithText(FilterChip, 'water'));
      await _tap(tester, find.widgetWithText(FilterChip, 'water'));
      await _tap(tester, find.text('Save node'));

      expect(_nodesOf(container).single.amenities, isEmpty);
    });

    testWidgets('a trigger distance becomes a narration', (tester) async {
      final (container, _) = await _pumpForm(tester);
      addTearDown(container.dispose);

      await tester.enterText(
          find.widgetWithText(TextField, 'Trigger distance (m)'), '150.5');
      await _tap(tester, find.text('Save node'));

      expect(_nodesOf(container).single.narration?.triggerDistanceM, 150.5);
    });

    testWidgets('an unparseable trigger distance is dropped, not crashed on',
        (tester) async {
      final (container, _) = await _pumpForm(tester);
      addTearDown(container.dispose);

      await tester.enterText(
          find.widgetWithText(TextField, 'Trigger distance (m)'), 'soon-ish');
      await _tap(tester, find.text('Save node'));

      expect(tester.takeException(), isNull);
      expect(_nodesOf(container).single.narration, isNull);
    });

    testWidgets('arc stage defaults to none', (tester) async {
      final (container, _) = await _pumpForm(tester);
      addTearDown(container.dispose);

      await _tap(tester, find.text('Save node'));

      expect(_nodesOf(container).single.arcStage, isNull);
    });
  });

  group('revising an existing node', () {
    testWidgets('replaces it rather than adding a second', (tester) async {
      final existing = Node(
          id: 'n1', kind: NodeKind.waypoint, coord: _coord, title: 'Old title');
      final (container, saved) =
          await _pumpForm(tester, existing: existing, nodes: [existing]);
      addTearDown(container.dispose);

      await tester.enterText(
          find.widgetWithText(TextField, 'Title'), 'New title');
      await _tap(tester, find.text('Save node'));

      final nodes = _nodesOf(container);
      expect(nodes, hasLength(1), reason: 'an edit must not duplicate the node');
      expect(nodes.single.id, 'n1', reason: 'the id is the anchor for everything else');
      expect(nodes.single.title, 'New title');
      expect(saved.single.id, 'n1');
    });

    testWidgets('clearing a field removes the value', (tester) async {
      final existing = Node(
          id: 'n1', kind: NodeKind.waypoint, coord: _coord, note: 'Old note');
      final (container, _) =
          await _pumpForm(tester, existing: existing, nodes: [existing]);
      addTearDown(container.dispose);

      await tester.enterText(find.widgetWithText(TextField, 'Note (Markdown)'), '');
      await _tap(tester, find.text('Save node'));

      expect(_nodesOf(container).single.note, isNull);
    });
  });

  group('the form re-seeds when pointed at a different node', () {
    testWidgets('switching nodes replaces the fields', (tester) async {
      // The Content tab drawer keeps one `NodeEditorForm` alive and swaps
      // `existing` under it. Without `didUpdateWidget`, the second node opens
      // showing the first one's text — and saving would write it back.
      _useTallWindow(tester);
      final container = ProviderContainer();
      final first = Node(
          id: 'n1', kind: NodeKind.poi, coord: _coord, title: 'First');
      final second = Node(
          id: 'n2',
          kind: NodeKind.restStop,
          coord: _coord,
          title: 'Second',
          amenities: const ['water']);
      container
          .read(currentTripProvider.notifier)
          .open(_trip(nodes: [first, second]));
      addTearDown(container.dispose);

      Widget host(Node existing) => UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(
                body: NodeEditorForm(
                  dayId: 'd1',
                  segmentId: 's1',
                  coord: _coord,
                  existing: existing,
                  onSaved: (_) {},
                ),
              ),
            ),
          );

      await tester.pumpWidget(host(first));
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget);

      await tester.pumpWidget(host(second));
      await tester.pumpAndSettle();

      expect(find.text('Second'), findsOneWidget);
      expect(find.text('First'), findsNothing);
      final waterChip =
          tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'water'));
      expect(waterChip.selected, isTrue,
          reason: 'amenities must re-seed too, not just the text fields');
    });

    testWidgets('re-pumping the same node leaves an in-progress edit alone',
        (tester) async {
      // A rebuild for any other reason must not discard what the Author is
      // halfway through typing.
      _useTallWindow(tester);
      final container = ProviderContainer();
      final node = Node(id: 'n1', kind: NodeKind.poi, coord: _coord, title: 'First');
      container.read(currentTripProvider.notifier).open(_trip(nodes: [node]));
      addTearDown(container.dispose);

      Widget host() => UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(
                body: NodeEditorForm(
                  dayId: 'd1',
                  segmentId: 's1',
                  coord: _coord,
                  existing: node,
                  onSaved: (_) {},
                ),
              ),
            ),
          );

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'Title'), 'Half-typed edit');
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      expect(find.text('Half-typed edit'), findsOneWidget);
    });
  });

  group('the modal container', () {
    testWidgets('the sheet closes once the node is saved', (tester) async {
      _useTallWindow(tester);
      final container = ProviderContainer();
      container.read(currentTripProvider.notifier).open(_trip());
      addTearDown(container.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showNodeEditorSheet(context,
                    dayId: 'd1', segmentId: 's1', coord: _coord),
                child: const Text('add node'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('add node'));
      await tester.pumpAndSettle();
      expect(find.text('New node'), findsOneWidget);

      await _tap(tester, find.text('Save node'));

      expect(find.text('New node'), findsNothing);
      expect(_nodesOf(container), hasLength(1));
    });
  });
}
