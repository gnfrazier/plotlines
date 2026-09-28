# data

RoutingClient (→ HTTP, local|hosted), `app_database.dart` (→ drift local storage; no sync yet),
SidecarManager (→ M12 lifecycle, `sidecar_*.dart`), FieldRuntime (→ offline GPS engine, ARCH §6),
CurationClient (→ layers, candidates, clusters),
PluginRegistry + OutputIntegration + SecureStore (→ `plugins/`, ARCH §14.3 — FR84's
output half: the seam is declared, no destination is named), RevealView (→ `reveal_view.dart`,
the object that crosses a content boundary: reveal, attribution, and encoded bytes).
A group relay agent (ARCH §9, store-and-forward) is not built. See ARCH §10.1.
