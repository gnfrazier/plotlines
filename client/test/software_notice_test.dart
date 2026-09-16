// Issue #267, addendum L5 — parsing `GET /about`'s `software_notices` field.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/software_notice.dart';

void main() {
  group('softwareNoticesFrom', () {
    test('parses a well-formed list', () {
      final notices = softwareNoticesFrom([
        {'name': 'pyinstaller', 'version': '6.22.3', 'licence': 'GPL-2.0-or-later', 'text': 'full text'},
      ]);
      expect(notices, hasLength(1));
      expect(notices.single.name, 'pyinstaller');
      expect(notices.single.version, '6.22.3');
      expect(notices.single.licence, 'GPL-2.0-or-later');
      expect(notices.single.text, 'full text');
    });

    test('returns an empty list when absent, never a hardcoded fallback', () {
      // Unlike attributionLinesFrom, there is no static obligation to fall
      // back to here — "no bundle" is a true, expected state.
      expect(softwareNoticesFrom(null), isEmpty);
    });

    test('returns an empty list rather than throwing on malformed input', () {
      expect(softwareNoticesFrom('not a list'), isEmpty);
      expect(softwareNoticesFrom([1, 2, 3]), isEmpty);
    });
  });
}
