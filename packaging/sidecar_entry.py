"""Freeze entrypoint for the sidecar binary.

Both freezers (PyInstaller and Nuitka) target this file rather than
`plotlines_service.__main__`, so the two builds share one entrypoint and the
`python -m plotlines_service` source path stays identical to the frozen path.
"""

import multiprocessing

from plotlines_service.__main__ import main

if __name__ == "__main__":
    multiprocessing.freeze_support()
    raise SystemExit(main())
