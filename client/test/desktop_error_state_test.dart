// M13 (issue #143) — the typed state enum behind the one shared error
// surface, and the three properties its AC turns on:
//   1. it covers exactly the twelve states M13 names (eight original + four
//      v2.0), each with a defined treatment;
//   2. a failure in an optional enrichment never blocks the app or lets the
//      Author's primary work be discarded;
//   3. compose-mode distance deviation and stale derived work are NOT states
//      here (ARCH D53) — routing them through would teach the Author that
//      ordinary editing produces errors.
// Plus the FR145 alignment: every state's name is a ReasonCode of the same
// name, and its treatment points at that code.

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/desktop_error_state.dart';
import 'package:plotlines_client/domain/reason_phrase.dart';

void main() {
  group('the enum covers exactly M13\'s twelve states, each with a treatment', () {
    test('twelve states, no more, no fewer', () {
      expect(DesktopErrorState.values.length, 12);
    });

    test('every state has a defined treatment', () {
      expect(desktopErrorStatesMissingTreatment(), isEmpty);
      expect(desktopErrorTreatments.length, DesktopErrorState.values.length);
    });

    test('the state names are M13\'s state list from reason_phrase.dart, in order', () {
      expect(
        [for (final s in DesktopErrorState.values) s.name],
        m13States,
      );
    });

    test('the four v2.0 additions are present', () {
      final names = {for (final s in DesktopErrorState.values) s.name};
      expect(
        names,
        containsAll([
          'capabilityWarming',
          'layerExtractionFailed',
          'pluginLayerUnloadableOnLicence',
          'noClustersFoundInBbox',
        ]),
      );
    });

    test('the eight original states are present', () {
      final names = {for (final s in DesktopErrorState.values) s.name};
      expect(
        names,
        containsAll([
          'sidecarStarting',
          'sidecarWontStart',
          'sidecarDiedMidSession',
          'noRoutePossible',
          'noDataForArea',
          'elevationVoidOrMissingTile',
          'externalProviderUnreachable',
          'exportFailed',
        ]),
      );
    });
  });

  group('FR145 alignment with the ReasonCode phrase table', () {
    test('every state has a ReasonCode of the same name, and its treatment points at it', () {
      expect(desktopErrorStatesUnalignedWithReasonCodes(), isEmpty);
    });

    test('every treatment\'s reason has a phrase in the bounded table', () {
      for (final treatment in desktopErrorTreatments.values) {
        expect(reasonPhrases.containsKey(treatment.reason), isTrue,
            reason: treatment.reason.name);
      }
    });
  });

  group('only the pre-sidecar states block the app', () {
    test('sidecarStarting and sidecarWontStart block; nothing else does', () {
      final blocking = [
        for (final entry in desktopErrorTreatments.entries)
          if (entry.value.blocksApp) entry.key,
      ];
      expect(blocking, unorderedEquals([
        DesktopErrorState.sidecarStarting,
        DesktopErrorState.sidecarWontStart,
      ]));
    });

    test('every state preserves the Author\'s already-made primary work', () {
      for (final treatment in desktopErrorTreatments.values) {
        expect(treatment.preservesPrimaryWork, isTrue);
      }
    });
  });

  group('the optional-enrichment invariant (M13 AC)', () {
    test('no optional-enrichment state blocks the app or discards primary work', () {
      expect(desktopErrorStatesBreakingEnrichmentInvariant(), isEmpty);
    });

    test('the optional-enrichment set is exactly the enrichment failures', () {
      final enrichment = {
        for (final entry in desktopErrorTreatments.entries)
          if (entry.value.optionalEnrichment) entry.key,
      };
      expect(enrichment, {
        DesktopErrorState.elevationVoidOrMissingTile,
        DesktopErrorState.externalProviderUnreachable,
        DesktopErrorState.capabilityWarming,
        DesktopErrorState.layerExtractionFailed,
        DesktopErrorState.pluginLayerUnloadableOnLicence,
        DesktopErrorState.noClustersFoundInBbox,
      });
    });
  });

  group('the D53 boundary — two causes sit deliberately outside the enum', () {
    test('no DesktopErrorState is named for compose deviation or stale work', () {
      expect(desktopErrorStatesWronglyIncluded(), isEmpty);
      final names = {for (final s in DesktopErrorState.values) s.name};
      expect(names, isNot(contains('composeDistanceIsAnOutcome')));
      expect(names, isNot(contains('derivedWorkIsStale')));
    });

    test('those two ReasonCodes still exist, but classed advisory and listed outside M13', () {
      for (final code in [ReasonCode.composeDistanceIsAnOutcome, ReasonCode.derivedWorkIsStale]) {
        expect(reasonPhrases[code]!.reasonClass, ReasonClass.advisory);
        expect(reasonCodesOutsideM13, contains(code));
      }
    });
  });

  group('per-state treatment specifics from Author Flows Flow 8', () {
    test('the sidecar-death state degrades over the still-usable app, it does not block', () {
      final t = desktopErrorTreatments[DesktopErrorState.sidecarDiedMidSession]!;
      expect(t.presentation, ErrorSurfacePresentation.bannerOverApp);
      expect(t.blocksApp, isFalse);
      expect(t.retryable, isTrue);
    });

    test('no-clusters-found renders elsewhere (the proposals view), not on this surface', () {
      final t = desktopErrorTreatments[DesktopErrorState.noClustersFoundInBbox]!;
      expect(t.presentation, ErrorSurfacePresentation.elsewhere);
    });

    test('export-failed is a dialog with a retry', () {
      final t = desktopErrorTreatments[DesktopErrorState.exportFailed]!;
      expect(t.presentation, ErrorSurfacePresentation.dialog);
      expect(t.retryable, isTrue);
    });

    test('layer-extraction-failed offers a retry (just that layer); plugin-licence does not', () {
      expect(desktopErrorTreatments[DesktopErrorState.layerExtractionFailed]!.retryable, isTrue);
      expect(desktopErrorTreatments[DesktopErrorState.pluginLayerUnloadableOnLicence]!.retryable,
          isFalse);
    });

    test('no-route-possible is an inline card, not a blocking screen (FR9 relaxations)', () {
      final t = desktopErrorTreatments[DesktopErrorState.noRoutePossible]!;
      expect(t.presentation, ErrorSurfacePresentation.inlineCard);
      expect(t.blocksApp, isFalse);
    });
  });
}
