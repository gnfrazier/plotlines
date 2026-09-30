// The app's own fonts, for a test that measures layout. Flutter tests render
// with a square-glyph font by default, which wraps every label far sooner
// than the shipped typefaces do (#328's 900 px rail check).
library;

import 'dart:io';

import 'package:flutter/services.dart';

bool _loaded = false;

Future<void> loadAppFonts() async {
  if (_loaded) return;
  const dir = 'packages/plotlines_ui/assets/fonts';
  Future<ByteData> read(String name) async =>
      ByteData.sublistView(Uint8List.fromList(await File('$dir/$name').readAsBytes()));
  await (FontLoader('Archivo')..addFont(read('Archivo-Variable.ttf'))).load();
  await (FontLoader('JetBrains Mono')..addFont(read('JetBrainsMono-Variable.ttf'))).load();
  await (FontLoader('Instrument Serif')..addFont(read('InstrumentSerif-Regular.ttf'))).load();
  _loaded = true;
}
