import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// The OS process the sidecar runs as, behind a platform-specific
/// implementation (ARCH §7.3; SPIKE-00 `WINDOWS.md` §3).
///
/// **POSIX** is a plain `dart:io` [Process]: `SIGTERM`, then `SIGKILL` after a
/// grace period. The child is spawned into its own session so the
/// next-launch orphan sweep can still find a survivor if the client dies
/// without cleaning up.
///
/// **Windows cannot deliver `SIGTERM` at all** — `Process.kill` there is
/// `TerminateProcess`, an unblockable hard kill that runs no handler and
/// severs whatever request is in flight. The only catchable stop is a
/// console control event, and a Flutter GUI process has no console to send
/// one through. So the Windows implementation does not use `dart:io`: it
///
///  * spawns via Win32 `CreateProcess` with
///    `CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW` — the child owns a
///    console with no visible window, which is what makes it addressable by
///    a control event without anything flashing on screen;
///  * pins the child in a Job Object with
///    `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` so the OS reaps it if this client
///    exits without cleanup (crash, `taskkill`) — Windows has no process
///    groups to sweep and never reparents, so the POSIX next-launch sweep
///    has no analogue here;
///  * stops it with `AttachConsole` + a muted default Ctrl handler +
///    `GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT)`, hard-killing only if the
///    grace period elapses.
abstract class SidecarProcess {
  /// Spawns [executable] with [args]. On Windows this applies the creation
  /// flags and Job Object described above; on POSIX it is `Process.start`.
  static Future<SidecarProcess> start(String executable, List<String> args) {
    if (Platform.isWindows) {
      return _WindowsSidecarProcess.start(executable, args);
    }
    return _PosixSidecarProcess.start(executable, args);
  }

  /// The child PID.
  int get pid;

  /// Completes with the process's exit code once it has exited for any
  /// reason — graceful stop, crash, or an external kill. Returns the same
  /// future on every call.
  Future<int> get exitCode;

  /// Asks the sidecar to shut down gracefully, then hard-kills it if it has
  /// not exited within [grace].
  Future<void> stop({required Duration grace});
}

class _PosixSidecarProcess implements SidecarProcess {
  _PosixSidecarProcess._(this._process);

  final Process _process;

  static Future<SidecarProcess> start(
    String executable,
    List<String> args,
  ) async {
    final process = await Process.start(executable, args);
    return _PosixSidecarProcess._(process);
  }

  @override
  int get pid => _process.pid;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  Future<void> stop({required Duration grace}) async {
    _process.kill(ProcessSignal.sigterm);
    final exited =
        await _process.exitCode.timeout(grace, onTimeout: () => -1);
    if (exited == -1) _process.kill(ProcessSignal.sigkill);
  }
}

// --- Windows ---------------------------------------------------------------
//
// Win32 flag / signal / limit values. These are part of the frozen Win32
// ABI; they are spelled out here rather than imported because win32 5.15
// does not export several of the symbols this path needs —
// `GenerateConsoleCtrlEvent`, `ResumeThread`, and the `JOBOBJECT_*` structs
// among them — so the file already has to reach past the package for those,
// and mixing package constants with hand-written ones is worse than one
// consistent set.

const int _createSuspended = 0x00000004;
const int _createNewProcessGroup = 0x00000200;
const int _createNoWindow = 0x08000000;
const int _ctrlBreakEvent = 1;
const int _jobObjectInfoClassExtendedLimit = 9; // JobObjectExtendedLimitInformation
const int _jobObjectLimitKillOnJobClose = 0x00002000;
const int _waitObject0 = 0x00000000;
const int _waitTimeout = 0x00000102;

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

/// `BOOL GenerateConsoleCtrlEvent(DWORD dwCtrlEvent, DWORD dwProcessGroupId)`
/// — not exported by win32 5.15.
final int Function(int dwCtrlEvent, int dwProcessGroupId)
    _generateConsoleCtrlEvent = _kernel32.lookupFunction<
        Int32 Function(Uint32, Uint32),
        int Function(int, int)>('GenerateConsoleCtrlEvent');

/// `DWORD ResumeThread(HANDLE hThread)` — not exported by win32 5.15.
final int Function(int hThread) _resumeThread = _kernel32.lookupFunction<
    Uint32 Function(IntPtr),
    int Function(int)>('ResumeThread');

// The three JOBOBJECT_* structs win32 5.15 does not provide. Field order and
// types are the Win32 headers'; Dart's default natural alignment matches the
// MSVC layout (no `#pragma pack` is in effect for these), so `sizeOf` gives
// the value `SetInformationJobObject` expects.

final class _JobObjectBasicLimitInformation extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;
  @Int64()
  external int perJobUserTimeLimit;
  @Uint32()
  external int limitFlags;
  @IntPtr()
  external int minimumWorkingSetSize;
  @IntPtr()
  external int maximumWorkingSetSize;
  @Uint32()
  external int activeProcessLimit;
  @IntPtr()
  external int affinity;
  @Uint32()
  external int priorityClass;
  @Uint32()
  external int schedulingClass;
}

final class _IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;
  @Uint64()
  external int writeOperationCount;
  @Uint64()
  external int otherOperationCount;
  @Uint64()
  external int readTransferCount;
  @Uint64()
  external int writeTransferCount;
  @Uint64()
  external int otherTransferCount;
}

final class _JobObjectExtendedLimitInformation extends Struct {
  external _JobObjectBasicLimitInformation basicLimitInformation;
  external _IoCounters ioInfo;
  @IntPtr()
  external int processMemoryLimit;
  @IntPtr()
  external int jobMemoryLimit;
  @IntPtr()
  external int peakProcessMemoryUsed;
  @IntPtr()
  external int peakJobMemoryUsed;
}

class _WindowsSidecarProcess implements SidecarProcess {
  _WindowsSidecarProcess._(this._processHandle, this.pid, this._jobHandle) {
    // No `Process.exitCode` future on this path — poll the handle instead.
    // 200 ms is well inside the health-poll cadence the manager already runs
    // at, and cold start dominates start-up by ~45× regardless.
    _reaper = Timer.periodic(const Duration(milliseconds: 200), (_) => _poll());
  }

  final int _processHandle;
  final int _jobHandle; // 0 if the Job Object could not be set up
  @override
  final int pid;

  final Completer<int> _exitCompleter = Completer<int>();
  Timer? _reaper;

  @override
  Future<int> get exitCode => _exitCompleter.future;

  static Future<SidecarProcess> start(
    String executable,
    List<String> args,
  ) async {
    final appNamePtr = executable.toNativeUtf16();
    // CreateProcess may write into lpCommandLine, so it gets its own buffer.
    final commandLinePtr =
        buildWindowsCommandLine(executable, args).toNativeUtf16();
    final startupInfo = calloc<STARTUPINFO>()..ref.cb = sizeOf<STARTUPINFO>();
    final processInfo = calloc<PROCESS_INFORMATION>();

    try {
      final created = CreateProcess(
        appNamePtr,
        commandLinePtr,
        nullptr, // default process security
        nullptr, // default thread security
        FALSE, // do not inherit handles
        _createNewProcessGroup | _createNoWindow | _createSuspended,
        nullptr, // inherit the client's environment
        nullptr, // inherit the client's working directory
        startupInfo,
        processInfo,
      );
      if (created == FALSE) {
        throw StateError(
          'CreateProcess failed for $executable (WinError ${GetLastError()})',
        );
      }

      final processHandle = processInfo.ref.hProcess;
      final threadHandle = processInfo.ref.hThread;
      final pid = processInfo.ref.dwProcessId;

      final jobHandle = _assignKillOnCloseJob(processHandle);

      // Created suspended so the Job Object is in place before the child
      // runs a single instruction — no window in which it could spawn or
      // orphan anything unheld.
      _resumeThread(threadHandle);
      CloseHandle(threadHandle);

      return _WindowsSidecarProcess._(processHandle, pid, jobHandle);
    } finally {
      malloc.free(appNamePtr);
      malloc.free(commandLinePtr);
      calloc.free(startupInfo);
      calloc.free(processInfo);
    }
  }

  /// Creates a Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` and puts
  /// [processHandle] in it. The job handle is held for the lifetime of this
  /// object; if the client process dies, the OS closes the handle and reaps
  /// the sidecar with it (SPIKE-00 `WINDOWS.md` §3). Returns 0 if any step
  /// fails — the sidecar still runs, just without the orphan backstop, which
  /// is no worse than the pre-FFI `taskkill` behaviour.
  static int _assignKillOnCloseJob(int processHandle) {
    final jobHandle = CreateJobObject(nullptr, nullptr);
    if (jobHandle == 0) {
      debugPrint(
        'sidecar: CreateJobObject failed (WinError ${GetLastError()}); '
        'continuing without orphan protection',
      );
      return 0;
    }

    final limits = calloc<_JobObjectExtendedLimitInformation>();
    limits.ref.basicLimitInformation.limitFlags = _jobObjectLimitKillOnJobClose;
    final configured = SetInformationJobObject(
      jobHandle,
      _jobObjectInfoClassExtendedLimit,
      limits,
      sizeOf<_JobObjectExtendedLimitInformation>(),
    );
    calloc.free(limits);

    if (configured == FALSE ||
        AssignProcessToJobObject(jobHandle, processHandle) == FALSE) {
      debugPrint(
        'sidecar: Job Object setup failed (WinError ${GetLastError()}); '
        'continuing without orphan protection',
      );
      CloseHandle(jobHandle);
      return 0;
    }
    return jobHandle;
  }

  void _poll() {
    final wait = WaitForSingleObject(_processHandle, 0);
    if (wait == _waitTimeout) return; // still running

    _reaper?.cancel();
    _reaper = null;

    var code = -1;
    if (wait == _waitObject0) {
      final out = calloc<Uint32>();
      if (GetExitCodeProcess(_processHandle, out) != FALSE) code = out.value;
      calloc.free(out);
    }

    CloseHandle(_processHandle);
    if (_jobHandle != 0) CloseHandle(_jobHandle);
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(code);
  }

  @override
  Future<void> stop({required Duration grace}) async {
    if (_exitCompleter.isCompleted) return;

    final attached = AttachConsole(pid) != FALSE;
    var mutedOwnHandler = false;
    if (attached) {
      // A console control event reaches every process sharing that console,
      // this one included. A real Dart replacement handler is not an option:
      // the OS calls console handlers on a thread it creates, and a Dart FFI
      // callback invoked off the main isolate's thread crashes the VM. The
      // NULL form is handled inside kernel32 with no callback, so use that
      // for the brief window we are attached.
      mutedOwnHandler = SetConsoleCtrlHandler(nullptr, TRUE) != FALSE;
      // dwProcessGroupId == pid: the child is its own group leader
      // (CREATE_NEW_PROCESS_GROUP), so the event lands only on it.
      _generateConsoleCtrlEvent(_ctrlBreakEvent, pid);
    } else {
      debugPrint(
        'sidecar: AttachConsole($pid) failed (WinError ${GetLastError()}); '
        'no graceful stop available — hard kill after grace',
      );
    }

    final code =
        await _exitCompleter.future.timeout(grace, onTimeout: () => -1);

    if (mutedOwnHandler) SetConsoleCtrlHandler(nullptr, FALSE);
    if (attached) FreeConsole();

    if (code == -1 && !_exitCompleter.isCompleted) {
      TerminateProcess(_processHandle, 1);
      await _exitCompleter.future
          .timeout(const Duration(seconds: 2), onTimeout: () => -1);
    }
  }
}

/// Builds the single command-line string Win32 `CreateProcess` takes from an
/// argv-style list, quoting each token per the MSVCRT rules that
/// `CommandLineToArgvW` reverses: a run of backslashes is literal unless it
/// precedes a `"` (or ends a quoted span), where each backslash must be
/// doubled and a literal `"` escaped as `\"`.
///
/// Exposed for tests because everything else on the Windows path is FFI that
/// only runs on Windows.
@visibleForTesting
String buildWindowsCommandLine(String executable, List<String> args) {
  final buffer = StringBuffer(_quoteWindowsArg(executable));
  for (final arg in args) {
    buffer
      ..write(' ')
      ..write(_quoteWindowsArg(arg));
  }
  return buffer.toString();
}

String _quoteWindowsArg(String arg) {
  if (arg.isNotEmpty && !arg.contains(RegExp(r'[ \t\n\v"]'))) return arg;

  final buffer = StringBuffer('"');
  final units = arg.codeUnits;
  for (var i = 0; i < units.length; i++) {
    var backslashes = 0;
    while (i < units.length && units[i] == 0x5C) {
      backslashes++;
      i++;
    }

    if (i == units.length) {
      // Escape trailing backslashes so they don't escape the closing quote.
      buffer.write('\\' * (backslashes * 2));
      break;
    } else if (units[i] == 0x22) {
      // Escape the backslashes that precede this quote, then the quote.
      buffer
        ..write('\\' * (backslashes * 2 + 1))
        ..writeCharCode(units[i]);
    } else {
      buffer
        ..write('\\' * backslashes)
        ..writeCharCode(units[i]);
    }
  }
  buffer.write('"');
  return buffer.toString();
}
