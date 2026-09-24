import '../l10n/app_localizations.dart';
import '../services/pocketbase_service.dart';

/// Localized, user-facing text for anything a screen caught.
///
/// PocketBase explains its own rejections in prose ("Schedule conflict: venue
/// already booked in this time range."), and that wording is always better than
/// a guess made client-side, so it wins. Transport and unclassified failures
/// have no server prose to show and map to localized text through
/// [PocketBaseException.kind] instead of leaking `Exception: ...` to the user.
String errorText(AppLocalizations l10n, Object error) {
  if (error is PocketBaseException) {
    final message = error.message.trim();
    // A transport failure carries a short non-localized description from the
    // http layer; prefer the localized text for those kinds.
    if (message.isNotEmpty && _isServerProse(error)) return message;
    return _textForKind(
      l10n,
      error.kind,
      fallback: message.isEmpty ? l10n.couldNotLoadData : message,
    );
  }
  return l10n.couldNotLoadData;
}

bool _isServerProse(PocketBaseException error) => switch (error.kind) {
  PbErrorKind.network ||
  PbErrorKind.timeout ||
  PbErrorKind.server ||
  PbErrorKind.unknown => false,
  _ => true,
};

String _textForKind(
  AppLocalizations l10n,
  PbErrorKind kind, {
  required String fallback,
}) => switch (kind) {
  PbErrorKind.network => l10n.backendUnreachable,
  PbErrorKind.timeout => l10n.requestTimedOut,
  PbErrorKind.auth => l10n.sessionExpired,
  PbErrorKind.forbidden => l10n.forbidden,
  PbErrorKind.notFound => l10n.notFound,
  PbErrorKind.server => l10n.serverError,
  PbErrorKind.validation || PbErrorKind.conflict => fallback,
  PbErrorKind.unknown => fallback,
};
