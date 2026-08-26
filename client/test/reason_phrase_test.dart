// FR145 / M14 — the bounded phrase table, and the two boundaries it has to
// hold.
//
// The first is the alignment FR145 asks for: where a cause is a failure, the
// enum aligns with M13's typed state enum. M13 (#143) is not built, so the
// alignment is pinned to `m13States` — the state list from M13's own AC.
//
// The second matters more, because the natural implementation gets it wrong.
// "One reason enum" invites putting *every* cause in it and routing them all
// to the shared error surface. ARCH D53 forbids exactly that for two of
// them: compose-mode distance deviation (FR118) and stale derived work
// (FR140a) are not failures, and teaching an Author that ordinary editing
// produces errors is the defect. Those two are asserted out.

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/message_catalog.dart';
import 'package:plotlines_client/domain/message_template.dart';
import 'package:plotlines_client/domain/reason_phrase.dart';

void main() {
  group('the table is bounded and complete (M14 AC)', () {
    test('every ReasonCode has exactly one phrase', () {
      expect(reasonCodesMissingPhrases(), isEmpty);
      expect(reasonPhrases.length, ReasonCode.values.length);
    });

    test('every phrase names a template that exists', () {
      for (final phrase in reasonPhrases.values) {
        expect(messageTemplates.containsKey(phrase.phrase), isTrue, reason: phrase.phrase.name);
        expect(baseLocalePatterns[phrase.phrase], isNotNull);
      }
    });

    test('no two causes share a phrase — a table entry per cause, as the AC requires', () {
      final phrases = reasonPhrases.values.map((p) => p.phrase).toList();
      expect(phrases.toSet().length, phrases.length);
    });
  });

  group('alignment with M13 (FR145: where the cause is a failure)', () {
    test('every M13 state has a ReasonCode of the same name', () {
      expect(m13StatesWithoutReasonCodes(), isEmpty);
    });

    test('M13 carries all twelve of its states — the eight original plus v2.0\'s four', () {
      expect(m13States.length, 12);
      expect(
        m13States,
        containsAll([
          'capabilityWarming',
          'layerExtractionFailed',
          'pluginLayerUnloadableOnLicence',
          'noClustersFoundInBbox',
        ]),
      );
    });

    test('a sidecar that will not start is a failure; one still starting is not', () {
      expect(reasonPhrases[ReasonCode.sidecarWontStart]!.reasonClass, ReasonClass.failure);
      expect(reasonPhrases[ReasonCode.sidecarStarting]!.reasonClass, ReasonClass.pending);
      expect(reasonPhrases[ReasonCode.capabilityWarming]!.reasonClass, ReasonClass.pending);
    });
  });

  group('the D53 boundary — two causes sit deliberately outside M13', () {
    test('compose-mode distance and stale work are neither M13 states nor failures', () {
      expect(reasonCodesWronglyInsideM13(), isEmpty);
      for (final code in reasonCodesOutsideM13) {
        expect(m13States, isNot(contains(code.name)));
        expect(reasonPhrases[code]!.reasonClass, ReasonClass.advisory);
      }
    });

    test('the two are exactly the ones FR118 and FR140a name', () {
      expect(reasonCodesOutsideM13,
          [ReasonCode.composeDistanceIsAnOutcome, ReasonCode.derivedWorkIsStale]);
    });

    test('their phrases do not read as failures', () {
      const messages = MessageResolver();
      for (final code in reasonCodesOutsideM13) {
        final phrase = messages.reason(code).toLowerCase();
        for (final failureWord in ['error', 'failed', 'could not', 'unable']) {
          expect(phrase, isNot(contains(failureWord)),
              reason: '${code.name} is pending or reported work, not a failure (ARCH D53)');
        }
      }
    });
  });

  test('a cause can only be stated by adding a table entry — there is no text path', () {
    // ReasonSlot's only constructor takes a ReasonCode; the resolver's only
    // reason entry point takes one too. This test is the compile-time
    // guarantee written down, plus the runtime half: an unmapped code would
    // throw rather than render a blank.
    const messages = MessageResolver();
    for (final code in ReasonCode.values) {
      expect(const ReasonSlot(ReasonCode.exportFailed).type, SlotType.reason);
      expect(messages.resolve(MessageId.operationFailedBecause, {'reason': ReasonSlot(code)}), contains('—'));
    }
  });
}
