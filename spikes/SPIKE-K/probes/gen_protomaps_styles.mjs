// Generate the five Protomaps-native candidate styles from upstream's own
// generator, unmodified.
//
// Protomaps does not publish static style JSONs for its basemap: the
// canonical artefact is `@protomaps/basemaps`' `layers(source, flavor, opts)`
// function, which is what SPIKE-14 extracted its `style_light.json` from and
// what maps.protomaps.com serves. Calling that with a named flavor and no
// overrides *is* "the real upstream style" — there is nothing more upstream
// to fetch. Every option here is the generator's own default (English labels,
// the upstream glyph host, the upstream v4 sprite sheet for the two flavors
// that ship one); nothing is hand-tuned, so the comparison stays honest.
//
// The one input we supply is the tile source URL, and even that is a
// placeholder the harness swaps for the configured mirror URL at load time
// (harness/index.html `rewriteSources`) — the style files stay
// host-independent and identical in every respect except the flavor.
//
// Pairing that matters: the corridor archive reports `version 4.15.2` in its
// PMTiles metadata (the *tileset* schema), and `@protomaps/basemaps` 5.7.2 is
// the generator release whose layers target that v4 schema (its sprite path
// is `/sprites/v4/`). The npm package's major version diverged from the
// tileset's; do not read "5.7.2 vs 4.15.2" as a mismatch.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { layers, namedFlavor } from "@protomaps/basemaps";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const pkgVersion = require("@protomaps/basemaps/package.json").version;

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(here, "..", "harness", "styles");
fs.mkdirSync(outDir, { recursive: true });

// Placeholder; see header. The harness replaces every vector source's `url`.
const TILES_PLACEHOLDER = "pmtiles://corridor.pmtiles";
const LANG = "en";

// Order is the issue's priority order, with White/Black in the slots the
// schema-risk check vacated (see README §2).
const FLAVORS = ["light", "dark", "grayscale", "white", "black"];

for (const flavor of FLAVORS) {
  const style = {
    version: 8,
    name: `protomaps-v4-${flavor}`,
    metadata: {
      "plotlines:spike": "SPIKE-K",
      "plotlines:generator": `@protomaps/basemaps@${pkgVersion} layers("protomaps", namedFlavor("${flavor}"), {lang: "${LANG}"})`,
      "plotlines:modifications": "none — generator defaults; source url is a placeholder the harness rewrites",
    },
    sources: {
      protomaps: {
        type: "vector",
        attribution:
          '<a href="https://github.com/protomaps/basemaps">Protomaps</a> © <a href="https://osm.org/copyright">OpenStreetMap</a>',
        url: TILES_PLACEHOLDER,
      },
    },
    layers: layers("protomaps", namedFlavor(flavor), { lang: LANG }),
    glyphs: "https://protomaps.github.io/basemaps-assets/fonts/{fontstack}/{range}.pbf",
  };
  // Upstream's generate_style.ts attaches a sprite sheet only for light and
  // dark — the other three flavors have no upstream sprite, so their POI
  // layers render text without icons. Reproduced, not corrected.
  if (flavor === "light" || flavor === "dark") {
    style.sprite = `https://protomaps.github.io/basemaps-assets/sprites/v4/${flavor}`;
  }
  const out = path.join(outDir, `protomaps_${flavor}.json`);
  fs.writeFileSync(out, JSON.stringify(style, null, 2) + "\n");
  console.log(`${path.relative(process.cwd(), out)}: ${style.layers.length} layers`);
}
