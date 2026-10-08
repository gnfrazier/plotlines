// Epic #641 (ARCH D73, story #647) — the client tells the sidecar which held
// map areas live trips still need: the full set of live trips' stored
// bboxes, on every change and on every sidecar (re)start, with no trip id
// or title anywhere in what is sent.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/state/cache_references_sync.dart';

class _Manager extends SidecarManager {
  SidecarState state = SidecarState.starting;
  String url = 'http://127.0.0.1:4001';

  @override
  SidecarStatus get status => SidecarStatus(state);

  @override
  String get baseUrl => url;

  void set({SidecarState? to, String? newUrl}) {
    if (to != null) state = to;
    if (newUrl != null) url = newUrl;
    notifyListeners();
  }
}

Future<void> _save(AppDatabase db, String id, String title, String bboxJson) =>
    db.saveTrip(
      id: id,
      title: title,
      modes: const ['cycling'],
      payloadJson: '{}',
      updatedAt: DateTime.utc(2026, 10, 7),
      bboxJson: bboxJson,
    );

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late AppDatabase db;
  late _Manager manager;
  late List<(String, List<List<double>>)> sent;
  late CacheReferencesSync sync;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    manager = _Manager();
    sent = [];
    sync = CacheReferencesSync(
      bboxes: db.watchTripBboxes(),
      manager: manager,
      send: (url, bboxes) async => sent.add((url, bboxes)),
    );
  });

  tearDown(() async {
    sync.dispose();
    await db.close();
  });

  test('nothing is sent before the sidecar is ready', () async {
    await _save(db, 't1', 'Blue Ridge', '[-82.6,35.5,-82.5,35.6]');
    await _settle();
    expect(sent, isEmpty);
    manager.set(to: SidecarState.ready);
    await _settle();
    expect(sent.single.$2, [
      [-82.6, 35.5, -82.5, 35.6]
    ]);
  });

  test('create, edit and delete each send the full set; an undrawn trip is left out', () async {
    manager.set(to: SidecarState.ready);
    await _save(db, 't1', 'Blue Ridge', '[-82.6,35.5,-82.5,35.6]');
    await _save(db, 't2', 'Greensboro', '[-79.9,36.0,-79.8,36.1]');
    await _save(db, 't3', 'Not drawn yet', '');
    await _settle();
    expect(sent.last.$2.toSet().length, 2);

    await _save(db, 't2', 'Greensboro', '[-79.95,36.0,-79.8,36.1]');
    await _settle();
    expect(sent.last.$2, contains(equals([-79.95, 36.0, -79.8, 36.1])));

    await db.deleteTrip('t1');
    await _settle();
    expect(sent.last.$2, [
      [-79.95, 36.0, -79.8, 36.1]
    ]);
  });

  test('an unchanged set is not resent, but a restarted sidecar gets it again', () async {
    manager.set(to: SidecarState.ready);
    await _save(db, 't1', 'Blue Ridge', '[-82.6,35.5,-82.5,35.6]');
    await _settle();
    final before = sent.length;
    manager.set();
    await _settle();
    expect(sent.length, before);

    manager.set(to: SidecarState.restarting);
    manager.set(to: SidecarState.ready, newUrl: 'http://127.0.0.1:4002');
    await _settle();
    expect(sent.length, before + 1);
    expect(sent.last.$1, 'http://127.0.0.1:4002');
  });

  test('a failed send is tried again on the next change', () async {
    var fail = true;
    sync.dispose();
    sync = CacheReferencesSync(
      bboxes: db.watchTripBboxes(),
      manager: manager,
      send: (url, bboxes) async {
        if (fail) throw const SocketException('down');
        sent.add((url, bboxes));
      },
    );
    manager.set(to: SidecarState.ready);
    await _save(db, 't1', 'Blue Ridge', '[-82.6,35.5,-82.5,35.6]');
    await _settle();
    expect(sent, isEmpty);
    fail = false;
    manager.set();
    await _settle();
    expect(sent.single.$2.single, [-82.6, 35.5, -82.5, 35.6]);
  });

  test('the request body carries bboxes only — no trip id or title', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <String>[];
    server.listen((request) async {
      bodies.add('${request.method} ${request.uri.path} '
          '${await utf8.decoder.bind(request).join()}');
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"references":1,"areas":0,"referenced":0}');
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    await RoutingClient('http://127.0.0.1:${server.port}')
        .putCacheReferences([
      [-82.6, 35.5, -82.5, 35.6]
    ]);

    expect(bodies.single, 'PUT /cache/references {"bboxes":[[-82.6,35.5,-82.5,35.6]]}');
    expect(bodies.single.toLowerCase(), isNot(contains('trip')));
    expect(bodies.single, isNot(contains('Blue Ridge')));
  });
}
