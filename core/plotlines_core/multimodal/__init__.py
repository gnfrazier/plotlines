"""Per-mode graph building + water/technical params. See ARCH §6.2, §6.4.

`modes.py` is the traversal-mode registry (FR10 / B1, FR130 / M1): a mode is a
row of data — a `WeightProfile` plus its domain parameters — never a branch of
code, and station activities (FR109 / O4) are excluded from it by invariant.
"""

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
