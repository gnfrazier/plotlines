// M12 — `SidecarManager.start()` against real (scripted) child processes.
//
// `sidecar_lifecycle_test.dart` covers the lifecycle *rules* as pure
// functions; this drives the manager itself, because the defects it pins
// live in how those rules are wired to real process exits and async polls:
//
//  * a binary that cannot be launched must settle on "won't start" rather
//    than escape `start()` as an unhandled error (leaving the gate on
//    "checking sidecar version" forever);
//  * a sidecar that dies at startup twice must *stay* degraded — the
//    abandoned startup polls used to keep writing "starting up" over it;
//  * Retry after a health-check timeout must not leak the first sidecar
//    beside the new one.
//
// POSIX only — the subjects are `sh` scripts.
@TestOn('posix')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/data/sidecar_registry.dart';
import 'package:plotlines_client/data/sidecar_upstreams.dart';

bool _alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

/// A stand-in sidecar binary: answers `--version` with the client's own
/// stamp (so the A8 pairing passes), and otherwise runs [body].
String _script(Directory dir, String body) {
  final file = File('${dir.path}/fake-sidecar');
  file.writeAsStringSync('#!/bin/sh\n'
      'if [ "\$1" = "--version" ]; then echo "${resolveClientVersion()}"; exit 0; fi\n'
      '$body\n');
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

SidecarManager _manager(Directory dir, String binary, {Duration? startupTimeout}) =>
    SidecarManager(
      binaryOverride: binary,
      cacheDirOverride: dir,
      registry: SidecarRegistry(File('${dir.path}/orphan_registry.json')),
      upstreams: SidecarUpstreams.none,
      startupTimeout: startupTimeout ?? const Duration(seconds: 60),
    );

Future<void> _until(bool Function() done, {Duration within = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(within);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not reached within $within');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('plotlines_launch'));
  tearDown(() => dir.delete(recursive: true));

  test('a binary that cannot be run settles on failed instead of throwing', () async {
    final manager = _manager(dir, '${dir.path}/no-such-sidecar');
    addTearDown(manager.dispose);

    await expectLater(manager.start(), completes);

    expect(manager.status.state, SidecarState.failed);
    expect(manager.status.detail, 'the sidecar could not be launched');
  });

  test('a sidecar that dies at startup twice stays degraded', () async {
    final manager = _manager(dir, _script(dir, 'exit 3'));
    addTearDown(manager.dispose);

    await manager.start().timeout(const Duration(seconds: 15));
    await _until(() => manager.status.state == SidecarState.degraded);

    // The two abandoned startup polls ran every 500 ms; give them several
    // ticks to prove they no longer overwrite the settled state.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(manager.status.state, SidecarState.degraded);
  });

  test('Retry after a health-check timeout stops the first sidecar', () async {
    final pids = File('${dir.path}/pids');
    final manager = _manager(
      dir,
      _script(dir, 'echo \$\$ >> "${pids.path}"; exec sleep 30'),
      startupTimeout: const Duration(seconds: 1),
    );
    addTearDown(() async {
      await manager.stop();
      manager.dispose();
      for (final pid in pids.readAsLinesSync()) {
        Process.killPid(int.parse(pid), ProcessSignal.sigkill);
      }
    });

    await manager.start();
    expect(manager.status.state, SidecarState.failed);
    final first = int.parse(pids.readAsLinesSync().single);
    expect(_alive(first), isTrue);

    await manager.start(); // SidecarGate's Retry
    expect(manager.status.state, SidecarState.failed);
    final all = pids.readAsLinesSync().map(int.parse).toList();
    expect(all, hasLength(2));
    await _until(() => !_alive(first));
    expect(_alive(all.last), isTrue);
    // Retiring the first never counted as a crash to restart from.
    expect(pids.readAsLinesSync(), hasLength(2));
  });
}
