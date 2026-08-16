# spike14_harness

The SPIKE-14 rendering harness — a Flutter Linux desktop app that draws a real routed
polyline with node markers over a vector basemap, drives a scripted pan/zoom, and prints
frame-timing JSON to stdout.

Not an application and not a starting point for one: it exists to answer whether the
Author Desktop map is buildable on Flutter desktop, and it is kept because the
measurements in [`../results/RESULTS.md`](../results/RESULTS.md) should be reproducible.

See [`../README.md`](../README.md) for how to run it, what the environment variables do,
and the two things that will silently invalidate a measurement (the persistent tile
cache at `/tmp/.vector_map`, and any other process on the CPU).

Build in **profile** mode — `vector_map_tiles` disables its isolate concurrency in debug
builds, so debug frame times measure a configuration we would never ship:

```bash
flutter build linux --profile
```
