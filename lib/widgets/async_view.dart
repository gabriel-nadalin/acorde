import 'package:flutter/material.dart';

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
    this.errorMessage = 'Could not load data',
    this.onRetry,
  });

  final AsyncSnapshot<T> snapshot;

  /// Builds the content from the resolved data.
  final Widget Function(BuildContext context, T data) builder;

  final Widget? loading;
  final String errorMessage;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (snapshot.connectionState == ConnectionState.waiting) {
      return loading ?? const Center(child: CircularProgressIndicator());
    }
    if (snapshot.hasError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(errorMessage),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      );
    }
    return builder(context, snapshot.requireData);
  }
}