# data

RoutingClient (→ HTTP, local|hosted), TripRepository (→ drift local + sync), FieldRuntime
(→ offline GPS engine, ARCH §5), GroupRelayAgent (→ ARCH §8, store-and-forward),
PluginRegistry + OutputIntegration + SecureStore (→ `plugins/`, ARCH §14.3 — FR84's
output half: the seam is declared, no destination is named), RevealView (→ `reveal_view.dart`,
the object that crosses a content boundary: reveal, attribution, and encoded bytes).
See ARCH §9.1.
