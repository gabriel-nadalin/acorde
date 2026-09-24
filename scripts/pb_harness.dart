/// Shared PocketBase bootstrap + assertion plumbing for the backend scripts.
///
/// `guard_test.dart` and `verify_schema.dart` both need the same three things:
/// a real `pocketbase` binary booted against a throwaway database with the
/// shipped migrations applied and the shipped hooks loaded, an HTTP client that
/// speaks the app's wire format, and a PASS/FAIL tally that exits non-zero.
/// Keeping that in one place means a fix to the boot sequence (a changed CLI
/// flag, a slower start-up) cannot leave one of the two scripts behind.
///
/// Nothing here is reached by the Flutter app; it runs under plain `dart run`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Environment overrides, all optional:
///
///   * `PB_TEST_URL` — drive an already-running instance instead of booting
///     one. The temp data dir is then not used, and no superuser is created.
///   * `PB_TEST_ADMIN_EMAIL` / `PB_TEST_ADMIN_PASSWORD` — superuser identity
///     for the booted instance (and for `PB_TEST_URL` instances).
///   * `PB_TEST_BINARY` — path to the pocketbase executable.
///   * `PB_TEST_PORT` — fixed port; by default an OS-assigned free port is used.
class PbHarness {
  static const defaultAdminEmail = 'ci-admin@agenda.test';
  static const defaultAdminPassword = 'ci-admin-password-123';

  PbHarness();

  final String adminEmail = _env('PB_TEST_ADMIN_EMAIL') ?? defaultAdminEmail;
  final String adminPassword =
      _env('PB_TEST_ADMIN_PASSWORD') ?? defaultAdminPassword;

  final http.Client client = http.Client();
  late final String baseUrl;

  Process? _process;
  Directory? _dataDir;
  final StringBuffer _output = StringBuffer();
  bool _booted = false;

  static String? _env(String key) {
    final value = Platform.environment[key]?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Boots the backend and waits until it answers `/api/health`.
  Future<void> start() async {
    final external = _env('PB_TEST_URL');
    if (external != null) {
      baseUrl = external.replaceAll(RegExp(r'/+$'), '');
      await _waitForHealth();
      return;
    }

    final repoRoot = Directory.current;
    final binary = _env('PB_TEST_BINARY') ?? '${repoRoot.path}/pocketbase';
    if (!File(binary).existsSync()) {
      throw StateError(
        'PocketBase binary not found at "$binary". Set PB_TEST_BINARY.',
      );
    }
    final migrationsDir = '${repoRoot.path}/pb_migrations';
    final hooksDir = '${repoRoot.path}/pb_hooks';
    if (!Directory(migrationsDir).existsSync() ||
        !Directory(hooksDir).existsSync()) {
      throw StateError(
        'Expected pb_migrations/ and pb_hooks/ under ${repoRoot.path}; '
        'run this script from the repository root.',
      );
    }

    // A throwaway data dir, never `pb_data/`: that holds the developer's real
    // venues, performers and events, and the migrations under test rewrite the
    // schema underneath them.
    _dataDir = Directory.systemTemp.createTempSync('agenda_pb_test_');
    final dataDirPath = _dataDir!.path;
    final port = await _freePort();

    await _run(binary, [
      'migrate',
      'up',
      '--dir=$dataDirPath',
      '--migrationsDir=$migrationsDir',
    ]);

    // The superuser is created through the CLI: the API route that would do it
    // requires a superuser token, which is exactly what is missing here.
    await _run(binary, [
      'superuser',
      'upsert',
      adminEmail,
      adminPassword,
      '--dir=$dataDirPath',
      '--migrationsDir=$migrationsDir',
    ]);

    baseUrl = 'http://127.0.0.1:$port';
    final process = await Process.start(binary, [
      'serve',
      '--dir=$dataDirPath',
      '--migrationsDir=$migrationsDir',
      '--hooksDir=$hooksDir',
      '--http=127.0.0.1:$port',
    ]);
    _process = process;
    _booted = true;

    // Both pipes must be drained: an undrained stdout buffer eventually blocks
    // the child and the whole run hangs with nothing to show for it.
    process.stdout.transform(utf8.decoder).listen(_output.write);
    process.stderr.transform(utf8.decoder).listen(_output.write);

    await _waitForHealth();
    await _disableRateLimits();
  }

  /// The shipped defaults already disable rate limits, but a pre-provisioned
  /// instance may not, and a throttled 429 is indistinguishable from a guard
  /// rejection in an assertion.
  Future<void> _disableRateLimits() async {
    final token = await superuserToken();
    if (token.isEmpty) return;
    try {
      await client.patch(
        Uri.parse('$baseUrl/api/settings'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'rateLimits': {'enabled': false},
        }),
      );
    } catch (_) {
      // Non-fatal, and not worth failing a run over.
    }
  }

  Future<void> _waitForHealth() async {
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      final process = _process;
      if (_booted && process != null) {
        final exited = await Future.any([
          process.exitCode.then((code) => 'exit $code'),
          Future<String>.delayed(const Duration(milliseconds: 1), () => ''),
        ]);
        if (exited.isNotEmpty) {
          throw StateError(
            'pocketbase exited during boot ($exited).\n$_output',
          );
        }
      }
      try {
        final resp = await client
            .get(Uri.parse('$baseUrl/api/health'))
            .timeout(const Duration(seconds: 3));
        if (resp.statusCode == 200) return;
      } catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError(
      'pocketbase did not become healthy at $baseUrl within 45s '
      '(last error: $lastError).\n$_output',
    );
  }

  Future<void> _run(String binary, List<String> args) async {
    final result = await Process.run(binary, args);
    _output.write(result.stdout);
    _output.write(result.stderr);
    if (result.exitCode != 0) {
      throw StateError(
        '`$binary ${args.join(' ')}` failed with exit ${result.exitCode}:\n'
        '${result.stdout}\n${result.stderr}',
      );
    }
  }

  /// Terminates the process, removes the temp dir, and returns the captured
  /// server log so a failing run can print it.
  Future<String> stop() async {
    final process = _process;
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
    client.close();
    final dir = _dataDir;
    if (dir != null) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {
        // A leftover temp dir is not worth failing a run over.
      }
    }
    return _output.toString();
  }

  Future<int> _freePort() async {
    final override = _env('PB_TEST_PORT');
    if (override != null) return int.parse(override);
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  // ---------------------------------------------------------------- requests

  Future<String> superuserToken() async {
    final resp = await post('/api/collections/_superusers/auth-with-password', {
      'identity': adminEmail,
      'password': adminPassword,
    });
    return (resp.body['token'] as String?) ?? '';
  }

  Future<PbResponse> send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
  }) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }

    final uri = Uri.parse('$baseUrl$path');
    final http.Response resp;
    switch (method) {
      case 'GET':
        resp = await client.get(uri, headers: headers);
      case 'POST':
        resp = await client.post(
          uri,
          headers: headers,
          body: jsonEncode(body ?? const {}),
        );
      case 'PATCH':
        resp = await client.patch(
          uri,
          headers: headers,
          body: jsonEncode(body ?? const {}),
        );
      case 'DELETE':
        resp = await client.delete(uri, headers: headers);
      default:
        throw ArgumentError('Unsupported method $method');
    }
    return PbResponse(resp);
  }

  Future<PbResponse> get(String path, {String? token}) =>
      send('GET', path, token: token);

  Future<PbResponse> post(
    String path,
    Map<String, dynamic> body, {
    String? token,
  }) => send('POST', path, body: body, token: token);

  Future<PbResponse> patch(
    String path,
    Map<String, dynamic> body, {
    String? token,
  }) => send('PATCH', path, body: body, token: token);

  Future<PbResponse> delete(String path, {String? token}) =>
      send('DELETE', path, token: token);
}

class PbResponse {
  PbResponse(this.raw);

  final http.Response raw;

  int get status => raw.statusCode;

  Map<String, dynamic> get body {
    if (raw.body.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw.body);
      return decoded is Map<String, dynamic> ? decoded : {'data': decoded};
    } catch (_) {
      return {'raw': raw.body};
    }
  }

  String get message {
    final value = body['message'];
    return value is String ? value : '';
  }

  String get id => (body['id'] as String?) ?? '';

  @override
  String toString() => '$status ${raw.body.isEmpty ? '(empty)' : raw.body}';
}

/// PASS/FAIL tally. `exitCode` is 0 only when nothing failed.
class PbAssertions {
  final List<String> _passed = <String>[];
  final List<String> _failed = <String>[];

  List<String> get failed => List.unmodifiable(_failed);
  bool get ok => _failed.isEmpty;

  void check(String name, bool condition, [String detail = '']) {
    if (condition) {
      _passed.add(name);
      stdout.writeln('PASS  $name');
    } else {
      _failed.add(name);
      stdout.writeln('FAIL  $name${detail.isEmpty ? '' : '  ($detail)'}');
    }
  }

  /// Prints the tally and returns the process exit code.
  int summary() {
    final total = _passed.length + _failed.length;
    stdout.writeln('\n========================================');
    stdout.writeln('${_passed.length}/$total assertions passed');
    for (final name in _failed) {
      stdout.writeln('  FAILED: $name');
    }
    stdout.writeln(_failed.isEmpty ? 'RESULT: PASS' : 'RESULT: FAIL');
    stdout.writeln('========================================');
    return _failed.isEmpty ? 0 : 1;
  }
}

/// Runs [body] with a booted harness, always tears it down, and prints the
/// server log only when something failed.
Future<int> runWithHarness(
  Future<void> Function(PbHarness harness, PbAssertions assertions) body,
) async {
  final harness = PbHarness();
  final assertions = PbAssertions();
  try {
    await harness.start();
    await body(harness, assertions);
  } catch (error, stack) {
    stderr.writeln('FATAL: $error');
    stderr.writeln(stack);
    assertions.check(
      'harness boots PocketBase and answers /api/health',
      false,
      '$error',
    );
  } finally {
    final output = await harness.stop();
    if (!assertions.ok) {
      stdout.writeln('\n--- pocketbase output (tail) ---');
      final lines = output.split('\n');
      stdout.writeln(
        lines.length <= 60
            ? output
            : lines.sublist(lines.length - 60).join('\n'),
      );
    }
  }
  return assertions.summary();
}
