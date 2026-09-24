import 'dart:ffi';

/// Switches the process-local timezone for the running test isolate.
///
/// The calendar and recurrence code is only correct if it steps days and
/// recurrences by *calendar components*. A `Duration(days: 1)` implementation
/// is indistinguishable from a correct one in a zone without DST — and the
/// machine this suite runs on sits in `America/Sao_Paulo`, which has had no
/// transition since 2019, so a DST test written there would pass for the wrong
/// reason and keep passing after the bug came back.
///
/// POSIX exposes `setenv` + `tzset`, and Dart resolves the local zone through
/// the C library on each conversion, so the override takes effect immediately
/// for `DateTime` in this isolate. `flutter test` runs each test file in its own
/// process, and callers restore the original value in `tearDownAll`, so the
/// override cannot leak into other suites.
class LocalTimeZone {
  LocalTimeZone._();

  static DynamicLibrary? _libc;
  static bool _symbolsResolved = false;
  static int Function(Pointer<Uint8>, Pointer<Uint8>, int)? _setenv;
  static void Function()? _tzset;
  static Pointer<Uint8> Function(int)? _malloc;
  static void Function(Pointer<Uint8>)? _free;

  /// Points the process at the IANA [zone].
  ///
  /// Throws [StateError] when the platform does not expose the POSIX
  /// timezone hooks: silently doing nothing would turn every DST assertion in
  /// the suite into a test that cannot fail.
  static void use(String zone) {
    _resolve();
    final key = _cString('TZ');
    final value = _cString(zone);
    try {
      final result = _setenv!(key, value, 1);
      if (result != 0) {
        throw StateError('setenv("TZ", "$zone") failed with $result');
      }
      _tzset!();
    } finally {
      _free!(key);
      _free!(value);
    }
  }

  /// Reads the current `TZ` value so [restore] can put it back.
  static String? current() {
    _resolve();
    return _readEnv('TZ');
  }

  /// Restores a value captured from [current]; a null value means `TZ` was
  /// unset, so it is removed again rather than left pointing at [zone].
  static void restore(String? zone) {
    if (zone != null) {
      use(zone);
      return;
    }
    _resolve();
    final key = _cString('TZ');
    try {
      _libc!.lookupFunction<
        Int32 Function(Pointer<Uint8>),
        int Function(Pointer<Uint8>)
      >('unsetenv')(key);
      _tzset!();
    } finally {
      _free!(key);
    }
  }

  static void _resolve() {
    if (_symbolsResolved) return;
    final libc = _openLibc();
    _libc = libc;
    _setenv = libc
        .lookupFunction<
          Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Int32),
          int Function(Pointer<Uint8>, Pointer<Uint8>, int)
        >('setenv');
    _tzset = libc.lookupFunction<Void Function(), void Function()>('tzset');
    _malloc = libc
        .lookupFunction<
          Pointer<Uint8> Function(IntPtr),
          Pointer<Uint8> Function(int)
        >('malloc');
    _free = libc
        .lookupFunction<
          Void Function(Pointer<Uint8>),
          void Function(Pointer<Uint8>)
        >('free');
    _symbolsResolved = true;
  }

  static DynamicLibrary _openLibc() {
    final attempts = <Object>[];
    for (final path in const [
      '/lib/x86_64-linux-gnu/libc.so.6',
      '/lib64/libc.so.6',
      '/usr/lib/libc.so.6',
      '/usr/lib/libSystem.B.dylib',
    ]) {
      try {
        return DynamicLibrary.open(path);
      } catch (error) {
        attempts.add('$path ($error)');
      }
    }
    try {
      // Linux resolves libc symbols through the process handle; the dylib
      // paths above cover the platforms where it does not.
      return DynamicLibrary.process();
    } catch (error) {
      attempts.add('process ($error)');
    }
    throw StateError(
      'Cannot load the C library to set TZ; tried ${attempts.join(', ')}',
    );
  }

  static Pointer<Uint8> _cString(String value) {
    final units = value.codeUnits;
    final pointer = _malloc!(units.length + 1);
    for (var i = 0; i < units.length; i++) {
      pointer[i] = units[i];
    }
    pointer[units.length] = 0;
    return pointer;
  }

  static String? _readEnv(String name) {
    try {
      final getenv = _libc!
          .lookupFunction<
            Pointer<Uint8> Function(Pointer<Uint8>),
            Pointer<Uint8> Function(Pointer<Uint8>)
          >('getenv');
      final key = _cString(name);
      try {
        final value = getenv(key);
        if (value == nullptr) return null;
        final bytes = <int>[];
        for (var i = 0; value[i] != 0; i++) {
          bytes.add(value[i]);
        }
        if (bytes.isEmpty) return null;
        return String.fromCharCodes(bytes);
      } finally {
        _free!(key);
      }
    } catch (_) {
      return null;
    }
  }
}
