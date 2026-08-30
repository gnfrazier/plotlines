// M12 — the sidecar-lifecycle test suite named in the story's AC and in
// ARCH §12: ephemeral-port binding, the mid-session death-and-restart rule
// ("restarts once, then a second failure degrades honestly"), and the
// next-launch orphan sweep after an ungraceful client exit.
//
// The Win32 FFI stop path is verified separately (see sidecar_process_test.dart
// and spikes/SPIKE-00/harness/), and the per-capability /health parsing has
// its own suite (sidecar_manager_capabilities_test.dart). What is left is the
// lifecycle logic, exercised here without spawning a real process.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/data/sidecar_registry.dart';

/// The recorded entries left in an orphan-registry file, for asserting what a
/// sweep retained versus pruned (issue #183).
List<Map<String, dynamic>> entriesInFile(File file) {
  if (!file.existsSync()) return const [];
  final raw = jsonDecode(file.readAsStringSync());
  if (raw is! Map || raw['entries'] is! List) return const [];
  return [for (final e in raw['entries'] as List) (e as Map).cast<String, dynamic>()];
}

void main() {
  group('pickEphemeralPort (M12: "spawn binds an ephemeral port")', () {
    test('returns a real, non-privileged port', () async {
      final port = await pickEphemeralPort();
      expect(port, greaterThan(1024));
      expect(port, lessThanOrEqualTo(65535));
    });

    test('releases the socket so the caller can bind the port it was given', () async {
      final port = await pickEphemeralPort();
      // If pickEphemeralPort had held the socket, this bind would throw.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      expect(server.port, port);
      await server.close();
    });

    test('successive calls hand out usable ports even while earlier ones are held', () async {
      final held = <ServerSocket>[];
      final ports = <int>{};
      for (var i = 0; i < 5; i++) {
        final port = await pickEphemeralPort();
        ports.add(port);
        held.add(await ServerSocket.bind(InternetAddress.loopbackIPv4, port));
      }
      expect(ports.length, 5, reason: 'every pick was a distinct free port');
      for (final s in held) {
        await s.close();
      }
    });
  });

  group('decideOnSidecarExit (M12: restart once, then degrade)', () {
    test('a deliberate stop settles to stopped', () {
      expect(
        decideOnSidecarExit(stoppingDeliberately: true, alreadyRestarted: false),
        SidecarExitDecision.stop,
      );
    });

    test('a deliberate stop still settles to stopped even after a restart', () {
      expect(
        decideOnSidecarExit(stoppingDeliberately: true, alreadyRestarted: true),
        SidecarExitDecision.stop,
      );
    });

    test('the first unexpected exit restarts exactly once', () {
      expect(
        decideOnSidecarExit(stoppingDeliberately: false, alreadyRestarted: false),
        SidecarExitDecision.restartOnce,
      );
    });

    test('a second unexpected exit degrades honestly instead of looping', () {
      expect(
        decideOnSidecarExit(stoppingDeliberately: false, alreadyRestarted: true),
        SidecarExitDecision.degrade,
      );
    });
  });

  group('sidecarVersionIsPaired (M12: "the app refuses to run on a mismatch")', () {
    test('identical stamps are a pair', () {
      expect(sidecarVersionIsPaired('1.4.2', '1.4.2'), isTrue);
    });

    test('surrounding whitespace is ignored on either side', () {
      expect(sidecarVersionIsPaired('1.4.2\n', '  1.4.2 '), isTrue);
    });

    test('any difference is a mismatch — the app must refuse', () {
      expect(sidecarVersionIsPaired('1.4.2', '1.4.3'), isFalse);
      expect(sidecarVersionIsPaired('1.4.2', '1.4.2-dev'), isFalse);
    });

    test('an empty stamp on either side is never a pair', () {
      expect(sidecarVersionIsPaired('', ''), isFalse);
      expect(sidecarVersionIsPaired('1.4.2', ''), isFalse);
      expect(sidecarVersionIsPaired('   ', '1.4.2'), isFalse);
    });
  });

  group('SidecarRegistry — the next-launch orphan sweep (ARCH §8.4)', () {
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('plotlines_orphan_test');
      file = File('${dir.path}/orphan_registry.json');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    SidecarRegistry registry({
      Set<int> alive = const {},
      Set<int> sidecarPorts = const {},
      List<int>? killed,
      bool actOnThisPlatform = true,
    }) {
      return SidecarRegistry(
        file,
        actOnThisPlatform: actOnThisPlatform,
        isProcessAlive: alive.contains,
        respondsAsSidecar: (port) async => sidecarPorts.contains(port),
        terminate: (pid) async => killed?.add(pid),
      );
    }

    test('record then re-read round-trips the entry', () async {
      await registry().record(4242, 51000);
      final raw = await file.readAsString();
      expect(raw, contains('4242'));
      expect(raw, contains('51000'));
    });

    test('recording the same PID twice keeps a single entry', () async {
      final r = registry();
      await r.record(4242, 51000);
      await r.record(4242, 51001);
      final killed = <int>[];
      await registry(alive: {4242}, sidecarPorts: {51001}, killed: killed).sweep();
      expect(killed, [4242]);
    });

    test('forget removes one entry and leaves the others', () async {
      final r = registry();
      await r.record(10, 5000);
      await r.record(20, 5001);
      await r.forget(10);
      final killed = <int>[];
      await registry(alive: {10, 20}, sidecarPorts: {5000, 5001}, killed: killed).sweep();
      expect(killed, [20]);
    });

    test('forget of an unrecorded PID is a no-op', () async {
      final r = registry();
      await r.record(20, 5001);
      await r.forget(999);
      final killed = <int>[];
      await registry(alive: {20}, sidecarPorts: {5001}, killed: killed).sweep();
      expect(killed, [20]);
    });

    test('sweep terminates a survivor that is alive AND still answers as a sidecar', () async {
      await registry().record(777, 52000);
      final killed = <int>[];
      final swept =
          await registry(alive: {777}, sidecarPorts: {52000}, killed: killed).sweep();
      expect(swept, [777]);
      expect(killed, [777]);
    });

    test('sweep leaves a dead PID alone', () async {
      await registry().record(777, 52000);
      final killed = <int>[];
      final swept = await registry(alive: {}, sidecarPorts: {52000}, killed: killed).sweep();
      expect(swept, isEmpty);
      expect(killed, isEmpty);
    });

    test('sweep leaves a recycled PID alone when its old port is not a sidecar', () async {
      // PID 777 is live again, but owned by something unrelated now — the
      // recorded port answers nothing.
      await registry().record(777, 52000);
      final killed = <int>[];
      final swept = await registry(alive: {777}, sidecarPorts: {}, killed: killed).sweep();
      expect(swept, isEmpty);
      expect(killed, isEmpty);
    });

    test('sweep clears the registry afterward so the next launch starts clean', () async {
      await registry().record(777, 52000);
      await registry(alive: {777}, sidecarPorts: {52000}).sweep();
      final swept2 = await registry(alive: {777}, sidecarPorts: {52000}).sweep();
      expect(swept2, isEmpty, reason: 'entries were consumed by the first sweep');
    });

    test('sweep on a missing registry file is a silent no-op', () async {
      expect(await file.exists(), isFalse);
      final swept = await registry(alive: {1}, sidecarPorts: {1}).sweep();
      expect(swept, isEmpty);
    });

    test('a corrupt registry file never blocks startup', () async {
      await file.writeAsString('{ this is not json');
      final killed = <int>[];
      final swept = await registry(alive: {1}, sidecarPorts: {1}, killed: killed).sweep();
      expect(swept, isEmpty);
      expect(killed, isEmpty);
    });

    test('sweep is a no-op off-POSIX (Windows relies on the Job Object)', () async {
      await registry().record(777, 52000);
      final killed = <int>[];
      final swept = await registry(
        alive: {777},
        sidecarPorts: {52000},
        killed: killed,
        actOnThisPlatform: false,
      ).sweep();
      expect(swept, isEmpty);
      expect(killed, isEmpty);
    });

    test('a terminate that throws is swallowed and the sweep still completes', () async {
      await registry().record(1, 100);
      await registry().record(2, 200);
      final killed = <int>[];
      final r = SidecarRegistry(
        file,
        actOnThisPlatform: true,
        isProcessAlive: {1, 2}.contains,
        respondsAsSidecar: (p) async => {100, 200}.contains(p),
        terminate: (pid) async {
          if (pid == 1) throw const OSError('boom');
          killed.add(pid);
        },
      );
      final swept = await r.sweep();
      expect(swept, [2], reason: 'pid 1 threw, pid 2 still handled');
      expect(killed, [2]);
    });

    // --- issue #183: a sweep only removes what it resolved -----------------

    test('an alive entry that fails the /health probe is kept for the next sweep', () async {
      await registry().record(900, 53000);
      final killed = <int>[];

      // Sweep 1: the process is up but still booting — /health times out.
      final swept1 = await registry(alive: {900}, sidecarPorts: {}, killed: killed).sweep();
      expect(swept1, isEmpty);
      expect(killed, isEmpty);
      expect(entriesInFile(file).single['pid'], 900,
          reason: 'a provisionally-skipped survivor must not be erased');

      // Sweep 2: boot finished, it answers now — it is still known, so reaped.
      final swept2 = await registry(alive: {900}, sidecarPorts: {53000}, killed: killed).sweep();
      expect(swept2, [900]);
      expect(killed, [900]);
      expect(entriesInFile(file), isEmpty);
    });

    test('an entry whose terminate throws is retained for a later retry', () async {
      await registry().record(901, 53001);

      final failing = SidecarRegistry(
        file,
        actOnThisPlatform: true,
        isProcessAlive: {901}.contains,
        respondsAsSidecar: (p) async => p == 53001,
        terminate: (_) async => throw const OSError('kill failed'),
      );
      final swept1 = await failing.sweep();
      expect(swept1, isEmpty);
      expect(entriesInFile(file).single['pid'], 901,
          reason: 'a failed kill leaves the entry alive — it must survive the sweep');

      final killed = <int>[];
      final swept2 = await registry(alive: {901}, sidecarPorts: {53001}, killed: killed).sweep();
      expect(swept2, [901]);
      expect(entriesInFile(file), isEmpty);
    });

    test('a confirmed-dead entry is pruned', () async {
      await registry().record(902, 53002);
      await registry(alive: {}, sidecarPorts: {53002}).sweep();
      expect(entriesInFile(file), isEmpty);
    });

    test('a confirmed-killed entry is pruned', () async {
      await registry().record(903, 53003);
      await registry(alive: {903}, sidecarPorts: {53003}, killed: []).sweep();
      expect(entriesInFile(file), isEmpty);
    });

    test('a stuck-unidentifiable entry is dropped once the attempt bound is hit', () async {
      await registry().record(904, 53004);
      for (var i = 0; i < 12; i++) {
        await registry(alive: {904}, sidecarPorts: {}).sweep();
      }
      expect(entriesInFile(file), isEmpty,
          reason: 'bounded retention must not carry a stuck entry forever');
    });

    test('an unresolved entry older than the age bound is dropped', () async {
      file.writeAsStringSync('{"entries":[{"pid":905,"port":53005,'
          '"spawned_at":"2020-01-01T00:00:00.000Z"}]}');
      await registry(alive: {905}, sidecarPorts: {}).sweep();
      expect(entriesInFile(file), isEmpty);
    });

    test('a registry written before sweep_attempts existed still sweeps', () async {
      file.writeAsStringSync('{"entries":[{"pid":906,"port":53006,'
          '"spawned_at":"2026-08-30T00:00:00.000Z"}]}');
      final killed = <int>[];
      final swept =
          await registry(alive: {906}, sidecarPorts: {53006}, killed: killed).sweep();
      expect(swept, [906]);
    });

    test('a retained entry carries an incremented attempt count', () async {
      await registry().record(907, 53007);
      await registry(alive: {907}, sidecarPorts: {}).sweep();
      expect(entriesInFile(file).single['sweep_attempts'], 1);
      await registry(alive: {907}, sidecarPorts: {}).sweep();
      expect(entriesInFile(file).single['sweep_attempts'], 2);
    });
  });

  group('SidecarManager wires the registry in', () {
    test('sweepOrphans delegates to the injected registry', () async {
      final dir = await Directory.systemTemp.createTemp('plotlines_mgr_sweep');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/orphan_registry.json')
        ..writeAsStringSync('{"entries":[{"pid":424242,"port":53000,'
            '"spawned_at":"2026-01-01T00:00:00.000Z"}]}');
      final killed = <int>[];
      final manager = SidecarManager(
        registry: SidecarRegistry(
          file,
          actOnThisPlatform: true,
          isProcessAlive: {424242}.contains,
          respondsAsSidecar: (p) async => p == 53000,
          terminate: (pid) async => killed.add(pid),
        ),
      );
      final swept = await manager.sweepOrphans();
      expect(swept, [424242]);
      expect(killed, [424242]);
    });
  });
}
