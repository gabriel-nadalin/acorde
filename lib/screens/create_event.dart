import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../l10n/app_localizations.dart';
import '../models/event.dart';
import '../models/performer.dart';
import '../models/recurrence.dart';
import '../models/venue.dart';
import '../utils/calendar_math.dart';
import '../utils/error_text.dart';
import '../utils/event_delete.dart';
import '../widgets/date_time_field.dart';
import '../widgets/entity_search_picker.dart';

/// Repeat frequency offered by the form.
///
/// [RecurrenceFreq] has no "none" case, and a null dropdown value renders as a
/// hint rather than as a selection, so "does not repeat" needs its own case
/// here and is mapped away when the rule is built.
enum _RepeatFreq { none, daily, weekly, monthly }

extension on _RepeatFreq {
  RecurrenceFreq? get rule => switch (this) {
    _RepeatFreq.none => null,
    _RepeatFreq.daily => RecurrenceFreq.daily,
    _RepeatFreq.weekly => RecurrenceFreq.weekly,
    _RepeatFreq.monthly => RecurrenceFreq.monthly,
  };
}

/// How the series stops.
enum _RepeatEnd { never, count, until }

class CreateEventPage extends StatefulWidget {
  final Event? event;
  final DateTime? initialDate;
  final String? prefillVenueId;
  final String? prefillVenueName;
  final bool lockVenue;
  final List<String>? prefillPerformerIds;

  const CreateEventPage({
    super.key,
    this.event,
    this.initialDate,
    this.prefillVenueId,
    this.prefillVenueName,
    this.lockVenue = false,
    this.prefillPerformerIds,
  });

  @override
  State<CreateEventPage> createState() => _CreateEventPageState();
}

class _CreateEventPageState extends State<CreateEventPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  DateTime _start = DateTime.now().add(const Duration(hours: 1));
  DateTime _end = DateTime.now().add(const Duration(hours: 2));
  bool _saving = false;

  Set<String> _selectedPerformerIds = {};

  /// Names of the selected performers, remembered from taps and list hits so a
  /// chip keeps its label after the server-side search replaces the list with
  /// records that no longer contain it.
  final Map<String, String> _selectedPerformerNames = {};
  String? _selectedVenueId;
  String? _selectedVenueName;

  // Recurrence state. Only read while [widget.event] is null: an edit targets
  // one instance and never rewrites the group's rule.
  _RepeatFreq _repeat = _RepeatFreq.none;
  final _intervalController = TextEditingController(text: '1');
  final _countController = TextEditingController(text: '12');
  _RepeatEnd _repeatEnd = _RepeatEnd.never;

  /// Last day a generated occurrence may start on (inclusive). The rule stores
  /// the exclusive bound derived from it, see [_pendingRule].
  DateTime _untilDay = DateTime.now().add(const Duration(days: 30));

  static final _random = Random();

  PerformerRepository get _performersRepo =>
      context.read<PerformerRepository>();

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _intervalController.dispose();
    _countController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (widget.event != null) {
      final e = widget.event!;
      _titleController.text = e.title;
      _descriptionController.text = e.description ?? '';
      _selectedVenueId = widget.prefillVenueId?.isNotEmpty == true
          ? widget.prefillVenueId!
          : (e.venueId ?? '');
      _selectedVenueName = widget.prefillVenueName;
      _start = e.start;
      _end = e.end;
      _selectedPerformerIds = Set<String>.from(e.performers);
      _untilDay = addDays(_start, 30);
    } else if (widget.initialDate != null) {
      final d = widget.initialDate!;
      _start = DateTime(d.year, d.month, d.day, 19, 0);
      _end = _start.add(const Duration(hours: 1));
      _untilDay = addDays(_start, 30);
      if (widget.prefillVenueId != null) {
        _selectedVenueId = widget.prefillVenueId;
        _selectedVenueName = widget.prefillVenueName;
      }
      if (widget.prefillPerformerIds != null &&
          widget.prefillPerformerIds!.isNotEmpty) {
        _selectedPerformerIds = Set<String>.from(widget.prefillPerformerIds!);
      }
    } else if (widget.prefillVenueId != null) {
      _selectedVenueId = widget.prefillVenueId;
      _selectedVenueName = widget.prefillVenueName;
      if (widget.prefillPerformerIds != null &&
          widget.prefillPerformerIds!.isNotEmpty) {
        _selectedPerformerIds = Set<String>.from(widget.prefillPerformerIds!);
      }
    }
  }

  Future<List<Performer>> _loadPerformers() async {
    final repo = _performersRepo;
    await repo.load();
    return repo.items;
  }

  Future<List<Venue>> _loadVenues() async {
    // Only venues this user manages: creating an event at any other venue is
    // rejected by the server (pb_hooks/events.guard.pb.js), so the picker must
    // not offer one.
    final assignments = context.read<AssignmentsController>();
    await assignments.refresh();
    return assignments.myVenues;
  }

  /// Venue search narrowed to the venues the user may actually book.
  ///
  /// The picker's previous implementation only ever saw one page of venues, so
  /// the query is delegated to the repository, which searches the whole
  /// collection. A hit at somebody else's venue is still filtered out here:
  /// the guard rejects an event booked there, and the picker must not offer it.
  Future<List<Venue>> _searchVenues(String query) async {
    final assignments = context.read<AssignmentsController>();
    final found = await context.read<VenueRepository>().search(query);
    return [
      for (final venue in found)
        if (venue.id != null && assignments.isMyVenue(venue.id!)) venue,
    ];
  }

  String _performerLabel(String id, List<Performer> records) {
    final chosen = _selectedPerformerNames[id];
    if (chosen != null) return chosen;
    for (final performer in records) {
      if (performer.id == id) return performer.name;
    }
    return id;
  }

  String _venueLabel(String id, List<Venue> records) {
    for (final venue in records) {
      if (venue.id == id) return venue.name;
    }
    return _selectedVenueName ?? id;
  }

  void _togglePerformer(String id, String name) {
    setState(() {
      if (_selectedPerformerIds.contains(id)) {
        _selectedPerformerIds.remove(id);
        _selectedPerformerNames.remove(id);
      } else {
        _selectedPerformerIds.add(id);
        _selectedPerformerNames[id] = name;
      }
    });
  }

  void _toggleVenue(String id, String name) {
    setState(() {
      if (_selectedVenueId == id) {
        _selectedVenueId = null;
        _selectedVenueName = null;
      } else {
        _selectedVenueId = id;
        _selectedVenueName = name;
      }
    });
  }

  Future<DateTime?> _pickDateTime(DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (date == null) return null;
    if (!mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _pickStart() async {
    final picked = await _pickDateTime(_start);
    if (picked == null) return;
    setState(() {
      _start = picked;
      // Keep the repeat bound ahead of the start: an `until` that no longer
      // covers the start would collapse the series to a single occurrence.
      if (!_untilDay.isAfter(picked)) _untilDay = addDays(picked, 30);
    });
  }

  Future<void> _pickEnd() async {
    final picked = await _pickDateTime(_end);
    if (picked != null) setState(() => _end = picked);
  }

  Future<void> _pickUntilDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _untilDay.isAfter(_start) ? _untilDay : _start,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked != null) setState(() => _untilDay = startOfDay(picked));
  }

  /// Rule described by the repeat section, or null when the event does not
  /// repeat.
  ///
  /// The end condition travels inside the rule (`count` / `until`), so each
  /// instance the server stores describes its own series instead of relying on
  /// the client to remember how far the group goes.
  Recurrence? get _pendingRule {
    final freq = _repeat.rule;
    if (freq == null) return null;
    final interval = int.tryParse(_intervalController.text.trim()) ?? 1;
    final count = _repeatEnd == _RepeatEnd.count
        ? int.tryParse(_countController.text.trim())
        : null;
    return Recurrence(
      freq: freq,
      interval: interval < 1 ? 1 : interval,
      count: count != null && count > 0 ? count : null,
      // `until` is exclusive on the occurrence start, so the picked day has to
      // reach its end or the last booking on that day is dropped.
      until: _repeatEnd == _RepeatEnd.until ? startOfNextDay(_untilDay) : null,
    );
  }

  /// Occurrence starts the current rule would create, including the first.
  List<DateTime> _occurrences() =>
      _pendingRule?.occurrences(_start) ?? const [];

  /// Interval and occurrence count are both positive integers bounded by the
  /// model's generation limit; the shared key states exactly that range.
  String? _positiveInt(String? value) {
    final parsed = int.tryParse((value ?? '').trim());
    if (parsed == null || parsed < 1 || parsed > Recurrence.hardMax) {
      return AppLocalizations.of(context).repeatCountInvalid;
    }
    return null;
  }

  /// Groups the instances of one submitted series. Unique among this client's
  /// own series is enough, so a timestamp plus 32 random bits avoids a uuid
  /// dependency.
  String _newSeriesId() =>
      's${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_random.nextInt(1 << 32).toRadixString(36)}';

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Deletes the event being edited and leaves the form.
  ///
  /// The confirmation — including the recurring-instance question — is shared
  /// with the upcoming list and the calendar's day sheet, so all three ask the
  /// same thing and none can quietly delete a whole series by accident.
  Future<void> _delete() async {
    final event = widget.event;
    if (event == null) return;
    final deleted = await confirmDeleteEvent(context, event);
    // The repository already refreshed its lists; the form's only job now is to
    // leave, reporting that something changed so its caller reloads too.
    if (deleted && mounted) context.pop(true);
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    if (!_formKey.currentState!.validate()) return;
    // Strictly after: `end == start` is a zero-length booking that the server's
    // own `start < end` guard rejects with an opaque 400.
    if (!_end.isAfter(_start)) {
      _snack(l10n.endMustBeAfterStart);
      return;
    }

    final eventsRepo = context.read<EventRepository>();

    final venueValue =
        widget.lockVenue && (widget.prefillVenueId?.isNotEmpty ?? false)
        ? widget.prefillVenueId!
        : (_selectedVenueId?.isNotEmpty == true ? _selectedVenueId! : null);

    final editing = widget.event?.id != null;

    final base = Event(
      title: _titleController.text.trim(),
      description: _descriptionController.text.trim(),
      start: _start,
      end: _end,
      venueId: venueValue,
      performers: _selectedPerformerIds.toList(),
      // An edit targets this instance only. `toMap()` always emits `seriesId`
      // and `recurrence` (null included), so not carrying them over would
      // detach the instance from its series on the server.
      seriesId: widget.event?.seriesId,
      recurrence: widget.event?.recurrence,
    );

    final rule = editing ? null : _pendingRule;
    final occurrences = _occurrences();

    setState(() => _saving = true);

    String? error;
    int? seriesCount;
    List<String> rejected = const [];
    try {
      if (editing) {
        await eventsRepo
            .update(widget.event!.id!, base.toMap())
            .timeout(const Duration(seconds: 15));
      } else if (rule != null && occurrences.length > 1) {
        final seriesId = _newSeriesId();
        final series = [
          for (final at in occurrences)
            base
                .occurrenceAt(at)
                .copyWith(seriesId: seriesId, recurrence: rule),
        ];
        // No outer deadline: every instance is its own request, so a deadline
        // over the whole series would give up midway with no way to tell the
        // user which bookings were stored.
        rejected = await eventsRepo.createSeries(series);
        seriesCount = series.length - rejected.length;
      } else {
        await eventsRepo.create(base).timeout(const Duration(seconds: 15));
      }
    } catch (e) {
      // The double-booking rule lives on the server; show its own wording
      // (e.g. "Schedule conflict: venue already booked in this time range.")
      // instead of re-deriving the comparison here.
      error = errorText(l10n, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }

    if (!mounted) return;
    if (error != null) {
      _snack(l10n.errorWithMessage(error));
      return;
    }

    if (seriesCount != null) {
      // Both halves are reported: "created 7" alone would hide the 5 slots the
      // guard refused, and each rejected occurrence carries the reason the
      // server gave, so the user can see which slots to rebook.
      _snack(
        rejected.isEmpty
            ? l10n.seriesCreated(seriesCount)
            : '${l10n.seriesPartial(seriesCount, rejected.length)} ${l10n.seriesPartialDetail(rejected.join('; '))}',
      );
      context.pop(true);
      return;
    }

    _snack(editing ? l10n.eventUpdated : l10n.eventCreated);
    context.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final creating = widget.event == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.event != null ? l10n.editEvent : l10n.createEvent),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              // Title
              TextFormField(
                controller: _titleController,
                decoration: InputDecoration(labelText: l10n.titleLabel),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? l10n.titleRequired : null,
              ),
              const SizedBox(height: 12),

              // Description
              TextFormField(
                controller: _descriptionController,
                decoration: InputDecoration(labelText: l10n.descriptionLabel),
                maxLines: 3,
              ),
              const SizedBox(height: 12),

              // Venue selector (unless locked via prefill)
              if (!widget.lockVenue) ...[
                EntitySearchPicker<Venue>(
                  title: l10n.venue,
                  searchLabel: l10n.searchVenues,
                  emptyMessage: l10n.noVenuesFound,
                  errorMessage: l10n.couldNotLoadVenues,
                  noneSelected: Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      l10n.noVenueSelected,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                  load: _loadVenues,
                  search: _searchVenues,
                  labelFor: _venueLabel,
                  selectedIds: _selectedVenueId == null
                      ? const <String>{}
                      : {_selectedVenueId!},
                  onToggle: _toggleVenue,
                  listHeight: 140,
                  clearSearchOnSelect: true,
                ),
                const SizedBox(height: 12),
              ],

              // Locked venue display
              if (widget.lockVenue && (_selectedVenueId?.isNotEmpty == true))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Chip(
                    label: Text(
                      l10n.venueWithName(
                        _selectedVenueName ?? _selectedVenueId ?? '',
                      ),
                    ),
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                  ),
                ),

              // Performers picker
              EntitySearchPicker<Performer>(
                title: l10n.performers,
                searchLabel: l10n.searchPerformers,
                emptyMessage: l10n.noPerformersFound,
                errorMessage: l10n.couldNotLoadPerformers,
                noneSelected: Chip(label: Text(l10n.noneSelected)),
                load: _loadPerformers,
                repository: context.read<PerformerRepository>(),
                labelFor: _performerLabel,
                selectedIds: _selectedPerformerIds,
                onToggle: _togglePerformer,
                listHeight: 160,
              ),
              const SizedBox(height: 12),

              // Start date/time
              DateTimeField(
                label: l10n.startLabel,
                value: _start,
                onTap: _pickStart,
              ),
              DateTimeField(label: l10n.endLabel, value: _end, onTap: _pickEnd),

              // Repeat: create only, because editing one instance of a series
              // must not rewrite the rule for the occurrences already stored.
              if (creating) ...[
                const Divider(height: 32),
                Text(
                  l10n.repeatLabel,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<_RepeatFreq>(
                  initialValue: _repeat,
                  decoration: InputDecoration(labelText: l10n.repeatLabel),
                  items: [
                    DropdownMenuItem(
                      value: _RepeatFreq.none,
                      child: Text(l10n.repeatNone),
                    ),
                    DropdownMenuItem(
                      value: _RepeatFreq.daily,
                      child: Text(l10n.repeatDaily),
                    ),
                    DropdownMenuItem(
                      value: _RepeatFreq.weekly,
                      child: Text(l10n.repeatWeekly),
                    ),
                    DropdownMenuItem(
                      value: _RepeatFreq.monthly,
                      child: Text(l10n.repeatMonthly),
                    ),
                  ],
                  onChanged: (value) =>
                      setState(() => _repeat = value ?? _RepeatFreq.none),
                ),
                if (_repeat != _RepeatFreq.none) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _intervalController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: l10n.repeatIntervalLabel,
                    ),
                    validator: _positiveInt,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<_RepeatEnd>(
                    initialValue: _repeatEnd,
                    decoration: InputDecoration(
                      labelText: l10n.repeatEndsLabel,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: _RepeatEnd.never,
                        child: Text(l10n.repeatEndsNever),
                      ),
                      DropdownMenuItem(
                        value: _RepeatEnd.count,
                        child: Text(l10n.repeatEndsCount),
                      ),
                      DropdownMenuItem(
                        value: _RepeatEnd.until,
                        child: Text(l10n.repeatEndsUntil),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => _repeatEnd = value ?? _RepeatEnd.never),
                  ),
                  if (_repeatEnd == _RepeatEnd.count) ...[
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _countController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: l10n.repeatCountLabel,
                      ),
                      validator: _positiveInt,
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                  if (_repeatEnd == _RepeatEnd.until) ...[
                    const SizedBox(height: 12),
                    ListTile(
                      title: Text(l10n.repeatUntilLabel),
                      subtitle: Text(formatDate(locale, _untilDay)),
                      trailing: const Icon(Icons.calendar_today),
                      onTap: _pickUntilDay,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    l10n.occurrenceCountLabel(_occurrences().length),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],

              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? const CircularProgressIndicator()
                    : Text(widget.event != null ? l10n.save : l10n.createEvent),
              ),
              // Only while editing: there is nothing to delete about a booking
              // that has not been created yet.
              if (widget.event?.id != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _saving ? null : _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(l10n.deleteEvent),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
