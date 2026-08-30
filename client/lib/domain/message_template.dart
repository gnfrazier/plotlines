/// FR145 / M14 — **a message is a template, not a sentence.** Every
/// user-visible string in the client resolves a *fixed* template against
/// *typed* slots, and this file is the enumeration: [MessageId] names every
/// template, [messageTemplates] declares each one's slots, and [SlotValue]
/// is the closed set of things a slot may ever carry.
///
/// **Why this is a reveal-gate file and not a localization convenience.**
/// ARCH P11 makes [RevealResolver] the single gate every content path
/// crosses, and the punch-list CI gates (§6A.2) assert that unrevealed
/// content never appears in export bytes. A sentence assembled in
/// Presentation — `'$reveal · ${role.note}'` — is downstream of those byte
/// assertions and therefore **a path around the gate they structurally
/// cannot see** (ARCH A30, D57). A template with typed slots is
/// inspectable; a composed sentence is not. That is why the slot set below
/// is closed, why there is no `text`/`freeText`/`content` member of
/// [SlotType], and why the reason for anything is a [ReasonCode] rather
/// than a string a call site wrote.
///
/// **The three rules this file makes structural:**
/// - *No unbounded string slot.* [SlotValue] is `sealed`; every subtype
///   carries a value the app already holds (a count, a distance, a
///   duration, a day index, a timestamp, a coordinate, a share) or a
///   bounded key ([NameSource], [ReasonCode], another [MessageId]). The two
///   subtypes that do carry free-form text — [NameSlot], [NameListSlot] —
///   must declare a [NameSource], and `NameSource` has no member for
///   authored role content and never gains one (`tools/ci/reveal_gate_lint.sh`).
/// - *A message about a role names it and states its type* — [RoleRefSlot],
///   which takes a [RoleKind] and the **anchor's own title**, never
///   `Role.title` / `Role.note` / `Role.media`. Content a surface is allowed
///   to show still travels beside the sentence, not inside it (see
///   `speech.dart` for the TTS shape of exactly that separation).
/// - *Plural and list forms are locale rules, not English string surgery.*
///   The patterns live in ICU MessageFormat form and resolve through
///   `message_catalog.dart`, which is the seam M8's ARB codegen replaces —
///   `lib/l10n/app_en.arb` is generated from this registry today so that
///   replacement is mechanical.
///
/// Zero-slot templates are the app's **vocabulary**: role kinds, reveal
/// states, arc stages, travel modes, capabilities, units, and the reason
/// phrases keyed by [ReasonCode] (`reason_phrase.dart`). They are the only
/// values a [TermSlot] may take, which is what makes "adding a cause means
/// adding a table entry, never writing a sentence at a call site" (M14 AC)
/// true by construction rather than by review.
///
/// Not part of the trip payload schema — this is the presentation
/// vocabulary, not trip content.
library;

import 'anchor.dart' show RoleKind;
import 'reason_phrase.dart' show ReasonCode;

/// The closed set of value kinds a template slot may carry.
///
/// **Deliberately absent, and enforced by `tools/ci/reveal_gate_lint.sh`:**
/// any member meaning "arbitrary text" — `text`, `freeText`, `content`,
/// `note`, `title`, `body`, `prose`. A message with an unbounded string slot
/// fails review (M14 AC); making the failure unrepresentable is cheaper than
/// remembering to look for it.
enum SlotType {
  /// An integer the plural rules of the locale select a form for.
  count,

  /// A bare number rendered through the locale's number format — the value
  /// side of a unit label or a coordinate. Bound by the resolver itself when
  /// it nests a unit or coordinate template, never by a call site.
  number,

  /// A length in metres, rendered through the reader's unit system.
  distance,

  /// An elapsed or estimated time.
  duration,

  /// A 1-based day index within a trip.
  dayIndex,

  /// An instant, rendered through the locale's date/time pattern.
  timestamp,

  /// A latitude/longitude pair the app already holds.
  coordinate,

  /// A fraction in `0.0..1.0`, rendered through the locale's percent pattern.
  share,

  /// One proper noun the app holds, tagged with the [NameSource] it came
  /// from.
  name,

  /// Several [name]s, joined by the locale's list rule — never by a
  /// hardcoded `", "` and `" and "`.
  nameList,

  /// A reference to a role: its [RoleKind] plus, optionally, the name of the
  /// anchor it sits on. Never the role's own authored content.
  roleRef,

  /// A cause drawn from the bounded phrase table (`reason_phrase.dart`).
  reason,

  /// Another template, which must itself declare no slots — the app's own
  /// vocabulary used as a value.
  term,
}

/// Where a [NameSlot]'s text came from. The point of the enum is the
/// exclusion: there is no member for `Role.title`, `Role.note`,
/// `Role.media`, or an Author note, so a name slot cannot be the vehicle
/// that carries authored role content into a sentence (FR145; ARCH A30).
/// Adding a member is the reviewable act — the CI lint fails on any name
/// containing `role`, `note`, `content`, or `body`.
enum NameSource {
  /// The Author's title for the trip.
  tripTitle,

  /// The Author's title for one day.
  dayTitle,

  /// The Author's title for a promoted place (`Anchor.title`) — the *place's*
  /// name, which is what "a message about a role names it" means.
  anchorTitle,

  /// A Character's display name.
  characterName,

  /// A layer's own name, as the layer declares it.
  layerName,

  /// A place name carried on a source feature (OSM `name=*`).
  placeName,

  /// A travel mode, capability, or export format the app itself enumerates.
  capabilityName,

  /// A file the user chose or the app wrote.
  fileName,

  /// The Author's label for an alternate route (`Alternate.label`) — the
  /// alternate's own name, always Character-visible (a fork nobody can see is
  /// not a choice), never a role's title/note/media.
  alternateLabel,
}

/// One value bound to one slot. `sealed`, so the resolver's `switch` is
/// exhaustive and a new value kind cannot be added without a slot type to
/// declare it.
sealed class SlotValue {
  const SlotValue();

  /// The [SlotType] this value satisfies. A binding whose value type does
  /// not match the template's declared slot type is rejected at resolve
  /// time rather than rendered.
  SlotType get type;
}

/// An integer the locale's plural rules select a form for.
final class CountSlot extends SlotValue {
  const CountSlot(this.count);

  final int count;

  @override
  SlotType get type => SlotType.count;
}

/// A number the locale's number format renders — never a call site's
/// `toStringAsFixed`, which is English-decimal-point by construction.
final class NumberSlot extends SlotValue {
  const NumberSlot(this.value, {this.fractionDigits = 0});

  final num value;
  final int fractionDigits;

  @override
  SlotType get type => SlotType.number;
}

/// A length in metres. Metres, not "km" or "mi" — the unit is a render-time
/// transform (ARCH D49), applied by the resolver against the reader's unit
/// system, never frozen into the value.
final class DistanceSlot extends SlotValue {
  const DistanceSlot(this.metres);

  final double metres;

  @override
  SlotType get type => SlotType.distance;
}

/// An elapsed or estimated time.
final class DurationSlot extends SlotValue {
  const DurationSlot(this.duration);

  final Duration duration;

  @override
  SlotType get type => SlotType.duration;
}

/// A 1-based day index within a trip.
final class DayIndexSlot extends SlotValue {
  const DayIndexSlot(this.dayIndex);

  final int dayIndex;

  @override
  SlotType get type => SlotType.dayIndex;
}

/// An instant. Stored and passed as a `DateTime`; the display pattern is the
/// locale's (and the reader's K5 preference), applied at resolve time —
/// never a pre-formatted string (ARCH D49).
final class TimestampSlot extends SlotValue {
  const TimestampSlot(this.at);

  final DateTime at;

  @override
  SlotType get type => SlotType.timestamp;
}

/// A latitude/longitude pair the app already holds — a role offset, an
/// anchor's coord, a bbox corner.
final class CoordinateSlot extends SlotValue {
  const CoordinateSlot({required this.lat, required this.lon});

  final double lat;
  final double lon;

  @override
  SlotType get type => SlotType.coordinate;
}

/// A fraction in `0.0..1.0`, rendered through the locale's percent pattern.
final class ShareSlot extends SlotValue {
  const ShareSlot(this.fraction);

  final double fraction;

  @override
  SlotType get type => SlotType.share;
}

/// One proper noun the app holds, tagged with where it came from.
final class NameSlot extends SlotValue {
  const NameSlot(this.name, {required this.source});

  final String name;
  final NameSource source;

  @override
  SlotType get type => SlotType.name;
}

/// Several names, joined by the locale's list rule at resolve time.
final class NameListSlot extends SlotValue {
  const NameListSlot(this.names, {required this.source});

  final List<String> names;
  final NameSource source;

  @override
  SlotType get type => SlotType.nameList;
}

/// A reference to a role: **what type it is**, and — when the anchor has a
/// title — **which place it is on**. FR145's "a message about a role names
/// it and states its type", made a type rather than a convention.
///
/// [placeName] is `Anchor.title`. It is never `Role.title`, `Role.note`, or
/// any part of `Role.media`: those are content, they pass through
/// [RevealResolver] as content, and they never become part of a sentence.
final class RoleRefSlot extends SlotValue {
  const RoleRefSlot({required this.kind, this.placeName});

  final RoleKind kind;

  /// The **anchor's** title, or `null` for an anchor the Author has not
  /// named — in which case the message states the role's type alone.
  final String? placeName;

  @override
  SlotType get type => SlotType.roleRef;
}

/// A cause, drawn from the bounded phrase table keyed by [ReasonCode].
/// There is no constructor taking a phrase: the only way to state a reason
/// is to have added it to the table (M14 AC).
final class ReasonSlot extends SlotValue {
  const ReasonSlot(this.reason);

  final ReasonCode reason;

  @override
  SlotType get type => SlotType.reason;
}

/// One of the app's own vocabulary templates used as a value. [term] must
/// name a zero-slot template — asserted by [termTemplatesDeclaringSlots].
final class TermSlot extends SlotValue {
  const TermSlot(this.term);

  final MessageId term;

  @override
  SlotType get type => SlotType.term;
}

/// One declared slot on one template: the placeholder name as it appears in
/// the ICU pattern, and the [SlotType] a binding must satisfy.
class MessageSlot {
  const MessageSlot(this.name, this.type);

  final String name;
  final SlotType type;
}

/// One template: an [id], the slots it accepts, and a note on where it is
/// used. The pattern itself lives in the catalog (`message_catalog.dart`),
/// because the pattern is the part that varies by locale and the slot list
/// is the part that does not.
class MessageTemplate {
  const MessageTemplate({required this.id, this.slots = const [], required this.usage});

  final MessageId id;

  /// Empty for a vocabulary term or a reason phrase — the two kinds of
  /// template a [TermSlot] / [ReasonSlot] may resolve to.
  final List<MessageSlot> slots;

  /// What this template is for, in the reviewer's terms. Not user-visible.
  final String usage;

  bool get isTerm => slots.isEmpty;

  MessageSlot? slot(String name) {
    for (final s in slots) {
      if (s.name == name) return s;
    }
    return null;
  }
}

/// Every user-visible template in the client, by id.
///
/// Ordering is by family — vocabulary first, then the messages that consume
/// it — because that is how a reviewer checks the AC's first clause ("every
/// template is enumerable with its slots typed"): read down the list and see
/// the slot types.
enum MessageId {
  // ── Vocabulary: role kinds (FR106) ──────────────────────────────────────
  termRoleNarrative,
  termRoleProvision,
  termRoleStation,

  // ── Vocabulary: reveal states (FR114, FR115) ────────────────────────────
  termRevealAlwaysVisible,
  termRevealAlwaysVisibleByDefault,
  termRevealOnArrival,
  termRevealNotSet,
  termHidden,

  // ── Vocabulary: arc stages (FR38) ───────────────────────────────────────
  termArcExposition,
  termArcRising,
  termArcCrux,
  termArcClimax,
  termArcResolution,

  // ── Vocabulary: travel modes (FR10, FR144) ──────────────────────────────
  termModeCycling,
  termModeHiking,
  termModePaddling,
  termModeCrossCountrySkiing,
  termModePackrafting,
  termModeRiverboarding,
  termModeMountainBiking,
  termModeDriving,
  termModeTransit,

  // ── Vocabulary: capabilities (FR121, M12a) ──────────────────────────────
  termCapabilityTiles,
  termCapabilityLayers,
  termCapabilityRouting,
  termCapabilityElevation,

  // ── Vocabulary: units (rendered, never stored — ARCH D49) ───────────────
  unitKilometres,
  unitMetres,
  unitMiles,
  unitFeet,

  // ── Vocabulary: durations (nested by the resolver, never concatenated) ──
  durationHoursMinutes,
  durationMinutes,

  // ── Reason phrases: the bounded table keyed by ReasonCode ───────────────
  // Failures — aligned name-for-name with M13's typed state enum.
  reasonSidecarStarting,
  reasonSidecarWontStart,
  reasonSidecarDiedMidSession,
  reasonNoRoutePossible,
  reasonNoDataForArea,
  reasonElevationVoidOrMissingTile,
  reasonExternalProviderUnreachable,
  reasonExportFailed,
  reasonCapabilityWarming,
  reasonLayerExtractionFailed,
  reasonPluginLayerUnloadableOnLicence,
  reasonNoClustersFoundInBbox,
  // Deliberately outside M13 (FR118, FR140a, ARCH D53).
  reasonComposeDistanceIsAnOutcome,
  reasonDerivedWorkIsStale,

  // ── Messages about a role — FR145's reveal-gate family ──────────────────
  roleRefNamed,
  roleRefAnonymous,
  roleReveal,
  roleOffset,
  roleOffsetLine,
  roleHazardAlwaysVisible,
  roleArcStage,
  roleWithheldUntilArrival,
  roleVisibleBeforeDeparture,

  // ── Alternates (FR20 [AMENDED v2.0] / C4) ──────────────────────────────
  alternateBranchNotAnEffortOption,

  // ── Counts (plural forms from the locale, never an appended "s") ────────
  dayCount,
  anchorCount,
  candidateCount,
  staleItemCount,

  // ── Measures ────────────────────────────────────────────────────────────
  dayDistance,
  elevationGain,
  realizedDistance,
  sharedRoadShare,

  // ── Time and position ───────────────────────────────────────────────────
  dayLabel,
  lastSolvedAt,
  estimatedDuration,
  coordinateLatLon,

  // ── Lists (joined by the locale's list rule) ────────────────────────────
  declaredModes,

  // ── Spoken (H2a) — the lead-in a content utterance follows ──────────────
  spokenRoleIntroduction,
  spokenHazardWarning,

  // ── Causes: the reason always arrives as a ReasonCode ───────────────────
  controlDisabledBecause,
  operationFailedBecause,
  capabilityUnavailableBecause,
}

const String _slotCount = 'count';
const String _slotDistance = 'distance';
const String _slotRole = 'role';

/// The enumeration itself. Every [MessageId] has an entry; asserted by
/// [messageIdsMissingTemplates].
const Map<MessageId, MessageTemplate> messageTemplates = {
  // Vocabulary — zero slots by definition; these are the values a TermSlot
  // may take, not messages in their own right.
  MessageId.termRoleNarrative: MessageTemplate(id: MessageId.termRoleNarrative, usage: 'RoleKind.narrative'),
  MessageId.termRoleProvision: MessageTemplate(id: MessageId.termRoleProvision, usage: 'RoleKind.provision'),
  MessageId.termRoleStation: MessageTemplate(id: MessageId.termRoleStation, usage: 'RoleKind.station'),
  MessageId.termRevealAlwaysVisible:
      MessageTemplate(id: MessageId.termRevealAlwaysVisible, usage: 'RevealPolicy.alwaysVisible, set by the Author'),
  MessageId.termRevealAlwaysVisibleByDefault: MessageTemplate(
      id: MessageId.termRevealAlwaysVisibleByDefault,
      usage: "FR114 — a provision role the Author left unset, resolved by the engine default"),
  MessageId.termRevealOnArrival: MessageTemplate(id: MessageId.termRevealOnArrival, usage: 'RevealPolicy.onArrival'),
  MessageId.termRevealNotSet: MessageTemplate(
      id: MessageId.termRevealNotSet, usage: "FR114 — narrative/station with no engine default: the Author's choice"),
  MessageId.termHidden: MessageTemplate(
      id: MessageId.termHidden, usage: "PRD P1 — a marker whose content is withheld: 'something is here'"),
  MessageId.termArcExposition: MessageTemplate(id: MessageId.termArcExposition, usage: 'ArcStage.exposition'),
  MessageId.termArcRising: MessageTemplate(id: MessageId.termArcRising, usage: 'ArcStage.rising'),
  MessageId.termArcCrux: MessageTemplate(id: MessageId.termArcCrux, usage: 'ArcStage.crux'),
  MessageId.termArcClimax: MessageTemplate(id: MessageId.termArcClimax, usage: 'ArcStage.climax'),
  MessageId.termArcResolution: MessageTemplate(id: MessageId.termArcResolution, usage: 'ArcStage.resolution'),
  MessageId.termModeCycling: MessageTemplate(id: MessageId.termModeCycling, usage: 'travel mode "cycling"'),
  MessageId.termModeHiking: MessageTemplate(id: MessageId.termModeHiking, usage: 'travel mode "hiking"'),
  MessageId.termModePaddling: MessageTemplate(id: MessageId.termModePaddling, usage: 'travel mode "paddling"'),
  MessageId.termModeCrossCountrySkiing: MessageTemplate(
      id: MessageId.termModeCrossCountrySkiing, usage: 'travel mode "cross_country_skiing"'),
  MessageId.termModePackrafting:
      MessageTemplate(id: MessageId.termModePackrafting, usage: 'travel mode "packrafting"'),
  MessageId.termModeRiverboarding:
      MessageTemplate(id: MessageId.termModeRiverboarding, usage: 'travel mode "riverboarding"'),
  MessageId.termModeMountainBiking:
      MessageTemplate(id: MessageId.termModeMountainBiking, usage: 'travel mode "mountain_biking"'),
  MessageId.termModeDriving: MessageTemplate(id: MessageId.termModeDriving, usage: 'travel mode "driving"'),
  MessageId.termModeTransit: MessageTemplate(id: MessageId.termModeTransit, usage: 'travel mode "transit"'),
  MessageId.termCapabilityTiles: MessageTemplate(id: MessageId.termCapabilityTiles, usage: 'FR121 capability "tiles"'),
  MessageId.termCapabilityLayers:
      MessageTemplate(id: MessageId.termCapabilityLayers, usage: 'FR121 capability "layers"'),
  MessageId.termCapabilityRouting:
      MessageTemplate(id: MessageId.termCapabilityRouting, usage: 'FR121 capability "routing"'),
  MessageId.termCapabilityElevation:
      MessageTemplate(id: MessageId.termCapabilityElevation, usage: 'FR121 capability "elevation"'),

  // Units — the label is a template too, so a locale that writes its units
  // differently changes a pattern rather than a call site.
  MessageId.unitKilometres: MessageTemplate(
      id: MessageId.unitKilometres,
      slots: [MessageSlot('value', SlotType.number)],
      usage: 'metric distance ≥ 1 km'),
  MessageId.unitMetres: MessageTemplate(
      id: MessageId.unitMetres,
      slots: [MessageSlot('value', SlotType.number)],
      usage: 'metric distance < 1 km, and climb'),
  MessageId.unitMiles:
      MessageTemplate(id: MessageId.unitMiles, slots: [MessageSlot('value', SlotType.number)], usage: 'imperial distance'),
  MessageId.unitFeet: MessageTemplate(
      id: MessageId.unitFeet,
      slots: [MessageSlot('value', SlotType.number)],
      usage: 'imperial short distance and climb'),
  MessageId.durationHoursMinutes: MessageTemplate(
      id: MessageId.durationHoursMinutes,
      slots: [MessageSlot('hours', SlotType.number), MessageSlot('minutes', SlotType.number)],
      usage: 'a duration of an hour or more'),
  MessageId.durationMinutes: MessageTemplate(
      id: MessageId.durationMinutes,
      slots: [MessageSlot('minutes', SlotType.number)],
      usage: 'a duration under an hour'),

  // Reason phrases — zero slots, one per ReasonCode (reason_phrase.dart).
  MessageId.reasonSidecarStarting:
      MessageTemplate(id: MessageId.reasonSidecarStarting, usage: 'M13 state: sidecar starting'),
  MessageId.reasonSidecarWontStart:
      MessageTemplate(id: MessageId.reasonSidecarWontStart, usage: "M13 state: sidecar won't start"),
  MessageId.reasonSidecarDiedMidSession:
      MessageTemplate(id: MessageId.reasonSidecarDiedMidSession, usage: 'M13 state: sidecar died mid-session'),
  MessageId.reasonNoRoutePossible:
      MessageTemplate(id: MessageId.reasonNoRoutePossible, usage: 'M13 state: no route possible'),
  MessageId.reasonNoDataForArea:
      MessageTemplate(id: MessageId.reasonNoDataForArea, usage: 'M13 state: no data for the area'),
  MessageId.reasonElevationVoidOrMissingTile:
      MessageTemplate(id: MessageId.reasonElevationVoidOrMissingTile, usage: 'M13 state: elevation void / missing tile'),
  MessageId.reasonExternalProviderUnreachable: MessageTemplate(
      id: MessageId.reasonExternalProviderUnreachable, usage: 'M13 state: external provider unreachable'),
  MessageId.reasonExportFailed: MessageTemplate(id: MessageId.reasonExportFailed, usage: 'M13 state: export failed'),
  MessageId.reasonCapabilityWarming:
      MessageTemplate(id: MessageId.reasonCapabilityWarming, usage: 'M13 state: capability warming (FR121)'),
  MessageId.reasonLayerExtractionFailed:
      MessageTemplate(id: MessageId.reasonLayerExtractionFailed, usage: 'M13 state: layer extraction failed'),
  MessageId.reasonPluginLayerUnloadableOnLicence: MessageTemplate(
      id: MessageId.reasonPluginLayerUnloadableOnLicence,
      usage: 'M13 state: plugin layer unloadable on licence (FR101)'),
  MessageId.reasonNoClustersFoundInBbox:
      MessageTemplate(id: MessageId.reasonNoClustersFoundInBbox, usage: 'M13 state: no clusters found in bbox (FR102)'),
  MessageId.reasonComposeDistanceIsAnOutcome: MessageTemplate(
      id: MessageId.reasonComposeDistanceIsAnOutcome,
      usage: 'FR118 — deliberately NOT an M13 failure state (ARCH D53)'),
  MessageId.reasonDerivedWorkIsStale: MessageTemplate(
      id: MessageId.reasonDerivedWorkIsStale, usage: 'FR140a — deliberately NOT an M13 failure state (ARCH D53)'),

  // Messages about a role. Note what is *not* here: no slot carries the
  // role's title, note, or media. A surface that may show those renders them
  // beside the message, through RevealResolver, as content.
  MessageId.roleRefNamed: MessageTemplate(
      id: MessageId.roleRefNamed,
      slots: [MessageSlot('type', SlotType.term), MessageSlot('place', SlotType.name)],
      usage: 'FR145 — names the role and states its type; "place" is Anchor.title'),
  MessageId.roleRefAnonymous: MessageTemplate(
      id: MessageId.roleRefAnonymous,
      slots: [MessageSlot('type', SlotType.term)],
      usage: 'FR145 — an unnamed anchor: state the type alone'),
  MessageId.roleReveal: MessageTemplate(
      id: MessageId.roleReveal,
      slots: [MessageSlot(_slotRole, SlotType.roleRef), MessageSlot('reveal', SlotType.term)],
      usage: 'FR114 — the resolved reveal state of one role'),
  // The three facets below deliberately do *not* re-state the role: they sit
  // beside [roleReveal], which names it once, joined by
  // [MessageResolver.joinFacets] under the locale's own separator. Each is a
  // whole template — a list of facts, not a sentence assembled from parts.
  MessageId.roleOffset: MessageTemplate(
      id: MessageId.roleOffset,
      slots: [MessageSlot('at', SlotType.coordinate)],
      usage: 'FR107 — where this role triggers, as a tooltip facet'),
  MessageId.roleOffsetLine: MessageTemplate(
      id: MessageId.roleOffsetLine,
      slots: [MessageSlot('type', SlotType.term), MessageSlot('at', SlotType.coordinate)],
      usage: "FR107 — the offset's own line under an anchor card"),
  MessageId.roleHazardAlwaysVisible: MessageTemplate(
      id: MessageId.roleHazardAlwaysVisible, usage: 'FR115 — a hazard role cannot be hidden, on any trip'),
  MessageId.roleArcStage: MessageTemplate(
      id: MessageId.roleArcStage,
      slots: [MessageSlot('arc', SlotType.term)],
      usage: 'FR38 — the arc stage this role carries'),
  MessageId.roleWithheldUntilArrival: MessageTemplate(
      id: MessageId.roleWithheldUntilArrival,
      slots: [MessageSlot(_slotRole, SlotType.roleRef)],
      usage: 'PRD P1 — "something is here", said without saying what'),
  MessageId.roleVisibleBeforeDeparture: MessageTemplate(
      id: MessageId.roleVisibleBeforeDeparture,
      usage: 'O5 — a released role with no title or note of its own'),

  // Alternates.
  MessageId.alternateBranchNotAnEffortOption: MessageTemplate(
      id: MessageId.alternateBranchNotAnEffortOption,
      slots: [MessageSlot('name', SlotType.name)],
      usage: 'FR20 [AMENDED v2.0] / C4, Flow 11 §06 — chooseAlternate refuses a '
          'branch on the H6 effort layer; "name" is Alternate.label'),

  // Counts.
  MessageId.dayCount: MessageTemplate(
      id: MessageId.dayCount, slots: [MessageSlot(_slotCount, SlotType.count)], usage: 'days in a trip'),
  MessageId.anchorCount: MessageTemplate(
      id: MessageId.anchorCount, slots: [MessageSlot(_slotCount, SlotType.count)], usage: 'promoted anchors'),
  MessageId.candidateCount: MessageTemplate(
      id: MessageId.candidateCount, slots: [MessageSlot(_slotCount, SlotType.count)], usage: 'candidates in the bbox'),
  MessageId.staleItemCount: MessageTemplate(
      id: MessageId.staleItemCount,
      slots: [MessageSlot(_slotCount, SlotType.count)],
      usage: 'FR140 — the dashboard count of stale derived work'),

  // Measures.
  MessageId.dayDistance: MessageTemplate(
      id: MessageId.dayDistance, slots: [MessageSlot(_slotDistance, SlotType.distance)], usage: "a day's distance"),
  MessageId.elevationGain: MessageTemplate(
      id: MessageId.elevationGain, slots: [MessageSlot('rise', SlotType.distance)], usage: 'FR85 — climb'),
  MessageId.realizedDistance: MessageTemplate(
      id: MessageId.realizedDistance,
      slots: [MessageSlot(_slotDistance, SlotType.distance)],
      usage: 'FR8a — compose mode reports distance as an outcome'),
  MessageId.sharedRoadShare: MessageTemplate(
      id: MessageId.sharedRoadShare,
      slots: [MessageSlot('share', SlotType.share)],
      usage: 'A9 — the share of a loop ridden twice'),

  // Time and position.
  MessageId.dayLabel: MessageTemplate(
      id: MessageId.dayLabel, slots: [MessageSlot('day', SlotType.dayIndex)], usage: 'the timeline label for one day'),
  MessageId.lastSolvedAt: MessageTemplate(
      id: MessageId.lastSolvedAt, slots: [MessageSlot('at', SlotType.timestamp)], usage: 'when derived work last solved'),
  MessageId.estimatedDuration: MessageTemplate(
      id: MessageId.estimatedDuration,
      slots: [MessageSlot('duration', SlotType.duration)],
      usage: 'FR121 — how long a warming capability still needs'),
  MessageId.coordinateLatLon: MessageTemplate(
      id: MessageId.coordinateLatLon,
      slots: [MessageSlot('lat', SlotType.number), MessageSlot('lon', SlotType.number)],
      usage: 'a lat/lon pair, each side rendered by the locale number format'),

  // Lists.
  MessageId.declaredModes: MessageTemplate(
      id: MessageId.declaredModes,
      slots: [MessageSlot('modes', SlotType.nameList)],
      usage: 'FR144 / N0 — the modes declared at trip initiation'),

  // Spoken lead-ins (H2a). The content itself is never a slot here — it is a
  // separate SpokenContent part (`data/speech.dart`).
  MessageId.spokenRoleIntroduction: MessageTemplate(
      id: MessageId.spokenRoleIntroduction,
      slots: [MessageSlot(_slotRole, SlotType.roleRef)],
      usage: 'FR40a / H2a — what the engine says before released content'),
  MessageId.spokenHazardWarning: MessageTemplate(
      id: MessageId.spokenHazardWarning,
      slots: [MessageSlot(_slotRole, SlotType.roleRef)],
      usage: 'FR115 / I2a — a hazard role leads with a warning'),

  // Causes.
  MessageId.controlDisabledBecause: MessageTemplate(
      id: MessageId.controlDisabledBecause,
      slots: [MessageSlot('reason', SlotType.reason)],
      usage: 'M12a — every disabled control states its reason'),
  MessageId.operationFailedBecause: MessageTemplate(
      id: MessageId.operationFailedBecause,
      slots: [MessageSlot('reason', SlotType.reason)],
      usage: 'M13 — the shared failure surface states its cause'),
  MessageId.capabilityUnavailableBecause: MessageTemplate(
      id: MessageId.capabilityUnavailableBecause,
      slots: [MessageSlot('capability', SlotType.term), MessageSlot('reason', SlotType.reason)],
      usage: 'FR121 — which capability, and why it is not ready'),
};

/// Substrings that must never name a slot or a [SlotType] member —
/// the shapes an unbounded string slot takes when someone adds one
/// (M14 AC; ARCH §15.1's "no template accepts authored text"). The same list
/// drives `tools/ci/reveal_gate_lint.sh`, so the architecture test and the
/// CI gate cannot drift apart in what they consider authored text.
const List<String> authoredTextSlotNames = [
  'text',
  'freetext',
  'content',
  'note',
  'title',
  'body',
  'prose',
  'sentence',
  'description',
];

/// The same rule for [NameSource], minus `title`: a trip's, a day's, or an
/// **anchor's** title is a name the app holds and FR145 explicitly allows a
/// message to state ("a message about a role names it"). What may never
/// become a name source is a *role's* own content.
const List<String> roleContentSourceNames = [
  'role',
  'note',
  'content',
  'media',
  'body',
  'prose',
  'sentence',
];

/// Every [MessageId] with no entry in [messageTemplates] — empty when the
/// enumeration is complete.
List<MessageId> messageIdsMissingTemplates() =>
    [for (final id in MessageId.values) if (!messageTemplates.containsKey(id)) id];

/// Every template whose declared [MessageTemplate.id] disagrees with its key
/// — a copy-paste guard on a `const` map big enough for it to matter.
List<MessageId> misKeyedTemplates() =>
    [for (final entry in messageTemplates.entries) if (entry.value.id != entry.key) entry.key];

/// Every slot whose name reads as authored text — the M14 review rule
/// ("a message with an unbounded string slot fails review") applied to slot
/// *names*, since [SlotType] already makes the value side unrepresentable.
/// Returned as `templateId.slotName` pairs so a failure names the offender.
///
/// `value`, `lat`, and `lon` are [SlotType.number] slots the resolver binds
/// itself when it nests a unit or coordinate template — no call site can
/// reach them.
List<String> slotsNamedLikeAuthoredText() => [
      for (final template in messageTemplates.values)
        for (final slot in template.slots)
          if (authoredTextSlotNames.any((banned) => slot.name.toLowerCase().contains(banned)))
            '${template.id.name}.${slot.name}',
    ];

/// Every [SlotType] or [NameSource] member whose name reads as authored
/// content — the structural half of the same rule. Empty by construction
/// today; the check exists so that adding `SlotType.content` or
/// `NameSource.roleNote` fails a build rather than a code review.
List<String> valueKindsNamedLikeAuthoredText() => [
      for (final type in SlotType.values)
        if (authoredTextSlotNames.any((banned) => type.name.toLowerCase().contains(banned))) 'SlotType.${type.name}',
      for (final source in NameSource.values)
        if (roleContentSourceNames.any((banned) => source.name.toLowerCase().contains(banned)))
          'NameSource.${source.name}',
    ];

/// Every template used as a vocabulary term ([TermSlot]) that declares slots
/// of its own — a term must be resolvable with no bindings, or nesting it
/// inside another message becomes composition again.
List<MessageId> termTemplatesDeclaringSlots() => [
      for (final id in MessageId.values)
        if (id.name.startsWith('term') && !(messageTemplates[id]?.isTerm ?? true)) id,
    ];
