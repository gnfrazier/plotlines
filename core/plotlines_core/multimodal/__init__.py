"""Per-mode graph building + water/technical params. See ARCH §6.2, §6.4.

`modes.py` is the traversal-mode registry (FR10 / B1, FR130 / M1): a mode is a
row of data — a `WeightProfile` plus its domain parameters — never a branch of
code, and station activities (FR109 / O4) are excluded from it by invariant.

`disciplines.py` is the second axis (issue #315): a discipline refines one
category with its own `WeightProfile`. `legacy.py` maps the three `travel_mode`
values #315 removed (`mountain_biking`, `packrafting`, `riverboarding`) onto
their new `(category, discipline)` spelling.
"""

from plotlines_core.multimodal.disciplines import (  # noqa: F401
    DISCIPLINES,
    Discipline,
    all_discipline_keys,
    category_of,
    discipline,
    discipline_label,
    disciplines_for,
    is_discipline,
    weights_for_discipline,
)
from plotlines_core.multimodal.legacy import (  # noqa: F401
    LEGACY_MODE_ALIASES,
    canonical_mode,
    migrate_payload_modes,
)
from plotlines_core.multimodal.modes import (  # noqa: F401
    EXTENDED,
    FIRST_CLASS,
    STATION_ACTIVITIES,
    TRANSPORT_NOTE_MODES,
    TRAVERSAL_MODES,
    TraversalMode,
    access_mode_for,
    all_mode_keys,
    base_speed_kmh,
    extended_modes,
    first_class_modes,
    is_station_activity,
    is_traversal_mode,
    mode_label,
    network_type_for,
    traversal_mode,
    weights_for,
)
