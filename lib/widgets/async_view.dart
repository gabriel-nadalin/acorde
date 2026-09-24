import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Standardized async states for list-loading screens.
///
/// Replaces the ad-hoc FutureBuilder + spinner + error-text blocks with a
/// single implementation: spinner while waiting, message + retry on error,
/// and the caller's content once data is available.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.snapshot,
    required this.builder,
    this.loading,
    this.errorMessage,
    this.onRetry,
  });

  final AsyncSnapshot<T> snapshot;

  /// Builds the content from the resolved data.
  final Widget Function(BuildContext context, T data) builder;

  final Widget? loading;

  /// Falls back to the localized generic failure message.
  final String? errorMessage;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (snapshot.connectionState == ConnectionState.waiting) {
      return loading ?? const Center(child: CircularProgressIndicator());
    }
    final l10n = AppLocalizations.of(context);
    if (snapshot.hasError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(errorMessage ?? l10n.couldNotLoadData),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              ElevatedButton(onPressed: onRetry, child: Text(l10n.retry)),
            ],
          ],
        ),
      );
    }
    // Not [AsyncSnapshot.requireData]: it treats a null value as "no data", and a
    // `Future<void>` completes with exactly that. Screens that only need to know
    // *that* a refresh finished use `AsyncView<void>` (the dashboard), so a
    // completed snapshot with neither data nor error is the success case — and
    // reading it through `requireData` threw `StateError: Snapshot has neither
    // data nor error` on every single one of those renders.
    return builder(context, snapshot.data as T);
  }
}
