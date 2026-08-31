# FIT SDK licence — what the spike found, and what still needs counsel

**Task (from the issue):** "Check the FIT SDK's licence terms for redistribution
while you are there."

**Status: directional, not cleared.** This is a reading of the public licence
text, not legal advice. The load-bearing point for the F3 decision is that the
Python-in-core arm **does not redistribute the FIT SDK at all**, so most of the
questions below only bite the Dart-FFI arm.

## What the FIT protocol / SDK licence says (public text, FIT SDK 21.x)

The SDK ships under the **"Flexible and Interoperable Data Transfer (FIT)
Protocol License Agreement"** (Garmin / Dynastream). Salient clauses:

| Clause | Effect on us |
|---|---|
| Grants a licence to use the SDK to build applications that read/write FIT files | Both arms are in-scope uses. |
| Permits redistribution of the SDK **as part of** an application that communicates with FIT products | The Dart-FFI arm would redistribute the C/C++ SDK (or a Dart port of it) inside the desktop binary and the mobile app — allowed, but see below. |
| Prohibits redistributing the SDK **on its own** or in a form that "competes with" the SDK | A vendored copy inside our binary is fine; publishing our build of it as a standalone package is not. |
| Requires retention of copyright / licence notices | Adds a `LICENSE`/`NOTICE` obligation to every platform bundle the FFI arm ships — desktop (Win/macOS/Linux), iOS, Android. |
| Prohibits modifying the FIT protocol itself | We must not "extend" FIT with private messages in the exported files. (We don't intend to.) |
| Restricts use of Garmin/ANT/FIT trademarks | No "Garmin" in our UI copy for the feature; "FIT" only as the format name. |
| Disclaims all warranty; no support obligation | The FFI arm's native dependency has no upstream SLA. |
| The **FIT protocol specification** is openly published; there is **no per-file or per-seat royalty** | The Python-in-core arm, which implements the documented protocol without shipping Garmin code, carries **no redistribution obligation and no notice obligation** beyond our own. |

## The asymmetry that matters for the decision

- **Python-in-core arm:** implements the openly published protocol. Ships **no
  Garmin code**. No SDK licence redistribution clause applies. The only IP
  surface is the protocol spec itself, which is published for exactly this use.
- **Dart-FFI-against-official-SDK arm:** ships Garmin's SDK (native, per
  platform). Pulls in the notice/attribution obligation on five platform
  bundles, the "don't ship it standalone" constraint on our release tooling, and
  a native dependency with no warranty — on a binary already carrying GDAL/GEOS
  (**risk A5**).

## Open — needs counsel before the FFI arm could ship

1. Confirm the **current** licence text at the SDK download gate (it is
   click-through and has been revised; this note is against the 21.x era text).
2. Confirm "as part of an application" covers an **open-source** distribution of
   the Plotlines client, not just a closed binary.
3. Confirm the notice obligation's exact placement requirement (in-app "about",
   bundled file, or both) for each target OS store.
4. Confirm a **pure-Python re-implementation** of the protocol (the in-core arm)
   is unencumbered — near-certain given the spec is published, but it is the one
   line worth a lawyer's sign-off since it is the recommended path.
