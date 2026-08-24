/// FR114, FR115 / O5 — the resolved, always-concrete state of one role's
/// reveal for a given Character (or Author preview). [RevealPolicy] alone
/// cannot be rendered directly: it may be `null` (undecided), and even when
/// set, "on_arrival" still needs a Character's arrival state to become a yes
/// or no. [RevealState] is what [RevealResolver] collapses all of that down
/// to — every surface that renders reveal state (a role chip, a map marker,
/// a cue sheet, a print layout) switches on this, never on [RevealPolicy] or
/// [Role.reveal] directly, so "undecided" can never leak through as "shown."
library;

enum RevealState {
  /// Always part of the plan, regardless of arrival — an always-visible
  /// role, a role kind's engine default (FR114's provision default), or a
  /// hazard/technical-crux role (FR115 — never anything but this state).
  alwaysVisible,

  /// An `on_arrival` role whose Character has reached its trigger — visible
  /// now, and unlocked permanently for that Character (PRD P1).
  revealed,

  /// An `on_arrival` role not yet reached, or a narrative/station role left
  /// undecided by the Author (FR114: "the Author's choice" — no engine
  /// default, so undecided reads as withheld, never as an accidental leak).
  withheld;

  /// `false` only for [withheld] — the single place "may this render its
  /// content" is decided, so a caller never has to enumerate the other two.
  bool get isVisible => this != RevealState.withheld;
}
