import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../models/event.dart';
import '../data/repositories.dart';
import '../widgets/date_time_field.dart';

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
  final _performerSearchController = TextEditingController();
  final _venueSearchController = TextEditingController();
  DateTime _start = DateTime.now().add(const Duration(hours: 1));
  DateTime _end = DateTime.now().add(const Duration(hours: 2));
  bool _saving = false;

  PerformerRepository get _performersRepo => context.read<AuthController>().performers;
  VenueRepository get _venuesRepo => context.read<AuthController>().venues;

  // Performer state
  List<Map<String, dynamic>> _availablePerformers = [];
  List<Map<String, dynamic>> _filteredPerformers = [];
  Set<String> _selectedPerformerIds = {};
  bool _loadingPerformers = false;
  String _performerQuery = '';

  // Venue state
  List<Map<String, dynamic>> _availableVenues = [];
  List<Map<String, dynamic>> _filteredVenues = [];
  String? _selectedVenueId;
  String? _selectedVenueName;
  bool _loadingVenues = false;
  String _venueQuery = '';

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _performerSearchController.dispose();
    _venueSearchController.dispose();
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
    _loadPerformers();
    _loadVenues();
  }

  String _performerName(Map<String, dynamic> p) {
    return (p['name'] ?? p['title'] ?? p['displayName'] ?? p['username'] ?? p['email'] ?? p['id']).toString();
  }

  String _venueName(Map<String, dynamic> v) {
    return (v['name'] ?? v['title'] ?? v['displayName'] ?? v['id']).toString();
  }

  Future<void> _loadPerformers() async {
    final repo = _performersRepo;
    setState(() => _loadingPerformers = true);
    try {
      await repo.load();
      if (!mounted) return;
      setState(() {
        _availablePerformers = repo.items;
        _updatePerformerFilter();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load performers: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingPerformers = false);
    }
  }

  Future<void> _loadVenues() async {
    final repo = _venuesRepo;
    setState(() => _loadingVenues = true);
    try {
      await repo.load();
      if (!mounted) return;
      setState(() {
        _availableVenues = repo.items;
        _updateVenueFilter();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load venues: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingVenues = false);
    }
  }

  void _updatePerformerFilter() {
    final query = _performerQuery.toLowerCase().trim();
    if (query.isEmpty) {
      _filteredPerformers = List<Map<String, dynamic>>.from(_availablePerformers);
      return;
    }
    _filteredPerformers = _availablePerformers.where((p) {
      final name = _performerName(p).toLowerCase();
      return name.contains(query);
    }).toList();
  }

  void _updateVenueFilter() {
    final query = _venueQuery.toLowerCase().trim();
    if (query.isEmpty) {
      _filteredVenues = List<Map<String, dynamic>>.from(_availableVenues);
      return;
    }
    _filteredVenues = _availableVenues.where((v) {
      final name = _venueName(v).toLowerCase();
      return name.contains(query);
    }).toList();
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
    if (!_formKey.currentState!.validate()) return;
    if (_end.isBefore(_start)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('End must be after start')),
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

    // Check for conflicts via overlapping-events query

    List<Event> overlapping = [];
    String? fetchError;
    try {
      overlapping = await eventsRepo.overlapping(evt.start, evt.end);
    } catch (e) {
      fetchError = e.toString();
      overlapping = [];
    }
    if (!mounted) return;

    // Narrow to conflicts involving our venue or performers
    final newPerfs = evt.performers.map((p) => p.toString().trim()).where((s) => s.isNotEmpty).toSet();
    final newVenue = evt.venueId?.toString().trim() ?? '';
    final currentEventId = widget.event?.id?.toString().trim() ?? '';

    final conflicts = <Map<String, dynamic>>[];
    for (final e in overlapping) {
      final existingId = e.id?.toString().trim() ?? '';
      if (currentEventId.isNotEmpty && existingId.isNotEmpty && existingId == currentEventId) continue;

      final reasons = <String>[];
      final existingVenue = e.venueId?.toString().trim() ?? '';
      if (newVenue.isNotEmpty && existingVenue.isNotEmpty && newVenue == existingVenue) reasons.add('venue');

      final existingPerfs = e.performers.map((p) => p.toString().trim()).where((s) => s.isNotEmpty).toSet();
      if (newPerfs.isNotEmpty && existingPerfs.intersection(newPerfs).isNotEmpty) reasons.add('performer');

      if (reasons.isNotEmpty) conflicts.add({'event': e, 'reasons': reasons});
    }

    if (fetchError != null) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Could not verify conflicts'),
          content: Text('Unable to check for scheduling conflicts: $fetchError'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Proceed anyway')),
          ],
        ),
      );
      if (proceed != true) return;
    } else if (conflicts.isNotEmpty) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Schedule conflicts detected'),
          content: SizedBox(
            width: double.maxFinite,
            height: 240,
            child: ListView.separated(
              itemCount: conflicts.length,
              separatorBuilder: (_, _) => const Divider(height: 8),
              itemBuilder: (c, i) {
                final ce = conflicts[i]['event'] as Event;
                final reasons = List<String>.from(conflicts[i]['reasons'] as List);
                final reasonStr = reasons.map((r) => r == 'venue' ? 'Venue' : 'Performer').join(' & ');
                final perfNames = ce.performerNames.isNotEmpty
                    ? ce.performerNames.join(', ')
                    : ce.performers.join(', ');
                return ListTile(
                  title: Text(ce.title.isNotEmpty ? ce.title : '(no title)'),
                  subtitle: Text('${formatDateTime(ce.start.toLocal())} — ${formatDateTime(ce.end.toLocal())}\n$reasonStr • ${ce.venueName ?? ce.venueId ?? ''}\n$perfNames'),
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Proceed Anyway')),
          ],
        ),
      );
      if (proceed != true) return;
    }

    setState(() => _saving = true);

    String? error;
    try {
      if (widget.event != null && widget.event!.id != null) {
        await eventsRepo.update(widget.event!.id!, evt.toMap()).timeout(const Duration(seconds: 15));
      } else {
        await eventsRepo.create(evt).timeout(const Duration(seconds: 15));
      }
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => _saving = false);
    }

    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $error')));
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(widget.event != null ? 'Event updated' : 'Event created')),
    );
    context.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.event != null ? 'Edit Event' : 'Create Event')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              // Title
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: 'Title'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a title' : null,
              ),
              const SizedBox(height: 12),

              // Description
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(labelText: 'Description'),
                maxLines: 3,
              ),
              const SizedBox(height: 12),

              // Venue selector (unless locked via prefill)
              if (!widget.lockVenue) ...[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Venue', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (_selectedVenueId != null)
                      Chip(
                        label: Text(_selectedVenueName ?? _selectedVenueId!),
                        onDeleted: () => setState(() {
                          _selectedVenueId = null;
                          _selectedVenueName = null;
                        }),
                      )
                    else
                      const Padding(
                        padding: EdgeInsets.only(bottom: 6),
                        child: Text('No venue selected', style: TextStyle(color: Colors.grey)),
                      ),
                    TextField(
                      controller: _venueSearchController,
                      decoration: const InputDecoration(
                        labelText: 'Search venues',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (v) => setState(() {
                        _venueQuery = v;
                        _updateVenueFilter();
                      }),
                    ),
                    const SizedBox(height: 8),
                    if (_loadingVenues)
                      const SizedBox(height: 24, child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                    else
                      SizedBox(
                        height: 140,
                        child: _filteredVenues.isEmpty
                            ? const Center(child: Text('No venues found'))
                            : ListView.separated(
                                itemCount: _filteredVenues.length,
                                separatorBuilder: (_, _) => const Divider(height: 1),
                                itemBuilder: (ctx, i) {
                                  final v = _filteredVenues[i];
                                  final id = v['id']?.toString();
                                  final name = _venueName(v);
                                  final selected = id != null && id == _selectedVenueId;
                                  return ListTile(
                                    dense: true,
                                    title: Text(name),
                                    trailing: Icon(selected ? Icons.check_circle : Icons.add_circle_outline),
                                    onTap: id == null
                                        ? null
                                        : () => setState(() {
                                              if (selected) {
                                                _selectedVenueId = null;
                                                _selectedVenueName = null;
                                              } else {
                                                _selectedVenueId = id;
                                                _selectedVenueName = name;
                                              }
                                              _venueQuery = '';
                                              _venueSearchController.clear();
                                              _updateVenueFilter();
                                            }),
                                  );
                                },
                              ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],

              // Locked venue display
              if (widget.lockVenue && (_selectedVenueId?.isNotEmpty == true))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Chip(
                    label: Text('Venue: ${_selectedVenueName ?? _selectedVenueId}'),
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  ),
                ),

              // Performers picker
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Performers', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: _selectedPerformerIds.isEmpty
                        ? [const Chip(label: Text('None selected'))]
                        : _selectedPerformerIds.map((id) {
                            final p = _availablePerformers.firstWhere(
                              (x) => x['id']?.toString() == id,
                              orElse: () => {'id': id, 'name': id},
                            );
                            return Chip(
                              label: Text(_performerName(p)),
                              onDeleted: () => setState(() => _selectedPerformerIds.remove(id)),
                            );
                          }).toList(),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _performerSearchController,
                    decoration: const InputDecoration(
                      labelText: 'Search performers',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (v) => setState(() {
                      _performerQuery = v;
                      _updatePerformerFilter();
                    }),
                  ),
                  const SizedBox(height: 8),
                  if (_loadingPerformers)
                    const SizedBox(height: 24, child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                  else
                    SizedBox(
                      height: 160,
                      child: _filteredPerformers.isEmpty
                          ? const Center(child: Text('No performers found'))
                          : ListView.separated(
                              itemCount: _filteredPerformers.length,
                              separatorBuilder: (_, _) => const Divider(height: 1),
                              itemBuilder: (ctx, i) {
                                final p = _filteredPerformers[i];
                                final id = p['id']?.toString();
                                final name = _performerName(p);
                                final selected = id != null && _selectedPerformerIds.contains(id);
                                return ListTile(
                                  dense: true,
                                  title: Text(name),
                                  trailing: Icon(selected ? Icons.check_circle : Icons.add_circle_outline),
                                  onTap: id == null
                                      ? null
                                      : () => setState(() {
                                            if (selected) {
                                              _selectedPerformerIds.remove(id);
                                            } else {
                                              _selectedPerformerIds.add(id);
                                            }
                                          }),
                                );
                              },
                            ),
                    ),
                ],
              ),
              const SizedBox(height: 12),

              // Start date/time
              DateTimeField(label: 'Start', value: _start, onTap: _pickStart),
              DateTimeField(label: 'End', value: _end, onTap: _pickEnd),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _saving ? null : _submit,
                child: _saving ? const CircularProgressIndicator() : Text(widget.event != null ? 'Save' : 'Create Event'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}