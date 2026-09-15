import 'package:flutter/material.dart';

import 'async_view.dart';

/// Searchable picker over PocketBase records (performers or venues).
///
/// Owns its own search text and filtering, so typing only rebuilds the picker
/// instead of the whole form. The selection itself stays with the caller: it
/// receives [selectedIds] and reports taps through [onToggle].
///
/// Records are loaded through [load] once per picker; a failed load renders
/// the standard [AsyncView] error with a retry action.
class EntitySearchPicker extends StatefulWidget {
  const EntitySearchPicker({
    super.key,
    required this.title,
    required this.searchLabel,
    required this.emptyMessage,
    required this.errorMessage,
    required this.noneSelected,
    required this.load,
    required this.displayName,
    required this.labelFor,
    required this.selectedIds,
    required this.onToggle,
    required this.listHeight,
    this.clearSearchOnSelect = false,
  });

  /// Section heading, e.g. `Performers`.
  final String title;

  /// Label of the search field, e.g. `Search performers`.
  final String searchLabel;

  /// Shown in the list area when nothing matches the current query.
  final String emptyMessage;

  /// Shown by [AsyncView] when [load] fails.
  final String errorMessage;

  /// Shown in place of the selected chips when [selectedIds] is empty.
  final Widget noneSelected;

  /// Fetches the selectable records; invoked once per picker and again on retry.
  final Future<List<Map<String, dynamic>>> Function() load;

  /// Name of a record, used both for search matching and for list labels.
  final String Function(Map<String, dynamic> record) displayName;

  /// Label of the chip for [id]; [records] holds whatever has loaded so far so
  /// a pre-selected id can still be labelled before its record arrives.
  final String Function(String id, List<Map<String, dynamic>> records) labelFor;

  final Set<String> selectedIds;

  /// Called with the tapped record's id and name, and with the chip's label
  /// when a chip is deleted.
  final void Function(String id, String name) onToggle;

  final double listHeight;

  /// Clears the query after a selection (single-select behaviour).
  final bool clearSearchOnSelect;

  @override
  State<EntitySearchPicker> createState() => _EntitySearchPickerState();
}

class _EntitySearchPickerState extends State<EntitySearchPicker> {
  final _searchController = TextEditingController();
  late Future<List<Map<String, dynamic>>> _future;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _retry() {
    setState(() => _future = widget.load());
  }

  void _select(String id, String name) {
    if (widget.clearSearchOnSelect) {
      _searchController.clear();
      setState(() => _query = '');
    }
    widget.onToggle(id, name);
  }

  List<Map<String, dynamic>> _matching(List<Map<String, dynamic>> records) {
    final query = _query.toLowerCase().trim();
    if (query.isEmpty) return records;
    return records.where((r) => widget.displayName(r).toLowerCase().contains(query)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) {
        final loaded = snapshot.data ?? const <Map<String, dynamic>>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (widget.selectedIds.isEmpty)
              widget.noneSelected
            else
              Wrap(
                spacing: 8,
                children: [
                  for (final id in widget.selectedIds)
                    Chip(
                      label: Text(widget.labelFor(id, loaded)),
                      onDeleted: () => widget.onToggle(id, widget.labelFor(id, loaded)),
                    ),
                ],
              ),
            const SizedBox(height: 6),
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: widget.searchLabel,
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            AsyncView<List<Map<String, dynamic>>>(
              snapshot: snapshot,
              errorMessage: widget.errorMessage,
              onRetry: _retry,
              loading: const SizedBox(
                height: 24,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              builder: (context, records) {
                final filtered = _matching(records);
                return SizedBox(
                  height: widget.listHeight,
                  child: filtered.isEmpty
                      ? Center(child: Text(widget.emptyMessage))
                      : ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (ctx, i) {
                            final record = filtered[i];
                            final id = record['id']?.toString();
                            final name = widget.displayName(record);
                            final selected = id != null && widget.selectedIds.contains(id);
                            return ListTile(
                              dense: true,
                              title: Text(name),
                              trailing: Icon(selected ? Icons.check_circle : Icons.add_circle_outline),
                              onTap: id == null ? null : () => _select(id, name),
                            );
                          },
                        ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}
