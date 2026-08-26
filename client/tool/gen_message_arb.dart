/// Regenerates `lib/l10n/app_en.arb` from the M14 message registry
/// (FR145) — run `dart run tool/gen_message_arb.dart` from `client/`.
///
/// The registry is the source of truth *until M8 lands*, at which point the
/// ARB becomes the input and this script's output becomes the generated
/// `AppLocalizations`. Either way the two are never hand-kept in sync:
/// `test/message_arb_test.dart` fails if the committed ARB has drifted.
library;

import 'dart:io';

import 'package:plotlines_client/domain/message_catalog.dart';

void main() {
  final file = File('lib/l10n/app_en.arb');
  file.writeAsStringSync(messageArbSource());
  stdout.writeln('wrote ${file.path}');
}
