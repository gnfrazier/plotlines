// FR145 / M14 with FR40a / H2a — "the TTS path reads templates and resolved
// content separately, never a pre-composed sentence."
//
// The assertion that matters is the ARCH §6A.2 one applied to speech: the
// string handed to the engine must not contain an unrevealed role's content.
// Because a SpeechScript keeps templates and content in different parts,
// that is checkable here — on the utterances themselves, not on the code
// path — which is the same discipline the export byte assertions use, and
// the one they structurally cannot extend to Presentation (ARCH A30).

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/data/reveal_resolver.dart';
import 'package:plotlines_client/data/speech.dart';
import 'package:plotlines_client/domain/anchor.dart';
import 'package:plotlines_client/domain/message_catalog.dart';
import 'package:plotlines_client/domain/message_template.dart';

const _resolver = RevealResolver();
const _messages = MessageResolver();

const _secret = 'The stone marks where the mill burned in 1897.';

Anchor _anchor() => Anchor(
      id: 'a1',
      coord: [-105.266, 40.024],
      title: 'Sunset Overlook',
      roles: [
        Role(
          id: 'r-narrative',
          kind: RoleKind.narrative,
          reveal: RevealPolicy.onArrival,
          title: 'The mill stone',
          note: _secret,
        ),
        Role(
          id: 'r-provision',
          kind: RoleKind.provision,
          title: 'Spring box',
          note: 'Water, year-round.',
        ),
        Role(
          id: 'r-hazard',
          kind: RoleKind.station,
          hazard: true,
          title: 'Loose scree traverse',
          note: 'Fifty metres of moving rock above a drop.',
        ),
      ],
    );

void main() {
  group('a withheld role is never read aloud early (H2a AC)', () {
    test('an unarrived on_arrival role produces no script at all', () {
      final anchor = _anchor();
      final revealed = _resolver.resolve(anchor.roles.first, hasArrived: false, anchorCoord: anchor.coord);
      final script = speechForRole(revealed, placeName: anchor.title);
      expect(script.isEmpty, isTrue);
      expect(script.utterances(_messages), isEmpty);
    });

    test('the withheld content appears in no utterance handed to the engine', () {
      final anchor = _anchor();
      final scripts = speechForAnchor(
        _resolver.resolveAnchor(anchor, hasArrived: false),
        placeName: anchor.title,
        hazardRoleIds: {'r-hazard'},
      );
      final spoken = [for (final s in scripts) ...s.utterances(_messages)].join('\n');
      expect(spoken, isNot(contains(_secret)));
      expect(spoken, isNot(contains('The mill stone')));
      // …and the always-visible roles still speak, so the assertion above is
      // not passing merely because nothing was produced.
      expect(spoken, contains('Water, year-round.'));
    });

    test('a hazard role speaks even before arrival (FR115 — no exception, ever)', () {
      final anchor = _anchor();
      final scripts = speechForAnchor(
        _resolver.resolveAnchor(anchor, hasArrived: false),
        placeName: anchor.title,
        hazardRoleIds: {'r-hazard'},
      );
      final spoken = [for (final s in scripts) ...s.utterances(_messages)];
      expect(spoken, contains('Fifty metres of moving rock above a drop.'));
      // The hazard's own script leads with the warning, so a Character hears
      // what kind of thing this is before they hear the detail (I2a).
      final hazardScript = scripts.singleWhere((s) => s.contentParts.any((c) => c.roleId == 'r-hazard'));
      expect(hazardScript.utterances(_messages).first, startsWith('Hazard.'));
    });
  });

  group('templates and content stay separate (M14 AC)', () {
    test('content is its own part, never interpolated into the lead-in', () {
      final anchor = _anchor();
      final revealed = _resolver.resolve(anchor.roles[1], hasArrived: false, anchorCoord: anchor.coord);
      final script = speechForRole(revealed, placeName: anchor.title);

      expect(script.parts.first, isA<SpokenMessage>());
      expect(script.messageUtterances(_messages), ['Reaching the provision role at Sunset Overlook.']);
      expect(
        script.contentParts.map((c) => c.text),
        ['Spring box', 'Water, year-round.'],
      );
    });

    test('no message utterance ever contains authored content', () {
      final anchor = _anchor();
      for (final revealed in _resolver.resolveAnchor(anchor, hasArrived: true)) {
        final script = speechForRole(revealed, placeName: anchor.title);
        for (final utterance in script.messageUtterances(_messages)) {
          expect(utterance, isNot(contains(_secret)));
          expect(utterance, isNot(contains('The mill stone')));
          expect(utterance, isNot(contains('Spring box')));
        }
      }
    });

    test('every content part names the role that released it, so it can be re-checked', () {
      final anchor = _anchor();
      for (final revealed in _resolver.resolveAnchor(anchor, hasArrived: true)) {
        for (final content in speechForRole(revealed).contentParts) {
          expect(content.roleId, revealed.roleId);
          expect(SpokenContentKind.values, contains(content.kind));
        }
      }
    });

    test('the lead-in names the role and states its type — and nothing else', () {
      final anchor = _anchor();
      final revealed = _resolver.resolve(anchor.roles[1], hasArrived: false, anchorCoord: anchor.coord);
      final lead = speechForRole(revealed).messageUtterances(_messages).single;
      expect(lead, 'Reaching the provision role.');
      expect(lead, isNot(contains('Sunset Overlook')), reason: 'no placeName was given, so none is stated');
    });

    test('an arrived role with no title or note speaks only its lead-in', () {
      final anchor = Anchor(
        id: 'a2',
        coord: [-105.0, 40.0],
        roles: [Role(id: 'r', kind: RoleKind.station, reveal: RevealPolicy.onArrival)],
      );
      final revealed = _resolver.resolve(anchor.roles.single, hasArrived: true, anchorCoord: anchor.coord);
      final script = speechForRole(revealed);
      expect(script.contentParts, isEmpty);
      expect(script.utterances(_messages), ['Reaching the station role.']);
    });
  });

  test('the spoken lead-ins are templates in the registry like any other string', () {
    for (final id in [MessageId.spokenRoleIntroduction, MessageId.spokenHazardWarning]) {
      expect(messageTemplates[id]!.slots.single.type, SlotType.roleRef);
    }
  });
}
