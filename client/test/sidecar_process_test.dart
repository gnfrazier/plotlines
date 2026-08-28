// The Windows sidecar lifecycle (ARCH §7.3, SPIKE-00 WINDOWS.md §3) is Win32
// FFI that only runs on Windows and is verified end-to-end by
// `spikes/SPIKE-00/harness/`. The one piece with logic worth unit-testing in
// isolation is the argv -> single-string quoting `CreateProcess` needs, since
// a cache-dir path with a space in it (`C:\Users\First Last\...`) is the
// common case and getting the backslash/quote rules wrong silently splits an
// argument.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/sidecar_process.dart';

void main() {
  group('buildWindowsCommandLine', () {
    test('leaves space-free tokens unquoted', () {
      expect(
        buildWindowsCommandLine('plotlines-sidecar.exe', [
          '--port=52111',
          '--host=127.0.0.1',
          '--mode=sidecar',
        ]),
        'plotlines-sidecar.exe --port=52111 --host=127.0.0.1 --mode=sidecar',
      );
    });

    test('quotes a token containing a space, backslashes left literal', () {
      expect(
        buildWindowsCommandLine('C:\\Program Files\\Plotlines\\sidecar.exe', [
          '--cache-dir=C:\\Users\\First Last\\AppData\\Roaming\\Plotlines',
        ]),
        '"C:\\Program Files\\Plotlines\\sidecar.exe" '
            '"--cache-dir=C:\\Users\\First Last\\AppData\\Roaming\\Plotlines"',
      );
    });

    test('doubles a run of backslashes only when it precedes a quote', () {
      // `a\\"b` -> the two backslashes are doubled and the quote escaped.
      expect(buildWindowsCommandLine('x', ['a\\\\"b']), 'x "a\\\\\\\\\\"b"');
    });

    test('doubles trailing backslashes so they do not escape the close quote', () {
      expect(
        buildWindowsCommandLine('x', ['C:\\path with space\\']),
        'x "C:\\path with space\\\\"',
      );
    });

    test('escapes an embedded quote in an otherwise plain token', () {
      expect(buildWindowsCommandLine('x', ['a"b']), 'x "a\\"b"');
    });
  });
}
