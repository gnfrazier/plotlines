/// FR102–FR105a / FR110 (Story N4a) — state for the proposals review view:
/// the co-location result, the Author's session-scoped Defer set, the
/// trip-scoped Reject set (persisted, undoable within the session), the sort
/// and filter, and the list↔map selection.
///
/// The list is the primary surface (N4a); this notifier is what both the
/// list and the synchronized map read. Nothing here writes canon (ARCH P10)
/// — Promote is the only path into `trip.payload`, and it runs through the
/// existing promotion interaction (O1), not this notifier.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../data/curation_client.dart';
import '../domain/candidate.dart' show RoleAffinity;
import '../domain/cluster_proposal.dart';
import '../domain/json_utils.dart' show Coord;
import '../domain/trip_bbox.dart';
import 'current_trip_provider.dart';
import 'providers.dart';

/// N4a — "default sort is combined salience × tightness, resortable by
/// distance-from-route or by layer." Corridor proximity is a resort, never
/// folded into the default rank (SPIKE-B / ARCH Q12).
enum ProposalSort { rank, distanceFromRoute, layer }

class ProposalFilter {
  const ProposalFilter({this.role, this.layer, this.maxDistanceToRouteM, this.minSalience});

  final RoleAffinity? role;
  final String? layer;
  final double? maxDistanceToRouteM;
  final double? minSalience;

  bool get isActive =>
      role != null || layer != null || maxDistanceToRouteM != null || minSalience != null;

  bool matches(ClusterProposal p) {
    if (role != null && !p.roleAffinities.contains(role)) return false;
    if (layer != null && !p.members.any((m) => m.layer == layer)) return false;
    if (minSalience != null && p.salienceScore < minSalience!) return false;
    if (maxDistanceToRouteM != null) {
      final d = p.distanceToRouteM;
      if (d == null || d > maxDistanceToRouteM!) return false;
    }
    return true;
  }

  ProposalFilter copyWith({
    Object? role = _sentinel,
    Object? layer = _sentinel,
    Object? maxDistanceToRouteM = _sentinel,
    Object? minSalience = _sentinel,
  }) =>
      ProposalFilter(
        role: role == _sentinel ? this.role : role as RoleAffinity?,
        layer: layer == _sentinel ? this.layer : layer as String?,
        maxDistanceToRouteM: maxDistanceToRouteM == _sentinel
            ? this.maxDistanceToRouteM
            : maxDistanceToRouteM as double?,
        minSalience: minSalience == _sentinel ? this.minSalience : minSalience as double?,
      );

  static const _sentinel = Object();
}

class ProposalsState {
  const ProposalsState({
    this.result,
    this.loading = false,
    this.error,
    this.sort = ProposalSort.rank,
    this.filter = const ProposalFilter(),
    this.deferredIds = const {},
    this.rejectedIds = const {},
    this.selectedId,
    this.lastUndoableRejectId,
  });

  final ColocationResult? result;
  final bool loading;
  final String? error;
  final ProposalSort sort;
  final ProposalFilter filter;

  /// Session-scoped (N4a: Defer "stays in the list, sorts below").
  final Set<String> deferredIds;

  /// Trip-scoped and persisted; a re-run does not re-propose these (FR110).
  final Set<String> rejectedIds;

  /// The card selected in the list — the map highlights its extent, and a
  /// tap on the map's cluster sets this (N4a's list↔map sync).
  final String? selectedId;

  /// The most recent reject, for the one-gesture session undo.
  final String? lastUndoableRejectId;

  bool get hasRun => result != null;

  /// N4a — "no clusters found says so and suggests widening layers or the
  /// bbox." Distinct from [hasRun] being false (never run yet).
  bool get isEmptyResult => result != null && result!.proposals.isEmpty && result!.nBeyondCap == 0;

  int get nBeyondCap => result?.nBeyondCap ?? 0;

  /// The proposals to show, in order: not rejected, filter applied, sorted,
  /// with deferred proposals moved to the bottom (still visible).
  List<ClusterProposal> get visible {
    final all = result?.proposals ?? const <ClusterProposal>[];
    final kept = [
      for (final p in all)
        if (!rejectedIds.contains(p.id) && filter.matches(p)) p,
    ];
    int cmp(ClusterProposal a, ClusterProposal b) {
      final ad = deferredIds.contains(a.id), bd = deferredIds.contains(b.id);
      if (ad != bd) return ad ? 1 : -1; // deferred sink below
      switch (sort) {
        case ProposalSort.rank:
          return b.rankScore.compareTo(a.rankScore);
        case ProposalSort.distanceFromRoute:
          final av = a.distanceToRouteM ?? double.infinity;
          final bv = b.distanceToRouteM ?? double.infinity;
          final c = av.compareTo(bv);
          return c != 0 ? c : b.rankScore.compareTo(a.rankScore);
        case ProposalSort.layer:
          final c = _primaryLayer(a).compareTo(_primaryLayer(b));
          return c != 0 ? c : b.rankScore.compareTo(a.rankScore);
      }
    }

    return [...kept]..sort(cmp);
  }

  static String _primaryLayer(ClusterProposal p) =>
      p.members.isEmpty ? '' : p.members.first.layer;

  ProposalsState copyWith({
    Object? result = _sentinel,
    bool? loading,
    Object? error = _sentinel,
    ProposalSort? sort,
    ProposalFilter? filter,
    Set<String>? deferredIds,
    Set<String>? rejectedIds,
    Object? selectedId = _sentinel,
    Object? lastUndoableRejectId = _sentinel,
  }) =>
      ProposalsState(
        result: result == _sentinel ? this.result : result as ColocationResult?,
        loading: loading ?? this.loading,
        error: error == _sentinel ? this.error : error as String?,
        sort: sort ?? this.sort,
        filter: filter ?? this.filter,
        deferredIds: deferredIds ?? this.deferredIds,
        rejectedIds: rejectedIds ?? this.rejectedIds,
        selectedId: selectedId == _sentinel ? this.selectedId : selectedId as String?,
        lastUndoableRejectId: lastUndoableRejectId == _sentinel
            ? this.lastUndoableRejectId
            : lastUndoableRejectId as String?,
      );

  static const _sentinel = Object();
}

class ProposalsNotifier extends StateNotifier<ProposalsState> {
  ProposalsNotifier(this._db, this._client, this._tripId) : super(const ProposalsState());

  final AppDatabase _db;
  final CurationClient _client;
  final String _tripId;

  String get _memberKey => 'rejected_cluster_members:$_tripId';

  /// Member-id sets for every rejected proposal, so a re-run can be told what
  /// not to re-propose even after membership drifts (ARCH §4.4's jaccard).
  Map<String, Set<String>> _rejectedMembers = {};

  /// Completes once the persisted reject set has been read back. Exposed so
  /// a test (or a screen that wants to gate its first render) can await the
  /// warm-up rather than race it.
  late final Future<void> ready = _loadRejected();

  Future<void> _loadRejected() async {
    try {
      final ids = await _db.rejectedProposalIds(_tripId);
      if (!mounted) return;
      final raw = await _db.getSetting(_memberKey);
      if (!mounted) return;
      if (raw != null) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _rejectedMembers = {
          for (final e in decoded.entries) e.key: (e.value as List).cast<String>().toSet(),
        };
      }
      state = state.copyWith(rejectedIds: ids);
    } catch (_) {
      // A torn-down provider whose DB has already closed — nothing to load.
      if (mounted) rethrow;
    }
  }

  Future<void> _persistMembers() =>
      _db.setSetting(_memberKey, jsonEncode({
        for (final e in _rejectedMembers.entries) e.key: e.value.toList(),
      }));

  // --------------------------------------------------------------- analyze

  /// FR102 — the named Author action. [route] is the current route polyline
  /// (lon/lat), when one exists; passing it enables the corridor sort/filter
  /// and grows the reviewable cap.
  Future<void> analyze({
    required TripBbox bbox,
    required Set<String> liveLayers,
    List<Coord> route = const [],
  }) async {
    await ready;
    state = state.copyWith(loading: true, error: null);
    // The prior run's membership, so proposals unchanged since last time are
    // not flagged `isNew` (N4a).
    final previous = [for (final p in state.result?.proposals ?? const <ClusterProposal>[]) p.memberIds];
    try {
      final result = await _client.analyzeColocation(
        bbox: bbox,
        liveLayers: liveLayers,
        route: route,
        rejected: _rejectedMembers.values,
        previous: previous,
        sort: 'rank',
      );
      state = state.copyWith(
        result: result,
        loading: false,
        // Re-running preserves prior rejections (they are still in
        // `rejectedIds` and were passed as `rejected`), and clears the stale
        // selection.
        selectedId: null,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  // ---------------------------------------------------------- selection/sort

  void select(String? id) => state = state.copyWith(selectedId: id);

  void setSort(ProposalSort sort) => state = state.copyWith(sort: sort);

  void setFilter(ProposalFilter filter) => state = state.copyWith(filter: filter);

  void clearFilter() => state = state.copyWith(filter: const ProposalFilter());

  // ------------------------------------------------------------ defer

  void defer(String id) =>
      state = state.copyWith(deferredIds: {...state.deferredIds, id});

  void undefer(String id) =>
      state = state.copyWith(deferredIds: state.deferredIds.where((x) => x != id).toSet());

  // ------------------------------------------------------------ reject

  ClusterProposal? _proposal(String id) =>
      state.result?.proposals.where((p) => p.id == id).firstOrNull;

  Future<void> reject(String id) async {
    final p = _proposal(id);
    if (p != null) _rejectedMembers[id] = p.memberIds;
    await _db.rejectProposal(tripId: _tripId, proposalId: id);
    await _persistMembers();
    state = state.copyWith(
      rejectedIds: {...state.rejectedIds, id},
      deferredIds: state.deferredIds.where((x) => x != id).toSet(),
      selectedId: state.selectedId == id ? null : state.selectedId,
      lastUndoableRejectId: id,
    );
  }

  /// N4a — "undoable within the session".
  Future<void> undoReject(String id) async {
    _rejectedMembers.remove(id);
    await _db.unrejectProposal(tripId: _tripId, proposalId: id);
    await _persistMembers();
    state = state.copyWith(
      rejectedIds: state.rejectedIds.where((x) => x != id).toSet(),
      lastUndoableRejectId:
          state.lastUndoableRejectId == id ? null : state.lastUndoableRejectId,
    );
  }

  /// N4a — "Bulk reject by filter … so an Author dismisses forty street-tree
  /// proposals in one action rather than forty." Rejects every currently
  /// *visible* proposal that also matches the given predicate. Returns the
  /// ids rejected, so the caller can offer a single undo.
  Future<List<String>> bulkReject({
    RoleAffinity? byRole,
    String? byLayer,
    double? belowSalience,
  }) async {
    final targets = <ClusterProposal>[
      for (final p in state.visible)
        if ((byRole == null || p.roleAffinities.contains(byRole)) &&
            (byLayer == null || p.members.any((m) => m.layer == byLayer)) &&
            (belowSalience == null || p.salienceScore < belowSalience))
          p,
    ];
    for (final p in targets) {
      _rejectedMembers[p.id] = p.memberIds;
      await _db.rejectProposal(tripId: _tripId, proposalId: p.id);
    }
    await _persistMembers();
    final ids = [for (final p in targets) p.id];
    state = state.copyWith(
      rejectedIds: {...state.rejectedIds, ...ids},
      selectedId: ids.contains(state.selectedId) ? null : state.selectedId,
    );
    return ids;
  }

  Future<void> undoBulk(List<String> ids) async {
    for (final id in ids) {
      _rejectedMembers.remove(id);
      await _db.unrejectProposal(tripId: _tripId, proposalId: id);
    }
    await _persistMembers();
    state = state.copyWith(rejectedIds: state.rejectedIds.where((x) => !ids.contains(x)).toSet());
  }
}

/// One notifier per open trip. Autodisposed with the workspace.
final proposalsProvider =
    StateNotifierProvider.autoDispose<ProposalsNotifier, ProposalsState>((ref) {
  final tripId = ref.watch(currentTripProvider.select((t) => t.id));
  final n = ProposalsNotifier(
    ref.watch(appDatabaseProvider),
    ref.watch(curationClientProvider),
    tripId,
  );
  n.ready; // kick off the persisted-rejections warm-up
  return n;
});
