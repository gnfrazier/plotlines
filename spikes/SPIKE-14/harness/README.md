# spike14_harness

The SPIKE-14 rendering harness — a Flutter desktop app (Linux **and** Windows) that draws
a real routed polyline with node markers over a vector basemap, drives a scripted
pan/zoom, and prints frame-timing JSON to stdout.

Not an application and not a starting point for one: it exists to answer whether the
Author Desktop map is buildable on Flutter desktop, and it is kept because the
measurements in [`../results/RESULTS.md`](../results/RESULTS.md) should be reproducible.

See [`../README.md`](../README.md) for how to run it, what the environment variables do,
and the two things that will silently invalidate a measurement (the persistent tile
cache at `/tmp/.vector_map`, and any other process on the CPU).

Build in **profile** mode — `vector_map_tiles` disables its isolate concurrency in debug
builds, so debug frame times measure a configuration we would never ship:

```bash
flutter build linux --profile      # → build/linux/x64/profile/bundle/spike14_harness
flutter build windows --profile    # → build/windows/x64/runner/Profile/spike14_harness.exe
```

The Windows runner under `windows/` was generated with `flutter create --platforms=windows .`
and is committed as-is; **no source change was needed to render on Windows**, only a
non-Linux fallback for the RSS probe (`/proc/self/status` does not exist there, and the
original returned a silent zero).

One thing to watch if you regenerate the platform folder: `flutter create` re-resolves
dependencies and moved four transitive packages, which would have measured a different
dependency set than the Linux run. `pubspec.lock` is committed precisely so that cannot
happen quietly — restore it and re-run `flutter pub get` before building.
