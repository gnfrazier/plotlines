/// FR145 / M14 — the resolution half of the template seam: the base-locale
/// **patterns**, the **locale rules** that turn typed slots into text, and
/// the ARB projection M8 will take over.
///
/// [messageTemplates] (`message_template.dart`) declares *what* each message
/// accepts; this file holds *how* it reads in one locale, in ICU
/// MessageFormat form — the same form ARB files carry. Plural selection runs
/// through `package:intl`'s [MessageFormat], so `one`/`other` (and `few`,
/// `many`, `two`, `zero` where a locale has them) come from CLDR rather than
/// from an appended `s`. Numbers, percentages, and dates run through
/// [NumberFormat] / [DateFormat] for the same reason: a decimal comma is a
/// locale rule, and `toStringAsFixed` does not know that.
///
/// **List rules are a table, not English.** `package:intl` has no list
/// formatter, so [ListPatterns] carries the CLDR shape (`two` / `start` /
/// `middle` / `end`) per locale. Adding a locale adds a table entry; no call
/// site ever writes `", "` and `" and "` again.
///
/// **The M8 seam.** [MessageCatalog] is the interface M8's generated
/// `AppLocalizations` implements: give it a locale's patterns and everything
/// downstream — including every call site — is unchanged.
/// [messageArbSource] projects this registry into `lib/l10n/app_en.arb` so
/// M8's extraction step starts from a complete, correct ARB rather than
/// from a grep over the widget tree; `message_arb_test.dart` fails if the
/// committed ARB has drifted from the registry.
///
/// **What the resolver refuses.** [MessageResolver.resolve] rejects a
/// binding whose value type does not match the declared slot, a missing
/// slot, and an unknown one. There is no "and also append this" parameter,
/// and no overload taking a raw string: the only way to get text out of this
/// class is to name a template (FR145; ARCH A30, D57).
library;

import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:intl/message_format.dart';

import 'anchor.dart' show ArcStage, RoleKind;
import 'message_template.dart';
import 'reason_phrase.dart';
import 'reveal_state.dart';

/// `intl`'s [DateFormat] refuses an explicit locale until its symbol tables
/// are registered, and a message resolved during a widget build cannot wait
/// on a `Future` to do it. `initializeDateFormatting` from
/// `date_symbol_data_local` registers the bundled tables synchronously (the
/// `Future` it returns is already complete), so one lazy call at the first
/// timestamp is enough — and it is what lets [TimestampSlot] render in the
/// reader's locale rather than in whatever the process default happens to
/// be.
bool _dateFormattingReady = false;

void _ensureDateFormatting() {
  if (_dateFormattingReady) return;
  initializeDateFormatting();
  _dateFormattingReady = true;
}

/// Thrown when a call site binds slots a template does not declare, omits
/// one it does, or binds a value of the wrong type. A programming error, not
/// a user-facing condition — which is the point: the template is fixed, so a
/// mismatch is caught at the call, never rendered.
class MessageBindingError extends ArgumentError {
  MessageBindingError(MessageId id, String detail) : super('message ${id.name}: $detail');
}

/// Whose units the reader sees (FR79 / K5). A render-time transform — the
/// stored value is always metres (ARCH D49).
enum UnitSystem { metric, imperial }

/// CLDR's list-join shape for one locale. Four patterns cover every list
/// length: `two` for exactly two, then `start` / `middle` / `end` for three
/// or more.
class ListPatterns {
  const ListPatterns({
    required this.two,
    required this.start,
    required this.middle,
    required this.end,
    required this.facetSeparator,
  });

  final String two;
  final String start;
  final String middle;
  final String end;

  /// How independently-resolved messages sit beside each other on one line
  /// (a chip tooltip, a status strip). Not a list rule and not sentence
  /// composition: each facet is a whole resolved template, and this is the
  /// locale's separator between them.
  final String facetSeparator;
}

/// `en` list patterns, in CLDR's own form.
const ListPatterns enListPatterns = ListPatterns(
  two: '{0} and {1}',
  start: '{0}, {1}',
  middle: '{0}, {1}',
  end: '{0}, and {1}',
  facetSeparator: ' · ',
);

/// One locale's patterns. M8's generated `AppLocalizations` implements this.
abstract class MessageCatalog {
  const MessageCatalog();

  /// BCP-47 tag, passed to every `intl` formatter so plural, number, and
  /// date rules are the locale's own.
  String get locale;

  /// The ICU pattern for [id], or `null` if this locale has no entry — in
  /// which case [MessageResolver] falls back to [baseLocaleCatalog], which
  /// is M8's "missing keys fall back to the base locale" rule.
  String? pattern(MessageId id);

  ListPatterns get listPatterns;
}

/// The base locale. Until M8's ARB codegen lands, this is also the runtime
/// catalog; after it lands, this stays as the fallback M8's AC requires.
class BaseLocaleCatalog extends MessageCatalog {
  const BaseLocaleCatalog();

  @override
  String get locale => 'en';

  @override
  String? pattern(MessageId id) => baseLocalePatterns[id];

  @override
  ListPatterns get listPatterns => enListPatterns;
}

const BaseLocaleCatalog baseLocaleCatalog = BaseLocaleCatalog();

/// Every template's `en` pattern. One entry per [MessageId] — asserted by
/// `message_template_test.dart`, which is what makes "every template is
/// enumerable" checkable rather than aspirational.
const Map<MessageId, String> baseLocalePatterns = {
  // Vocabulary — role kinds.
  MessageId.termRoleNarrative: 'narrative',
  MessageId.termRoleProvision: 'provision',
  MessageId.termRoleStation: 'station',

  // Vocabulary — reveal states.
  MessageId.termRevealAlwaysVisible: 'always visible',
  MessageId.termRevealAlwaysVisibleByDefault: 'always visible (default)',
  MessageId.termRevealOnArrival: 'on arrival',
  MessageId.termRevealNotSet: 'not set yet — the Author\u2019s choice',
  MessageId.termHidden: 'hidden',

  // Vocabulary — arc stages.
  MessageId.termArcExposition: 'exposition',
  MessageId.termArcRising: 'rising action',
  MessageId.termArcCrux: 'crux',
  MessageId.termArcClimax: 'climax',
  MessageId.termArcResolution: 'resolution',

  // Vocabulary — travel modes.
  MessageId.termModeCycling: 'Ride',
  MessageId.termModeHiking: 'Hike',
  MessageId.termModePaddling: 'Paddle',
  MessageId.termModeCrossCountrySkiing: 'Ski',
  MessageId.termModePackrafting: 'Packraft',
  MessageId.termModeRiverboarding: 'Riverboard',
  MessageId.termModeMountainBiking: 'MTB',
  MessageId.termModeDriving: 'Drive',
  MessageId.termModeTransit: 'Transit',

  // Vocabulary — capabilities.
  MessageId.termCapabilityTiles: 'the basemap',
  MessageId.termCapabilityLayers: 'layers and places',
  MessageId.termCapabilityRouting: 'routing',
  MessageId.termCapabilityElevation: 'elevation',

  // Vocabulary — units.
  MessageId.unitKilometres: '{value} km',
  MessageId.unitMetres: '{value} m',
  MessageId.unitMiles: '{value} mi',
  MessageId.unitFeet: '{value} ft',

  // Vocabulary — durations.
  MessageId.durationHoursMinutes: '{hours} h {minutes} min',
  MessageId.durationMinutes: '{minutes} min',

  // Reason phrases — the bounded table's text.
  MessageId.reasonSidecarStarting: 'the planning engine is still starting',
  MessageId.reasonSidecarWontStart: 'the planning engine could not start',
  MessageId.reasonSidecarDiedMidSession: 'the planning engine stopped during this session',
  MessageId.reasonNoRoutePossible: 'no route is possible between these points',
  MessageId.reasonNoDataForArea: 'there is no map data for this area yet',
  MessageId.reasonElevationVoidOrMissingTile: 'elevation data is missing for part of this area',
  MessageId.reasonExternalProviderUnreachable: 'an external data provider is unreachable',
  MessageId.reasonExportFailed: 'the export could not be written',
  MessageId.reasonCapabilityWarming: 'it is still being prepared',
  MessageId.reasonLayerExtractionFailed: 'layer extraction did not finish',
  MessageId.reasonPluginLayerUnloadableOnLicence: 'this plugin layer cannot be loaded under its licence',
  MessageId.reasonNoClustersFoundInBbox: 'no clusters were found in this area',
  MessageId.reasonComposeDistanceIsAnOutcome: 'in Compose mode the distance is what the places add up to',
  MessageId.reasonDerivedWorkIsStale: 'an edit invalidated work that has not been re-solved',

  // Messages about a role.
  MessageId.roleRefNamed: 'the {type} role at {place}',
  MessageId.roleRefAnonymous: 'the {type} role',
  MessageId.roleReveal: '{role}: {reveal}',
  MessageId.roleOffset: 'offset {at}',
  MessageId.roleOffsetLine: '{type} offset: {at}',
  MessageId.roleHazardAlwaysVisible: 'hazard/technical crux — cannot be hidden (FR115)',
  MessageId.roleArcStage: 'arc: {arc}',
  MessageId.roleWithheldUntilArrival: '{role} is revealed on arrival — not shown yet.',
  MessageId.roleVisibleBeforeDeparture: 'Visible to a Character before departure.',

  // Alternates.
  MessageId.alternateBranchNotAnEffortOption:
      '{name} is a branch — a choice made on the day, at the fork. It is not offered as an effort option.',

  // Counts.
  MessageId.dayCount: '{count, plural, =0{No days yet} one{1 day} other{# days}}',
  MessageId.anchorCount: '{count, plural, =0{Nothing promoted yet} one{1 anchor} other{# anchors}}',
  MessageId.candidateCount: '{count, plural, =0{No candidates} one{1 candidate} other{# candidates}}',
  MessageId.staleItemCount: '{count, plural, =0{Nothing stale} one{1 stale item} other{# stale items}}',

  // Measures.
  MessageId.dayDistance: 'Distance {distance}',
  MessageId.elevationGain: 'Climb {rise}',
  MessageId.realizedDistance: 'Realized distance {distance}',
  MessageId.sharedRoadShare: 'Road ridden twice {share}',

  // Time and position.
  MessageId.dayLabel: 'Day {day}',
  MessageId.lastSolvedAt: 'Last solved {at}',
  MessageId.estimatedDuration: 'about {duration} remaining',
  MessageId.coordinateLatLon: '{lat}, {lon}',

  // Lists.
  MessageId.declaredModes: 'Modes {modes}',

  // Spoken lead-ins.
  MessageId.spokenRoleIntroduction: 'Reaching {role}.',
  MessageId.spokenHazardWarning: 'Hazard. {role}.',

  // Causes.
  MessageId.controlDisabledBecause: 'Unavailable — {reason}.',
  MessageId.operationFailedBecause: 'That did not finish — {reason}.',
  MessageId.capabilityUnavailableBecause: '{capability} is not ready — {reason}.',
};

/// Resolves a [MessageId] plus typed slots into text for one locale and one
/// unit system. Holds no state beyond those two, so a widget may construct
/// one per build; the app-wide instance lives behind `messagesProvider`
/// (`state/messages_provider.dart`).
class MessageResolver {
  const MessageResolver({
    this.catalog = baseLocaleCatalog,
    this.units = UnitSystem.metric,
    this.fallback = baseLocaleCatalog,
  });

  final MessageCatalog catalog;
  final MessageCatalog fallback;
  final UnitSystem units;

  String get locale => catalog.locale;

  /// Resolves [id] against [slots].
  ///
  /// Throws [MessageBindingError] when a slot is missing, unknown, or of the
  /// wrong type — the template is fixed, so a mismatch is a defect at the
  /// call site rather than something to render around.
  String resolve(MessageId id, [Map<String, SlotValue> slots = const {}]) {
    final template = messageTemplates[id];
    if (template == null) throw MessageBindingError(id, 'no template declared');
    final pattern = catalog.pattern(id) ?? fallback.pattern(id);
    if (pattern == null) throw MessageBindingError(id, 'no pattern in ${catalog.locale} or ${fallback.locale}');

    for (final slot in template.slots) {
      final value = slots[slot.name];
      if (value == null) throw MessageBindingError(id, 'slot "${slot.name}" (${slot.type.name}) was not bound');
      if (value.type != slot.type) {
        throw MessageBindingError(
            id, 'slot "${slot.name}" expects ${slot.type.name}, got ${value.type.name}');
      }
    }
    for (final name in slots.keys) {
      if (template.slot(name) == null) throw MessageBindingError(id, 'no slot named "$name"');
    }

    final arguments = <String, Object>{
      for (final slot in template.slots) slot.name: _argument(slots[slot.name]!),
    };
    return MessageFormat(pattern, locale: locale).format(arguments);
  }

  /// One vocabulary term, resolved on its own — the shape a chip label or a
  /// dropdown entry needs.
  String term(MessageId id) {
    final template = messageTemplates[id];
    if (template != null && !template.isTerm) {
      throw MessageBindingError(id, 'is not a zero-slot term');
    }
    return resolve(id);
  }

  /// One cause, from the bounded phrase table — never from a caller's string.
  String reason(ReasonCode code) {
    final phrase = reasonPhrases[code];
    if (phrase == null) throw ArgumentError('reason ${code.name}: no phrase in the bounded table');
    return resolve(phrase.phrase);
  }

  /// Joins already-resolved *messages* with the locale's facet separator.
  /// Each element must itself be a resolved template: this is how a surface
  /// shows several independent facts on one line without composing a
  /// sentence out of them (FR145).
  String joinFacets(Iterable<String> facets) {
    final parts = [for (final f in facets) if (f.isNotEmpty) f];
    return parts.join(catalog.listPatterns.facetSeparator);
  }

  /// Joins names by the locale's list rule (CLDR `two`/`start`/`middle`/`end`).
  String joinNames(List<String> names) {
    final p = catalog.listPatterns;
    if (names.isEmpty) return '';
    if (names.length == 1) return names.first;
    if (names.length == 2) return _fill(p.two, names[0], names[1]);
    var acc = _fill(p.start, names[0], names[1]);
    for (var i = 2; i < names.length - 1; i++) {
      acc = _fill(p.middle, acc, names[i]);
    }
    return _fill(p.end, acc, names.last);
  }

  static String _fill(String pattern, String a, String b) => pattern.replaceAll('{0}', a).replaceAll('{1}', b);

  /// The term for one [RoleKind] — a bounded map, so a new role kind is a
  /// compile error here rather than an untranslated string in the UI.
  MessageId roleKindTerm(RoleKind kind) => switch (kind) {
        RoleKind.narrative => MessageId.termRoleNarrative,
        RoleKind.provision => MessageId.termRoleProvision,
        RoleKind.station => MessageId.termRoleStation,
      };

  /// The term for one resolved [RevealState] (FR114/FR115 — always the
  /// *resolved* state, never `Role.reveal`, so "undecided" cannot leak
  /// through as "shown"). [byDefault] distinguishes a provision role the
  /// Author never set from one they chose.
  MessageId revealStateTerm(RevealState state, {bool byDefault = false}) => switch (state) {
        RevealState.alwaysVisible =>
          byDefault ? MessageId.termRevealAlwaysVisibleByDefault : MessageId.termRevealAlwaysVisible,
        RevealState.revealed => MessageId.termRevealAlwaysVisible,
        RevealState.withheld => byDefault ? MessageId.termRevealNotSet : MessageId.termRevealOnArrival,
      };

  MessageId arcStageTerm(ArcStage stage) => switch (stage) {
        ArcStage.exposition => MessageId.termArcExposition,
        ArcStage.rising => MessageId.termArcRising,
        ArcStage.crux => MessageId.termArcCrux,
        ArcStage.climax => MessageId.termArcClimax,
        ArcStage.resolution => MessageId.termArcResolution,
      };

  /// The term for one travel mode wire value (`kTravelModes`). Returns
  /// `null` for a mode this build has no term for — a plugin-declared mode,
  /// which the caller names with a [NameSlot] instead.
  MessageId? travelModeTerm(String mode) => switch (mode) {
        'cycling' => MessageId.termModeCycling,
        'hiking' => MessageId.termModeHiking,
        'paddling' => MessageId.termModePaddling,
        'cross_country_skiing' => MessageId.termModeCrossCountrySkiing,
        'packrafting' => MessageId.termModePackrafting,
        'riverboarding' => MessageId.termModeRiverboarding,
        'mountain_biking' => MessageId.termModeMountainBiking,
        'driving' => MessageId.termModeDriving,
        'transit' => MessageId.termModeTransit,
        _ => null,
      };

  // ── typed slot → ICU argument ─────────────────────────────────────────
  //
  // Every branch either hands MessageFormat a number it can apply plural or
  // number rules to, or hands it text produced by another *template*. No
  // branch concatenates.
  Object _argument(SlotValue value) => switch (value) {
        CountSlot(count: final c) => c,
        NumberSlot(value: final v, fractionDigits: final d) => _number(v, d),
        DistanceSlot(metres: final m) => _distance(m),
        DurationSlot(duration: final d) => _duration(d),
        DayIndexSlot(dayIndex: final i) => _number(i, 0),
        TimestampSlot(at: final at) => _timestamp(at),
        CoordinateSlot(lat: final lat, lon: final lon) => resolve(MessageId.coordinateLatLon, {
            'lat': NumberSlot(lat, fractionDigits: 5),
            'lon': NumberSlot(lon, fractionDigits: 5),
          }),
        ShareSlot(fraction: final f) => NumberFormat.percentPattern(locale).format(f),
        NameSlot(name: final n) => n,
        NameListSlot(names: final n) => joinNames(n),
        RoleRefSlot(kind: final kind, placeName: final place) => place == null
            ? resolve(MessageId.roleRefAnonymous, {'type': TermSlot(roleKindTerm(kind))})
            : resolve(MessageId.roleRefNamed, {
                'type': TermSlot(roleKindTerm(kind)),
                'place': NameSlot(place, source: NameSource.anchorTitle),
              }),
        ReasonSlot(reason: final code) => reason(code),
        TermSlot(term: final id) => term(id),
      };

  String _timestamp(DateTime at) {
    _ensureDateFormatting();
    return DateFormat.yMMMd(locale).add_jm().format(at);
  }

  String _number(num value, int fractionDigits) =>
      NumberFormat.decimalPatternDigits(locale: locale, decimalDigits: fractionDigits).format(value);

  /// Metres → the reader's units, as a *nested unit template*: the unit
  /// label is localizable and the number goes through the locale's number
  /// format. Never `'${m / 1000} km'`.
  String _distance(double metres) {
    switch (units) {
      case UnitSystem.metric:
        return metres.abs() >= 1000
            ? resolve(MessageId.unitKilometres, {'value': NumberSlot(metres / 1000, fractionDigits: 1)})
            : resolve(MessageId.unitMetres, {'value': NumberSlot(metres.roundToDouble(), fractionDigits: 0)});
      case UnitSystem.imperial:
        final miles = metres / 1609.344;
        return miles.abs() >= 0.1
            ? resolve(MessageId.unitMiles, {'value': NumberSlot(miles, fractionDigits: 1)})
            : resolve(MessageId.unitFeet, {'value': NumberSlot((metres * 3.28084).roundToDouble(), fractionDigits: 0)});
    }
  }

  String _duration(Duration duration) {
    final totalMinutes = duration.inMinutes;
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    return hours == 0
        ? resolve(MessageId.durationMinutes, {'minutes': NumberSlot(minutes, fractionDigits: 0)})
        : resolve(MessageId.durationHoursMinutes, {
            'hours': NumberSlot(hours, fractionDigits: 0),
            'minutes': NumberSlot(minutes, fractionDigits: 0),
          });
  }
}

/// The ARB type for one [SlotType], as the placeholder is actually bound
/// into the ICU pattern: `count` selects a plural form so it stays an `int`,
/// a raw number stays `num`, and everything else has already been rendered
/// by *its own* template or formatter by the time it reaches the pattern.
String arbPlaceholderType(SlotType type) => switch (type) {
      SlotType.count => 'int',
      SlotType.number => 'num',
      _ => 'String',
    };

/// Projects the registry into ARB source (`lib/l10n/app_en.arb`) — M8's
/// input, generated rather than transcribed. `tool/gen_message_arb.dart`
/// writes it; `message_arb_test.dart` asserts the committed file matches, so
/// adding a template without regenerating fails a test rather than shipping
/// an unlocalizable string.
String messageArbSource() {
  final buffer = StringBuffer()
    ..writeln('{')
    ..writeln('  "@@locale": "en",')
    ..writeln('  "@@x-generated-by": "client/tool/gen_message_arb.dart from '
        'lib/domain/message_template.dart + message_catalog.dart (FR145 / M14)",');
  final ids = MessageId.values;
  for (var i = 0; i < ids.length; i++) {
    final id = ids[i];
    final template = messageTemplates[id]!;
    buffer.writeln('  ${_json(id.name)}: ${_json(baseLocalePatterns[id]!)},');
    buffer.writeln('  ${_json('@${id.name}')}: {');
    buffer.write('    "description": ${_json(template.usage)}');
    if (template.slots.isEmpty) {
      buffer.writeln();
    } else {
      buffer.writeln(',');
      buffer.writeln('    "placeholders": {');
      for (var s = 0; s < template.slots.length; s++) {
        final slot = template.slots[s];
        final comma = s == template.slots.length - 1 ? '' : ',';
        buffer.writeln('      ${_json(slot.name)}: {"type": ${_json(arbPlaceholderType(slot.type))}, '
            '"x-slot-type": ${_json(slot.type.name)}}$comma');
      }
      buffer.writeln('    }');
    }
    buffer.writeln('  }${i == ids.length - 1 ? '' : ','}');
  }
  buffer.writeln('}');
  return buffer.toString();
}

String _json(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n');
  return '"$escaped"';
}
