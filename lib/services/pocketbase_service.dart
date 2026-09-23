import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/event.dart';

/// Base URL of the PocketBase backend, overridable at build/run time via
/// `--dart-define`:
///
///   flutter run --dart-define=PB_URL=http://192.168.1.10:8090
///   flutter build web --dart-define=PB_URL=https://api.example.com
///
/// For Flutter web the URL is resolved by the *browser*, so it must be
/// reachable from the client, not from the container.
const String kPocketBaseUrl = String.fromEnvironment(
  'PB_URL',
  defaultValue: 'http://127.0.0.1:8090',
);

/// Failure reported by PocketBase for a rejected request.
///
/// PocketBase answers a failed write with a JSON envelope such as
/// `{"data":{},"message":"Schedule conflict: venue already booked in this time
/// range.","status":400}`; [message] carries that human-readable text so
/// screens can surface the server's own explanation instead of guessing the
/// rule client-side. Bodies that are not JSON are kept verbatim.
class PocketBaseException implements Exception {
  PocketBaseException(this.statusCode, this.message);

  /// Builds an exception from a PocketBase error body.
  factory PocketBaseException.fromBody(int statusCode, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final message = decoded['message']?.toString();
        if (message != null && message.isNotEmpty) {
          return PocketBaseException(statusCode, message);
        }
      }
    } catch (_) {
      // Not JSON: fall back to the raw body.
    }
    return PocketBaseException(statusCode, body);
  }

  /// HTTP status reported by the server (400 for a schedule conflict, 403 for
  /// a permission failure, ...).
  final int statusCode;

  /// Human-readable reason from the server, e.g. "Schedule conflict: venue
  /// already booked in this time range.".
  final String message;

  @override
  String toString() =>
      message.isEmpty ? 'PocketBaseException($statusCode)' : 'PocketBaseException($statusCode): $message';
}

class PocketBaseService {
  final String baseUrl;
  final http.Client _client;
  String? _authToken;
  String? _cookieHeader;

  String? get authToken => _authToken;
  String? get authCookie => _cookieHeader;

  /// Restores a previously persisted session (token + cookie) without a
  /// network round-trip.
  void restoreAuth(String? token, String? cookie) {
    _authToken = token;
    _cookieHeader = cookie;
  }

  /// App-wide shared instance. Screens use this instead of constructing new
  /// instances so the auth token and cookie survive navigation.
  static final PocketBaseService shared = PocketBaseService();

  PocketBaseService({String? baseUrl, http.Client? client})
      : baseUrl = baseUrl ?? kPocketBaseUrl,
        _client = client ?? http.Client();

  Map<String, String> _buildHeaders({bool json = true}) {
    final headers = <String, String>{};
    if (json) headers['Content-Type'] = 'application/json';
    if (_cookieHeader != null && _cookieHeader!.isNotEmpty) headers['Cookie'] = _cookieHeader!;
    if (_authToken != null && _authToken!.isNotEmpty) headers['Authorization'] = 'Bearer ${_authToken!}';
    return headers;
  }

  Future<Map<String, dynamic>?> login(String email, String password) async {
    final url = Uri.parse('$baseUrl/api/collections/users/auth-with-password');
    final resp = await _client
        .post(url, headers: {'Content-Type': 'application/json'}, body: jsonEncode({'identity': email, 'password': password}))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      try {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final token = (data['token'] ?? data['data']?['token'])?.toString();
        if (token != null) _authToken = token;

        // Try to extract the user/record from common places
        Map<String, dynamic>? record;
        if (data.containsKey('record') && data['record'] is Map) {
          record = Map<String, dynamic>.from(data['record']);
        } else if (data.containsKey('user') && data['user'] is Map) record = Map<String, dynamic>.from(data['user']);
        else if (data.containsKey('data') && data['data'] is Map && (data['data']['record'] is Map || data['data']['user'] is Map)) {
          if (data['data']['record'] is Map) {
            record = Map<String, dynamic>.from(data['data']['record']);
          } else if (data['data']['user'] is Map) record = Map<String, dynamic>.from(data['data']['user']);
        }

        // capture cookie if present
        final sc = resp.headers['set-cookie'];
        if (sc != null && sc.isNotEmpty) {
          final pairs = <String>[];
          for (final m in RegExp(r'([^=;\s]+)=([^;\s]+)').allMatches(sc)) {
            pairs.add('${m.group(1)}=${m.group(2)}');
          }
          if (pairs.isNotEmpty) _cookieHeader = pairs.join('; ');
        }

        return record;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Creates a `users` record (public signup) and adopts the session
  /// PocketBase returns so the caller is signed in immediately.
  Future<Map<String, dynamic>> signUp({
    required String email,
    required String password,
    required String passwordConfirm,
    String? name,
  }) async {
    final url = Uri.parse('$baseUrl/api/collections/users/records');
    final body = <String, dynamic>{
      'email': email,
      'password': password,
      'passwordConfirm': passwordConfirm,
      if (name != null && name.isNotEmpty) 'name': name,
    };
    final resp = await _client
        .post(url, headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    if (!(resp.statusCode >= 200 && resp.statusCode < 300)) {
      throw PocketBaseException.fromBody(resp.statusCode, resp.body);
    }
    final created = Map<String, dynamic>.from(jsonDecode(resp.body) as Map);
    // The record exists; authenticate to get a token/cookie for it.
    return await login(email, password) ?? created;
  }

  Future<String> createEvent(Event event) async {
    final url = Uri.parse('$baseUrl/api/collections/events/records');
    final body = event.toMap();
    final resp = await _client.post(url, headers: _buildHeaders(), body: jsonEncode(body)).timeout(const Duration(seconds: 15));
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      // PocketBase returns the created record as the response body with an 'id'
      final id = data['id']?.toString();
      return id ?? '';
    } else {
      throw PocketBaseException.fromBody(resp.statusCode, resp.body);
    }
  }

  /// Fetches all event records matching [filter], following PocketBase's
  /// pagination until every record is returned (no silent truncation).
  Future<List<Event>> getEvents({int perPage = 200, String? filter}) async {
    var query = 'perPage=$perPage';
    if (filter != null && filter.isNotEmpty) {
      query += '&filter=${Uri.encodeComponent(filter)}';
    }
    // Resolve related venue/performer records inline so callers don't need
    // separate name lookups.
    query += '&expand=venueId,performers';

    final all = <Event>[];
    var page = 1;
    while (true) {
      final url = Uri.parse('$baseUrl/api/collections/events/records?$query&page=$page');
      final resp = await _client.get(url, headers: _buildHeaders()).timeout(const Duration(seconds: 10));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('PocketBase get failed: ${resp.statusCode}: ${resp.body}');
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = data['items'] ?? data['data'] ?? [];
      final parsed = <Event>[];
      if (items is List) {
        for (final item in items) {
          final map = Map<String, dynamic>.from(item as Map);
          parsed.add(Event.fromMap(map, map['id']?.toString()));
        }
      }
      all.addAll(parsed);
      final totalItems = (data['totalItems'] as num?)?.toInt() ?? parsed.length;
      if (parsed.length < perPage || page * perPage >= totalItems) break;
      page++;
    }
    return all;
  }

  /// Fetches all records of [collection], following pagination until every
  /// record is returned.
  Future<List<Map<String, dynamic>>> _getAllMaps(String collection, {int perPage = 1000}) async {
    final all = <Map<String, dynamic>>[];
    var page = 1;
    while (true) {
      final url = Uri.parse('$baseUrl/api/collections/$collection/records?perPage=$perPage&page=$page');
      final resp = await _client.get(url, headers: _buildHeaders()).timeout(const Duration(seconds: 10));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('PocketBase get$collection failed: ${resp.statusCode}: ${resp.body}');
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = data['items'] ?? data['data'] ?? [];
      final parsed = <Map<String, dynamic>>[];
      if (items is List) {
        for (final item in items) {
          parsed.add(Map<String, dynamic>.from(item as Map));
        }
      }
      all.addAll(parsed);
      final totalItems = (data['totalItems'] as num?)?.toInt() ?? parsed.length;
      if (parsed.length < perPage || page * perPage >= totalItems) break;
      page++;
    }
    return all;
  }

  Future<List<Map<String, dynamic>>> getPerformers({int perPage = 1000}) =>
      _getAllMaps('performers', perPage: perPage);

  Future<List<Map<String, dynamic>>> getVenues({int perPage = 1000}) =>
      _getAllMaps('venues', perPage: perPage);

  Future<void> updateEvent(String id, Map<String, dynamic> updates) async {
    final url = Uri.parse('$baseUrl/api/collections/events/records/$id');
    final resp = await _client.patch(url, headers: _buildHeaders(), body: jsonEncode(updates)).timeout(const Duration(seconds: 10));
    if (!(resp.statusCode >= 200 && resp.statusCode < 300)) {
      throw PocketBaseException.fromBody(resp.statusCode, resp.body);
    }
  }

  Future<void> deleteEvent(String id) async {
    final url = Uri.parse('$baseUrl/api/collections/events/records/$id');
    final resp = await _client.delete(url, headers: _buildHeaders()).timeout(const Duration(seconds: 10));
    if (!(resp.statusCode >= 200 && resp.statusCode < 300)) {
      throw PocketBaseException.fromBody(resp.statusCode, resp.body);
    }
  }

  /// Parse a field that may be stored as JSON array, comma-separated string,
  /// or already as a List. Returns a list of string ids.
  List<String> parseIds(dynamic field) {
    if (field == null) return [];
    if (field is List) return field.map((e) => e.toString()).toList();
    if (field is String) {
      final s = field.trim();
      if (s.isEmpty) return [];
      try {
        final decoded = jsonDecode(s);
        if (decoded is List) return decoded.map((e) => e.toString()).toList();
      } catch (_) {
        // not JSON, fall through to comma-split
      }
      return s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    }
    return [field.toString()];
  }
}
