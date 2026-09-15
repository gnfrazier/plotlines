// Issue #399 — FR79's date and clock preferences reach a surface only if the
// surface asks `DisplayFormat` rather than `intl`'s `DateFormat` with a
// pattern of its own. K5 shipped the transform, #312 wired distance, and
// the date/clock half then sat unread on four surfaces because nothing
// stopped a `DateFormat('MMM d')` from landing. This is what stops the
// next one: every `DateFormat(` in `lib/` is either the ISO 8601 stored
// form (ARCH D49 — the *only* pattern a payload may be written with) or one
// of the calendar picker's own chrome patterns, which are named here so
// adding a third is a deliberate edit to this list.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The patterns `intl` may still be asked for, and where.
const _allowed = <String, Set<String>>{
  // The stored/exported form — never a display choice.
  "'yyyy-MM-dd'": {
    'lib/presentation/screens/new_route_screen.dart',
    'lib/presentation/screens/plan_tabs/logistics_tab.dart',
  },
  // Calendar chrome in the date-range picker: a month heading and a per-day
  // screen-reader label are not a date *value* in one of FR79's forms.
  "'MMMM y'": {'lib/presentation/widgets/plot_date_range_picker.dart'},
  "'EEEE, MMMM d, y'": {'lib/presentation/widgets/plot_date_range_picker.dart'},
};

final _call = RegExp(r"DateFormat\(\s*('[^']*')");

void main() {
  test('no presentation surface formats a date with its own intl pattern', () {
    final offenders = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final m in _call.allMatches(lines[i])) {
          final pattern = m.group(1)!;
          final where = _allowed[pattern];
          if (where == null || !where.contains(file.path)) {
            offenders.add('${file.path}:${i + 1}: DateFormat($pattern)');
          }
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'Render dates through DisplayFormat (displayFormatOf(context, ref) '
            'in a widget), not an intl pattern:\n${offenders.join('\n')}');
  });

  test('the allowlist still points at real call sites', () {
    // An entry that matches nothing is a rule that has quietly stopped
    // guarding anything.
    _allowed.forEach((pattern, paths) {
      for (final path in paths) {
        final src = File(path).readAsStringSync();
        expect(src, contains('DateFormat($pattern)'), reason: '$path lost $pattern');
      }
    });
  });
}
