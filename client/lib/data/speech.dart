/// FR145 / M14, with FR40a / H2a — **the TTS path reads templates and
/// resolved content separately, never a pre-composed sentence.**
///
/// This is the narrow seam M14 requires, not H2a itself: no platform speech
/// engine, no voice, no queueing, no trigger-priority handling (I2a) — those
/// arrive with H2a. What lands here is the *shape* of what gets handed to a
/// speech engine, because that shape is the reveal-gate decision and it has
/// to be right before anything speaks.
///
/// **Why the separation is load-bearing.** ARCH §6A.2 requires byte-level
/// assertions that unrevealed content never appears in export output, and
/// "the TTS path needs the equivalent assertion on the string handed to the
/// speech engine." A [SpeechScript] makes that assertion possible: every
/// part is either a [SpokenMessage] — a [MessageId] resolved against typed
/// slots, containing no authored content by construction — or a
/// [SpokenContent], which carries content that [RevealResolver] has already
/// released, tagged with which field it came from. Nothing concatenates the
/// two. A test (and, later, H2a's engine adapter) can therefore inspect
/// exactly what would be spoken, and a withheld role produces **no content
/// part at all**.
///
/// The inverse — building `'Reaching ${role.title}: ${role.note}'` and
/// handing that to the engine — is the failure mode this file exists to make
/// unavailable: it is assembled in Presentation, downstream of every byte
/// assertion, and reads a spoiled trip aloud to a Character who has not
/// arrived (ARCH A22, A30).
library;

import '../domain/anchor.dart' show RoleKind;
import '../domain/message_catalog.dart';
import '../domain/message_template.dart';
import 'reveal_resolver.dart';

/// Which authored field one [SpokenContent] came from. Bounded so the
/// speech engine — and any assertion over it — can tell content apart from
/// message text without parsing.
enum SpokenContentKind { roleTitle, roleNote }

/// One thing to say. `sealed`: a part is either a template or released
/// content, and there is no third kind that could be a sentence built from
/// both.
sealed class SpeechPart {
  const SpeechPart();
}

/// A template, resolved at speak time exactly as it would be on screen.
final class SpokenMessage extends SpeechPart {
  const SpokenMessage(this.id, [this.slots = const {}]);

  final MessageId id;
  final Map<String, SlotValue> slots;

  String text(MessageResolver messages) => messages.resolve(id, slots);
}

/// Authored content that [RevealResolver] has released, spoken as itself.
/// Never a slot value, never inside a pattern — its own part.
final class SpokenContent extends SpeechPart {
  const SpokenContent({required this.kind, required this.roleId, required this.text});

  final SpokenContentKind kind;

  /// Which role released this, so a caller can re-check it against the
  /// resolver rather than trusting the script it was handed.
  final String roleId;

  final String text;
}

/// An ordered script for the speech engine. [utterances] is deliberately a
/// *list* of strings rather than one string: the engine speaks them in turn,
/// and nothing in this file ever joins them.
class SpeechScript {
  const SpeechScript(this.parts);

  final List<SpeechPart> parts;

  bool get isEmpty => parts.isEmpty;

  /// One string per part, in order. Message parts resolve; content parts
  /// pass through untouched.
  List<String> utterances(MessageResolver messages) => [
        for (final part in parts)
          switch (part) {
            SpokenMessage() => part.text(messages),
            SpokenContent() => part.text,
          },
      ];

  /// The text that came from templates only — what an assertion checks when
  /// it wants to prove no authored content leaked into a sentence.
  List<String> messageUtterances(MessageResolver messages) =>
      [for (final part in parts) if (part is SpokenMessage) part.text(messages)];

  /// The released content only — empty for a withheld role, which is the
  /// property H2a's "an unrevealed plot point is never read aloud early"
  /// reduces to.
  List<SpokenContent> get contentParts => [for (final part in parts) if (part is SpokenContent) part];
}

/// Builds the script for one already-resolved role.
///
/// [revealed] must come from [RevealResolver] (P11) — this function makes no
/// reveal decision of its own and cannot: [RevealedRole] carries `null`
/// title, note, and media for anything withheld, so a withheld role yields
/// an introduction-free, content-free script rather than a redacted one.
///
/// [placeName] is the **anchor's** title (`Anchor.title`), which is what
/// FR145's "a message about a role names it and states its type" means. It
/// is never the role's own title.
///
/// [hazard] mirrors `Role.hazard`: a hazard role leads with a warning
/// (FR115 — always visible, always speakable, on every trip).
SpeechScript speechForRole(
  RevealedRole revealed, {
  String? placeName,
  bool hazard = false,
}) {
  if (!revealed.visible) return const SpeechScript([]);
  final role = RoleRefSlot(kind: revealed.kind, placeName: placeName);
  return SpeechScript([
    if (hazard)
      SpokenMessage(MessageId.spokenHazardWarning, {'role': role})
    else
      SpokenMessage(MessageId.spokenRoleIntroduction, {'role': role}),
    if (revealed.title != null && revealed.title!.trim().isNotEmpty)
      SpokenContent(kind: SpokenContentKind.roleTitle, roleId: revealed.roleId, text: revealed.title!),
    if (revealed.note != null && revealed.note!.trim().isNotEmpty)
      SpokenContent(kind: SpokenContentKind.roleNote, roleId: revealed.roleId, text: revealed.note!),
  ]);
}

/// The scripts for a whole anchor's resolved roles, in order. Withheld roles
/// contribute nothing — not an empty script, not a placeholder.
List<SpeechScript> speechForAnchor(
  List<RevealedRole> resolved, {
  String? placeName,
  Set<String> hazardRoleIds = const {},
}) =>
    [
      for (final revealed in resolved)
        if (revealed.visible)
          speechForRole(revealed, placeName: placeName, hazard: hazardRoleIds.contains(revealed.roleId)),
    ];

/// The role kinds a Character-facing speech path may reach at all. Present
/// so H2a's engine adapter has a bounded set to switch on rather than
/// inventing one; every kind is speakable, and what varies is only whether
/// [RevealResolver] released the content.
const List<RoleKind> speakableRoleKinds = RoleKind.values;
