#!/usr/bin/env python3
"""Thin CLI entry point — see `plotlines_core.licensing.generate` for the
actual scanning/rendering logic and `packaging/build_sidecar.sh` for how this
is invoked (issue #267, addendum L5).

Run with the *build venv's* own interpreter, the same one that runs
`pyinstaller`/`nuitka` — `plotlines_core` is already installed editable there
alongside the sidecar's own dependencies, so `importlib.metadata` sees
exactly the environment the frozen binary was built from:

    "$VENV_BIN/python" packaging/generate_third_party_licenses.py \\
        --output packaging/dist/pyinstaller-onedir/THIRD_PARTY_LICENSES
"""

from plotlines_core.licensing.generate import main

if __name__ == "__main__":
    main()
