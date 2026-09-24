import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The signed-in session as it is persisted between launches.
class StoredSession {
  const StoredSession({required this.user, this.token, this.cookie});

  /// The `users` record the server returned, kept verbatim so a relaunch can
  /// render the profile without asking the backend for it.
  final Map<String, dynamic> user;

  /// Bearer credential for the API. Secret.
  final String? token;

  /// The session cookie the backend sets beside the token. Secret.
  final String? cookie;
}

/// Where the session lives between launches.
///
/// An interface rather than a utility class because the credential has to be
/// stored differently in a test than on a device: the keystore is a platform
/// channel that does not exist under `flutter test`, so a test can hand the
/// controller an in-memory store instead of a device to write to.
abstract class SessionStore {
  /// The persisted session, or null when there is nothing to restore.
  Future<StoredSession?> read();

  /// Replaces the persisted session with [session].
  Future<void> write(StoredSession session);

  /// Drops the persisted session, whether or not there is one.
  Future<void> clear();
}

/// Lazily resolved [SharedPreferences] handle.
///
/// Resolving on first use is not a micro-optimisation: constructing the store
/// happens while the app is still being wired up, and [SharedPreferences]
/// reaches a platform channel that throws outside a widget-test binding — so a
/// session that is never read or written must not cost a channel call.
class _PrefsHandle {
  _PrefsHandle([this._injected]);

  final Future<SharedPreferences>? _injected;
  Future<SharedPreferences>? _resolved;

  Future<SharedPreferences> get instance =>
      _resolved ??= _injected ?? SharedPreferences.getInstance();
}

/// The session split across the two stores the platform gives us.
///
/// The token and the cookie are a replayable credential, so they belong in the
/// keystore; the user record is the public profile the screens render and stays
/// in [SharedPreferences] under the key it has always used, which keeps the
/// shape of the app's other caches unchanged.
///
/// Every keystore access is best-effort. On a device whose keystore is
/// unreachable, and under `flutter test`, the honest reading of a failed read is
/// "no credential stored": a signed-out app is usable, an app that throws on
/// launch is not.
class SecureSessionStore implements SessionStore {
  SecureSessionStore({
    FlutterSecureStorage? storage,
    Future<SharedPreferences>? prefs,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _prefs = _PrefsHandle(prefs);

  /// Key the pre-migration builds wrote the user record to. Unchanged, so an
  /// install that upgrades keeps the profile it already had.
  static const String _userKey = 'auth_user';

  /// Keys the pre-migration builds wrote the credential to in plaintext.
  ///
  /// Also the keystore's own key names: [read] has to find a value written by
  /// either generation under the same key, so a second mapping would only be one
  /// more thing to keep in step.
  static const String _tokenKey = 'auth_token';
  static const String _cookieKey = 'auth_cookie';

  final FlutterSecureStorage _storage;
  final _PrefsHandle _prefs;

  @override
  Future<StoredSession?> read() async {
    final prefs = await _prefs.instance;
    final raw = prefs.getString(_userKey);
    if (raw == null) return null;
    final Map<String, dynamic> user;
    try {
      user = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      // A profile this build cannot decode is one it cannot sign in as, and
      // every screen reads the session — so treat it the way the controller
      // treats any other corrupt session: signed out, and re-authenticate.
      return null;
    }
    return StoredSession(
      user: user,
      token: await _adoptLegacy(_tokenKey, prefs),
      cookie: await _adoptLegacy(_cookieKey, prefs),
    );
  }

  @override
  Future<void> write(StoredSession session) async {
    final prefs = await _prefs.instance;
    await prefs.setString(_userKey, jsonEncode(session.user));
    await _writeCredential(_tokenKey, session.token);
    await _writeCredential(_cookieKey, session.cookie);
  }

  @override
  Future<void> clear() async {
    // Each half is dropped on its own and nothing here throws: a sign-out is
    // not a screen the user can retry, and a keystore that refuses to answer
    // must not leave the user record behind to sign them back in next launch —
    // nor may a failed prefs write leave the credential in the keystore.
    for (final key in const [_tokenKey, _cookieKey]) {
      try {
        await _storage.delete(key: key);
      } catch (_) {
        // Best-effort, as above.
      }
    }
    final prefs = await _prefs.instance;
    for (final key in const [_userKey, _tokenKey, _cookieKey]) {
      try {
        await prefs.remove(key);
      } catch (_) {
        // Best-effort, as above.
      }
    }
  }

  /// The credential under [key], taking a plaintext copy left by an older build
  /// with it on the way out.
  ///
  /// The plaintext key is only removed once the encrypted write has landed:
  /// dropping it after a failed keystore write would sign a pre-migration
  /// install out for good, while leaving it in place costs one more migration
  /// attempt next launch — and the value at hand still signs this launch in.
  Future<String?> _adoptLegacy(String key, SharedPreferences prefs) async {
    final stored = await _readCredential(key);
    if (stored != null) return stored;
    final legacy = prefs.getString(key);
    if (legacy == null) return null;
    try {
      await _guard(_storage.write(key: key, value: legacy));
      await prefs.remove(key);
    } catch (_) {
      // Best-effort, as above.
    }
    return legacy;
  }

  /// The keystore's answer for [key], or null when the keystore cannot be
  /// reached at all.
  Future<String?> _readCredential(String key) async {
    try {
      return await _guard(_storage.read(key: key));
    } catch (_) {
      return null;
    }
  }

  /// A keystore call that cannot outlast [_keystoreTimeout].
  ///
  /// `MissingPluginException` — the keystore simply not being there — is not the
  /// only way a platform channel fails. A call can also go unanswered: no
  /// result, no error, just a future that never completes. Under
  /// `flutter test` that is exactly what happens, and the consequence is
  /// disproportionate to the cause, because the session is persisted *inside*
  /// `login` — so a channel that never replies leaves the app on the sign-in
  /// screen with a spinner that never stops, which reads as "the server is
  /// unreachable" and is nothing of the sort.
  ///
  /// The timeout makes the failure mode the one this class already handles: give
  /// up on persistence, sign the user in, and retry on the next write. Two
  /// seconds because a keystore that has not answered by then is not about to,
  /// and this sits in front of a sign-in.
  Future<T> _guard<T>(Future<T> call) => call.timeout(
    _keystoreTimeout,
    onTimeout: () => throw const _KeystoreTimeout(),
  );

  static const Duration _keystoreTimeout = Duration(seconds: 2);

  /// Stores [value] under [key], deleting a stale entry when there is none.
  ///
  /// A null credential means the caller has no credential, not that the last
  /// one should survive: keeping it would resurrect a session the service has
  /// already been told to forget.
  Future<void> _writeCredential(String key, String? value) async {
    // Caught here rather than at the call site, for the same reason [clear]
    // catches per key: this is the boundary that promised best-effort, and a
    // `SessionStore` whose `write` throws while its `clear` does not is a
    // contract nobody can rely on. The failure the caller sees is "the session
    // was not saved" — which is what a keystore that threw and a keystore that
    // never answered both amount to.
    try {
      if (value == null) {
        await _guard(_storage.delete(key: key));
      } else {
        await _guard(_storage.write(key: key, value: value));
      }
    } catch (_) {
      // Best-effort, as above.
    }
  }
}

/// Thrown by [_SecureSessionStore._guard] when the keystore does not answer.
///
/// Private and caught by the caller that made the call: it exists to turn "the
/// channel hung" into the same best-effort path as "the channel threw", not to
/// be reported anywhere.
class _KeystoreTimeout implements Exception {
  const _KeystoreTimeout();
}

/// A session kept for as long as this object lives.
///
/// What a test injects when it needs the controller's real
/// restore/persist/sign-out behaviour but has no device to persist it on.
class MemorySessionStore implements SessionStore {
  MemorySessionStore([this._session]);

  StoredSession? _session;

  @override
  Future<StoredSession?> read() async => _session;

  @override
  Future<void> write(StoredSession session) async {
    _session = session;
  }

  @override
  Future<void> clear() async {
    _session = null;
  }
}
