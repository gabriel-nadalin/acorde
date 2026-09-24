import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../models/event.dart';
import '../theme/colors.dart';
import '../utils/calendar_math.dart';

/// Month calendar grid: weekday header, month navigation, and day cells.
///
/// Pure presentation — day taps, keyboard activations and month changes are
/// forwarded to the callbacks; the parent decides what they mean (create,
/// edit, browse).
///
/// The day grid is a single roving tab stop: arrow keys move the focused day
/// (±1 left/right, ±7 up/down), Home/End jump to the first/last day of the
/// displayed month, and Enter/Space do exactly what a tap does. Without it a
/// keyboard user would have to Tab through up to 42 cells to get past the
/// calendar, and there would be no way to reach a day off the current week.
class CalendarGrid extends StatefulWidget {
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

  final void Function(
    BuildContext context,
    DateTime day,
    List<Event> dayEvents,
    bool hasEvent,
  )
  onDayTap;

  /// Whether a day cell does anything when tapped. Drives the semantics
  /// `button` flag so screen readers don't announce inert cells as actions,
  /// and gates the keyboard/screen-reader activation paths so all three can
  /// never disagree about what a cell does.
  final bool Function(bool hasEvent)? dayEnabled;

  final bool showLegend;

  @override
  State<CalendarGrid> createState() => _CalendarGridState();
}

class _CalendarGridState extends State<CalendarGrid> {
  /// The day the roving focus sits on. Always inside the displayed month, so an
  /// arrow key can never park focus on a cell the grid does not render.
  DateTime? _focusedDay;

  /// One [FocusNode] per **cell slot** (`0…41`), never per date.
  ///
  /// Slots are bounded and each one keeps its owner widget across month
  /// changes. A node per *date* would instead have to be re-parented between
  /// two live [Focus] widgets when the month changes, which Flutter rejects
  /// ("used by multiple widgets"), so slots are the stable identity here.
  final Map<int, FocusNode> _nodes = {};

  DateTime get _month =>
      DateTime(widget.focusedMonth.year, widget.focusedMonth.month);
  int get _leadingEmpty => DateTime(_month.year, _month.month, 1).weekday % 7;
  int get _daysInMonth => DateTime(_month.year, _month.month + 1, 0).day;

  @override
  void initState() {
    super.initState();
    _focusedDay = _defaultFocusedDay();
  }

  @override
  void didUpdateWidget(covariant CalendarGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sameMonth =
        oldWidget.focusedMonth.year == widget.focusedMonth.year &&
        oldWidget.focusedMonth.month == widget.focusedMonth.month;
    if (sameMonth) return;

    // Every cell now shows a different date, so the old roving position
    // describes a grid that is no longer on screen. Re-anchor it (and, if the
    // grid was holding keyboard focus, move that focus with it) so the focus
    // ring does not sit on a day the user never navigated to.
    //
    // No setState: this runs inside the rebuild the new widget already
    // scheduled.
    _focusedDay = _defaultFocusedDay();
    final day = _focusedDay!;
    if (!_nodes.values.any((node) => node.hasFocus)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nodeFor(_slotOf(day)).requestFocus();
    });
  }

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Today when it is in the displayed month, the 1st otherwise: "this month"
  /// is almost always meant as "the part of it around now".
  DateTime _defaultFocusedDay() {
    final now = DateTime.now();
    final month = _month;
    if (now.year == month.year && now.month == month.month) {
      return startOfDay(now);
    }
    return DateTime(month.year, month.month, 1);
  }

  FocusNode _nodeFor(int slot) => _nodes.putIfAbsent(slot, () {
    final node = FocusNode(debugLabel: 'calendar-day-$slot');
    // Repaint on focus changes and read the ring off the node itself.
    // A shared "is focused" boolean updated by `onFocusChange` would be
    // wrong here: a single focus move notifies the *gaining* node before
    // the losing one, so the pair would settle on `false`.
    node.addListener(_onNodeFocusChanged);
    return node;
  });

  void _onNodeFocusChanged() {
    if (mounted) setState(() {});
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Cell slot of [day] in the displayed month.
  int _slotOf(DateTime day) => _leadingEmpty + day.day - 1;

  bool _dayHasEvent(DateTime day) =>
      widget.highlightedDays.contains(ymdKey(day));

  bool _enabled(DateTime day) =>
      (widget.dayEnabled ?? (_) => true)(_dayHasEvent(day));

  /// Single activation path for taps, Enter/Space and screen readers.
  void _activate(DateTime day) {
    if (!_enabled(day)) return;
    widget.onDayTap(
      context,
      day,
      eventsForDay(day, widget.events),
      _dayHasEvent(day),
    );
  }

  void _moveFocusTo(DateTime day) {
    if (_focusedDay == null || !_isSameDay(day, _focusedDay!)) {
      setState(() => _focusedDay = day);
    }
    // Roving tab index: cells other than the focused one are skipped by
    // traversal but stay requestable, so this programmatic move always lands.
    // (`canRequestFocus: false` for the others would make the *next* move a
    // no-op: the request happens before the rebuild that re-enables the node.)
    _nodeFor(_slotOf(day)).requestFocus();
  }

  /// Arrow/Home/End/Enter handling for the day grid.
  ///
  /// Attached to a non-focusable [Focus] *around the day cells only*, so key
  /// events from a cell bubble up to it while the month arrows (which are
  /// ordinary focusable buttons) keep their own behaviour.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final focused = _focusedDay;
    if (focused == null) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      // Only the initial press activates: a held key repeats, and each
      // activation opens a day sheet on top of the previous one.
      if (event is KeyDownEvent) _activate(focused);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final firstOfMonth = DateTime(_month.year, _month.month, 1);
    final lastOfMonth = DateTime(_month.year, _month.month, _daysInMonth);
    DateTime? next;
    if (key == LogicalKeyboardKey.arrowLeft) {
      next = addDays(focused, -1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      next = addDays(focused, 1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      next = addDays(focused, -7);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      next = addDays(focused, 7);
    } else if (key == LogicalKeyboardKey.home) {
      next = firstOfMonth;
    } else if (key == LogicalKeyboardKey.end) {
      next = lastOfMonth;
    }
    if (next == null) return KeyEventResult.ignored;

    // Clamp to the displayed month. The grid renders exactly one month, so
    // walking past its edge would move the ring onto a slot that shows no
    // date; changing months stays the month arrows' job.
    if (next.isBefore(firstOfMonth)) next = firstOfMonth;
    if (next.isAfter(lastOfMonth)) next = lastOfMonth;
    _moveFocusTo(next);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final focusedMonth = widget.focusedMonth;
    final events = widget.events;
    final highlightedDays = widget.highlightedDays;
    final eventCats = widget.eventCats;
    final dayEnabledFor = widget.dayEnabled ?? (_) => true;
    final focusedDay = _focusedDay;
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
                onPressed: () =>
                    widget.onMonthChanged(DateTime(year, month - 1, 1)),
              ),
              Text(
                monthLabel(locale, focusedMonth),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                tooltip: l10n.calendarNextMonth,
                onPressed: () =>
                    widget.onMonthChanged(DateTime(year, month + 1, 1)),
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
        Builder(
          builder: (context) {
            final screenHeight = MediaQuery.of(context).size.height;
            final screenWidth = MediaQuery.of(context).size.width;
            final calendarHeight = math.min(480.0, screenHeight * 0.45);
            final gridPadding = 8.0;
            final mainAxisSpacing = 6.0;
            final crossAxisSpacing = 6.0;
            final totalSpacingWidth = crossAxisSpacing * 6;
            final availableWidth =
                screenWidth - (gridPadding * 2) - totalSpacingWidth;
            final cellWidth = availableWidth / 7;
            final rowCount = totalCells ~/ 7;
            final totalSpacingHeight = mainAxisSpacing * (rowCount - 1);
            final availableHeight = calendarHeight - totalSpacingHeight;
            final cellHeight = (rowCount > 0)
                ? (availableHeight / rowCount)
                : 40.0;
            final childAspectRatio = (cellHeight > 0)
                ? (cellWidth / cellHeight)
                : 1.0;

            return Center(
              child: Container(
                height: calendarHeight,
                margin: const EdgeInsets.symmetric(horizontal: 8.0),
                padding: const EdgeInsets.all(6.0),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Semantics(
                  container: true,
                  // Names the grid and teaches the arrow-key model. The cells
                  // below stay separate nodes (they are containers too), so this
                  // label is context, not a replacement for any day.
                  label: l10n.calendarGridLabel(
                    monthLabel(locale, focusedMonth),
                  ),
                  hint: l10n.calendarHint,
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    // Our own semantics above already describe the grid; the
                    // Focus widget's implicit node would be an empty sibling.
                    includeSemantics: false,
                    onKeyEvent: _onKeyEvent,
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
                        final hasEvent = highlightedDays.contains(
                          ymdKey(dayDate),
                        );
                        final isFocused =
                            focusedDay != null &&
                            _isSameDay(focusedDay, dayDate);
                        final node = _nodeFor(index);

                        // Compute day's events and category once to reuse for the
                        // marker and the background tint.
                        final dayEvents = eventsForDay(dayDate, events);
                        final cats = <String>{};
                        for (final e in dayEvents) {
                          cats.addAll(eventCats(e));
                        }

                        final tint = _tintFor(context, cats);
                        final bgColor = hasEvent
                            ? tint.withValues(alpha: 0.12)
                            : Colors.transparent;
                        final enabled = dayEnabledFor(hasEvent);
                        // Read the ring off the node, not off `isFocused`: between
                        // a roving move and focus landing they disagree for one
                        // frame, and the ring must follow real focus.
                        final showFocusRing = isFocused && node.hasFocus;

                        return Semantics(
                          container: true,
                          button: enabled,
                          // The cell paints the day number and markers; the label
                          // replaces them for assistive tech so the colour/shape
                          // encoding is never the only carrier of meaning, and
                          // moving the roving focus re-reads it — that is how the
                          // focused day is announced.
                          excludeSemantics: true,
                          focusable: true,
                          focused: showFocusRing,
                          label: _daySemanticsLabel(
                            l10n,
                            locale,
                            dayDate,
                            hasEvent,
                            cats,
                          ),
                          // Screen readers that focus a day directly get the same
                          // roving position a Tab would land on.
                          onFocus: isFocused
                              ? null
                              : () => _moveFocusTo(dayDate),
                          // The child's own tap semantics are excluded above, so
                          // the action has to be declared here.
                          onTap: enabled ? () => _activate(dayDate) : null,
                          child: Focus(
                            // See the grid-level Focus: this widget's implicit
                            // semantics node would sit unlabelled above the cell.
                            includeSemantics: false,
                            focusNode: node,
                            // Roving tab index: exactly one cell is tab-reachable
                            // at a time, and it is the one the ring is on.
                            skipTraversal: !isFocused,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _activate(dayDate),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: bgColor,
                                  borderRadius: BorderRadius.circular(8),
                                  // Default focus highlight is invisible against
                                  // the tinted cell, so draw the ring explicitly.
                                  border: showFocusRing
                                      ? Border.all(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                          width: 2,
                                        )
                                      : null,
                                ),
                                child: Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        dayIndex.toString(),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      if (hasEvent) const SizedBox(height: 6),
                                      if (hasEvent) _DayMarker(cats: cats),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        if (widget.showLegend)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 12.0,
              vertical: 6.0,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _LegendItem(cats: const {'performer'}, label: l10n.performer),
                const SizedBox(width: 12),
                _LegendItem(cats: const {'venue'}, label: l10n.venue),
                const SizedBox(width: 12),
                _LegendItem(
                  cats: const {'performer', 'venue'},
                  label: l10n.both,
                ),
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
    if (hasPerformer) {
      return _marker(AppColors.performer(context), BoxShape.circle);
    }
    if (hasVenue) return _marker(AppColors.venue(context), BoxShape.rectangle);
    return _marker(AppColors.other(context), BoxShape.circle);
  }

  Widget _marker(Color color, BoxShape shape) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: shape,
      borderRadius: shape == BoxShape.rectangle
          ? BorderRadius.circular(size * 0.2)
          : null,
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
