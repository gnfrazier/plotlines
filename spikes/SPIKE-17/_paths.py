"""sys.path bootstrap so every SPIKE-17 script can `import plotlines_core` and
import its sibling spike modules — same convention as SPIKE-H's `_paths.py`.
Import this before anything else in an entry-point script.
"""

from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORE = HERE.parents[1] / "core"

for p in (str(CORE), str(HERE)):
    if p not in sys.path:
        sys.path.insert(0, p)
