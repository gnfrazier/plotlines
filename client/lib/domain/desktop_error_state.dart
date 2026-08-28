/// M13 (issue #143) — **the typed state enum behind the one shared error
/// surface.** Every desktop error/empty *failure* state the app can be in is
/// a value here, and every value has a defined treatment in
/// [desktopErrorTreatments]: how it is presented, whether it blocks the app,
/// whether it offers a retry, and whether it is an optional-enrichment
/// failure that must never destroy the Author's primary work.
///
/// **The eight original states plus v2.0's four** (PRD §9 M13 AC, verbatim):
/// sidecar starting / won't start / died mid-session, no route possible, no
/// data for the area, elevation void or missing tile, external provider
/// unreachable, export failed — plus capability-warming (FR121),
/// layer-extraction-failed, plugin-layer-unloadable-on-licence (FR101), and
/// no-clusters-found-in-bbox (FR102).
///
/// **What is deliberately *not* here** (ARCH D53; FR118, FR140a): compose-mode
/// distance deviation and stale derived work. Both are things the Author
/// caused on purpose and both have their own resolutions and their own
/// surfaces — routing either through this enum would teach the Author that
/// ordinary editing produces errors. [desktopErrorStatesExcludedByDesign]
/// names them and `desktop_error_state_test.dart` asserts they never appear
/// as a value here.
///
/// This is the domain half — the enum and the treatment contract. The
/// Presentation half is `presentation/widgets/desktop_error_surface.dart`,
/// which renders any state through this one contract. Not part of the trip
/// payload schema.
library;

import 'reason_phrase.dart' show ReasonCode;

/// One failure/empty state the shared error surface handles. The name of
/// each value matches a [ReasonCode] of the same name (FR145's alignment
/// requirement) and the M13 state list in `reason_phrase.dart`
/// (`m13States`) — pinned by `desktop_error_state_test.dart`.
enum DesktopErrorState {
  /// The sidecar is coming up. An honest escalating wait, not a spinner.
  sidecarStarting,

  /// The sidecar failed to start (and, after the one restart, stayed down
  /// at launch). Full-screen, with a retry.
  sidecarWontStart,

  /// The sidecar was up and exited. Restarted once; a second death degrades
  /// honestly — the trip stays readable.
  sidecarDiedMidSession,

  /// The bands / constraints cannot all hold at once. Named conflict plus
  /// relaxations with their trade-offs (FR9), never a raw "no route found".
  noRoutePossible,

  /// The bbox has no routable OSM coverage at all — no graph to route on.
  noDataForArea,

  /// One or more elevation tiles are void / a DEM tile is missing. Logged
  /// once; never blocks a solve, never raises — climb figures over that
  /// stretch read low, not wrong-shaped.
  elevationVoidOrMissingTile,

  /// An elevation/weather provider is down or rate-limited. The route
  /// already generated; this only narrates the enrichment gap.
  externalProviderUnreachable,

  /// An export write failed (bad path, read-only folder, disk full). The
  /// trip is unchanged and still open.
  exportFailed,

  /// FR121 — a capability (usually routing, waiting on elevation) is still
  /// warming. The reason a control is disabled, with an honest estimate;
  /// never a silent no-op on click.
  capabilityWarming,

  /// A layer's extraction did not finish (a tiled query timed out). The
  /// other layers stay live and usable; retry just this one.
  layerExtractionFailed,

  /// FR101 — a plugin layer declares no usable licence, so it is refused at
  /// registration rather than warned about later: its data would reach
  /// exports and printed sheets with nothing to credit.
  pluginLayerUnloadableOnLicence,

  /// FR102 — co-location analysis ran and found nothing in the bbox. A
  /// *result*, not a failure: it shows in the proposals view with what to
  /// try, not on the error surface itself.
  noClustersFoundInBbox,
}

/// How a state is put on screen. "Same shape whatever failed: what, why,
/// what still works, what to do" (Flow 8 §02) — the shape is constant, the
/// container varies with how much of the app the state implicates.
enum ErrorSurfacePresentation {
  /// Takes the whole window — nothing else is usable yet anyway.
  fullScreenBlock,

  /// A strip above the still-usable app. The trip stays on screen.
  bannerOverApp,

  /// A card in the surface that raised it, sitting alongside the primary
  /// work, never replacing it.
  inlineCard,

  /// A compact one-line notice — the quietest treatment, for a gap that
  /// needs stating but no decision.
  inlineNotice,

  /// A modal dialog with a retry — used only where the action was explicit
  /// (an export) and the result needs acknowledging.
  dialog,

  /// Rendered elsewhere (the proposals view), not on this surface — a
  /// result that belongs with the analysis that produced it.
  elsewhere,
}

/// The defined treatment for one [DesktopErrorState].
class DesktopErrorTreatment {
  const DesktopErrorTreatment({
    required this.presentation,
    required this.reason,
    required this.blocksApp,
    required this.retryable,
    required this.preservesPrimaryWork,
    required this.optionalEnrichment,
  });

  /// The container this state is shown in.
  final ErrorSurfacePresentation presentation;

  /// The aligned cause code — the phrase comes from `reason_phrase.dart`'s
  /// bounded table, never composed at a call site (FR145).
  final ReasonCode reason;

  /// Whether the whole app is blocked while this state holds. Only the two
  /// pre-sidecar states may be `true`.
  final bool blocksApp;

  /// Whether the surface offers a direct retry for this state.
  final bool retryable;

  /// Whether the Author's already-made primary work (a drawn/generated
  /// route, an open trip) survives this state untouched. Must be `true` for
  /// everything except the states where there is no primary work yet.
  final bool preservesPrimaryWork;

  /// Whether this is a failure in an *optional enrichment* — elevation, an
  /// external provider, a plugin layer, co-location analysis, a warming
  /// capability. M13's invariant: an optional-enrichment failure never
  /// blocks generation and never discards the route, so for these
  /// [blocksApp] is always `false` and [preservesPrimaryWork] always `true`.
  final bool optionalEnrichment;
}

/// Every [DesktopErrorState] with its defined treatment. Complete by
/// construction — asserted by [desktopErrorStatesMissingTreatment].
const Map<DesktopErrorState, DesktopErrorTreatment> desktopErrorTreatments = {
  DesktopErrorState.sidecarStarting: DesktopErrorTreatment(
    presentation: ErrorSurfacePresentation.fullScreenBlock,
    reason: ReasonCode.sidecarStarting,
    blocksApp: true,
    retryable: false,
    preservesPrimaryWork: true,
    optionalEnrichment: false,
  ),
  DesktopErrorState.sidecarWontStart: DesktopErrorTreatment(
    presentation: ErrorSurfacePresentation.fullScreenBlock,
    reason: ReasonCode.sidecarWontStart,
    blocksApp: true,
    retryable: true,
    preservesPrimaryWork: true,
    optionalEnrichment: false,
  ),
  DesktopErrorState.sidecarDiedMidSession: DesktopErrorTreatment(
    presentation: ErrorSurfacePresentation.bannerOverApp,
    reason: ReasonCode.sidecarDiedMidSession,
    blocksApp: false,
    retryable: true,
    preservesPrimaryWork: true,
    optionalEnrichment: false,
  ),
  DesktopErrorState.noRoutePossible: DesktopErrorTreatment(
    presentation: ErrorSurfacePresentation.inlineCard,
    reason: ReasonCode.noRoutePossible,
    blocksApp: false,
    retryable: false,
    preservesPrimaryWork: true,
    optionalEnrichment: false,
  ),
  DesktopErrorState.noDataForArea: DesktopErrorTreatment(
    presentation: ErrorSurfacePresentation.inlineCard,
    reason: ReasonCode.noDataForArea,
    blocksApp: false,
    retryable: false,
    preservesPrimaryWork: true,
    optionalEnrichment: false,
  ),
  DesktopErrorState.elevationVoidOrMissingTile: DesktopErrorTreatment(
    presentation: ErrorSurfacePresentation.inlineNotice,
    reason: ReasonCode.elevationVoidOrMissingTile,
    blocksApp: false,
    retryable: false,
    preservesPrimaryWork: true,
    optionalEnrichment: true,
  ),
  DesktopErrorState.externalProviderUnreachable: DesktopErrorTreatment(
    presentation: ErrorSurfacePresentation.inlineNotice,
    reason: ReasonCode.externalProviderUnreachable,
    blocksApp: false,
    retryable: false,
    preservesPrimaryWork: true,
    optionalEnrichment: true,
  ),
  DesktopErrorState.exportFailed: DesktopErrorTreatment(
    presentation: ErrorSurfacePresentation.dialog,
    reason: ReasonCode.exportFailed,
    blocksApp: false,
    retryable: true,
    preservesPrimaryWork: true,
    optionalEnrichment: false,
  ),
  DesktopErrorState.capabilityWarming: DesktopErrorTreatment(
    presentation: ErrorSurfacePresentation.inlineNotice,
    reason: ReasonCode.capabilityWarming,
    blocksApp: false,
    retryable: false,
    preservesPrimaryWork: true,
    optionalEnrichment: true,
  ),
  DesktopErrorState.layerExtractionFailed: DesktopErrorTreatment(
    presentation: ErrorSurfacePresentation.inlineCard,
    reason: ReasonCode.layerExtractionFailed,
    blocksApp: false,
    retryable: true,
    preservesPrimaryWork: true,
    optionalEnrichment: true,
  ),
  DesktopErrorState.pluginLayerUnloadableOnLicence: DesktopErrorTreatment(
    presentation: ErrorSurfacePresentation.inlineCard,
    reason: ReasonCode.pluginLayerUnloadableOnLicence,
    blocksApp: false,
    retryable: false,
    preservesPrimaryWork: true,
    optionalEnrichment: true,
  ),
  DesktopErrorState.noClustersFoundInBbox: DesktopErrorTreatment(
    presentation: ErrorSurfacePresentation.elsewhere,
    reason: ReasonCode.noClustersFoundInBbox,
    blocksApp: false,
    retryable: false,
    preservesPrimaryWork: true,
    optionalEnrichment: true,
  ),
};

/// The two causes that must never be a [DesktopErrorState] (ARCH D53). Held
/// as names so the assertion is "no enum value is named this", which is the
/// property that actually matters.
const List<String> desktopErrorStatesExcludedByDesign = [
  'composeDistanceIsAnOutcome',
  'derivedWorkIsStale',
];

/// Every [DesktopErrorState] with no entry in [desktopErrorTreatments] —
/// empty when the table is complete.
List<DesktopErrorState> desktopErrorStatesMissingTreatment() => [
      for (final state in DesktopErrorState.values)
        if (!desktopErrorTreatments.containsKey(state)) state,
    ];

/// Every optional-enrichment state whose treatment nonetheless blocks the
/// app or lets primary work be discarded — empty while M13's invariant
/// holds ("a failure in an optional enrichment never blocks generation or
/// discards the route").
List<DesktopErrorState> desktopErrorStatesBreakingEnrichmentInvariant() => [
      for (final entry in desktopErrorTreatments.entries)
        if (entry.value.optionalEnrichment &&
            (entry.value.blocksApp || !entry.value.preservesPrimaryWork))
          entry.key,
    ];

/// Every [DesktopErrorState] whose name has no matching [ReasonCode], or
/// whose treatment's [DesktopErrorTreatment.reason] is not the code of the
/// same name — empty while the FR145 alignment holds.
List<DesktopErrorState> desktopErrorStatesUnalignedWithReasonCodes() {
  final codeByName = {for (final code in ReasonCode.values) code.name: code};
  return [
    for (final state in DesktopErrorState.values)
      if (codeByName[state.name] == null ||
          desktopErrorTreatments[state]?.reason != codeByName[state.name])
        state,
  ];
}

/// Any name in [desktopErrorStatesExcludedByDesign] that has nonetheless
/// been added as a [DesktopErrorState] — empty while D53 holds.
List<String> desktopErrorStatesWronglyIncluded() {
  final names = {for (final state in DesktopErrorState.values) state.name};
  return [
    for (final excluded in desktopErrorStatesExcludedByDesign)
      if (names.contains(excluded)) excluded,
  ];
}
