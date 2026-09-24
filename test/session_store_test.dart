import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:event_calendar/data/repositories.dart';
import 'package:event_calendar/data/session_store.dart';
import 'package:event_calendar/services/pocketbase_service.dart';

import 'support/fake_pocketbase.dart';

/// A keystore that keeps its values in a map instead of on the device.
///
/// The plugin's channel is not installed under `flutter test`, which is why the
/// store takes its storage injected in the first place; [unreachable] covers the
/// other failure that matters, a device whose keystore the app cannot open. Only
/// the three calls [SecureSessionStore] makes are overridden — everything else
/// keeps the plugin's own behaviour.
class _FakeKeystore extends FlutterSecureStorage {
  _FakeKeystore();

  final Map<String, String> values = {};
  bool unreachable = false;

  void _guard() {
    if (unreachable) throw Exception('keystore unavailable');
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _guard();
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _guard();
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _guard();
    values.remove(key);
  }
}

/// A keystore that accepts the call and never answers it.
///
/// The failure this models is not hypothetical: under `flutter test` a real
/// `FlutterSecureStorage` call neither resolves nor throws, because the method
/// channel has no implementation to reply and nothing reports the missing
/// handler in a widget-test (fake-async) zone. The consequence is out of all
/// proportion to the cause — the session is persisted *inside* `login`, so a
/// channel that never replies left the app on the sign-in screen with a spinner
/// that never stopped. `SecureSessionStore` bounds every keystore call so this
/// ends up on the same best-effort path as a thrown error instead.
class _HangingKeystore extends FlutterSecureStorage {
  _HangingKeystore();

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => Completer<String?>().future;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => Completer<void>().future;

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => Completer<void>().future;
}

/// A store whose every call fails, like a keystore that is not there at all.
class _UnopenableStore implements SessionStore {
  @override
  Future<StoredSession?> read() async =>
      throw Exception('keystore unavailable');

  @override
  Future<void> write(StoredSession session) async =>
      throw Exception('keystore unavailable');

  @override
  Future<void> clear() async => throw Exception('keystore unavailable');
}

const Map<String, dynamic> kUser = {'id': 'u1', 'email': 'me@example.com'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeKeystore keystore;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    keystore = _FakeKeystore();
  });

  SecureSessionStore store() => SecureSessionStore(
    storage: keystore,
    prefs: SharedPreferences.getInstance(),
  );

  group('SecureSessionStore', () {
    test('a written session reads back with its profile in prefs', () async {
      final SessionStore subject = store();
      await subject.write(
        const StoredSession(user: kUser, token: 'tok-1', cookie: 'pb=1'),
      );

      final restored = await subject.read();
      expect(restored?.user, kUser);
      expect(restored?.token, 'tok-1');
      expect(restored?.cookie, 'pb=1');
      expect(restored?.user['id'], 'u1');

      // The credential is the part that has to be encrypted; the profile stays
      // where every other cache of this app keeps its JSON.
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString('auth_user')!) as Map,
        kUser,
        reason:
            'the profile keeps its existing key so the cache shape is unchanged',
      );
      expect(prefs.getString('auth_token'), isNull);
      expect(prefs.getString('auth_cookie'), isNull);
      expect(keystore.values.values, containsAll(['tok-1', 'pb=1']));
    });

    test('nothing stored reads as absent', () async {
      final SessionStore subject = store();
      expect(await subject.read(), isNull);
    });

    test('a legacy plaintext session moves into the keystore', () async {
      SharedPreferences.setMockInitialValues({
        'auth_user': jsonEncode(kUser),
        'auth_token': 'legacy-token',
        'auth_cookie': 'pb=legacy',
      });
      final SessionStore subject = store();

      final restored = await subject.read();
      expect(restored?.user, kUser);
      expect(restored?.token, 'legacy-token');
      expect(restored?.cookie, 'pb=legacy');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token'), isNull);
      expect(prefs.getString('auth_cookie'), isNull);
      expect(
        keystore.values.values,
        containsAll(['legacy-token', 'pb=legacy']),
      );

      // The next launch reads the same session from a keystore that has the
      // credential and no plaintext copy beside it.
      final again = await subject.read();
      expect(again?.token, 'legacy-token');
      expect(again?.cookie, 'pb=legacy');
    });

    test(
      'the keystore credential wins over a leftover plaintext copy',
      () async {
        SharedPreferences.setMockInitialValues({
          'auth_user': jsonEncode(kUser),
          'auth_token': 'stale-token',
        });
        await keystore.write(key: 'auth_token', value: 'current-token');
        final SessionStore subject = store();

        expect((await subject.read())?.token, 'current-token');
      },
    );

    test('a profile that cannot be decoded reads as absent', () async {
      SharedPreferences.setMockInitialValues({'auth_user': '{not json'});
      final SessionStore subject = store();

      expect(await subject.read(), isNull);
    });

    test(
      'an unreadable keystore costs the credential, not the launch',
      () async {
        SharedPreferences.setMockInitialValues({
          'auth_user': jsonEncode(kUser),
        });
        keystore.unreachable = true;
        final SessionStore subject = store();

        // The profile is not the keystore's, so it still reads; the token it
        // could not fetch is simply absent — an unreachable keystore must not
        // throw here, and it must not invent a credential either.
        final restored = await subject.read();
        expect(restored?.user, kUser);
        expect(restored?.token, isNull);
        expect(restored?.cookie, isNull);
      },
    );

    test(
      'an unreadable keystore does not cost a legacy install its session',
      () async {
        SharedPreferences.setMockInitialValues({
          'auth_user': jsonEncode(kUser),
          'auth_token': 'legacy-token',
          'auth_cookie': 'pb=legacy',
        });
        keystore.unreachable = true;
        final SessionStore subject = store();

        final restored = await subject.read();
        expect(restored?.user, kUser);
        expect(restored?.token, 'legacy-token');
        expect(restored?.cookie, 'pb=legacy');

        // Deleting the plaintext copy after a failed encrypted write would sign
        // this install out for good, so it is left for the next launch to retry.
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('auth_token'), 'legacy-token');
        expect(prefs.getString('auth_cookie'), 'pb=legacy');
      },
    );

    /// A keystore that never answers must not become a sign-in that never
    /// finishes. The write is abandoned after the store's own bound, so `login`
    /// completes and the user gets the app instead of an endless spinner.
    test('a keystore that never answers abandons the write', () async {
      final SessionStore subject = SecureSessionStore(
        storage: _HangingKeystore(),
        prefs: SharedPreferences.getInstance(),
      );

      await expectLater(
        subject.write(const StoredSession(user: kUser, token: 'tok-1')),
        completes,
      );
      // The profile half still landed: the two stores are independent, and a
      // credential that could not be written must not cost the profile that
      // could.
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('auth_user')!), kUser);
    });

    test('a keystore that never answers reads as absent', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('auth_user', jsonEncode(kUser));

      final SessionStore subject = SecureSessionStore(
        storage: _HangingKeystore(),
        prefs: Future.value(prefs),
      );

      // No credential, and no hang: a signed-out app is usable, an app that
      // never finishes launching is not.
      final restored = await subject.read();
      expect(restored, isNotNull);
      expect(restored!.token, isNull);
      expect(restored.cookie, isNull);
    });

    test('clear drops both halves', () async {
      SharedPreferences.setMockInitialValues({
        'auth_user': jsonEncode(kUser),
        'auth_token': 'legacy-token',
        'auth_cookie': 'pb=legacy',
      });
      final SessionStore subject = store();
      await subject.write(
        const StoredSession(user: kUser, token: 'tok-1', cookie: 'pb=1'),
      );

      await subject.clear();

      expect(await subject.read(), isNull);
      expect(keystore.values, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_user'), isNull);
      expect(prefs.getString('auth_token'), isNull);
      expect(prefs.getString('auth_cookie'), isNull);
    });
  });

  group('SessionController', () {
    late FakePb pb;
    late PocketBaseService service;

    setUp(() {
      pb = FakePb();
      service = PocketBaseService(
        baseUrl: 'http://pb.test',
        client: pb.client(),
      );
    });

    test(
      'restoreSession adopts an injected store without asking the server',
      () async {
        final store = MemorySessionStore(
          const StoredSession(user: kUser, token: 'tok-1', cookie: 'pb=1'),
        );
        final session = SessionController(service: service, store: store);

        await session.restoreSession();

        expect(session.isLoggedIn, isTrue);
        expect(session.userId, 'u1');
        expect(service.authToken, 'tok-1');
        expect(service.authCookie, 'pb=1');
        expect(
          pb.log,
          isEmpty,
          reason: 'restoring a session must not need the backend',
        );
      },
    );

    test(
      'login persists through the injected store and logout clears it',
      () async {
        pb.authRecord = kUser;
        final store = MemorySessionStore();
        final session = SessionController(service: service, store: store);

        await session.login('me@example.com', 'pw');
        final persisted = await store.read();
        expect(persisted?.user['id'], 'u1');
        expect(persisted?.token, 'token-1');

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('auth_token'),
          isNull,
          reason:
              'an injected store means this device writes no plaintext copy',
        );

        session.logout();
        await pumpEventQueue();
        expect(await store.read(), isNull);
      },
    );

    test('a store that cannot be opened signs the user out', () async {
      final session = SessionController(
        service: service,
        store: _UnopenableStore(),
      );

      await session.restoreSession();

      expect(session.isLoggedIn, isFalse);
      expect(service.authToken, isNull);
    });
  });
}
