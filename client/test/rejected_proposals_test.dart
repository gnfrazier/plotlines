// FR110 (Story O1) — "rejected proposals are remembered for the trip so the
// same cluster is not re-proposed on every run."
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('a rejected proposal is remembered for its trip', () async {
    await db.rejectProposal(tripId: 't1', proposalId: 'cluster-1');
    expect(await db.rejectedProposalIds('t1'), {'cluster-1'});
  });

  test('rejections are scoped per trip', () async {
    await db.rejectProposal(tripId: 't1', proposalId: 'cluster-1');
    expect(await db.rejectedProposalIds('t2'), isEmpty);
  });

  test('rejecting the same proposal twice does not duplicate it', () async {
    await db.rejectProposal(tripId: 't1', proposalId: 'cluster-1');
    await db.rejectProposal(tripId: 't1', proposalId: 'cluster-1');
    expect(await db.rejectedProposalIds('t1'), {'cluster-1'});
  });

  test('unrejecting removes it from the remembered set (session undo)', () async {
    await db.rejectProposal(tripId: 't1', proposalId: 'cluster-1');
    await db.unrejectProposal(tripId: 't1', proposalId: 'cluster-1');
    expect(await db.rejectedProposalIds('t1'), isEmpty);
  });

  test('multiple rejections for one trip all persist', () async {
    await db.rejectProposal(tripId: 't1', proposalId: 'cluster-1');
    await db.rejectProposal(tripId: 't1', proposalId: 'cluster-2');
    expect(await db.rejectedProposalIds('t1'), {'cluster-1', 'cluster-2'});
  });
}
