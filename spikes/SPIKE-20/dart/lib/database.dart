/// drift's local trip store (ARCH §10.3), reproduced exactly as the architecture
/// writes it: `trip(id, name, version, updated_at, payload, dirty, server_version)`.
///
/// The one design question this file answers for SPIKE-20: **what SQLite type does
/// `payload` get?** drift offers a `TextColumn().map(...)` JSON converter, which
/// hands the domain layer a decoded object and looks tidier. This uses a plain
/// `TextColumn` and decodes explicitly instead, because the converter would put the
/// JSON codec inside the database layer — and then the payload's rules (absent
/// means unset, floats stay floats) would be enforced in two places, one of which
/// nothing else can see. SQLite has no native JSON type; the column is TEXT either
/// way, which is also why local storage preserves key order and Postgres JSONB
/// (§10.1) will not.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

part 'database.g.dart';

/// ARCH §10.3, verbatim.
class Trips extends Table {
  TextColumn get id => text()();

  TextColumn get name => text()();

  /// FR59's comparison key. Monotonic, bumped on write — and deliberately NOT
  /// inside the payload, so a stored blob can never disagree with its own row.
  IntColumn get version => integer().withDefault(const Constant(1))();

  DateTimeColumn get updatedAt => dateTime()();

  /// The canonical plotline (P8) as JSON text.
  TextColumn get payload => text()();

  /// Changed since the last successful sync? Always true on desktop MVP, which has
  /// nothing to sync to.
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  IntColumn get serverVersion => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Trips])
class LocalDatabase extends _$LocalDatabase {
  LocalDatabase(super.executor);

  LocalDatabase.atPath(String path) : super(NativeDatabase(File(path)));

  @override
  int get schemaVersion => 1;

  Future<void> saveTrip({
    required String id,
    required String name,
    required String payload,
    required int version,
  }) =>
      into(trips).insertOnConflictUpdate(TripsCompanion.insert(
        id: id,
        name: name,
        payload: payload,
        updatedAt: DateTime.now().toUtc(),
        version: Value(version),
      ));

  Future<Trip> loadTrip(String id) =>
      (select(trips)..where((t) => t.id.equals(id))).getSingle();

  /// The obvious way to write G2a's list surface — and the wrong one. `select(trips)`
  /// is `SELECT *`, so every row drags its whole payload into memory to draw a title
  /// and a timestamp. Kept here because SPIKE-20 measures the difference against the
  /// projected query below rather than asserting it.
  Future<List<Trip>> listTrips() => (select(trips)
        ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
      .get();

  /// G2a — "a list surface shows every locally saved trip with title, modes and
  /// last-edited time, sorted most-recent-first". Projects three columns and never
  /// touches `payload`.
  Future<List<TripSummary>> listTripSummaries() async {
    final query = selectOnly(trips)
      ..addColumns([trips.id, trips.name, trips.updatedAt])
      ..orderBy([OrderingTerm.desc(trips.updatedAt)]);
    final rows = await query.get();
    return rows
        .map((row) => TripSummary(
              id: row.read(trips.id)!,
              name: row.read(trips.name)!,
              updatedAt: row.read(trips.updatedAt)!,
            ))
        .toList();
  }
}

/// What a trip-library row actually needs. Modes come from the payload and are the
/// one thing G2a asks for that a column does not carry — SPIKE-20's recommendation
/// is a denormalized `modes` column rather than decoding a megabyte per row.
class TripSummary {
  TripSummary({required this.id, required this.name, required this.updatedAt});

  final String id;
  final String name;
  final DateTime updatedAt;
}
