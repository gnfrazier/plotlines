// FR145 / M14 — the enumeration itself. "Every template is enumerable with
// its slots typed" is only worth anything if something checks it, and these
// are the checks: the registry is complete, no slot is unbounded, every
// pattern's placeholders are exactly the declared slots, and a term is
// resolvable with no bindings.
//
// The negative assertions matter more than the positive ones here. A
// template with an unbounded string slot is the reveal-leak path the export
// byte assertions structurally cannot see (ARCH A30) — so `SlotType` having
// no free-text member is asserted, not assumed.

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/anchor.dart' show RoleKind;
import 'package:plotlines_client/domain/message_catalog.dart';
import 'package:plotlines_client/domain/message_template.dart';
import 'package:plotlines_client/domain/empty_state.dart';
import 'package:plotlines_client/domain/reason_phrase.dart';
import 'package:plotlines_client/domain/teaching.dart';

/// Placeholder names in an ICU pattern: `{name}` and `{name, plural, ...}`,
/// but not a plural branch's body (`one{1 day}` is not a placeholder).
Set<String> _placeholders(String pattern) =>
    RegExp(r'\{(\w+)[},]').allMatches(pattern).map((m) => m.group(1)!).toSet();

void main() {
  group('the enumeration (M14 AC: every template is enumerable)', () {
    test('every MessageId has a template and every template is keyed by its own id', () {
      expect(messageIdsMissingTemplates(), isEmpty);
      expect(misKeyedTemplates(), isEmpty);
    });

    test('every MessageId has a base-locale pattern, and no pattern is orphaned', () {
      final missing = [for (final id in MessageId.values) if (!baseLocalePatterns.containsKey(id)) id];
      expect(missing, isEmpty, reason: 'a template with no pattern renders nothing');
      expect(baseLocalePatterns.keys.toSet(), MessageId.values.toSet());
    });

    test('no pattern is empty', () {
      for (final entry in baseLocalePatterns.entries) {
        expect(entry.value.trim(), isNotEmpty, reason: entry.key.name);
      }
    });
  });

  group('slots are typed and bounded (M14 AC: an unbounded string slot fails review)', () {
    test('SlotType and NameSource have no free-text member', () {
      expect(valueKindsNamedLikeAuthoredText(), isEmpty);
    });

    test('no declared slot is named after an authored text field', () {
      expect(slotsNamedLikeAuthoredText(), isEmpty);
    });

    test('every SlotValue subtype reports the SlotType it satisfies', () {
      const values = <SlotValue>[
        CountSlot(3),
        NumberSlot(1.5),
        DistanceSlot(1200),
        DurationSlot(Duration(minutes: 90)),
        DayIndexSlot(2),
        CoordinateSlot(lat: 40.0, lon: -105.0),
        ShareSlot(0.25),
        NameSlot('Sunset Overlook', source: NameSource.anchorTitle),
        NameListSlot(['Ride', 'Hike'], source: NameSource.capabilityName),
        ReasonSlot(ReasonCode.noRoutePossible),
        TermSlot(MessageId.termRoleNarrative),
        RoleRefSlot(kind: RoleKind.narrative),
      ];
      // No two value kinds may claim the same SlotType — that is what keeps
      // the resolver's type check meaningful rather than decorative.
      expect(values.map((v) => v.type).toSet().length, values.length);
      expect(TimestampSlot(DateTime(2026)).type, SlotType.timestamp);
    });
  });

  group('patterns and slots agree', () {
    test('every declared slot appears in its pattern', () {
      for (final template in messageTemplates.values) {
        final pattern = baseLocalePatterns[template.id]!;
        for (final slot in template.slots) {
          expect(_placeholders(pattern), contains(slot.name),
              reason: '${template.id.name} declares "${slot.name}" but the pattern never uses it');
        }
      }
    });

    test('no pattern uses a placeholder the template does not declare', () {
      for (final template in messageTemplates.values) {
        final pattern = baseLocalePatterns[template.id]!;
        for (final placeholder in _placeholders(pattern)) {
          expect(template.slot(placeholder), isNotNull,
              reason: '${template.id.name} interpolates "$placeholder", which is not a declared slot — '
                  'an undeclared placeholder is exactly the unbounded slot FR145 forbids');
        }
      }
    });

    test('a zero-slot template interpolates nothing', () {
      for (final template in messageTemplates.values.where((t) => t.isTerm)) {
        expect(_placeholders(baseLocalePatterns[template.id]!), isEmpty, reason: template.id.name);
      }
    });
  });

  group('vocabulary terms', () {
    test('every term template declares no slots', () {
      expect(termTemplatesDeclaringSlots(), isEmpty);
    });

    test('every value a TermSlot may take resolves with no bindings', () {
      const messages = MessageResolver();
      for (final id in MessageId.values.where((id) => messageTemplates[id]!.isTerm)) {
        expect(messages.term(id), isNotEmpty, reason: id.name);
      }
    });

    test('every reason phrase is a zero-slot template', () {
      for (final phrase in reasonPhrases.values) {
        expect(messageTemplates[phrase.phrase]!.isTerm, isTrue, reason: phrase.phrase.name);
      }
    });
  });

  // FR142(c) and FR142(e) each carry their own copy registry, written before
  // M14 and left in place by it: an empty state's next action and a teaching
  // block's explanation are fixed strings with no slots, which is a template
  // with an empty slot list. What M14 adds is the check — a `$` in either
  // registry means someone started composing at the call site, which is the
  // moment the sibling registries stop satisfying FR145.
  group('the sibling copy registries hold fixed strings, not compositions', () {
    test('no empty-state string interpolates anything', () {
      for (final entry in emptyStateRegistry.entries) {
        expect(entry.value.message, isNot(contains(r'$')), reason: entry.key.name);
        expect(entry.value.nextAction, isNot(contains(r'$')), reason: entry.key.name);
      }
    });

    test('no teaching string interpolates anything', () {
      for (final entry in teachingRegistry.entries) {
        expect(entry.value.message, isNot(contains(r'$')), reason: entry.key.name);
      }
    });
  });
}
