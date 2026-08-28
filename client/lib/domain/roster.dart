// FR134–FR136 (Stories G-roster / C8 / C9) and ARCH §11.1's `roster_entry` /
// `author_note` tables — the trip-scoped membership layer that sits *beside*
// the canonical `trip.payload`, never inside it.
//
// **Not a `trip_payload.schema.json` type.** FR136 is explicit: a Character's
// group "is stored on the trip roster entry, not the account profile" — and
// it is equally not on the payload. The schema is `additionalProperties:
// false` and carries no roster, group, gear-assignment, or meal-responsibility
// field. So this model is persisted the same way `Trip.declaredModes` is:
// its own column on the local `Trips` table (`app_database.dart`), alongside
// (not within) the payload blob. In hosted mode it maps to the `roster_entry`
// and `author_note` tables (ARCH §11.1), which are likewise separate from
// `trip.payload JSONB`.
//
// This layer's reason to exist right now is G2 / G2b (#71, #73): the Trip
// Library shows group size, and Clone carries or drops roster membership and
// everything keyed to a person. The Character-facing roster *runtime* (group
// visibility per day/passage, the per-Character detail view FR134) is a
// separate story with no client surface yet — the same boundary H6 (#80)
// drew — so this file is the domain model and its transforms only.
library;

/// FR136 — one Character's trip-scoped membership record: a group and
/// optional sub-group, defaulted at the trip level and overridable per day
/// and per passage ("a group's composition changes across the arc of a
/// day"). Character-visible, unlike [AuthorNote].
class RosterEntry {
  const RosterEntry({
    required this.characterId,
    required this.name,
    this.groupLabel,
    this.subgroupLabel,
    this.dayGroupOverrides = const {},
    this.passageGroupOverrides = const {},
  });

  final String characterId;
  final String name;

  /// The trip-level default group / sub-group. `null` = unassigned.
  final String? groupLabel;
  final String? subgroupLabel;

  /// FR136's time-scoping: `dayId` / `passageId` → group label, overriding
  /// [groupLabel] for that day or passage only. Keyed to days and passages,
  /// not to people — so a scope that keeps the roster but drops the authored
  /// trip (there are no days to key to) clears these, while a scope that
  /// drops people leaves them untouched.
  final Map<String, String> dayGroupOverrides;
  final Map<String, String> passageGroupOverrides;

  RosterEntry copyWith({
    String? groupLabel,
    String? subgroupLabel,
    Map<String, String>? dayGroupOverrides,
    Map<String, String>? passageGroupOverrides,
  }) =>
      RosterEntry(
        characterId: characterId,
        name: name,
        groupLabel: groupLabel ?? this.groupLabel,
        subgroupLabel: subgroupLabel ?? this.subgroupLabel,
        dayGroupOverrides: dayGroupOverrides ?? this.dayGroupOverrides,
        passageGroupOverrides: passageGroupOverrides ?? this.passageGroupOverrides,
      );

  /// Drops [dayGroupOverrides] / [passageGroupOverrides] — used when the
  /// authored trip is not in scope, so there is nothing for a per-day or
  /// per-passage override to point at.
  RosterEntry withoutPositionOverrides() => RosterEntry(
        characterId: characterId,
        name: name,
        groupLabel: groupLabel,
        subgroupLabel: subgroupLabel,
      );

  factory RosterEntry.fromJson(Map<String, dynamic> json) => RosterEntry(
        characterId: json['character_id'] as String,
        name: json['name'] as String,
        groupLabel: json['group_label'] as String?,
        subgroupLabel: json['subgroup_label'] as String?,
        dayGroupOverrides: _stringMap(json['day_group_overrides']),
        passageGroupOverrides: _stringMap(json['passage_group_overrides']),
      );

  Map<String, dynamic> toJson() => {
        'character_id': characterId,
        'name': name,
        if (groupLabel != null) 'group_label': groupLabel,
        if (subgroupLabel != null) 'subgroup_label': subgroupLabel,
        if (dayGroupOverrides.isNotEmpty) 'day_group_overrides': dayGroupOverrides,
        if (passageGroupOverrides.isNotEmpty)
          'passage_group_overrides': passageGroupOverrides,
      };
}

/// FR24 / C8 — a shared-group-gear line assigned to specific Characters.
/// (The gear *checklist* by mode / station activity is a payload concern via
/// `station.required_gear`; who carries the *shared* items is roster-scoped.)
class GearAssignment {
  const GearAssignment({
    required this.id,
    required this.label,
    this.assigneeIds = const {},
  });

  final String id;
  final String label;
  final Set<String> assigneeIds;

  GearAssignment withAssignees(Set<String> ids) =>
      GearAssignment(id: id, label: label, assigneeIds: ids);

  factory GearAssignment.fromJson(Map<String, dynamic> json) => GearAssignment(
        id: json['id'] as String,
        label: json['label'] as String,
        assigneeIds: {for (final v in (json['assignee_ids'] as List? ?? const [])) v as String},
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        if (assigneeIds.isNotEmpty) 'assignee_ids': assigneeIds.toList()..sort(),
      };
}

/// FR25 / C9 — a group meal with the Characters responsible for it, optionally
/// pinned to a day.
class MealResponsibility {
  const MealResponsibility({
    required this.id,
    required this.label,
    this.dayId,
    this.cookIds = const {},
  });

  final String id;
  final String label;
  final String? dayId;
  final Set<String> cookIds;

  MealResponsibility withCooks(Set<String> ids) =>
      MealResponsibility(id: id, label: label, dayId: dayId, cookIds: ids);

  factory MealResponsibility.fromJson(Map<String, dynamic> json) => MealResponsibility(
        id: json['id'] as String,
        label: json['label'] as String,
        dayId: json['day_id'] as String?,
        cookIds: {for (final v in (json['cook_ids'] as List? ?? const [])) v as String},
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        if (dayId != null) 'day_id': dayId,
        if (cookIds.isNotEmpty) 'cook_ids': cookIds.toList()..sort(),
      };
}

/// FR135 / D6 — free-text knowledge an Author holds about a Character. Scoped
/// to `(Author, Character)`, **not** to a trip: the knowledge is about the
/// person and persists across trips, so a clone that carries the roster
/// carries the notes *as a consequence of that scoping* — no rule is applied
/// (ARCH §11.8). [updatedAt] is preserved on clone and is meant to be shown
/// beside the note ("a three-year-old claim about someone's climbing is worse
/// than none if its age is invisible").
class AuthorNote {
  const AuthorNote({
    required this.subjectCharacterId,
    required this.body,
    required this.updatedAt,
  });

  final String subjectCharacterId;
  final String body;

  /// ISO-8601. Carried verbatim across a clone — never bumped to "now".
  final String updatedAt;

  factory AuthorNote.fromJson(Map<String, dynamic> json) => AuthorNote(
        subjectCharacterId: json['subject_character_id'] as String,
        body: json['body'] as String,
        updatedAt: json['updated_at'] as String,
      );

  Map<String, dynamic> toJson() => {
        'subject_character_id': subjectCharacterId,
        'body': body,
        'updated_at': updatedAt,
      };
}

/// The whole roster layer for one trip: membership, group assignments, shared
/// gear, meal responsibilities, and Author notes. Everything Clone reasons
/// about that is *not* the canonical payload.
class TripRoster {
  const TripRoster({
    this.entries = const [],
    this.gear = const [],
    this.meals = const [],
    this.authorNotes = const [],
  });

  final List<RosterEntry> entries;
  final List<GearAssignment> gear;
  final List<MealResponsibility> meals;
  final List<AuthorNote> authorNotes;

  static const TripRoster empty = TripRoster();

  bool get isEmpty =>
      entries.isEmpty && gear.isEmpty && meals.isEmpty && authorNotes.isEmpty;

  Set<String> get characterIds => {for (final e in entries) e.characterId};

  /// The "no dangling references" rule (FR74b / ARCH §11.8): "where a scope
  /// drops people, everything assigned to them drops with them ... rather
  /// than being left as dangling references."
  ///
  /// Keeps only entries whose `characterId` is in [keepIds]; intersects every
  /// gear/meal assignee set with [keepIds] and removes any line that is left
  /// with nobody on it (an unassigned "shared gear" line is not an
  /// assignment); keeps an [AuthorNote] iff its subject is kept (notes follow
  /// the person). Day/passage group overrides are keyed to the itinerary, not
  /// to people, so they are untouched here.
  TripRoster retainingPeople(Set<String> keepIds) {
    final keptGear = [
      for (final g in gear)
        if (g.assigneeIds.any(keepIds.contains))
          g.withAssignees(g.assigneeIds.intersection(keepIds)),
    ];
    final keptMeals = [
      for (final m in meals)
        if (m.cookIds.any(keepIds.contains))
          m.withCooks(m.cookIds.intersection(keepIds)),
    ];
    return TripRoster(
      entries: [for (final e in entries) if (keepIds.contains(e.characterId)) e],
      gear: keptGear,
      meals: keptMeals,
      authorNotes: [
        for (final n in authorNotes)
          if (keepIds.contains(n.subjectCharacterId)) n,
      ],
    );
  }

  /// Used when the roster is carried but the authored trip is not: there are
  /// no days or passages, so per-day / per-passage group overrides have
  /// nothing to point at (FR74b: roster only = "membership and group
  /// assignments, no days, passages, anchors, or content").
  TripRoster withoutPositionOverrides() => TripRoster(
        entries: [for (final e in entries) e.withoutPositionOverrides()],
        gear: gear,
        meals: meals,
        authorNotes: authorNotes,
      );

  factory TripRoster.fromJson(Map<String, dynamic> json) => TripRoster(
        entries: [
          for (final v in (json['entries'] as List? ?? const []))
            RosterEntry.fromJson(Map<String, dynamic>.from(v as Map)),
        ],
        gear: [
          for (final v in (json['gear'] as List? ?? const []))
            GearAssignment.fromJson(Map<String, dynamic>.from(v as Map)),
        ],
        meals: [
          for (final v in (json['meals'] as List? ?? const []))
            MealResponsibility.fromJson(Map<String, dynamic>.from(v as Map)),
        ],
        authorNotes: [
          for (final v in (json['author_notes'] as List? ?? const []))
            AuthorNote.fromJson(Map<String, dynamic>.from(v as Map)),
        ],
      );

  Map<String, dynamic> toJson() => {
        if (entries.isNotEmpty) 'entries': [for (final e in entries) e.toJson()],
        if (gear.isNotEmpty) 'gear': [for (final g in gear) g.toJson()],
        if (meals.isNotEmpty) 'meals': [for (final m in meals) m.toJson()],
        if (authorNotes.isNotEmpty)
          'author_notes': [for (final n in authorNotes) n.toJson()],
      };
}

Map<String, String> _stringMap(dynamic raw) => raw == null
    ? const {}
    : {for (final e in (raw as Map).entries) e.key as String: e.value as String};
