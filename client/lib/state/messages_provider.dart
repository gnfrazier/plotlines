/// FR145 / M14 — where Presentation gets its [MessageResolver] from.
///
/// Three providers rather than one, because the two inputs a resolver takes
/// belong to stories that are not M14 and must be able to arrive
/// independently:
/// - [messageLocaleProvider] — the app language (FR83 / K6, on M8's ARB
///   framework). Overriding it is all that changes when M8 lands: the
///   generated `AppLocalizations` implements [MessageCatalog], and
///   [messagesProvider] takes it instead of [baseLocaleCatalog].
/// - [messageUnitSystemProvider] — miles or kilometres (FR79 / K5). K5's
///   `settingsProvider` already holds a `DistanceUnit`; this provider is the
///   seam it drives once its own surfaces are migrated, and is deliberately
///   *not* wired to it here. Wiring a provider that reads the settings
///   database into every widget that resolves a string would make a message
///   depend on storage, which is not a dependency a label should have.
///
/// Neither default is a decision this story is making — they are the
/// existing behaviour (English, metric) expressed as overridable values
/// instead of as literals scattered through the widget tree.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/message_catalog.dart';

/// The catalog the app resolves against. M8 overrides this with its
/// generated `AppLocalizations` for the selected locale.
final messageCatalogProvider = Provider<MessageCatalog>((ref) => baseLocaleCatalog);

/// Kept separate from [messageCatalogProvider] so a test — or K6's language
/// picker — can change the language without supplying a catalog.
final messageLocaleProvider = Provider<String>((ref) => ref.watch(messageCatalogProvider).locale);

/// FR79 / K5. See the library note on why this is not read from
/// `settingsProvider` yet.
final messageUnitSystemProvider = Provider<UnitSystem>((ref) => UnitSystem.metric);

/// The app's resolver. Every user-visible string in Presentation comes from
/// here (FR145); nothing composes one locally.
final messagesProvider = Provider<MessageResolver>((ref) => MessageResolver(
      catalog: ref.watch(messageCatalogProvider),
      units: ref.watch(messageUnitSystemProvider),
    ));
