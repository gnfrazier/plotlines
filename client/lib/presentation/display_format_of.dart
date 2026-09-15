// K5 / FR79 (issue #399) — the one place a surface that renders a **date or
// a clock time** resolves `inherit` against the device.
//
// `displayFormatProvider` carries the stored preferences and is complete
// for distance and temperature, which have no `inherit`. Date and clock do:
// FR79 says `inherit` "defers to the platform's own locale pattern … and
// resolves at render time rather than being frozen at install", and the
// plumbing for that (`DisplayFormat.platformDateFormatter` /
// `platformUses24Hour`) existed from K5 onward with no caller supplying it,
// so every inherited date read as ISO 8601 and every inherited clock as
// 24-hour whatever the machine said. This attaches the answers a
// `BuildContext` can give and nothing else, so a widget test that pins
// `displayFormatProvider` still pins the preferences it means to.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/settings_provider.dart';

export '../state/settings_provider.dart' show DisplayFormat;

/// The Author's [DisplayFormat] with the device's current `inherit` answers
/// attached. Use this — not `displayFormatProvider` directly — from any
/// widget that formats a [DateTime] for display.
///
/// The date pattern comes from [MaterialLocalizations.formatShortDate]
/// (`Sep 12, 2026` in the default `en_US` localisation — month-name rather
/// than numeric because a fresh install should never show a date a
/// mixed-locale party can read two ways; the numeric forms are one menu
/// choice away). It follows the app's locale the day the app registers
/// localisation delegates, with nothing to change here. The clock comes
/// from [MediaQueryData.alwaysUse24HourFormat], which is the platform's own
/// flag surfaced through the view.
DisplayFormat displayFormatOf(BuildContext context, WidgetRef ref) {
  final material = Localizations.of<MaterialLocalizations>(context, MaterialLocalizations);
  return ref.watch(displayFormatProvider).withPlatform(
        dateFormatter: material?.formatShortDate,
        uses24Hour: MediaQuery.maybeOf(context)?.alwaysUse24HourFormat,
      );
}
