# domain

Trip, Day, Segment, WeightProfile, RiderProfile, FieldNote, Amendment — pure Dart, no I/O. See ARCH §9.1.

**Four of those seven are the trip payload; three are not** (SPIKE-20). `Trip`, `Day`,
`Segment` and `WeightProfile` (plus every nested `$defs` shape they carry — `Node`,
`Hazard`, `Cue`, `RouteMetrics`, ...) deserialize from `trip.payload` against
[`docs/schemas/trip_payload.schema.json`](../../../docs/schemas/trip_payload.schema.json),
which is the authority for their field names and types (ARCH D28: where the schema
and `plotlines_core.trips.payload` disagree, the schema wins). `RiderProfile` is
account-scoped and `FieldNote`/`Amendment` are group-relay layers over the canon (P8) —
they have their own tables and write paths, and never live inside the trip blob. Those
three are not implemented here yet.

The payload classes live in this directory now (`trip.dart`, `day.dart`, `segment.dart`,
`weight_profile.dart`, and friends — see `domain.dart` for the full barrel export),
hand-authored against the schema and cross-checked against
[`spikes/SPIKE-20/dart/lib/domain.dart`](../../../spikes/SPIKE-20/dart/lib/domain.dart)
and [SPIKE-20's results](../../../spikes/SPIKE-20/results/RESULTS.md), which
round-tripped an earlier version of this shape against real solved trips with zero
field loss. Two things about it are requirements rather than style, both measured by
SPIKE-20 and enforced in `json_utils.dart`'s `JsonFields` helper:

* **Read every fractional field through `num`, never `as double`.** `{"distance_m": 4}`
  is valid against the schema and throws on a `double` cast — validation cannot catch
  it, only the reader can.
* **Reads are exhaustive.** Popping each key and failing on the remainder is what makes
  `additionalProperties: false` true at the client as well as at the validator; a
  `fromJson` that silently ignores a field drops it on the next write.

No pub packages beyond plain Dart: no code generation, no `build_runner`, no
serialization library. `fromJson`/`toJson` are hand-written on every class.
