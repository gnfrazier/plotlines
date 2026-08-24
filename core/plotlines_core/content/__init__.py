"""The anchor/role object model (ARCH §7.8, restructured for v2.0). PRD FR106,
FR110, Story O1. See `content.anchor` for the dataclasses and their doc comments."""

from plotlines_core.content.anchor import (
    Anchor,
    AnchorProvenance,
    MediaRef,
    Role,
)

__all__ = ["Anchor", "AnchorProvenance", "MediaRef", "Role"]
