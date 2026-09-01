import sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
CORE = HERE.parents[1] / "core"
for p in (str(CORE), str(HERE)):
    if p not in sys.path:
        sys.path.insert(0, p)
