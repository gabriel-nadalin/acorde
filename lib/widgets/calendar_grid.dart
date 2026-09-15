import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../models/event.dart';
import '../theme/colors.dart';

/// YYYY-MM-DD key for a day, used for highlight sets and event-day matching.
String ymdKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Events overlapping the given calendar day (local time).
List<Event> eventsForDay(DateTime day, List<Event> items) {
  return items.where((e) {
    final start = e.start.toLocal();
    final end = e.end.toLocal();
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    return start.isBefore(dayEnd) && end.isAfter(dayStart);
  }).toList();
}

/// "August 2026" label for a month.
String monthLabel(DateTime m) {
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${months[m.month - 1]} ${m.year}';
}

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
    this.showLegend = false,
  });

  final DateTime focusedMonth;
  final ValueChanged<DateTime> onMonthChanged;
  final List<Event> events;
  final Set<String> highlightedDays;

  /// Per-event categories (e.g. {'performer'}, {'venue'}) used for dot colors.
  final Set<String> Function(Event event) eventCats;

  final void Function(BuildContext context, DateTime day, List<Event> dayEvents, bool hasEvent) onDayTap;

  final bool showLegend;

  @override
  Widget build(BuildContext context) {
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
                onPressed: () => onMonthChanged(DateTime(year, month - 1, 1)),
              ),
              Text(monthLabel(focusedMonth), style: Theme.of(context).textTheme.titleLarge),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => onMonthChanged(DateTime(year, month + 1, 1)),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: Row(
            children: const [
              Expanded(child: Center(child: Text('Sun'))),
              Expanded(child: Center(child: Text('Mon'))),
              Expanded(child: Center(child: Text('Tue'))),
              Expanded(child: Center(child: Text('Wed'))),
              Expanded(child: Center(child: Text('Thu'))),
              Expanded(child: Center(child: Text('Fri'))),
              Expanded(child: Center(child: Text('Sat'))),
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

                  // Compute day's events and category once to reuse for dot and background.
                  final dayEvents = eventsForDay(dayDate, events);
                  final cats = <String>{};
                  for (final e in dayEvents) {
                    cats.addAll(eventCats(e));
                  }

                  Color dotColor;
                  if (cats.length == 2) {
                    dotColor = AppColors.both;
                  } else if (cats.contains('performer')) {
                    dotColor = AppColors.performer;
                  } else if (cats.contains('venue')) {
                    dotColor = AppColors.venue;
                  } else {
                    dotColor = AppColors.other;
                  }

                  final bgColor = hasEvent ? dotColor.withValues(alpha: 0.12) : Colors.transparent;

                  return GestureDetector(
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
                            if (hasEvent) _dot(dotColor),
                          ],
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
              children: const [
                _LegendDot(color: AppColors.performer, label: AppStrings.performer),
                SizedBox(width: 12),
                _LegendDot(color: AppColors.venue, label: AppStrings.venue),
                SizedBox(width: 12),
                _LegendDot(color: AppColors.both, label: AppStrings.both),
              ],
            ),
          ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _dot(color, size: 12),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

Widget _dot(Color color, {double size = 8}) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle));