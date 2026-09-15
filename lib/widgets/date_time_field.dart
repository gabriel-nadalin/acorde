import 'package:flutter/material.dart';

/// "2026-08-01 19:00" display format shared by date fields and dialogs.
String formatDateTime(DateTime dt) {
  return '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

/// Tappable date/time display field; the caller supplies the picker flow.
class DateTimeField extends StatelessWidget {
  const DateTimeField({super.key, required this.label, required this.value, required this.onTap});

  final String label;
  final DateTime value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      subtitle: Text(formatDateTime(value)),
      trailing: const Icon(Icons.calendar_today),
      onTap: onTap,
    );
  }
}