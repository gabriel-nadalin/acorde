import 'package:flutter/material.dart';

import '../utils/calendar_math.dart';

/// Tappable date/time display field; the caller supplies the picker flow.
class DateTimeField extends StatelessWidget {
  const DateTimeField({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final DateTime value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      subtitle: Text(
        formatDateTime(Localizations.localeOf(context).toLanguageTag(), value),
      ),
      trailing: const Icon(Icons.calendar_today),
      onTap: onTap,
    );
  }
}
