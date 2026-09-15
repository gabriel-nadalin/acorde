import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/event.dart';
import '../theme/colors.dart';
import '../utils/calendar_math.dart';

/// Month calendar grid: weekday header, month navigation, and day cells.
///
/// Pure presentation — day taps and month changes are forwarded to the
/// callbacks; the parent decides what they mean (create, edit, browse).
class CalendarGrid extends StatelessWidget {
  const CalendarGrid({
    super.key,
    required this.focusedMonth,
    required this.onMonthChanged,
    required this.events,
    required this.highlightedDays,
    required this.eventCats,
    required this.onDayTap,
    this.dayEnabled,
    this.showLegend = false,
  });

  final DateTime focusedMonth;
  final ValueChanged<DateTime> onMonthChanged;
  final List<Event> events;
  final Set<String> highlightedDays;

  /// Per-event categories (e.g. {'performer'}, {'venue'}) used for the day
  /// markers.
  final Set<String> Function(Event event) eventCats;

  final void Function(BuildContext context, DateTime day, List<Event> dayEvents, bool hasEvent) onDayTap;

  /// Whether a day cell does anything when tapped. Drives the semantics
  /// `button` flag so screen readers don't announce inert cells as actions.
  final bool Function(bool hasEvent)? dayEnabled;

  final bool showLegend;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final year = focusedMonth.year;
    final month = focusedMonth.month;
    final firstOfMonth = DateTime(year, month, 1);
    final leadingEmpty = firstOfMonth.weekday % 7;
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final totalCells = ((leadingEmpty + daysInMonth) <= 35) ? 35 : 42;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                tooltip: l10n.calendarPrevMonth,
                onPressed: () => onMonthChanged(DateTime(year, month - 1, 1)),
              ),
              Text(monthLabel(locale, focusedMonth), style: Theme.of(context).textTheme.titleLarge),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                tooltip: l10n.calendarNextMonth,
                onPressed: () => onMonthChanged(DateTime(year, month + 1, 1)),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: Row(
            children: [
              for (final name in weekdayAbbreviations(locale))
                Expanded(child: Center(child: Text(name))),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Builder(builder: (context) {
          final screenHeight = MediaQuery.of(context).size.height;
          final screenWidth = MediaQuery.of(context).size.width;
          final calendarHeight = math.min(480.0, screenHeight * 0.45);
          final gridPadding = 8.0;
          final mainAxisSpacing = 6.0;
          final crossAxisSpacing = 6.0;
          final totalSpacingWidth = crossAxisSpacing * 6;
          final availableWidth = screenWidth - (gridPadding * 2) - totalSpacingWidth;
          final cellWidth = availableWidth / 7;
          final rowCount = totalCells ~/ 7;
          final totalSpacingHeight = mainAxisSpacing * (rowCount - 1);
          final availableHeight = calendarHeight - totalSpacingHeight;
          final cellHeight = (rowCount > 0) ? (availableHeight / rowCount) : 40.0;
          final childAspectRatio = (cellHeight > 0) ? (cellWidth / cellHeight) : 1.0;

          return Center(
            child: Container(
              height: calendarHeight,
              margin: const EdgeInsets.symmetric(horizontal: 8.0),
              padding: const EdgeInsets.all(6.0),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: GridView.builder(
                padding: EdgeInsets.zero,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  mainAxisSpacing: mainAxisSpacing,
                  crossAxisSpacing: crossAxisSpacing,
                  childAspectRatio: childAspectRatio,
                ),
                itemCount: totalCells,
                itemBuilder: (context, index) {
                  final dayIndex = index - leadingEmpty + 1;
                  if (index < leadingEmpty || dayIndex > daysInMonth) {
                    return const SizedBox.shrink();
                  }
                  final dayDate = DateTime(year, month, dayIndex);
                  final hasEvent = highlightedDays.contains(ymdKey(dayDate));

                  // Compute day's events and category once to reuse for the
                  // marker and the background tint.
                  final dayEvents = eventsForDay(dayDate, events);
                  final cats = <String>{};
                  for (final e in dayEvents) {
                    cats.addAll(eventCats(e));
                  }

                  final tint = _tintFor(context, cats);
                  final bgColor = hasEvent ? tint.withValues(alpha: 0.12) : Colors.transparent;
                  final enabled = (dayEnabled ?? (_) => true)(hasEvent);

                  return Semantics(
                    button: enabled,
                    // The cell paints the day number and markers; the label
                    // replaces them for assistive tech so the colour/shape
                    // encoding is never the only carrier of meaning.
                    excludeSemantics: true,
                    label: _daySemanticsLabel(l10n, locale, dayDate, hasEvent, cats),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onDayTap(context, dayDate, dayEvents, hasEvent),
                      child: Container(
                        decoration: BoxDecoration(
                          color: bgColor,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(dayIndex.toString(), style: const TextStyle(fontWeight: FontWeight.w600)),
                              if (hasEvent) const SizedBox(height: 6),
                              if (hasEvent) _DayMarker(cats: cats),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        }),
        if (showLegend)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _LegendItem(cats: const {'performer'}, label: l10n.performer),
                const SizedBox(width: 12),
                _LegendItem(cats: const {'venue'}, label: l10n.venue),
                const SizedBox(width: 12),
                _LegendItem(cats: const {'performer', 'venue'}, label: l10n.both),
              ],
            ),
          ),
      ],
    );
  }

  static Color _tintFor(BuildContext context, Set<String> cats) {
    if (cats.length == 2) return AppColors.both(context);
    if (cats.contains('performer')) return AppColors.performer(context);
    if (cats.contains('venue')) return AppColors.venue(context);
    return AppColors.other(context);
  }

  static String _daySemanticsLabel(
    AppLocalizations l10n,
    String locale,
    DateTime day,
    bool hasEvent,
    Set<String> cats,
  ) {
    final date = formatFullDate(locale, day);
    if (!hasEvent) return l10n.calendarDayFree(date);
    if (cats.length == 2) return l10n.calendarDayBoth(date);
    if (cats.contains('performer')) return l10n.calendarDayPerformer(date);
    if (cats.contains('venue')) return l10n.calendarDayVenue(date);
    return l10n.calendarDayOther(date);
  }
}

/// Category marker.
///
/// Colour alone must not carry the meaning, so the shape does too:
/// performer = circle, venue = square, both = one of each.
class _DayMarker extends StatelessWidget {
  const _DayMarker({required this.cats, this.size = 8});

  final Set<String> cats;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hasPerformer = cats.contains('performer');
    final hasVenue = cats.contains('venue');
    if (hasPerformer && hasVenue) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _marker(AppColors.performer(context), BoxShape.circle),
          SizedBox(width: size * 0.4),
          _marker(AppColors.venue(context), BoxShape.rectangle),
        ],
      );
    }
    if (hasPerformer) return _marker(AppColors.performer(context), BoxShape.circle);
    if (hasVenue) return _marker(AppColors.venue(context), BoxShape.rectangle);
    return _marker(AppColors.other(context), BoxShape.circle);
  }

  Widget _marker(Color color, BoxShape shape) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: shape,
          borderRadius: shape == BoxShape.rectangle ? BorderRadius.circular(size * 0.2) : null,
        ),
      );
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.cats, required this.label});

  final Set<String> cats;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _DayMarker(cats: cats, size: 12),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}
