// FR102–FR105a / FR110 (Story N4a) — the proposals review state: sort,
// filter, Defer (session, sinks below), Reject (persisted, undoable),
// bulk reject by filter, and re-run preserving prior rejections + marking
// what is new. Pure logic — no widgets, no live HTTP.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/curation_client.dart';
import 'package:plotlines_client/domain/candidate.dart' show RoleAffinity;
import 'package:plotlines_client/domain/cluster_proposal.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/state/proposals_provider.dart';

Map<String, dynamic> _member(String id, String layer, double sal, String aff) => {
      'candidate_id': id,
      'layer': layer,
      'type': '$layer=thing',
      'salience': sal,
      'role_affinity': aff,
      'title': id,
    };

Map<String, dynamic> _proposal(
  String id, {
  double rank = 0.5,
  double salience = 0.5,
  double? distance,
  bool isNew = true,
  List<Map<String, dynamic>>? members,
  List<String> affinities = const ['narrative'],
}) =>
    {
      'id': id,
      'name': id,
      'kind': affinities.join('+'),
      'role_affinities': affinities,
      'members': members ?? [_member('$id-a', 'historic', salience, affinities.first)],
      'centroid': [-82.0, 36.0],
      'extent_m': 40.0,
      'tightness': 0.8,
      'salience_score': salience,
      'rank_score': rank,
      'distance_to_route_m': distance,
      'is_new': isNew,
    };

ColocationResult _result(List<Map<String, dynamic>> proposals,
        {int cap = 30, int beyond = 0}) =>
    ColocationResult.fromJson({
      'proposals': proposals,
      'cap': cap,
      'n_beyond_cap': beyond,
      'n_candidates': 100,
      'ruleset_version': '1.2.0',
      'layers_served': ['historic', 'sight'],
      'layers_unavailable': <String, dynamic>{},
    });

class FakeCurationClient extends CurationClient {
  FakeCurationClient(this._next) : super('http://x');
  ColocationResult _next;
  int calls = 0;
  List<List<String>> lastRejected = [];
  List<List<String>> lastPrevious = [];

  void setNext(ColocationResult r) => _next = r;

  @override
  Future<ColocationResult> analyzeColocation({
    required TripBbox bbox,
    required Set<String> liveLayers,
    List<dynamic> route = const [],
    Iterable<Set<String>> rejected = const [],
    Iterable<Set<String>> previous = const [],
    String sort = 'rank',
  }) async {
    calls++;
    lastRejected = [for (final s in rejected) s.toList()..sort()];
    lastPrevious = [for (final s in previous) s.toList()..sort()];
    return _next;
  }
}

final _bbox = TripBbox(minLon: -82.1, minLat: 35.9, maxLon: -81.9, maxLat: 36.1);

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  final _live = <ProposalsNotifier>[];
  tearDown(() {
    for (final n in _live) {
      n.dispose();
    }
    _live.clear();
  });
  ProposalsNotifier notifier(FakeCurationClient client) {
    final n = ProposalsNotifier(db, client, 't1');
    _live.add(n);
    return n;
  }

  test('default sort is combined salience x tightness (rank_score), highest first', () async {
    final client = FakeCurationClient(_result([
      _proposal('low', rank: 0.2),
      _proposal('high', rank: 0.9),
      _proposal('mid', rank: 0.5),
    ]));
    final n = notifier(client);
    await n.analyze(bbox: _bbox, liveLayers: {'historic'});
    expect(n.state.visible.map((p) => p.id).toList(), ['high', 'mid', 'low']);
  });

  test('resort by distance-from-route, then by layer', () async {
    final client = FakeCurationClient(_result([
      _proposal('far', rank: 0.9, distance: 900),
      _proposal('near', rank: 0.3, distance: 100),
      _proposal('noroute', rank: 0.5, distance: null),
    ]));
    final n = notifier(client);
    await n.analyze(bbox: _bbox, liveLayers: {'historic'});

    n.setSort(ProposalSort.distanceFromRoute);
    expect(n.state.visible.map((p) => p.id).toList(), ['near', 'far', 'noroute']);

    n.setSort(ProposalSort.layer);
    expect(n.state.visible.first.members.first.layer, 'historic');
  });

  test('Defer keeps a proposal in the list but sinks it below the rest', () async {
    final client = FakeCurationClient(_result([
      _proposal('a', rank: 0.9),
      _proposal('b', rank: 0.5),
    ]));
    final n = notifier(client);
    await n.analyze(bbox: _bbox, liveLayers: {'historic'});
    n.defer('a');
    expect(n.state.visible.map((p) => p.id).toList(), ['b', 'a']);
    n.undefer('a');
    expect(n.state.visible.map((p) => p.id).toList(), ['a', 'b']);
  });

  test('Reject removes a proposal, persists it, and is undoable within the session', () async {
    final client = FakeCurationClient(_result([_proposal('a'), _proposal('b')]));
    final n = notifier(client);
    await n.analyze(bbox: _bbox, liveLayers: {'historic'});

    await n.reject('a');
    expect(n.state.visible.map((p) => p.id), ['b']);
    expect(await db.rejectedProposalIds('t1'), contains('a'));
    expect(n.state.lastUndoableRejectId, 'a');

    await n.undoReject('a');
    expect(n.state.visible.map((p) => p.id), containsAll(['a', 'b']));
    expect(await db.rejectedProposalIds('t1'), isEmpty);
  });

  test('re-running the analysis preserves prior rejections and passes them down', () async {
    final client = FakeCurationClient(_result([
      _proposal('a', members: [_member('a1', 'historic', 0.6, 'narrative')]),
      _proposal('b'),
    ]));
    final n = notifier(client);
    await n.analyze(bbox: _bbox, liveLayers: {'historic'});
    await n.reject('a');

    client.setNext(_result([_proposal('b'), _proposal('c')]));
    await n.analyze(bbox: _bbox, liveLayers: {'historic'});

    // the rejected proposal's member-id set was sent to the sidecar
    expect(client.lastRejected, contains(equals(['a1'])));
    // and it is still remembered
    expect(n.state.rejectedIds, contains('a'));
  });

  test('re-running sends the prior run membership so isNew can be computed', () async {
    final client = FakeCurationClient(_result([
      _proposal('a', members: [_member('a1', 'historic', 0.6, 'narrative')]),
    ]));
    final n = notifier(client);
    await n.analyze(bbox: _bbox, liveLayers: {'historic'});
    client.setNext(_result([_proposal('a2')]));
    await n.analyze(bbox: _bbox, liveLayers: {'historic'});
    expect(client.lastPrevious, contains(equals(['a1'])));
  });

  test('bulk reject by layer dismisses every matching visible proposal in one action', () async {
    final client = FakeCurationClient(_result([
      _proposal('tree1', members: [_member('t1', 'natural', 0.1, 'narrative')]),
      _proposal('tree2', members: [_member('t2', 'natural', 0.1, 'narrative')]),
      _proposal('keep', members: [_member('k1', 'historic', 0.8, 'narrative')]),
    ]));
    final n = notifier(client);
    await n.analyze(bbox: _bbox, liveLayers: {'natural', 'historic'});

    final rejected = await n.bulkReject(byLayer: 'natural');
    expect(rejected.toSet(), {'tree1', 'tree2'});
    expect(n.state.visible.map((p) => p.id), ['keep']);

    await n.undoBulk(rejected);
    expect(n.state.visible.map((p) => p.id).toSet(), {'tree1', 'tree2', 'keep'});
  });

  test('bulk reject below a salience threshold', () async {
    final client = FakeCurationClient(_result([
      _proposal('weak', salience: 0.15),
      _proposal('strong', salience: 0.85),
    ]));
    final n = notifier(client);
    await n.analyze(bbox: _bbox, liveLayers: {'historic'});
    await n.bulkReject(belowSalience: 0.3);
    expect(n.state.visible.map((p) => p.id), ['strong']);
  });

  test('filter by role narrows the visible list without rejecting anything', () async {
    final client = FakeCurationClient(_result([
      _proposal('n', affinities: ['narrative']),
      _proposal('p', affinities: ['provision']),
    ]));
    final n = notifier(client);
    await n.analyze(bbox: _bbox, liveLayers: {'historic', 'amenity'});
    n.setFilter(const ProposalFilter(role: RoleAffinity.provision));
    expect(n.state.visible.map((p) => p.id), ['p']);
    expect(await db.rejectedProposalIds('t1'), isEmpty); // filter != reject
    n.clearFilter();
    expect(n.state.visible.map((p) => p.id).toSet(), {'n', 'p'});
  });

  test('empty result is distinguished from never-run, and from an over-cap dense result', () async {
    final client = FakeCurationClient(_result([]));
    final n = notifier(client);
    expect(n.state.hasRun, isFalse);

    await n.analyze(bbox: _bbox, liveLayers: {'historic'});
    expect(n.state.hasRun, isTrue);
    expect(n.state.isEmptyResult, isTrue);

    client.setNext(_result([_proposal('a')], cap: 1, beyond: 40));
    await n.analyze(bbox: _bbox, liveLayers: {'historic'});
    expect(n.state.isEmptyResult, isFalse);
    expect(n.state.nBeyondCap, 40);
  });

  test('selection is list<->map shared state and survives a reject of another card', () async {
    final client = FakeCurationClient(_result([_proposal('a'), _proposal('b')]));
    final n = notifier(client);
    await n.analyze(bbox: _bbox, liveLayers: {'historic'});
    n.select('a');
    expect(n.state.selectedId, 'a');
    await n.reject('b');
    expect(n.state.selectedId, 'a'); // unaffected
    await n.reject('a');
    expect(n.state.selectedId, isNull); // clears when the selected card goes
  });

  test('a persisted rejection is reloaded for the trip on a fresh notifier', () async {
    await db.rejectProposal(tripId: 't1', proposalId: 'x');
    await db.setSetting('rejected_cluster_members:t1', '{"x":["x1","x2"]}');
    final client = FakeCurationClient(_result([_proposal('x'), _proposal('y')]));
    final n = notifier(client);
    await n.ready;
    await n.analyze(bbox: _bbox, liveLayers: {'historic'});
    expect(n.state.visible.map((p) => p.id), ['y']);
    expect(client.lastRejected, contains(equals(['x1', 'x2'])));
  });
}
