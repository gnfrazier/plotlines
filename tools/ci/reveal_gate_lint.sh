#!/usr/bin/env bash
#
# The reveal-gate lint (ARCH §15.3, §15.5; MVP punch list §6A.1) and the
# no-authored-text-in-a-template gate (FR145 / M14; ARCH §15.1 ★, D57, A30).
#
# Same enforcement shape, and the same reason, as CI's "plotlines-core may
# not import fastapi": both are principles the design depends on and that a
# code review will not reliably catch. The violating path here will be a
# print preview, an export corner, or the TTS readout — surfaces nobody
# exercises with unrevealed content present — and a spoiled trip cannot be
# un-spoiled (ARCH A22).
#
# Gate 2 exists because gate 1 alone is not enough. The punch-list byte
# assertions (§6A.2) prove unrevealed content never reaches export bytes, but
# a sentence assembled in Presentation is *downstream* of those assertions
# and invisible to them (A30). A template with typed slots is inspectable; a
# composed sentence is not.
#
# Deliberately grep-based, no toolchain: it runs in CI without Flutter, in a
# pre-commit hook, or by hand. `client/test/reveal_gate_lint_test.dart` runs
# it too, so a developer sees a violation before pushing.
#
# Usage: tools/ci/reveal_gate_lint.sh [repo-root]

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PRESENTATION="$ROOT/client/lib/presentation"
CLIENT_LIB="$ROOT/client/lib"
TEMPLATES="$ROOT/client/lib/domain/message_template.dart"
REASONS="$ROOT/client/lib/domain/reason_phrase.dart"

status=0

fail() {
  echo "::error::$1"
  status=1
}

report() {
  # $1 = matches, $2 = message
  if [[ -n "$1" ]]; then
    echo "$1" | sed 's/^/    /'
    fail "$2"
  fi
}

for required in "$PRESENTATION" "$TEMPLATES" "$REASONS"; do
  if [[ ! -e "$required" ]]; then
    fail "reveal-gate lint: expected $required to exist — did a path move?"
    exit 1
  fi
done

# ── Gate 1 — no Presentation-layer access to a role's content ─────────────
#
# `Role.title` / `Role.note` / `Role.media` are authored content and belong
# to RevealResolver (ARCH P11). Presentation reads a `RevealedRole` instead,
# which carries nulls for anything withheld. Role *metadata* — kind, reveal,
# hazard, arc, coord — is not content and is not matched here.
role_content=$(grep -rnE '(^|[^A-Za-z0-9_.])(role|_role|r|roles\[[^]]*\])\.(title|note|media)\b' \
  "$PRESENTATION" 2>/dev/null)
report "$role_content" \
  "Presentation read a role's content directly. Route it through RevealResolver (ARCH P11, §15.3; punch list §6A.1) — a withheld role must render as 'something is here', not as an empty string someone forgot to check."

role_content_chain=$(grep -rnE '\.roles\b[^;]*\.(title|note|media)\b' "$PRESENTATION" 2>/dev/null)
report "$role_content_chain" \
  "Presentation traversed .roles to reach content. Same gate as above: resolve the anchor through RevealResolver.resolveAnchor and render the RevealedRole."

# ── Gate 2 — no template accepts authored text as a slot value ────────────
#
# The slot vocabulary itself: SlotType and NameSource may not gain a member
# meaning "arbitrary text". Kept in step with `authoredTextSlotNames` /
# `roleContentSourceNames` in message_template.dart, which the architecture
# test reads.
slot_type_block=$(awk '/^enum SlotType \{/,/^\}/' "$TEMPLATES")
banned_slot_kinds=$(echo "$slot_type_block" | grep -nE '^\s{2}(freeText|text|content|note|title|body|prose|sentence|description)[,;]')
report "$banned_slot_kinds" \
  "SlotType gained a free-text member. FR145: a message with an unbounded string slot fails review — the value must be something the app already holds, or a bounded key."

name_source_block=$(awk '/^enum NameSource \{/,/^\}/' "$TEMPLATES")
banned_name_sources=$(echo "$name_source_block" | grep -niE '^\s{2}\w*(role|note|content|media|body|prose|sentence)\w*[,;]')
report "$banned_name_sources" \
  "NameSource gained a member sourced from role content. A name slot names a trip, a day, a place, a Character, a layer or a file — never a role's title, note, or media (FR145; ARCH A30)."

# Declared slots: no slot may be *named* after an authored field either.
banned_slot_names=$(grep -nE "MessageSlot\('[^']*(text|content|note|title|body|prose|sentence|description)[^']*'" "$TEMPLATES")
report "$banned_slot_names" \
  "A template declared a slot named after an authored text field. Rename it, or — if it really is authored content — it does not belong in a template at all."

# Call sites: nothing binds a role's content into a slot value.
bound_content=$(grep -rnE '(NameSlot|NameListSlot|RoleRefSlot)\([^)]*\b(role|_role|r|revealed)\.(title|note|media)' \
  "$CLIENT_LIB" 2>/dev/null)
report "$bound_content" \
  "A slot value was built from a role's content. Released content is rendered as content beside the message (see data/speech.dart), never interpolated into it (FR145; ARCH A30, D57)."

resolved_content=$(grep -rnE '\.(resolve|term|reason)\([^)]*\b(role|_role|r|revealed)\.(title|note|media)' \
  "$CLIENT_LIB" 2>/dev/null)
report "$resolved_content" \
  "A message was resolved with a role's content as an argument. Same gate: a template names a role and states its type; the content travels separately."

# ── Gate 3 — reason phrases come from the bounded table ──────────────────
loose_reason_phrase=$(grep -rn 'ReasonPhrase(' "$CLIENT_LIB" 2>/dev/null | grep -v 'domain/reason_phrase.dart')
report "$loose_reason_phrase" \
  "A ReasonPhrase was constructed outside the bounded table. FR145: adding a cause means adding an entry to reasonPhrases in domain/reason_phrase.dart, never writing a sentence at a call site."

if [[ $status -eq 0 ]]; then
  echo "OK: no Presentation-layer role content, no authored text in a template slot, no off-table reason phrase."
fi
exit $status
