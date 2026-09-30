// #328 — the Route rail is an accordion of Frame / Tune / Refine, one open at
// a time (Tune on open). A test of a control inside another task opens that
// task the way an Author does: by tapping its header.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openRailTask(WidgetTester tester, String task) async {
  final header = find.byKey(ValueKey('rail-task-${task.toLowerCase()}'));
  await tester.ensureVisible(header);
  await tester.tap(find.descendant(of: header, matching: find.byType(InkWell)).first);
  await tester.pumpAndSettle();
}

/// Tune's Surface group is one collapsed row until opened.
Future<void> openSurfaceGroup(WidgetTester tester) async {
  if (find.text('Surface — paved').evaluate().isNotEmpty) return; // already open
  await tester.ensureVisible(find.text('SURFACE'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('SURFACE'));
  await tester.pumpAndSettle();
}

/// Frame's Discipline group is one row naming the current choice until opened.
Future<void> openDisciplineGroup(WidgetTester tester) async {
  if (find.text('CATEGORY DEFAULT').evaluate().isNotEmpty) return; // already open
  await tester.ensureVisible(find.text('DISCIPLINE'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('DISCIPLINE'));
  await tester.pumpAndSettle();
}

/// Tune's Interest group is one row showing its value until opened.
Future<void> openInterestGroup(WidgetTester tester) async {
  if (find.text('Interest — good places').evaluate().isNotEmpty) return; // already open
  await tester.ensureVisible(find.text('INTEREST'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('INTEREST'));
  await tester.pumpAndSettle();
}
