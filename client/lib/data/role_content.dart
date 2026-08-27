/// FR37 / E1 — the one sanctioned crossing point for a role's own authored
/// content *outside* [RevealResolver] (`reveal_resolver.dart`). That
/// resolver is Presentation's only reader for *displaying* a role — gate 1
/// of `tools/ci/reveal_gate_lint.sh` forbids `client/lib/presentation` from
/// reading `Role.note`/`Role.media` directly, full stop, because a withheld
/// role must never leak through a display surface nobody thought to gate.
///
/// The Author's own content-*editing* surface (`anchor_promotion_panel.dart`'s
/// role-content dialog) is a different case — the Author is looking at what
/// they themselves wrote, not previewing what a Character would see — but
/// the lint is deliberately blanket rather than trying to distinguish
/// "editing" from "displaying" by pattern-matching intent (that distinction
/// lives here, in Data, reviewed once, instead of trusted to every call
/// site). This module is that reviewed crossing point: it is the only place
/// in the codebase outside `RevealResolver` allowed to read [Role.note] /
/// [Role.media], and Presentation only ever touches the [RoleContentDraft]
/// it returns.
library;

import '../domain/domain.dart';

class RoleContentDraft {
  const RoleContentDraft({this.note, this.media = const []});
  final String? note;
  final List<MediaRef> media;

  bool get hasContent => note != null || media.isNotEmpty;
}

RoleContentDraft loadRoleContent(Role role) =>
    RoleContentDraft(note: role.note, media: role.media);
