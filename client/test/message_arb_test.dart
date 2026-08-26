// FR145 / M14, on M8's ARB framework — the committed ARB is a projection of
// the registry, not a hand-kept copy of it.
//
// M8 (#136) will generate `AppLocalizations` *from* the ARB; until then the
// registry generates the ARB. Either direction, the failure mode is the
// same: a template added in Dart and never extracted is an unlocalizable
// string that ships. This test is what makes that a failing build instead.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/message_catalog.dart';
import 'package:plotlines_client/domain/message_template.dart';

void main() {
  final file = File('lib/l10n/app_en.arb');

  test('the committed ARB matches the registry — run tool/gen_message_arb.dart', () {
    expect(file.existsSync(), isTrue, reason: 'lib/l10n/app_en.arb is missing');
    expect(
      file.readAsStringSync(),
      messageArbSource(),
      reason: 'the ARB has drifted from the message registry; regenerate it with '
          '`dart run tool/gen_message_arb.dart`',
    );
  });

  test('the ARB is valid JSON, declares its locale, and covers every template', () {
    final arb = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(arb['@@locale'], 'en');
    final keys = arb.keys.where((k) => !k.startsWith('@')).toSet();
    expect(keys, MessageId.values.map((id) => id.name).toSet());
  });

  test('every ARB entry declares exactly the placeholders its template does, with a type', () {
    final arb = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    for (final template in messageTemplates.values) {
      final meta = arb['@${template.id.name}'] as Map<String, dynamic>;
      final placeholders = (meta['placeholders'] as Map<String, dynamic>?) ?? const {};
      expect(placeholders.keys.toSet(), template.slots.map((s) => s.name).toSet(), reason: template.id.name);
      for (final slot in template.slots) {
        final declared = placeholders[slot.name] as Map<String, dynamic>;
        expect(declared['type'], arbPlaceholderType(slot.type), reason: '${template.id.name}.${slot.name}');
        // The slot type travels alongside the ARB type so a reviewer reading
        // the ARB alone can still see that no slot is authored text.
        expect(declared['x-slot-type'], slot.type.name);
      }
    }
  });

  test('no ARB placeholder is typed as free-form authored text', () {
    final arb = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    for (final key in arb.keys.where((k) => k.startsWith('@') && !k.startsWith('@@'))) {
      final placeholders = ((arb[key] as Map<String, dynamic>)['placeholders'] as Map<String, dynamic>?) ?? const {};
      for (final entry in placeholders.entries) {
        final slotType = (entry.value as Map<String, dynamic>)['x-slot-type'] as String;
        expect(authoredTextSlotNames.any((banned) => slotType.contains(banned)), isFalse,
            reason: '$key.${entry.key} is typed $slotType');
      }
    }
  });
}
