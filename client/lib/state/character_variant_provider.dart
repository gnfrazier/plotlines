// H6 (FR6, FR20) — the Character-side personalization layer.
//
// Ephemeral, per-Character, per-passage state that is *never* written into
// the trip payload — the same standing as `dayPlanningModeProvider` and the
// reveal layer. ARCH §7.8 / P8: personalization is a layer over the canonical
// plotline, and incorporating it into canon is an explicit Author action that
// does not live on this surface.
//
// Keyed by segment id. A reopened trip starts every passage back at the
// canonical line (an empty `CharacterVariant`), the same way
// `selectedSegmentProvider` starts unselected — there is nothing authored to
// persist.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/character_variant.dart';
import '../domain/segment.dart';

/// The Character's variant for one passage. Defaults to an empty variant
/// (canonical route, no adjustments). Widgets read this and call the
/// `domain/character_variant.dart` pure functions with it; the mutation
/// helpers below wrap the common edits so a call site never rebuilds the
/// map by hand.
final characterVariantProvider =
    StateProvider.family<CharacterVariant, String>((ref, segmentId) => CharacterVariant(segmentId: segmentId));

/// H6 — move one Author-variable parameter to [requested] for this Character,
/// clamped into the Author's band. Throws if [attribute] is locked (see
/// `adjustParameter`).
void adjustCharacterParameter(
  WidgetRef ref,
  Segment segment,
  String attribute,
  double requested,
) {
  final notifier = ref.read(characterVariantProvider(segment.id).notifier);
  notifier.state = adjustParameter(notifier.state, segment, attribute, requested);
}

/// H6 — return one parameter to the Author's full band.
void clearCharacterAdjustment(WidgetRef ref, Segment segment, String attribute) {
  final notifier = ref.read(characterVariantProvider(segment.id).notifier);
  notifier.state = clearAdjustment(notifier.state, attribute);
}

/// H6 / FR20 — take an accommodation alternate (or pass null for the
/// canonical line). Throws for an id that is not one of [segment]'s
/// alternates.
void chooseCharacterAlternate(WidgetRef ref, Segment segment, String? alternateId) {
  final notifier = ref.read(characterVariantProvider(segment.id).notifier);
  notifier.state = chooseAlternate(notifier.state, segment, alternateId);
}

/// H6 — drop every personal choice for this passage, returning the Character
/// to the Author's canonical route.
void resetCharacterVariant(WidgetRef ref, String segmentId) {
  ref.read(characterVariantProvider(segmentId).notifier).state =
      CharacterVariant(segmentId: segmentId);
}
