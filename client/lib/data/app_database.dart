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

  /// Denormalized comma-joined mode list (e.g. "cycling,hiking") so the
  /// library list can project it without decoding `payload` per row
  /// (SPIKE-20: full-row `SELECT *` on 20 trips cost 137ms vs 1.0ms projected).
  TextColumn get modes => text()();

  /// Canonical trip_payload.schema.json JSON, as TEXT (SQLite has no JSON type).
  TextColumn get payload => text()();

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
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(rejectedProposals);
          }
        },
      );

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'plotlines');
  }

  // --- G2a: save / reopen / list -----------------------------------------

  /// Projected list, most-recent-first — never decodes `payload` (SPIKE-20).
  Future<List<TripListEntry>> listTrips() {
    final q = select(trips)
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);
    return q
        .map((row) => TripListEntry(
              id: row.id,
              title: row.title,
              modes: row.modes.isEmpty ? const [] : row.modes.split(','),
              updatedAt: row.updatedAt,
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
  }) {
    return into(trips).insertOnConflictUpdate(TripsCompanion.insert(
      id: id,
      title: title,
      modes: modes.join(','),
      payload: payloadJson,
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

/// Projected row for the trip library list (G2a) — no thumbnail, sync badge,
/// group-size, or roster data, per that story's AC: "this is the floor, not
/// a preview of G2".
class TripListEntry {
  const TripListEntry({
    required this.id,
    required this.title,
    required this.modes,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final List<String> modes;
  final DateTime updatedAt;
}
