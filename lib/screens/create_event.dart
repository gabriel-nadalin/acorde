import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../models/event.dart';
import '../data/repositories.dart';
import '../l10n/app_localizations.dart';
import '../services/pocketbase_service.dart';
import '../widgets/date_time_field.dart';
import '../widgets/entity_search_picker.dart';

class CreateEventPage extends StatefulWidget {
  final Event? event;
  final DateTime? initialDate;
  final String? prefillVenueId;
  final String? prefillVenueName;
  final bool lockVenue;
  final List<String>? prefillPerformerIds;

  const CreateEventPage({super.key, this.event, this.initialDate, this.prefillVenueId, this.prefillVenueName, this.lockVenue = false, this.prefillPerformerIds});

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
  String? _selectedVenueId;
  String? _selectedVenueName;

  PerformerRepository get _performersRepo => context.read<AuthController>().performers;
  VenueRepository get _venuesRepo => context.read<AuthController>().venues;

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (widget.event != null) {
      final e = widget.event!;
      _titleController.text = e.title;
      _descriptionController.text = e.description ?? '';
      _selectedVenueId = widget.prefillVenueId?.isNotEmpty == true ? widget.prefillVenueId! : (e.venueId ?? '');
      _selectedVenueName = widget.prefillVenueName;
      _start = e.start;
      _end = e.end;
      _selectedPerformerIds = Set<String>.from(e.performers);
    } else if (widget.initialDate != null) {
      final d = widget.initialDate!;
      _start = DateTime(d.year, d.month, d.day, 19, 0);
      _end = _start.add(const Duration(hours: 1));
      if (widget.prefillVenueId != null) {
        _selectedVenueId = widget.prefillVenueId;
        _selectedVenueName = widget.prefillVenueName;
      }
      if (widget.prefillPerformerIds != null && widget.prefillPerformerIds!.isNotEmpty) {
        _selectedPerformerIds = Set<String>.from(widget.prefillPerformerIds!);
      }
    } else if (widget.prefillVenueId != null) {
      _selectedVenueId = widget.prefillVenueId;
      _selectedVenueName = widget.prefillVenueName;
      if (widget.prefillPerformerIds != null && widget.prefillPerformerIds!.isNotEmpty) {
        _selectedPerformerIds = Set<String>.from(widget.prefillPerformerIds!);
      }
    }
  }

  String _performerName(Map<String, dynamic> p) {
    return (p['name'] ?? p['title'] ?? p['displayName'] ?? p['username'] ?? p['email'] ?? p['id']).toString();
  }

  String _venueName(Map<String, dynamic> v) {
    return (v['name'] ?? v['title'] ?? v['displayName'] ?? v['id']).toString();
  }

  Future<List<Map<String, dynamic>>> _loadPerformers() async {
    final repo = _performersRepo;
    await repo.load();
    return repo.items;
  }

  Future<List<Map<String, dynamic>>> _loadVenues() async {
    final repo = _venuesRepo;
    await repo.load();
    return repo.items;
  }

  void _togglePerformer(String id, String name) {
    setState(() {
      if (_selectedPerformerIds.contains(id)) {
        _selectedPerformerIds.remove(id);
      } else {
        _selectedPerformerIds.add(id);
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
    final date = await showDatePicker(context: context, initialDate: initial, firstDate: DateTime(2020), lastDate: DateTime(2035));
    if (date == null) return null;
    if (!mounted) return null;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _pickStart() async {
    final picked = await _pickDateTime(_start);
    if (picked != null) setState(() => _start = picked);
  }

  Future<void> _pickEnd() async {
    final picked = await _pickDateTime(_end);
    if (picked != null) setState(() => _end = picked);
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    if (!_formKey.currentState!.validate()) return;
    if (_end.isBefore(_start)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.endMustBeAfterStart)),
        );
      }
      return;
    }

    final eventsRepo = context.read<EventRepository>();

    final venueValue = widget.lockVenue && (widget.prefillVenueId?.isNotEmpty ?? false)
        ? widget.prefillVenueId!
        : (_selectedVenueId?.isNotEmpty == true ? _selectedVenueId! : null);

    final evt = Event(
      title: _titleController.text.trim(),
      description: _descriptionController.text.trim(),
      start: _start,
      end: _end,
      venueId: venueValue,
      performers: _selectedPerformerIds.toList(),
    );

    setState(() => _saving = true);

    String? error;
    try {
      if (widget.event != null && widget.event!.id != null) {
        await eventsRepo.update(widget.event!.id!, evt.toMap()).timeout(const Duration(seconds: 15));
      } else {
        await eventsRepo.create(evt).timeout(const Duration(seconds: 15));
      }
    } catch (e) {
      // The double-booking rule lives on the server; show its own wording
      // (e.g. "Schedule conflict: venue already booked in this time range.")
      // instead of re-deriving the comparison here.
      error = e is PocketBaseException ? e.message : e.toString();
    } finally {
      if (mounted) setState(() => _saving = false);
    }

    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorWithMessage(error))));
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(widget.event != null ? l10n.eventUpdated : l10n.eventCreated)),
    );
    context.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.event != null ? l10n.editEvent : l10n.createEvent)),
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
                validator: (v) => (v == null || v.trim().isEmpty) ? l10n.titleRequired : null,
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
                EntitySearchPicker(
                  title: l10n.venue,
                  searchLabel: l10n.searchVenues,
                  emptyMessage: l10n.noVenuesFound,
                  errorMessage: l10n.couldNotLoadVenues,
                  noneSelected: Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(l10n.noVenueSelected, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
                  ),
                  load: _loadVenues,
                  displayName: _venueName,
                  labelFor: (id, _) => _selectedVenueName ?? id,
                  selectedIds: _selectedVenueId == null ? const <String>{} : {_selectedVenueId!},
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
                    label: Text(l10n.venueWithName(_selectedVenueName ?? _selectedVenueId ?? '')),
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  ),
                ),

              // Performers picker
              EntitySearchPicker(
                title: l10n.performers,
                searchLabel: l10n.searchPerformers,
                emptyMessage: l10n.noPerformersFound,
                errorMessage: l10n.couldNotLoadPerformers,
                noneSelected: Chip(label: Text(l10n.noneSelected)),
                load: _loadPerformers,
                displayName: _performerName,
                labelFor: (id, records) => _performerName(records.firstWhere(
                  (x) => x['id']?.toString() == id,
                  orElse: () => {'id': id, 'name': id},
                )),
                selectedIds: _selectedPerformerIds,
                onToggle: _togglePerformer,
                listHeight: 160,
              ),
              const SizedBox(height: 12),

              // Start date/time
              DateTimeField(label: l10n.startLabel, value: _start, onTap: _pickStart),
              DateTimeField(label: l10n.endLabel, value: _end, onTap: _pickEnd),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _saving ? null : _submit,
                child: _saving ? const CircularProgressIndicator() : Text(widget.event != null ? l10n.save : l10n.createEvent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
