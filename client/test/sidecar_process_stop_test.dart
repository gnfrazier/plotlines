// #235 B6 — `_PosixSidecarProcess.stop`'s SIGTERM → grace → SIGKILL escalation.
//
// `sidecar_process.dart` sat at 21%, and everything covered was
// `buildWindowsCommandLine`'s quoting. The escalation itself — five lines that
// decide whether a stuck sidecar is left running when the app quits — had never
// executed. `sidecar_lifecycle_test.dart` covers the layer above it well
// (restart-once, orphan sweep, paired versions) but always against a fake
// process, so the real signal handling was untested on both sides.
//
// These drive real OS processes rather than a stub, because that is the only
// way to find out whether a SIGTERM is actually delivered and whether the
// SIGKILL fallback actually fires. `sh` is the subject: one that exits on
// SIGTERM, and one that traps and ignores it — which is exactly the sidecar
// wedged mid-build that the grace period exists for.
//
// POSIX only. Windows takes `_WindowsSidecarProcess`, whose Win32 FFI is
// verified on-device by `spikes/SPIKE-00/harness/` (see WINDOWS.md §3).
@TestOn('posix')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/sidecar_process.dart';

/// A child that exits promptly on SIGTERM — the ordinary case.
Future<SidecarProcess> _wellBehaved() =>
    SidecarProcess.start('sh', ['-c', 'sleep 30']);

/// A child that traps SIGTERM and keeps running — a sidecar wedged mid-build,
/// which is the case the grace period and the SIGKILL fallback exist for.
Future<SidecarProcess> _ignoresSigterm() => SidecarProcess.start('sh', [
      '-c',
      // `wait` rather than a bare `sleep` so the trap can be serviced.
      "trap '' TERM; sleep 30 & wait",
    ]);

bool _alive(int pid) {
  // Signal 0 checks for existence without delivering anything.
  final result = Process.runSync('kill', ['-0', '$pid']);
  return result.exitCode == 0;
}

void main() {
  test('a spawned sidecar reports a live PID', () async {
    final process = await _wellBehaved();
    addTearDown(() => process.stop(grace: const Duration(seconds: 2)));

    expect(process.pid, greaterThan(0));
    expect(_alive(process.pid), isTrue);
  });

  test('stop ends a well-behaved sidecar inside the grace period', () async {
    final process = await _wellBehaved();
    final pid = process.pid;

    final watch = Stopwatch()..start();
    await process.stop(grace: const Duration(seconds: 5));
    watch.stop();

    expect(_alive(pid), isFalse);
    // It should have gone on the SIGTERM, not by waiting out the grace.
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)),
        reason: 'SIGTERM was not delivered — stop waited out the grace instead');
  });

  test('a sidecar that ignores SIGTERM is killed once the grace elapses',
      () async {
    // The escalation. Without it, quitting the app would leave a wedged
    // sidecar holding its port, and the next launch would find it — the
    // orphan `sidecar_lifecycle_test.dart`'s sweep then has to clean up.
    final process = await _ignoresSigterm();
    final pid = process.pid;

    // Give `sh` a moment to install the trap, or the SIGTERM lands before it
    // and the test proves nothing.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(_alive(pid), isTrue);

    await process.stop(grace: const Duration(milliseconds: 500));

    // `kill -9` is asynchronous at the syscall boundary; give the reaper a
    // beat rather than racing it.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(_alive(pid), isFalse,
        reason: 'the grace period elapsed and no SIGKILL followed');
  });

  test('stop waits out the whole grace before escalating', () async {
    // The grace is what lets a sidecar finish writing a graph rather than
    // being killed mid-write. A stop that escalated immediately would make
    // the parameter a lie.
    final process = await _ignoresSigterm();
    addTearDown(() => Process.runSync('kill', ['-9', '${process.pid}']));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final watch = Stopwatch()..start();
    await process.stop(grace: const Duration(seconds: 1));
    watch.stop();

    expect(watch.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 900)));
  });

  test('exitCode settles once the process is gone', () async {
    final process = await _wellBehaved();

    await process.stop(grace: const Duration(seconds: 5));

    // Negative: POSIX reports a signal-terminated child as `-signal`.
    expect(await process.exitCode, isNot(0));
  });

  test('exitCode hands back the same future on every call', () async {
    // The manager awaits it from more than one place (the restart-once watcher
    // and the shutdown path); a second `Process.exitCode` listener on an
    // already-completed future must not hang.
    final process = await _wellBehaved();
    final first = process.exitCode;
    final second = process.exitCode;

    await process.stop(grace: const Duration(seconds: 5));

    expect(await first, await second);
  });

  test('stopping an already-dead sidecar is not an error', () async {
    // The orphan sweep and the ordinary shutdown can both reach a process
    // that has already exited; neither should throw.
    final process = await _wellBehaved();
    await process.stop(grace: const Duration(seconds: 5));

    await expectLater(
        process.stop(grace: const Duration(milliseconds: 200)), completes);
  });
}
