# domain

Trip, Day, Segment, WeightProfile, RiderProfile, FieldNote, Amendment — pure Dart, no I/O. See ARCH §9.1.

**Four of those seven are the trip payload; three are not** (SPIKE-20). `Trip`, `Day`,
`Segment` and `WeightProfile` deserialize from `trip.payload` against
[`docs/schemas/trip_payload.schema.json`](../../../docs/schemas/trip_payload.schema.json),
which is the authority for their field names and types. `RiderProfile` is
account-scoped and `FieldNote`/`Amendment` are group-relay layers over the canon (P8) —
they have their own tables and write paths, and never live inside the trip blob.

A working implementation of the four payload classes exists at
[`spikes/SPIKE-20/dart/lib/domain.dart`](../../../spikes/SPIKE-20/dart/lib/domain.dart),
round-tripped against real solved trips with zero field loss. Two things about it are
requirements rather than style, both measured in
[SPIKE-20's results](../../../spikes/SPIKE-20/results/RESULTS.md):

* **Read every fractional field through `num`, never `as double`.** `{"distance_m": 4}`
  is valid against the schema and throws on a `double` cast — validation cannot catch
  it, only the reader can.
* **Reads are exhaustive.** Popping each key and failing on the remainder is what makes
  `additionalProperties: false` true at the client as well as at the validator; a
  `fromJson` that silently ignores a field drops it on the next write.
