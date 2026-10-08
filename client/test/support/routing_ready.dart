// Issue #656 — the trip shell's Generate / Regenerate / Diagnose wait on the
// trip region's routing readiness (`tripRoutingCapabilityProvider`), the
// way New Route's Generate always has. A widget test that presses one and
// is not about readiness pins the region ready with this.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_client/data/sidecar_manager.dart' show CapabilityStatus;
import 'package:plotlines_client/state/trip_bbox_provider.dart';

/// Pin the trip region's routing capability to ready.
Override routingReady() =>
    tripRoutingCapabilityProvider.overrideWithValue(const CapabilityStatus(ready: true));
