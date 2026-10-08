// Issue #639 — requirement and story ids were part of the Author's screen:
// "POI type (FR5)", "NARRATION TRIGGER (E4 — authoring only)", "NARRATIVE ARC
// (E2 / FR38)", "Assign at least one role (FR106).", a hazard role's
// "cannot be hidden (FR115)", and more. They belong in comments, where this
// codebase cites them on nearly every line, never in a string a surface
// renders. This is what stops the next one.
//
// Scope: every string literal under `lib/presentation/`, plus the domain
// files whose strings are screen copy (the message catalog, profile-field
// descriptions, empty states, teaching). An exception message, a log line or
// a widget key is not screen copy and is skipped; so is a comment.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Domain files whose strings reach the screen as written.
const _copyFiles = [
  'lib/domain/message_catalog.dart',
  'lib/domain/profile_request.dart',
  'lib/domain/empty_state.dart',
  'lib/domain/teaching.dart',
];

/// FR numbers (`FR5`, `FR16a`), story ids (`E4`, `O6`, `H2a`) and spike ids.
final _id = RegExp(r'\b(FR\d+[a-z]?|[A-Q]\d{1,2}[a-z]?|SPIKE-\w+)\b');

/// A single- or double-quoted string literal on one line.
final _literal = RegExp(r"r?'(?:[^'\\\n]|\\.)*'" '|' r'r?"(?:[^"\\\n]|\\.)*"');

/// A line whose strings are never rendered.
final _notCopy = RegExp(
    r'debugPrint\(|throw |StateError\(|ArgumentError\(|FormatException\(|assert\(|Key\(|usage:');

List<String> _offendersIn(File file) {
  final out = <String>[];
  final lines = file.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trimLeft().startsWith('//') || _notCopy.hasMatch(line)) continue;
    for (final m in _literal.allMatches(line)) {
      // Past a `//` outside a string, the rest of the line is a comment.
      if (line.substring(0, m.start).contains('//')) break;
      final hit = _id.firstMatch(m.group(0)!);
      if (hit != null) out.add('${file.path}:${i + 1}: ${hit.group(0)} in ${m.group(0)}');
    }
  }
  return out;
}

void main() {
  test('no string a surface renders carries a requirement or story id', () {
    final files = [
      ...Directory('lib/presentation')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')),
      for (final p in _copyFiles) File(p),
    ];
    final offenders = [for (final f in files) ..._offendersIn(f)];
    expect(offenders, isEmpty,
        reason: 'Requirement ids belong in comments, not on screen (#639):\n'
            '${offenders.join('\n')}');
  });

  test('the gate sees an id when there is one', () {
    final probe = File('${Directory.systemTemp.createTempSync('gate_639_').path}/probe.dart')
      ..writeAsStringSync("const a = Text('POI type (FR5)');\n"
          "// a comment citing FR38 is fine\n"
          "const b = Text('Arc'); // FR38 in a trailing comment is fine\n"
          "throw StateError('draw the area (FR120)');\n");
    addTearDown(() => probe.parent.deleteSync(recursive: true));
    expect(_offendersIn(probe), hasLength(1));
  });

  test('every named copy file exists', () {
    for (final p in _copyFiles) {
      expect(File(p).existsSync(), isTrue, reason: '$p moved; update this gate');
    }
  });
}
