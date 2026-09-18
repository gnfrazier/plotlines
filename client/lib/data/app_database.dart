import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// G2a's local trip library (MVP doc §10.3 — no `dirty`/`server_version`
/// columns here: desktop MVP has no accounts and nothing to sync against).
///
/// `TripRow`, not the generator's default `Trip`: that name is already the
/// domain layer's payload class (domain/trip_payload.dart) and this table's
/// row is a projection over it, not the same type.
@DataClassName('TripRow')
class Trips extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();

  /// FR144/N0, issue #319 — the trip's one travel-mode set (`Trip.modes`),
  /// comma-joined (e.g. "cycling,hiking"). Lives here rather than in
  /// `payload` because `trip_payload.schema.json` is
  /// `additionalProperties: false` and has no such field (`trip.dart`'s doc
  /// comment on `modes`) — this column is the field's only persistence, and
  /// the library list projects it without decoding `payload` per row
  /// (SPIKE-20: full-row `SELECT *` on 20 trips cost 137ms vs 1.0ms
  /// projected). Before schema v6 this was the segment-derived list and a
  /// second `declared_modes` column held the Author's set; the v6 migration
  /// folds the two into this one.
  TextColumn get modes => text()();

  /// Canonical trip_payload.schema.json JSON, as TEXT (SQLite has no JSON type).
  TextColumn get payload => text()();

  /// FR134–FR136 / G2b — the trip's roster layer (`TripRoster.toJson()`):
  /// membership, group and sub-group assignments, shared-gear and meal
  /// responsibilities, and Author notes. Kept **beside** [payload], not
  /// inside it, for the same reason [modes] is: the roster is not a
  /// `trip_payload.schema.json` type (FR136 — group "is stored on the trip
  /// roster entry, not the account profile", and equally not on the payload),
  /// and in hosted mode it maps to the separate `roster_entry` / `author_note`
  /// tables (ARCH §11.1), not to `trip.payload JSONB`. Empty string = no
  /// roster (old rows, or a trip nobody has been added to yet).
  TextColumn get roster => text().withDefault(const Constant(''))();

  /// G2 (FR74) — a compact JSON of the card-face metrics the Trip Library
  /// grid/list shows without decoding [payload] per row (SPIKE-20): distance,
  /// elevation gain, day count, variant count, and group size. Computed from
  /// the `Trip` and `TripRoster` at save time, the same denormalization
  /// [modes] already does. `{}` for old rows — the card falls back to
  /// "no metrics yet".
  TextColumn get summary => text().withDefault(const Constant('{}'))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// App-level (not trip-level) preferences: units/theme/contrast (K5), the
/// last-used trip-creation location (A10 — prefill only, never a flag that
/// gates trip creation), and the sidecar's last-known paired version. One
/// row per key; absent key = unset/default.
class SettingsKv extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// FR110 / O1 — "rejected proposals are remembered for the trip so the same
/// cluster is not re-proposed on every run." Local-only and outside canon
/// (ARCH P10: candidates and proposals are never `trip.payload`, only the
/// fact that one was rejected is worth keeping) — [proposalId] is a
/// candidate or cluster-proposal id, opaque to this table.
class RejectedProposals extends Table {
  TextColumn get tripId => text()();
  TextColumn get proposalId => text()();
  DateTimeColumn get rejectedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {tripId, proposalId};
}

@DriftDatabase(tables: [Trips, SettingsKv, RejectedProposals])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());
  AppDatabase.forTesting(super.connection);

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(rejectedProposals);
          }
          if (from < 3) {
            // FR144/N0 added the Author's declared set as its own column.
            // Raw SQL rather than `m.addColumn`, because the column is gone
            // from the table definition since v6 (#319 below) — a v2 file
            // still has to pass through the v5 fold, which reads it.
            await m.database.customStatement(
                "ALTER TABLE trips ADD COLUMN declared_modes TEXT NOT NULL DEFAULT ''");
          }
          if (from < 4) {
            // G2 / G2b — the roster layer and the card-face metrics summary.
            await m.addColumn(trips, trips.roster);
            await m.addColumn(trips, trips.summary);
          }
          if (from < 5) {
            // #315 — `mountain_biking` / `packrafting` / `riverboarding` left
            // the travel_mode enum. Fold them onto their category in the two
            // denormalized CSV columns (the `payload` blob is migrated on
            // decode by `Segment.fromJson`). Done row-by-row so a trip that
            // carried both `cycling` and `mountain_biking` ends up with one
            // `cycling`, not a duplicate.
            const alias = {
              'mountain_biking': 'cycling',
              'packrafting': 'paddling',
              'riverboarding': 'paddling',
            };
            List<String> fold(String csv) {
              final out = <String>[];
              for (final raw in csv.split(',')) {
                final v = raw.trim();
                if (v.isEmpty) continue;
                final canon = alias[v] ?? v;
                if (!out.contains(canon)) out.add(canon);
              }
              return out;
            }

            final rows = await m.database
                .customSelect('SELECT id, modes, declared_modes FROM trips')
                .get();
            for (final row in rows) {
              await m.database.customStatement(
                'UPDATE trips SET modes = ?, declared_modes = ? WHERE id = ?',
                [
                  fold(row.read<String>('modes')).join(','),
                  fold(row.read<String>('declared_modes')).join(','),
                  row.read<String>('id'),
                ],
              );
            }
          }
          if (from < 6) {
            // Issue #319 — one trip mode set. `modes` used to be the
            // segment-derived list and `declared_modes` the Author's stated
            // set; the stored set is now the single source of truth and
            // every segment's mode is a member of it (`Trip.modes`). Fold
            // the two into `modes` — declared first so the Author's own
            // order survives, then anything only a segment realised — and
            // drop the second column. Done row-by-row for the same reason
            // the v5 fold was: the union has to dedupe per row.
            final rows = await m.database
                .customSelect('SELECT id, modes, declared_modes FROM trips')
                .get();
            for (final row in rows) {
              final merged = <String>[];
              for (final csv in [row.read<String>('declared_modes'), row.read<String>('modes')]) {
                for (final raw in csv.split(',')) {
                  final v = raw.trim();
                  if (v.isNotEmpty && !merged.contains(v)) merged.add(v);
                }
              }
              await m.database.customStatement(
                'UPDATE trips SET modes = ? WHERE id = ?',
                [merged.join(','), row.read<String>('id')],
              );
            }
            // Recreates `trips` from the current table definition, which no
            // longer has `declared_modes`, copying every column both share.
            await m.alterTable(TableMigration(trips));
          }
        },
      );

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'plotlines');
  }

  // --- G2a / G2: save / reopen / list ------------------------------------

  /// Projected list, most-recent-first — never decodes `payload` (SPIKE-20).
  /// G2 adds the card-face metrics, read from the small denormalized
  /// [Trips.summary] JSON rather than the payload, and the sync badge, which
  /// on this single-device build is always [TripSyncBadge.thisDevice] (there
  /// is no account to sync against — see the class doc comment).
  Future<List<TripListEntry>> listTrips() {
    final q = select(trips)
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);
    return q
        .map((row) => TripListEntry(
              id: row.id,
              title: row.title,
              modes: row.modes.isEmpty ? const [] : row.modes.split(','),
              updatedAt: row.updatedAt,
              summary: TripCardMetrics.fromJsonString(row.summary),
              syncBadge: TripSyncBadge.thisDevice,
            ))
        .get();
  }

  Future<TripRow?> loadTrip(String id) =>
      (select(trips)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> saveTrip({
    required String id,
    required String title,
    required List<String> modes,
    required String payloadJson,
    required DateTime updatedAt,
    String rosterJson = '',
    String summaryJson = '{}',
  }) {
    return into(trips).insertOnConflictUpdate(TripsCompanion.insert(
      id: id,
      title: title,
      modes: modes.join(','),
      payload: payloadJson,
      roster: Value(rosterJson),
      summary: Value(summaryJson),
      createdAt: updatedAt,
      updatedAt: updatedAt,
    ));
  }

  Future<void> deleteTrip(String id) =>
      (delete(trips)..where((t) => t.id.equals(id))).go();

  // --- settings -------------------------------------------------------

  Future<String?> getSetting(String key) async {
    final row = await (select(settingsKv)..where((s) => s.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setSetting(String key, String value) {
    return into(settingsKv).insertOnConflictUpdate(
      SettingsKvCompanion.insert(key: key, value: value),
    );
  }

  // --- FR110 / O1: rejected proposals ------------------------------------

  Future<void> rejectProposal({required String tripId, required String proposalId}) {
    return into(rejectedProposals).insertOnConflictUpdate(RejectedProposalsCompanion.insert(
      tripId: tripId,
      proposalId: proposalId,
      rejectedAt: DateTime.now(),
    ));
  }

  /// Undoes a rejection — N4a's "undoable within the session" applies to the
  /// review surface this table backs, even though that surface is [P1].
  Future<void> unrejectProposal({required String tripId, required String proposalId}) {
    return (delete(rejectedProposals)
          ..where((r) => r.tripId.equals(tripId) & r.proposalId.equals(proposalId)))
        .go();
  }

  Future<Set<String>> rejectedProposalIds(String tripId) async {
    final rows = await (select(rejectedProposals)..where((r) => r.tripId.equals(tripId))).get();
    return rows.map((r) => r.proposalId).toSet();
  }
}

/// FR76 — the sync-status badge a Trip Library card shows. The PRD names
/// three (Cloud Synced, This Device, Offline Ready); this single-device build
/// has no account and nothing to sync against (see [AppDatabase]'s class doc
/// comment), so every locally-saved trip is [thisDevice]. The other two
/// arrive with hosted mode; the enum carries them now so callers switch on a
/// complete set rather than a bool.
enum TripSyncBadge {
  cloudSynced('Cloud synced'),
  thisDevice('This device'),
  offlineReady('Offline ready');

  const TripSyncBadge(this.label);
  final String label;
}

/// G2 (FR74) — the card-face metrics for a Trip Library entry, denormalized
/// into [Trips.summary] at save time so the grid/list never decodes a
/// payload per row (SPIKE-20). Every field is nullable: a trip saved before
/// this column existed, or one with no solved route yet, simply has no
/// numbers to show.
class TripCardMetrics {
  const TripCardMetrics({
    this.distanceM,
    this.ascentM,
    this.dayCount,
    this.variantCount,
    this.groupSize,
  });

  /// Trip total distance, metres (`Trip.metrics.total.distanceM`).
  final double? distanceM;

  /// Trip total elevation gain, metres (`Trip.metrics.total.climbM`).
  final double? ascentM;

  /// Number of authored days (`Trip.days.length`).
  final int? dayCount;

  /// FR74's "variant count" — per-Character route variants (H6). These are
  /// not persisted yet (they are a session-only layer, `character_variant.dart`),
  /// so this is written as 0 until they are; kept as a field so the card and
  /// the write path already have a home for it.
  final int? variantCount;

  /// FR74's "group size" — the number of Characters on the trip roster
  /// (`TripRoster.entries.length`).
  final int? groupSize;

  static const TripCardMetrics empty = TripCardMetrics();

  factory TripCardMetrics.fromJsonString(String raw) {
    if (raw.isEmpty || raw == '{}') return empty;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return TripCardMetrics(
        distanceM: (m['distance_m'] as num?)?.toDouble(),
        ascentM: (m['ascent_m'] as num?)?.toDouble(),
        dayCount: (m['day_count'] as num?)?.toInt(),
        variantCount: (m['variant_count'] as num?)?.toInt(),
        groupSize: (m['group_size'] as num?)?.toInt(),
      );
    } on FormatException {
      return empty;
    }
  }

  String toJsonString() => jsonEncode({
        if (distanceM != null) 'distance_m': distanceM,
        if (ascentM != null) 'ascent_m': ascentM,
        if (dayCount != null) 'day_count': dayCount,
        if (variantCount != null) 'variant_count': variantCount,
        if (groupSize != null) 'group_size': groupSize,
      });
}

/// Projected row for the Trip Library list. G2a shipped the floor (id, title,
/// modes, last-edited); G2 (FR74) adds the card-face metrics ([summary]) and
/// the sync badge ([syncBadge]) — still a projection, still no payload decode.
class TripListEntry {
  const TripListEntry({
    required this.id,
    required this.title,
    required this.modes,
    required this.updatedAt,
    this.summary = TripCardMetrics.empty,
    this.syncBadge = TripSyncBadge.thisDevice,
  });

  final String id;
  final String title;

  /// The trip's mode set (`Trip.modes`, #319) — what the card's mode tag
  /// shows and what G2's "filter by mode" matches against (FR74). Every
  /// segment's mode is a member, so a brand-new trip with no segments yet
  /// still filters on what it is *for*.
  final List<String> modes;

  final DateTime updatedAt;
  final TripCardMetrics summary;
  final TripSyncBadge syncBadge;
}
