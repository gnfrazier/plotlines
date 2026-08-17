import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import 'providers.dart';

/// G2a — save, reopen, list. Projected rows only (SPIKE-20: no `SELECT *`).
final tripLibraryProvider =
    FutureProvider.autoDispose<List<TripListEntry>>((ref) {
  return ref.read(appDatabaseProvider).listTrips();
});
