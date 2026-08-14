# packaging

Frozen-binary build, installers, and signing for the desktop distribution (ARCH §12).

## version.lock

`version.lock` holds the one version string both build artifacts — the frozen Python
sidecar and the Flutter client — stamp themselves with at build time. The client checks
the sidecar's reported version (via `/health`) against its own at runtime and refuses a
mismatch (ARCH §12.1). This is the concrete implementation of risk A8's mitigation: the
two artifacts version-lock instead of quietly diverging.

At this stage the seam is wired but not enforced — there is no build pipeline yet to read
`version.lock` into either artifact, and no runtime check to perform it. That lands with
the sidecar prototype (MVP doc §6, item 6).

## Open decisions

See `TODO.md` for the two deferred packaging decisions (Q4 freezer choice, Q5
bundle-vs-download).
