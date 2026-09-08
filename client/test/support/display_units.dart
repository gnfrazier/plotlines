// Issue #312 — `displayFormatProvider` now feeds every distance the planning,
// logistics, export and itinerary surfaces render, and it resolves from the
// OS locale (via `PlatformDisplayDefaults.detect()`) when nothing is stored.
// The `flutter_test` default locale is `en_US`, so an un-pinned provider
// resolves to **miles/feet** in a widget test. These overrides pin a widget
// tree to a known unit system so a test asserts the string it means to.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_client/state/settings_provider.dart';

/// Pin the tree to kilometres / metres.
Override metricUnits() =>
    displayFormatProvider.overrideWithValue(const DisplayFormat());

/// Pin the tree to miles / feet.
Override imperialUnits() => displayFormatProvider
    .overrideWithValue(const DisplayFormat(useMiles: true));
