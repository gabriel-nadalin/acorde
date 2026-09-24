/// Route-location builders for the event and entity flows.
///
/// Lives outside the router table (lib/router.dart) so screens can build
/// locations without importing it, avoiding a circular import.
library;

/// Builds a create-event route location, optionally prefilled from query params.
String eventsNewPath({
  String? venueId,
  String? venueName,
  String? performerId,
  DateTime? date,
  bool lockVenue = false,
}) {
  final q = <String, String>{};
  if (venueId != null && venueId.isNotEmpty) q['venueId'] = venueId;
  if (venueName != null && venueName.isNotEmpty) q['venueName'] = venueName;
  if (performerId != null && performerId.isNotEmpty) {
    q['performerId'] = performerId;
  }
  if (date != null) {
    q['date'] =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
  if (lockVenue) q['lockVenue'] = '1';
  return _withQuery('/events/new', q);
}

/// Builds an edit-event route location; the [Event] is passed via `extra`.
String eventsEditPath(
  String eventId, {
  String? venueId,
  String? venueName,
  bool lockVenue = false,
}) {
  final q = <String, String>{};
  if (venueId != null && venueId.isNotEmpty) q['venueId'] = venueId;
  if (venueName != null && venueName.isNotEmpty) q['venueName'] = venueName;
  if (lockVenue) q['lockVenue'] = '1';
  return _withQuery('/events/$eventId/edit', q);
}

/// Forgot-password location, prefilled with whatever the sign-in form held.
///
/// The address travels in the query rather than as a typed `extra` because this
/// route is also what a bookmarked or pasted URL can reach, where `extra` carries
/// nothing.
String forgotPasswordPath({String? email}) => _withQuery('/forgot-password', {
  if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
});

/// New-password location; [token] is the one from the reset email.
String resetPasswordPath(String token) =>
    _withQuery('/reset-password', {'token': token});

/// Venue browse list.
String venuesBrowsePath() => '/venues';

/// Performer browse list.
String performersBrowsePath() => '/performers';

/// Create-venue location.
String venuesNewPath() => '/venues/new';

/// Edit-venue location; this is also where managers are managed.
String venuesEditPath(String venueId) => '/venues/$venueId/edit';

/// Create-performer location.
String performersNewPath() => '/performers/new';

/// Edit-performer location; this is also where members are managed.
String performersEditPath(String performerId) =>
    '/performers/$performerId/edit';

/// Single-entity calendar location (`type` is `venue` or `performer`).
String entityCalendarPath(String type, String id) => '/calendar/$type/$id';

/// The tabbed calendar, opened on the month [month] falls in.
///
/// The month travels in the query rather than as an `extra` for the same reason
/// the reset token does: it is part of the location, so it survives a reload and
/// a pasted URL, and the route builder can read it without a navigation stack.
/// Month and year are all that is sent — the day itself is not a thing this
/// screen can focus, since the calendar shows whole months and picking the day
/// would land the user in the month without saying where in it to look.
String calendarMonthPath(DateTime month) => _withQuery('/calendar', {
  'month':
      '${month.year.toString().padLeft(4, '0')}-${month.month.toString().padLeft(2, '0')}',
});

/// Parses the `month` query parameter of [calendarMonthPath] (`YYYY-MM`).
///
/// Returns null for anything malformed, so a hand-edited or truncated URL
/// degrades to "the calendar, on the current month" rather than throwing during
/// a route build. `DateTime.tryParse` alone is not enough: it accepts
/// `2026-09-15` and `2026` as well, and a day or a bare year is not a month.
DateTime? parseCalendarMonth(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(value.trim());
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  // `DateTime(2026, 13)` would silently roll into January 2027 rather than
  // failing, so the range is checked here.
  if (month < 1 || month > 12) return null;
  return DateTime(year, month, 1);
}

String _withQuery(String path, Map<String, String> query) {
  if (query.isEmpty) return path;
  return '$path?${Uri(queryParameters: query).query}';
}
