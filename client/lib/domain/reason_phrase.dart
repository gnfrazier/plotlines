/// FR145 / M14 — **the bounded phrase table.** Where a message must state a
/// cause, the cause arrives as a [ReasonCode] and the phrase comes from
/// [reasonPhrases]. There is no constructor anywhere that takes a reason as
/// text: adding a cause means adding an enum member and a table entry, never
/// writing a sentence at a call site (M14 AC).
///
/// **Alignment with M13.** FR145 requires the enum to align with M13's typed
/// state enum *where the cause is a failure*. M13 (`#143`) is not built yet,
/// so the alignment is declared here instead of imported: [m13States] is
/// M13's state list, verbatim from the PRD's M13 acceptance criteria, and
/// every entry has a [ReasonCode] of the same name — asserted by
/// `reason_phrase_test.dart`. When M13 lands its enum, that test becomes the
/// place the two are pinned to each other, and the table below is already
/// the phrase source its surface needs.
///
/// **The boundary that matters more than the alignment** (ARCH D53, FR118,
/// FR140a): two causes sit deliberately *outside* M13 —
/// [ReasonCode.composeDistanceIsAnOutcome] and
/// [ReasonCode.derivedWorkIsStale]. Compose-mode distance deviation is an
/// editing outcome and stale derived work is pending work the Author caused
/// on purpose; routing either through the failure surface teaches the Author
/// that ordinary editing produces errors. They are [ReasonClass.advisory]
/// here, they are absent from [m13States], and `reason_phrase_test.dart`
/// asserts both — because the natural implementation of "one reason enum" is
/// to put everything in it, and that is exactly the defect D53 names.
///
/// Not part of the trip payload schema.
library;

import 'message_template.dart' show MessageId;

/// What kind of cause a [ReasonCode] is. The class decides which surface may
/// state it, which is why the M13 boundary is expressible rather than
/// remembered.
enum ReasonClass {
  /// A failure. Routes to M13's shared error surface; aligned name-for-name
  /// with M13's typed state enum.
  failure,

  /// Not yet ready — warming, starting. A state on M13's surface, but not a
  /// failure: nothing has gone wrong and nothing needs deciding (FR121).
  pending,

  /// A result or an editing outcome. **Never** routes to M13's failure
  /// surface (ARCH D53).
  advisory,
}

/// Every cause the client may state, ever. Bounded by construction.
enum ReasonCode {
  // ── Aligned with M13's typed state enum ────────────────────────────────
  sidecarStarting,
  sidecarWontStart,
  sidecarDiedMidSession,
  noRoutePossible,
  noDataForArea,
  elevationVoidOrMissingTile,
  externalProviderUnreachable,
  exportFailed,
  capabilityWarming,
  layerExtractionFailed,
  pluginLayerUnloadableOnLicence,
  noClustersFoundInBbox,

  // ── Deliberately outside M13 (ARCH D53) ────────────────────────────────
  composeDistanceIsAnOutcome,
  derivedWorkIsStale,
}

/// One cause's phrase and class. The phrase is a [MessageId], not a string —
/// a reason phrase is a zero-slot template like any other, so it localizes
/// through the same ARB path and can be nested into a message without ever
/// being concatenated.
class ReasonPhrase {
  const ReasonPhrase({required this.phrase, required this.reasonClass});

  /// The zero-slot template that states this cause.
  final MessageId phrase;

  final ReasonClass reasonClass;
}

/// The bounded phrase table. Every [ReasonCode] has exactly one entry;
/// asserted by [reasonCodesMissingPhrases].
const Map<ReasonCode, ReasonPhrase> reasonPhrases = {
  ReasonCode.sidecarStarting:
      ReasonPhrase(phrase: MessageId.reasonSidecarStarting, reasonClass: ReasonClass.pending),
  ReasonCode.sidecarWontStart:
      ReasonPhrase(phrase: MessageId.reasonSidecarWontStart, reasonClass: ReasonClass.failure),
  ReasonCode.sidecarDiedMidSession:
      ReasonPhrase(phrase: MessageId.reasonSidecarDiedMidSession, reasonClass: ReasonClass.failure),
  ReasonCode.noRoutePossible:
      ReasonPhrase(phrase: MessageId.reasonNoRoutePossible, reasonClass: ReasonClass.failure),
  ReasonCode.noDataForArea:
      ReasonPhrase(phrase: MessageId.reasonNoDataForArea, reasonClass: ReasonClass.failure),
  ReasonCode.elevationVoidOrMissingTile:
      ReasonPhrase(phrase: MessageId.reasonElevationVoidOrMissingTile, reasonClass: ReasonClass.failure),
  ReasonCode.externalProviderUnreachable:
      ReasonPhrase(phrase: MessageId.reasonExternalProviderUnreachable, reasonClass: ReasonClass.failure),
  ReasonCode.exportFailed: ReasonPhrase(phrase: MessageId.reasonExportFailed, reasonClass: ReasonClass.failure),
  ReasonCode.capabilityWarming:
      ReasonPhrase(phrase: MessageId.reasonCapabilityWarming, reasonClass: ReasonClass.pending),
  ReasonCode.layerExtractionFailed:
      ReasonPhrase(phrase: MessageId.reasonLayerExtractionFailed, reasonClass: ReasonClass.failure),
  ReasonCode.pluginLayerUnloadableOnLicence:
      ReasonPhrase(phrase: MessageId.reasonPluginLayerUnloadableOnLicence, reasonClass: ReasonClass.failure),

  // FR102 — a *result*, not a failure: the analysis ran and found nothing
  // (PRD §9's empty-state note). It appears on M13's surface because M13's
  // AC lists it, and it is classed as advisory because nothing failed.
  ReasonCode.noClustersFoundInBbox:
      ReasonPhrase(phrase: MessageId.reasonNoClustersFoundInBbox, reasonClass: ReasonClass.advisory),

  ReasonCode.composeDistanceIsAnOutcome:
      ReasonPhrase(phrase: MessageId.reasonComposeDistanceIsAnOutcome, reasonClass: ReasonClass.advisory),
  ReasonCode.derivedWorkIsStale:
      ReasonPhrase(phrase: MessageId.reasonDerivedWorkIsStale, reasonClass: ReasonClass.advisory),
};

/// M13's typed state enum, verbatim from that story's acceptance criteria —
/// the eight original desktop states plus the four added in v2.0. Held here
/// as names rather than as an import because M13 is not built; the moment it
/// is, this list is what pins the two enums together.
const List<String> m13States = [
  'sidecarStarting',
  'sidecarWontStart',
  'sidecarDiedMidSession',
  'noRoutePossible',
  'noDataForArea',
  'elevationVoidOrMissingTile',
  'externalProviderUnreachable',
  'exportFailed',
  'capabilityWarming',
  'layerExtractionFailed',
  'pluginLayerUnloadableOnLicence',
  'noClustersFoundInBbox',
];

/// The two causes that must never reach M13's failure surface (ARCH D53).
const List<ReasonCode> reasonCodesOutsideM13 = [
  ReasonCode.composeDistanceIsAnOutcome,
  ReasonCode.derivedWorkIsStale,
];

/// Every [ReasonCode] with no phrase — empty when the table is complete.
List<ReasonCode> reasonCodesMissingPhrases() =>
    [for (final code in ReasonCode.values) if (!reasonPhrases.containsKey(code)) code];

/// Every M13 state with no [ReasonCode] of the same name — empty when the
/// alignment FR145 requires actually holds.
List<String> m13StatesWithoutReasonCodes() {
  final codeNames = {for (final code in ReasonCode.values) code.name};
  return [for (final state in m13States) if (!codeNames.contains(state)) state];
}

/// Every [ReasonCode] in [reasonCodesOutsideM13] that has nonetheless been
/// listed as an M13 state or classed as a failure — empty while D53 holds.
List<ReasonCode> reasonCodesWronglyInsideM13() => [
      for (final code in reasonCodesOutsideM13)
        if (m13States.contains(code.name) || reasonPhrases[code]?.reasonClass == ReasonClass.failure) code,
    ];
