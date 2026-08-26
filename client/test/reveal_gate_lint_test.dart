// FR145 / M14 and punch list §6A.1 — the CI gate, run locally.
//
// `tools/ci/reveal_gate_lint.sh` is the enforcement; this test is how a
// developer finds out before pushing, and — more importantly — how the gate
// itself is verified. A grep-based gate that silently matches nothing is
// worse than no gate, so each rule is exercised against a fixture that
// violates it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `flutter test` runs with the client package as its working directory.
final Directory _repoRoot = Directory.current.parent;
final String _lint = '${_repoRoot.path}/tools/ci/reveal_gate_lint.sh';

ProcessResult _runLint(String root) => Process.runSync('bash', [_lint, root]);

/// A minimal repo shape the lint can run against: the real registry files
/// (so the slot-vocabulary rules have something to read) plus whatever
/// Presentation source the test wants to plant.
Directory _fixtureRoot({String presentation = '', String? templatesOverride}) {
  final root = Directory.systemTemp.createTempSync('reveal_gate_lint');
  addTearDown(() => root.deleteSync(recursive: true));
  Directory('${root.path}/client/lib/presentation').createSync(recursive: true);
  Directory('${root.path}/client/lib/domain').createSync(recursive: true);
  final templates = File('lib/domain/message_template.dart').readAsStringSync();
  File('${root.path}/client/lib/domain/message_template.dart')
      .writeAsStringSync(templatesOverride ?? templates);
  File('${root.path}/client/lib/domain/reason_phrase.dart')
      .writeAsStringSync(File('lib/domain/reason_phrase.dart').readAsStringSync());
  if (presentation.isNotEmpty) {
    File('${root.path}/client/lib/presentation/suspect.dart').writeAsStringSync(presentation);
  }
  return root;
}

void main() {
  test('the lint script exists and is executable', () {
    expect(File(_lint).existsSync(), isTrue);
  });

  test('the repository passes both gates today', () {
    final result = _runLint(_repoRoot.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stdout, contains('OK:'));
  });

  group('gate 1 — role content in Presentation', () {
    test('a direct read of Role.note fails', () {
      final root = _fixtureRoot(presentation: "Widget b() => Text(role.note ?? '');\n");
      final result = _runLint(root.path);
      expect(result.exitCode, 1);
      expect(result.stdout, contains('RevealResolver'));
    });

    test('reaching content through .roles fails', () {
      final root = _fixtureRoot(presentation: 'final t = anchor.roles.first.title;\n');
      final result = _runLint(root.path);
      expect(result.exitCode, 1);
    });

    test('role metadata is not content — kind, reveal, hazard, arc and coord pass', () {
      final root = _fixtureRoot(
        presentation: 'final k = role.kind;\nfinal r = role.reveal;\n'
            'final h = role.hazard;\nfinal a = role.arc;\nfinal c = role.coord;\n',
      );
      expect(_runLint(root.path).exitCode, 0);
    });

    test('a RevealedRole read passes — that is the whole point of resolving one', () {
      final root = _fixtureRoot(presentation: "final t = revealed.title ?? revealed.note ?? '';\n");
      expect(_runLint(root.path).exitCode, 0);
    });
  });

  group('gate 2 — authored text as a slot value', () {
    test('a free-text SlotType member fails', () {
      final templates = File('lib/domain/message_template.dart')
          .readAsStringSync()
          .replaceFirst('enum SlotType {', 'enum SlotType {\n  freeText,');
      final root = _fixtureRoot(templatesOverride: templates);
      final result = _runLint(root.path);
      expect(result.exitCode, 1);
      expect(result.stdout, contains('free-text member'));
    });

    test('a NameSource sourced from role content fails', () {
      final templates = File('lib/domain/message_template.dart')
          .readAsStringSync()
          .replaceFirst('enum NameSource {', 'enum NameSource {\n  roleNote,');
      final root = _fixtureRoot(templatesOverride: templates);
      final result = _runLint(root.path);
      expect(result.exitCode, 1);
      expect(result.stdout, contains('role content'));
    });

    test('a slot named after an authored field fails', () {
      final templates = File('lib/domain/message_template.dart')
          .readAsStringSync()
          .replaceFirst("MessageSlot('reveal', SlotType.term)", "MessageSlot('noteText', SlotType.term)");
      final root = _fixtureRoot(templatesOverride: templates);
      final result = _runLint(root.path);
      expect(result.exitCode, 1);
      expect(result.stdout, contains('authored text field'));
    });

    test('binding a role note into a slot value fails', () {
      final root = _fixtureRoot(presentation: "final s = NameSlot(role.note!, source: NameSource.placeName);\n");
      final result = _runLint(root.path);
      expect(result.exitCode, 1);
    });

    test('resolving a message with a role title as an argument fails', () {
      final root = _fixtureRoot(presentation: "messages.resolve(MessageId.dayLabel, {'x': role.title});\n");
      final result = _runLint(root.path);
      expect(result.exitCode, 1);
    });
  });

  group('gate 3 — reason phrases', () {
    test('constructing a ReasonPhrase outside the table fails', () {
      final root = _fixtureRoot(
        presentation: 'const p = ReasonPhrase(phrase: MessageId.reasonExportFailed, '
            'reasonClass: ReasonClass.failure);\n',
      );
      final result = _runLint(root.path);
      expect(result.exitCode, 1);
      expect(result.stdout, contains('bounded table'));
    });
  });

  test('a missing path is a failure, not a silent pass', () {
    final root = Directory.systemTemp.createTempSync('reveal_gate_lint_empty');
    addTearDown(() => root.deleteSync(recursive: true));
    expect(_runLint(root.path).exitCode, 1);
  });
}
