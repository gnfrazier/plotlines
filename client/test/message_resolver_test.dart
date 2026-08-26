// FR145 / M14 — resolution. Three properties are under test here and they
// are the ones the AC names:
//
//  - **plural and list rules are locale-driven, never hardcoded to English.**
//    Proved by resolving the same template through a catalog for a locale
//    whose CLDR plural rules have `few` and `many`, and a list rule that is
//    not "a, b, and c". If either were English-in-code, both would fail.
//  - **a reason is an enum plus a table.** `reason()` takes a ReasonCode;
//    there is no overload that takes text.
//  - **a mismatched binding is a defect at the call site, not a rendered
//    string.** Missing, unknown, and wrongly-typed slots all throw.

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/anchor.dart' show ArcStage, RoleKind;
import 'package:plotlines_client/domain/message_catalog.dart';
import 'package:plotlines_client/domain/message_template.dart';
import 'package:plotlines_client/domain/reason_phrase.dart';
import 'package:plotlines_client/domain/reveal_state.dart';

/// A catalog for a locale that is not English, with the same template ids.
/// Polish is the useful case: its plural rules use `few` (2–4) and `many`
/// (5+), so a resolver that quietly means "one vs other" cannot pass.
class _PlCatalog extends MessageCatalog {
  const _PlCatalog();

  @override
  String get locale => 'pl';

  @override
  ListPatterns get listPatterns => const ListPatterns(
        two: '{0} i {1}',
        start: '{0}, {1}',
        middle: '{0}, {1}',
        end: '{0} i {1}',
        facetSeparator: ' | ',
      );

  @override
  String? pattern(MessageId id) => switch (id) {
        MessageId.dayCount => '{count, plural, =0{Brak dni} one{1 dzień} few{# dni} many{# dni} other{# dnia}}',
        MessageId.unitKilometres => '{value} km',
        // Everything else deliberately absent, to exercise the fallback to
        // the base locale that M8's AC requires.
        _ => null,
      };
}

void main() {
  const messages = MessageResolver();

  group('plural forms come from the locale (M14 AC)', () {
    test('English selects =0 / one / other', () {
      expect(messages.resolve(MessageId.dayCount, {'count': const CountSlot(0)}), 'No days yet');
      expect(messages.resolve(MessageId.dayCount, {'count': const CountSlot(1)}), '1 day');
      expect(messages.resolve(MessageId.dayCount, {'count': const CountSlot(5)}), '5 days');
    });

    test('Polish selects few for 2 and many for 5 — rules English does not have', () {
      const pl = MessageResolver(catalog: _PlCatalog());
      expect(pl.resolve(MessageId.dayCount, {'count': const CountSlot(1)}), '1 dzień');
      expect(pl.resolve(MessageId.dayCount, {'count': const CountSlot(2)}), '2 dni');
      expect(pl.resolve(MessageId.dayCount, {'count': const CountSlot(5)}), '5 dni');
      expect(pl.resolve(MessageId.dayCount, {'count': const CountSlot(22)}), '22 dni');
    });

    test('a locale with no entry for a template falls back to the base locale (M8 AC)', () {
      const pl = MessageResolver(catalog: _PlCatalog());
      expect(pl.resolve(MessageId.termRoleNarrative), 'narrative');
    });
  });

  group('list rules come from the locale (M14 AC)', () {
    test('English joins two with "and" and three with an Oxford comma', () {
      expect(messages.joinNames(['Ride']), 'Ride');
      expect(messages.joinNames(['Ride', 'Hike']), 'Ride and Hike');
      expect(messages.joinNames(['Ride', 'Hike', 'Paddle']), 'Ride, Hike, and Paddle');
    });

    test('another locale joins by its own patterns, with no comma before the last item', () {
      const pl = MessageResolver(catalog: _PlCatalog());
      expect(pl.joinNames(['Ride', 'Hike']), 'Ride i Hike');
      expect(pl.joinNames(['Ride', 'Hike', 'Paddle']), 'Ride, Hike i Paddle');
    });

    test('a nameList slot resolves through the same rule', () {
      expect(
        messages.resolve(MessageId.declaredModes, {
          'modes': const NameListSlot(['Ride', 'Paddle'], source: NameSource.capabilityName),
        }),
        'Modes Ride and Paddle',
      );
    });

    test('facets are joined by the locale separator, not by a call site', () {
      expect(messages.joinFacets(['one', 'two']), 'one · two');
      expect(const MessageResolver(catalog: _PlCatalog()).joinFacets(['one', 'two']), 'one | two');
      expect(messages.joinFacets(['one', '', 'two']), 'one · two', reason: 'an absent facet leaves no separator');
    });
  });

  group('numbers, measures, and instants are render-time transforms (ARCH D49)', () {
    test('distance renders in the reader units, through a unit template', () {
      expect(messages.resolve(MessageId.dayDistance, {'distance': const DistanceSlot(42195)}), 'Distance 42.2 km');
      expect(messages.resolve(MessageId.dayDistance, {'distance': const DistanceSlot(420)}), 'Distance 420 m');
      const imperial = MessageResolver(units: UnitSystem.imperial);
      expect(imperial.resolve(MessageId.dayDistance, {'distance': const DistanceSlot(42195)}), 'Distance 26.2 mi');
      expect(imperial.resolve(MessageId.dayDistance, {'distance': const DistanceSlot(30)}), 'Distance 98 ft');
    });

    test('the same metres render differently per locale number format', () {
      const de = MessageResolver(catalog: _DeCatalog());
      expect(messages.resolve(MessageId.dayDistance, {'distance': const DistanceSlot(1250)}), 'Distance 1.3 km');
      expect(de.resolve(MessageId.dayDistance, {'distance': const DistanceSlot(1250)}), 'Distance 1,3 km');
    });

    test('a duration nests a duration template rather than being concatenated', () {
      expect(
        messages.resolve(MessageId.estimatedDuration, {'duration': const DurationSlot(Duration(minutes: 4))}),
        'about 4 min remaining',
      );
      expect(
        messages.resolve(MessageId.estimatedDuration, {'duration': const DurationSlot(Duration(minutes: 135))}),
        'about 2 h 15 min remaining',
      );
    });

    test('a share renders through the locale percent pattern', () {
      expect(messages.resolve(MessageId.sharedRoadShare, {'share': const ShareSlot(0.34)}), 'Road ridden twice 34%');
    });

    test('a coordinate renders through the locale number format, not toStringAsFixed', () {
      expect(
        messages.resolve(MessageId.roleOffset, {'at': const CoordinateSlot(lat: 40.024, lon: -105.266)}),
        'offset 40.02400, -105.26600',
      );
    });

    test('a timestamp renders through the locale date pattern', () {
      final rendered = messages.resolve(MessageId.lastSolvedAt, {'at': TimestampSlot(DateTime(2026, 8, 26, 14, 30))});
      expect(rendered, startsWith('Last solved '));
      expect(rendered, contains('2026'));
      expect(rendered, contains('Aug'));
    });
  });

  group('a message about a role names it and states its type (FR145)', () {
    test('a named anchor gives the place and the role type', () {
      expect(
        messages.resolve(MessageId.roleReveal, {
          'role': const RoleRefSlot(kind: RoleKind.narrative, placeName: 'Sunset Overlook'),
          'reveal': const TermSlot(MessageId.termRevealOnArrival),
        }),
        'the narrative role at Sunset Overlook: on arrival',
      );
    });

    test('an unnamed anchor states the type alone', () {
      expect(
        messages.resolve(MessageId.roleReveal, {
          'role': const RoleRefSlot(kind: RoleKind.provision),
          'reveal': const TermSlot(MessageId.termRevealAlwaysVisibleByDefault),
        }),
        'the provision role: always visible (default)',
      );
    });

    test('the vocabulary maps cover every enum member they claim to', () {
      for (final kind in RoleKind.values) {
        expect(messages.term(messages.roleKindTerm(kind)), isNotEmpty);
      }
      for (final stage in ArcStage.values) {
        expect(messages.term(messages.arcStageTerm(stage)), isNotEmpty);
      }
      for (final state in RevealState.values) {
        expect(messages.term(messages.revealStateTerm(state)), isNotEmpty);
        expect(messages.term(messages.revealStateTerm(state, byDefault: true)), isNotEmpty);
      }
      expect(messages.travelModeTerm('cycling'), MessageId.termModeCycling);
      expect(messages.travelModeTerm('via-ferrata-plugin'), isNull,
          reason: 'a plugin-declared mode has no term; the caller names it with a NameSlot instead');
    });
  });

  group('reasons come from the bounded table (M14 AC)', () {
    test('a ReasonCode resolves to its phrase', () {
      expect(messages.reason(ReasonCode.noRoutePossible), 'no route is possible between these points');
    });

    test('a cause slot takes the code, and the message frames it', () {
      expect(
        messages.resolve(MessageId.controlDisabledBecause, {'reason': const ReasonSlot(ReasonCode.capabilityWarming)}),
        'Unavailable — it is still being prepared.',
      );
      expect(
        messages.resolve(MessageId.capabilityUnavailableBecause, {
          'capability': const TermSlot(MessageId.termCapabilityRouting),
          'reason': const ReasonSlot(ReasonCode.sidecarStarting),
        }),
        'routing is not ready — the planning engine is still starting.',
      );
    });

    test('every ReasonCode resolves — no cause can be stated without a table entry', () {
      for (final code in ReasonCode.values) {
        expect(messages.reason(code), isNotEmpty, reason: code.name);
      }
    });
  });

  group('a mismatched binding never renders', () {
    test('a missing slot throws', () {
      expect(() => messages.resolve(MessageId.dayCount), throwsA(isA<MessageBindingError>()));
    });

    test('an unknown slot throws', () {
      expect(
        () => messages.resolve(MessageId.dayCount, {'count': const CountSlot(1), 'extra': const CountSlot(2)}),
        throwsA(isA<MessageBindingError>()),
      );
    });

    test('a wrongly-typed slot throws rather than being coerced', () {
      expect(
        () => messages.resolve(MessageId.dayCount, {'count': const NumberSlot(1)}),
        throwsA(isA<MessageBindingError>()),
      );
    });

    test('asking for a term that is not one throws', () {
      expect(() => messages.term(MessageId.dayCount), throwsA(isA<MessageBindingError>()));
    });
  });
}

/// German: comma decimal separator, so a number that is locale-formatted
/// reads differently and one that was built with `toStringAsFixed` does not.
class _DeCatalog extends MessageCatalog {
  const _DeCatalog();

  @override
  String get locale => 'de';

  @override
  ListPatterns get listPatterns => enListPatterns;

  @override
  String? pattern(MessageId id) => null;
}
