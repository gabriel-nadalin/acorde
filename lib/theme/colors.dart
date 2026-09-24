import 'package:flutter/material.dart';

/// Booking-category palette for the calendar.
///
/// The hues stay stable (blue performer / green venue / purple both) so the
/// legend remains learnable, but the shades follow the active
/// [ThemeData.brightness]: the light-mode shades are unreadable on a dark
/// surface and vice versa.
class AppColors {
  static const Color _performerLight = Color(0xFF1565C0);
  static const Color _performerDark = Color(0xFF64B5F6);
  static const Color _venueLight = Color(0xFF2E7D32);
  static const Color _venueDark = Color(0xFF81C784);
  static const Color _bothLight = Color(0xFF6A1B9A);
  static const Color _bothDark = Color(0xFFBA68C8);
  static const Color _otherLight = Color(0xFF546E7A);
  static const Color _otherDark = Color(0xFF90A4AE);

  static Color performer(BuildContext context) =>
      _resolve(context, _performerLight, _performerDark);
  static Color venue(BuildContext context) =>
      _resolve(context, _venueLight, _venueDark);
  static Color both(BuildContext context) =>
      _resolve(context, _bothLight, _bothDark);
  static Color other(BuildContext context) =>
      _resolve(context, _otherLight, _otherDark);

  static Color _resolve(BuildContext context, Color light, Color dark) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}
