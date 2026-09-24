import 'dart:async';

import 'package:flutter/material.dart';

import '../data/repositories.dart';
import '../models/identified.dart';
import 'async_view.dart';

/// Searchable picker over [NamedEntity] records (performers or venues).
///
/// Owns its own search text, so typing only rebuilds the picker instead of the
/// whole form. The selection itself stays with the caller: it receives
/// [selectedIds] and reports taps through [onToggle].
///
/// Matching for a non-empty query is delegated through [search] / [repository]
/// instead of being filtered out of one loaded list in Dart: the earlier
/// version only ever saw a single page of the collection, so any record outside
/// that page was unreachable no matter what the user typed. The query is
/// debounced so typing does not fan out one request per keystroke.
///
/// A failed load or failed search renders the standard [AsyncView] error with a
/// retry action.
class EntitySearchPicker<T extends NamedEntity> extends StatefulWidget {
  const EntitySearchPicker({
    super.key,
    required this.title,
    required this.searchLabel,
    required this.emptyMessage,
    required this.errorMessage,
    required this.noneSelected,
    required this.load,
    required this.labelFor,
    required this.selectedIds,
    required this.onToggle,
    required this.listHeight,
    this.search,
    this.repository,
    this.clearSearchOnSelect = false,
  }) : assert(
         search != null || repository != null,
         'EntitySearchPicker needs search or repository',
       );

  /// Section heading, e.g. `Performers`.
  final String title;

  /// Label of the search field, e.g. `Search performers`.
  final String searchLabel;

  /// Shown in the list area when the server returns nothing for the query.
  final String emptyMessage;

  /// Shown by [AsyncView] when [load] or the search fails.
  final String errorMessage;

  /// Shown in place of the selected chips when [selectedIds] is empty.
  final Widget noneSelected;

  /// Fetches the selectable records for the empty query; invoked once per
  /// picker and again on retry.
  final Future<List<T>> Function() load;

  /// Search for a non-empty query. Exactly one of [search] and [repository] is
  /// needed; the callback wins when both are given because it lets the caller
  /// narrow the results further (see the venue picker).
  final Future<List<T>> Function(String query)? search;

  /// Repository whose `search(query)` answers a non-empty query.
  final EntityRepository<T>? repository;

  /// Label of the chip for [id]; [records] holds whatever the current list is
  /// (the loaded page or the search hits) so a pre-selected id can still be
  /// labelled before its record arrives.
  final String Function(String id, List<T> records) labelFor;

  final Set<String> selectedIds;

  /// Called with the tapped record's id and name, and with the chip's label
  /// when a chip is deleted.
  final void Function(String id, String name) onToggle;

  final double listHeight;

  /// Clears the query after a selection (single-select behaviour).
  final bool clearSearchOnSelect;

  @override
  State<EntitySearchPicker<T>> createState() => _EntitySearchPickerState<T>();
}

class _EntitySearchPickerState<T extends NamedEntity>
    extends State<EntitySearchPicker<T>> {
  /// Fast enough that typing does not fire a request per keystroke, slow enough
  /// that the list settles before the user reads it.
  static const _debounceDelay = Duration(milliseconds: 300);

  final _searchController = TextEditingController();

  /// The empty-query list. Kept across queries so clearing the field restores
  /// the loaded page without another round trip.
  late Future<List<T>> _initialFuture;

  /// Latest search request, or null while the query is empty. During the
  /// debounce window this still holds the previous query's request, which is
  /// what stays on screen until the new results arrive.
  Future<List<T>>? _searchFuture;

  Timer? _debounce;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _initialFuture = _observed(widget.load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _retry() {
    _debounce?.cancel();
    setState(() {
      if (_query.isEmpty) {
        _searchFuture = null;
        _initialFuture = _observed(widget.load());
      } else {
        _searchFuture = _request(_query);
      }
    });
  }

  /// Marks [future]'s outcome as observed and returns it unchanged.
  ///
  /// The rebuild that hands a request to [AsyncView] arrives on the next
  /// frame, so a request that fails before that frame (a dead connection
  /// rejects immediately) would otherwise be reported as an unhandled async
  /// error even though the widget is showing it. `ignore()` registers that
  /// listener without consuming the result.
  Future<List<T>> _observed(Future<List<T>> future) {
    future.ignore();
    return future;
  }

  Future<List<T>> _request(String query) {
    final search = widget.search;
    if (search != null) return _observed(search(query));
    return _observed(widget.repository!.search(query));
  }

  void _onQueryChanged(String value) {
    final query = value.trim();
    if (query.isEmpty) {
      // Back to the loaded page; no request, the future is already resolved.
      _debounce?.cancel();
      setState(() {
        _query = '';
        _searchFuture = null;
      });
      return;
    }
    if (query == _query) {
      // Same trimmed query (a trailing space, say): leave the pending debounce
      // alone — cancelling here would drop the only request for this query and
      // leave the unfiltered list under a non-empty search field.
      return;
    }
    _debounce?.cancel();
    setState(() {
      _query = query;
    });
    _debounce = Timer(_debounceDelay, () {
      if (!mounted) return;
      setState(() {
        // Block body on purpose: `=> _searchFuture = …` would hand a Future
        // back to setState, which asserts against async callbacks.
        _searchFuture = _request(query);
      });
    });
  }

  void _select(T record) {
    final id = record.id;
    if (id == null) return;
    if (widget.clearSearchOnSelect) {
      _debounce?.cancel();
      _searchController.clear();
      setState(() {
        _query = '';
        _searchFuture = null;
      });
    }
    widget.onToggle(id, record.displayName);
  }

  @override
  Widget build(BuildContext context) {
    final future = _query.isEmpty
        ? _initialFuture
        : (_searchFuture ?? _initialFuture);
    return FutureBuilder<List<T>>(
      future: future,
      builder: (context, snapshot) {
        final loaded = snapshot.data ?? const [];
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
                      onDeleted: () =>
                          widget.onToggle(id, widget.labelFor(id, loaded)),
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
              onChanged: _onQueryChanged,
            ),
            const SizedBox(height: 8),
            AsyncView<List<T>>(
              snapshot: snapshot,
              errorMessage: widget.errorMessage,
              onRetry: _retry,
              loading: const SizedBox(
                height: 24,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              builder: (context, records) {
                return SizedBox(
                  height: widget.listHeight,
                  child: records.isEmpty
                      ? Center(child: Text(widget.emptyMessage))
                      : ListView.separated(
                          itemCount: records.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (ctx, i) {
                            final record = records[i];
                            final id = record.id;
                            final selected =
                                id != null && widget.selectedIds.contains(id);
                            return ListTile(
                              dense: true,
                              title: Text(record.displayName),
                              trailing: Icon(
                                selected
                                    ? Icons.check_circle
                                    : Icons.add_circle_outline,
                              ),
                              onTap: id == null ? null : () => _select(record),
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
