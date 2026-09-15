/// Route-location builders for the event create/edit flows.
///
/// Lives outside [router] (lib/router.dart) so screens can build locations
/// without importing the router table, avoiding a circular import.
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
  if (performerId != null && performerId.isNotEmpty) q['performerId'] = performerId;
  if (date != null) {
    q['date'] =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
  if (lockVenue) q['lockVenue'] = '1';
  return _withQuery('/events/new', q);
}

/// Builds an edit-event route location; the [Event] is passed via `extra`.
String eventsEditPath(String eventId, {String? venueId, String? venueName, bool lockVenue = false}) {
  final q = <String, String>{};
  if (venueId != null && venueId.isNotEmpty) q['venueId'] = venueId;
  if (venueName != null && venueName.isNotEmpty) q['venueName'] = venueName;
  if (lockVenue) q['lockVenue'] = '1';
  return _withQuery('/events/$eventId/edit', q);
}

String _withQuery(String path, Map<String, String> query) {
  if (query.isEmpty) return path;
  return '$path?${Uri(queryParameters: query).query}';
}
