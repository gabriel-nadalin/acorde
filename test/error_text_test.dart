import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:event_calendar/l10n/app_localizations.dart';
import 'package:event_calendar/models/event.dart';
import 'package:event_calendar/services/pocketbase_service.dart';
import 'package:event_calendar/utils/error_text.dart';

import 'support/fake_pocketbase.dart';

/// What a screen shows the user for a thrown error.
///
/// The rule under test: PocketBase's own prose wins when there is any (it names
/// the actual rule that was broken), and everything with no prose — a dropped
/// connection, a timeout, a 5xx — becomes localized text instead of leaking
/// `Exception: ...` into a SnackBar.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('pt'));

  final conflictProse =
      'Schedule conflict: venue already booked in this time range.';
  final validationProse = 'Start must be before end.';

  test('a validation failure shows the server\'s own wording', () {
    final error = PocketBaseException.fromBody(
      400,
      jsonEncode({'message': validationProse, 'status': 400}),
    );

    expect(error.kind, PbErrorKind.validation);
    expect(errorText(l10n, error), validationProse);
  });

  /// PocketBase wraps a validation failure in an envelope message that says
  /// nothing ("An error occurred while validating the submitted data.") plus a
  /// field-level one that names the problem. The field message is the one worth
  /// showing: it is what tells the user that a reset link expired, or which
  /// address was already taken.
  test('a field-level validation message beats the envelope', () {
    final error = PocketBaseException.fromBody(
      400,
      jsonEncode({
        'data': {
          'token': {
            'code': 'validation_invalid_token',
            'message': validationProse,
          },
        },
        'message': 'An error occurred while validating the submitted data.',
        'status': 400,
      }),
    );

    expect(error.message, validationProse);
    expect(error.kind, PbErrorKind.validation);
    expect(errorText(l10n, error), validationProse);
  });

  /// An envelope with nothing in `data` is the only explanation there is, so it
  /// must survive the rule above.
  test('an envelope with no field detail is still used', () {
    final error = PocketBaseException.fromBody(
      409,
      jsonEncode({'data': {}, 'message': conflictProse, 'status': 409}),
    );

    expect(error.message, conflictProse);
    expect(error.kind, PbErrorKind.conflict);
  });

  test('a schedule conflict shows the server\'s own wording', () {
    final error = PocketBaseException.fromBody(
      400,
      jsonEncode({'message': conflictProse, 'status': 400}),
    );

    expect(error.kind, PbErrorKind.conflict);
    expect(errorText(l10n, error), conflictProse);
  });

  test('transport, timeout and server failures become localized text', () {
    final network = PocketBaseException(
      0,
      'ClientException: Connection refused',
      kind: PbErrorKind.network,
    );
    final timeout = PocketBaseException(
      0,
      'Request timed out',
      kind: PbErrorKind.timeout,
    );
    final server = PocketBaseException.fromBody(
      500,
      jsonEncode({'message': 'Something exploded'}),
    );

    expect(server.kind, PbErrorKind.server);

    expect(errorText(l10n, network), l10n.backendUnreachable);
    expect(errorText(l10n, timeout), l10n.requestTimedOut);
    expect(errorText(l10n, server), l10n.serverError);

    for (final text in [
      errorText(l10n, network),
      errorText(l10n, timeout),
      errorText(l10n, server),
    ]) {
      expect(text, isNot(contains('Exception')));
      expect(text, isNot(contains('ClientException')));
    }
  });

  test(
    'status-only failures fall back to the localized text for their kind',
    () {
      expect(
        errorText(l10n, PocketBaseException(401, '', kind: PbErrorKind.auth)),
        l10n.sessionExpired,
      );
      expect(
        errorText(
          l10n,
          PocketBaseException(403, '', kind: PbErrorKind.forbidden),
        ),
        l10n.forbidden,
      );
      expect(
        errorText(
          l10n,
          PocketBaseException(404, '', kind: PbErrorKind.notFound),
        ),
        l10n.notFound,
      );
    },
  );

  test(
    'an error that is not a PocketBaseException never leaks its toString',
    () {
      final text = errorText(l10n, StateError('internal detail'));

      expect(text, l10n.couldNotLoadData);
      expect(text, isNot(contains('internal detail')));
    },
  );

  test(
    'a real transport failure written by the service maps to localized text',
    () async {
      final pb = FakePb();
      pb.intercept = (request) async =>
          throw http.ClientException('Connection refused');
      final service = PocketBaseService(
        baseUrl: 'http://pb.test',
        client: pb.client(),
      );

      try {
        await service.createVenue({'name': 'Hall'});
        fail('the request was supposed to fail');
      } on PocketBaseException catch (error) {
        expect(error.kind, PbErrorKind.network);
        expect(errorText(l10n, error), l10n.backendUnreachable);
      }
    },
  );

  test(
    'a real schedule-conflict rejection shows PocketBase\'s prose',
    () async {
      final pb = FakePb();
      pb.intercept = (request) async {
        if (request.method == 'POST' && request.url.path.contains('/events/')) {
          return FakePb.json(400, {'message': conflictProse, 'status': 400});
        }
        return null;
      };
      final service = PocketBaseService(
        baseUrl: 'http://pb.test',
        client: pb.client(),
      );

      try {
        await service.createEvent(
          Event(
            title: 'Gig',
            start: DateTime(2026, 9, 1, 19),
            end: DateTime(2026, 9, 1, 21),
            venueId: 'v1',
          ),
        );
        fail('the booking was supposed to be rejected');
      } on PocketBaseException catch (error) {
        expect(error.kind, PbErrorKind.conflict);
        expect(errorText(l10n, error), conflictProse);
      }
    },
  );
}
