/// FR78a, FR123 / D4a — the Author-side request/response surface an
/// in-field Character grants against. Not part of `trip_payload.schema.json`:
/// there is no `Character`/roster/account object anywhere in the wire
/// payload yet (FR136/FR137 are `[Later]`, not built here), so — same
/// reasoning `trip_authoring_meta_provider.dart` already documents for party
/// size — this is a client-authoring-only model, not a wire type. It is
/// deliberately **session-scoped** (`state/profile_request_provider.dart`),
/// not persisted to the local trip database: with no roster/invitation
/// mechanism yet, no real Character response can ever reach this app, so
/// persisting a request set or a response grid across restarts would be
/// storage for data nothing can populate. When the roster (FR136) and
/// Character-side response flow (K2) land, this model's shape — a request
/// set plus a per-Character response — is what they wire real data into.
///
/// **FR78a's "the request set includes arrival visibility (FR123) alongside
/// profile fields"** is why [ProfileField] carries a [ProfileFieldCategory]
/// rather than being a bag of profile-only strings: arrival visibility is
/// one more catalog entry, category [ProfileFieldCategory.permission], so
/// in-field sharing consent uses this one surface rather than a parallel
/// mechanism (D-I).
///
/// **"Requesting never auto-grants" (FR78a) is structural, not a UI rule**:
/// [resolveStatus] only ever returns [ConsentStatus.granted] when a
/// [CharacterResponse] explicitly says so (`grants[fieldId] == true`).
/// Adding a field to a [FieldRequestSet] can only ever move a field's status
/// to [ConsentStatus.requested] (pending), never to granted — there is no
/// code path in this file that sets a status to granted except reading an
/// explicit Character response.
library;

/// FR78/FR78a — whether a catalog entry is an ordinary profile field (name,
/// dietary needs, ...) or a non-profile permission of the same shape
/// (FR123's arrival visibility). Both flow through the identical
/// request/response mechanism; this only distinguishes how the two read in
/// the UI (a "permission" reads as a capability grant, not a data share).
enum ProfileFieldCategory {
  profile,
  permission;
}

/// One requestable item in the catalog an Author builds a per-trip request
/// from. [defaultRequested] marks the *default* set (FR78a: "a default set
/// the Author can adjust per trip") — it is not a consent default. Consent
/// itself always starts at nothing shared (FR78, FR123) regardless of
/// whether a field is in the default request set.
class ProfileField {
  const ProfileField({
    required this.id,
    required this.label,
    required this.description,
    required this.category,
    this.defaultRequested = false,
  });

  final String id;
  final String label;
  final String description;
  final ProfileFieldCategory category;
  final bool defaultRequested;
}

/// FR78a's adjustable default set. Ordinary profile fields default in
/// (an Author almost always wants to know who they're travelling with and
/// how to reach them); safety-relevant and sensitive fields default out
/// so a request is a deliberate ask, not a pre-checked wall of boxes.
/// FR123's arrival visibility carries the same "default nothing shared"
/// guarantee one level up: even requesting it is opt-in, and requesting it
/// still never auto-grants (that guarantee lives in [resolveStatus]).
const List<ProfileField> defaultProfileFieldCatalog = [
  ProfileField(
    id: 'full_name',
    label: 'Full name',
    description: 'Legal name, for permits, waivers, or check-in lists.',
    category: ProfileFieldCategory.profile,
    defaultRequested: true,
  ),
  ProfileField(
    id: 'phone',
    label: 'Phone number',
    description: 'Reachable if plans change or the group splits up.',
    category: ProfileFieldCategory.profile,
    defaultRequested: true,
  ),
  ProfileField(
    id: 'emergency_contact',
    label: 'Emergency contact',
    description: 'Who to call, and how, if this Character is hurt or lost.',
    category: ProfileFieldCategory.profile,
    defaultRequested: true,
  ),
  ProfileField(
    id: 'dietary_restrictions',
    label: 'Dietary restrictions',
    description: 'Allergies or diet needs that shape meal planning (C9).',
    category: ProfileFieldCategory.profile,
    defaultRequested: false,
  ),
  ProfileField(
    id: 'medical_conditions',
    label: 'Medical conditions',
    description: 'Anything relevant if this Character needs help in the field.',
    category: ProfileFieldCategory.profile,
    defaultRequested: false,
  ),
  ProfileField(
    id: 'pace_profile',
    label: 'Pace & experience',
    description: 'Stated pace and preferences (FR16a) feeding planning defaults.',
    category: ProfileFieldCategory.profile,
    defaultRequested: false,
  ),
  ProfileField(
    id: 'vehicle_info',
    label: 'Vehicle / shuttle info',
    description: 'Plate and vehicle details for trailhead shuttle logistics.',
    category: ProfileFieldCategory.profile,
    defaultRequested: false,
  ),
  ProfileField(
    id: 'arrival_visibility',
    label: 'Arrival visibility',
    description: 'FR123 — when granted, this Character reaching a plot point '
        'is visible to the trip roster (regroup: "three of us are already at '
        'the overlook"), never to the Author alone. Default nothing shared.',
    category: ProfileFieldCategory.permission,
    defaultRequested: false,
  ),
];

/// FR78a — the per-trip, Author-adjustable set of fields being requested.
/// Starts from [defaultProfileFieldCatalog]'s default-in fields; every
/// [toggle] is an explicit Author decision, in either direction.
class FieldRequestSet {
  const FieldRequestSet({this.requestedFieldIds = const {}});

  final Set<String> requestedFieldIds;

  factory FieldRequestSet.defaults({
    List<ProfileField> catalog = defaultProfileFieldCatalog,
  }) =>
      FieldRequestSet(
        requestedFieldIds: {
          for (final f in catalog)
            if (f.defaultRequested) f.id,
        },
      );

  bool isRequested(String fieldId) => requestedFieldIds.contains(fieldId);

  FieldRequestSet toggle(String fieldId) {
    final next = {...requestedFieldIds};
    next.contains(fieldId) ? next.remove(fieldId) : next.add(fieldId);
    return FieldRequestSet(requestedFieldIds: next);
  }

  FieldRequestSet copyWith({Set<String>? requestedFieldIds}) =>
      FieldRequestSet(requestedFieldIds: requestedFieldIds ?? this.requestedFieldIds);
}

/// K2 (not built here) is what a Character would eventually produce — this
/// is the shape it produces into. [grants] covers only fields the Author
/// actually requested: `true` grants it, `false` declines it, and a
/// requested field with no entry is still pending (FR78a: requesting never
/// auto-grants). [volunteeredFieldIds] are fields the Character shared
/// unprompted — FR78's "may grant requested fields, decline specific ones,
/// and volunteer fields the Author did not request" — surfaced separately
/// per D4a's AC ("nothing shared for safety is buried").
class CharacterResponse {
  const CharacterResponse({
    required this.characterId,
    required this.characterName,
    this.grants = const {},
    this.volunteeredFieldIds = const {},
  });

  final String characterId;
  final String characterName;
  final Map<String, bool> grants;
  final Set<String> volunteeredFieldIds;
}

/// FR78, FR78a / D4a's AC — "granted, declined, or volunteered unprompted."
/// [notRequested] covers a field the Author never asked for and the
/// Character never volunteered — the ordinary, common state for most of the
/// catalog on most trips.
enum ConsentStatus {
  notRequested,
  requested,
  granted,
  declined,
  volunteered;
}

/// The single decision point "requesting never auto-grants" runs through:
/// a field only ever reads [ConsentStatus.granted] when [response] carries
/// an explicit `true`. Volunteered status wins over a request-set entry
/// (FR78's "volunteer fields the Author did not request" — a Character can
/// also proactively share something the Author happened to also request;
/// volunteered is the more informative label either way, since it flags
/// this Character chose to disclose it, not merely responded to being asked).
ConsentStatus resolveStatus(
  FieldRequestSet request,
  CharacterResponse response,
  String fieldId,
) {
  if (response.volunteeredFieldIds.contains(fieldId)) return ConsentStatus.volunteered;
  if (!request.isRequested(fieldId)) return ConsentStatus.notRequested;
  final grant = response.grants[fieldId];
  if (grant == true) return ConsentStatus.granted;
  if (grant == false) return ConsentStatus.declined;
  return ConsentStatus.requested;
}

/// D4a's AC: "the Author sees per Character which fields were granted,
/// declined, and volunteered unprompted." One row per (Character, field)
/// this trip is tracking, built from [request] and [response] together —
/// the read model the roster status view renders, so no widget re-derives
/// [resolveStatus] itself.
class CharacterFieldStatus {
  const CharacterFieldStatus({required this.field, required this.status});
  final ProfileField field;
  final ConsentStatus status;
}

List<CharacterFieldStatus> resolveCharacterStatuses(
  FieldRequestSet request,
  CharacterResponse response, {
  List<ProfileField> catalog = defaultProfileFieldCatalog,
}) {
  final requestedOrVolunteered = <ProfileField>[
    for (final f in catalog)
      if (request.isRequested(f.id) || response.volunteeredFieldIds.contains(f.id)) f,
  ];
  return [
    for (final f in requestedOrVolunteered)
      CharacterFieldStatus(field: f, status: resolveStatus(request, response, f.id)),
  ];
}
