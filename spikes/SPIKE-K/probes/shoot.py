"""Drive the harness headlessly: every style at every fixed camera, one
screenshot each, plus the rendered-feature counts per source-layer that say
whether a style *drew* anything — the measurement behind README §3.

Needs `harness/serve.py` running (default port 8765) and Playwright with its
Chromium; both live outside the repo:

    uv venv /tmp/pw && uv pip install --python /tmp/pw/bin/python playwright
    /tmp/pw/bin/python -m playwright install chromium
    python3 harness/serve.py &
    /tmp/pw/bin/python probes/shoot.py

Writes `results/shots/<camera>__<style>.png` and `results/render_check.json`.

Every style is visited by *switching in-page* from the previous one (the
harness's own `switchStyle`, i.e. `map.setStyle` with the camera held), not
by reloading the page — so the run also exercises the issue's "no reload,
no lost position" requirement rather than only asserting it. The camera is
read back after each switch and compared to the requested one.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

SPIKE_ROOT = Path(__file__).resolve().parent.parent
SHOTS = SPIKE_ROOT / "results" / "shots"
HARNESS = "http://localhost:8765/"

STYLES = [
    "protomaps_light",
    "protomaps_dark",
    "protomaps_grayscale",
    "protomaps_white",
    "protomaps_black",
    "omt_liberty",
    "omt_bright",
]

# Three cameras, chosen for what Plotlines actually draws a basemap under:
# a town (roads, water, landuse, POIs and place labels all at once), a
# ridge-and-parkway cell (terrain context: park landuse, peaks, the one
# road), and a river town with a long-trail crossing (multimodal corridor:
# river, rail-trail, AT, small-town POIs). All inside WNC_CORRIDOR_BBOX.
CAMERAS = {
    "asheville-z13": dict(lng=-82.553, lat=35.595, z=13),
    "mitchell-z12": dict(lng=-82.265, lat=35.765, z=12),
    "hotsprings-z14": dict(lng=-82.828, lat=35.893, z=14),
}

VIEWPORT = {"width": 1200, "height": 800}


def main() -> int:
    SHOTS.mkdir(parents=True, exist_ok=True)
    report: dict = {"harness": HARNESS, "viewport": VIEWPORT, "cameras": CAMERAS, "runs": []}
    with sync_playwright() as p:
        browser = p.chromium.launch(
            args=[
                # Software WebGL — no GPU on the WSL box. Pixel output differs
                # from a GPU only in AA; feature counts do not.
                "--use-gl=angle",
                "--use-angle=swiftshader",
                "--enable-unsafe-swiftshader",
                "--ignore-gpu-blocklist",
            ]
        )
        page = browser.new_page(viewport=VIEWPORT, device_scale_factor=1)
        console: list[str] = []
        page.on("console", lambda m: console.append(f"{m.type}: {m.text}"))
        page.on("pageerror", lambda e: console.append(f"pageerror: {e}"))

        for cam, c in CAMERAS.items():
            url = f"{HARNESS}?ui=0&style={STYLES[0]}&lng={c['lng']}&lat={c['lat']}&z={c['z']}"
            page.goto(url)
            page.wait_for_function("window.__spikeK && window.__spikeK.map")
            # Poll `map.loaded()` rather than `once('idle')`: the first style
            # lands in well under a second from the mirror, so an idle
            # listener attached after navigation can miss the event and wait
            # forever. `loaded()` is false from the moment `setStyle` marks
            # the style dirty until every source tile and glyph is in.
            page.wait_for_function("__spikeK.map.loaded()", timeout=60_000)
            for style in STYLES:
                errors_before = page.evaluate("__spikeK.errors.length")
                t0 = time.perf_counter()
                # switchStyle resolves once setStyle has been *called*
                # (style JSON fetched, sources rewritten); the render is
                # what loaded() then waits on.
                page.evaluate("(id) => __spikeK.switchStyle(id)", style)
                page.wait_for_function("__spikeK.map.loaded()", timeout=60_000)
                wall_ms = (time.perf_counter() - t0) * 1000
                # Belt and braces: a short settle and a second loaded() so a
                # late glyph/sprite fetch doesn't leave a half-drawn label
                # layer in the shot.
                page.wait_for_timeout(500)
                page.wait_for_function("__spikeK.map.loaded()", timeout=60_000)

                info = page.evaluate(
                    """() => {
                        const m = __spikeK.map;
                        const c = m.getCenter();
                        const style = m.getStyle();
                        return {
                            current: __spikeK.current,
                            camera: {lng: c.lng, lat: c.lat, z: m.getZoom()},
                            layers_total: style.layers.length,
                            layers_vector: style.layers.filter(l => l['source-layer']).length,
                            rendered_by_source_layer: __spikeK.renderedBySourceLayer(),
                            errors: __spikeK.errors.slice(),
                        };
                    }"""
                )
                shot = SHOTS / f"{cam}__{style}.png"
                page.screenshot(path=str(shot))
                rendered_total = sum(info["rendered_by_source_layer"].values())
                drift = (
                    abs(info["camera"]["lng"] - c["lng"]),
                    abs(info["camera"]["lat"] - c["lat"]),
                    abs(info["camera"]["z"] - c["z"]),
                )
                run = {
                    "camera": cam,
                    "style": style,
                    "switch_ms": round(wall_ms),
                    "camera_after": info["camera"],
                    "camera_drift": {"lng": drift[0], "lat": drift[1], "z": drift[2]},
                    "layers_total": info["layers_total"],
                    "layers_vector": info["layers_vector"],
                    "rendered_total": rendered_total,
                    "rendered_by_source_layer": info["rendered_by_source_layer"],
                    "new_errors": info["errors"][errors_before:],
                    "shot": str(shot.relative_to(SPIKE_ROOT)),
                }
                report["runs"].append(run)
                print(
                    f"{cam:15} {style:20} {wall_ms:6.0f} ms  "
                    f"{info['layers_vector']:3} vector layers  {rendered_total:5} features  "
                    f"{len(run['new_errors'])} errors",
                    flush=True,
                )
        report["console"] = console
        browser.close()

    out = SPIKE_ROOT / "results" / "render_check.json"
    out.write_text(json.dumps(report, indent=2) + "\n")
    print(f"wrote {out.relative_to(SPIKE_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
