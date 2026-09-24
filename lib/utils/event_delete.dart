import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../l10n/app_localizations.dart';
import '../models/event.dart';
import 'error_text.dart';

/// Confirms and deletes an event, returning true when something was deleted.
///
/// One implementation for every place an event can be removed — the upcoming
/// list, the calendar's day sheet, the edit form — because the interesting part
/// is not the request but the question asked first.
///
/// A recurring instance is the case that matters. Deleting "the event" on one
/// Wednesday of a weekly booking is almost never what somebody means, and the
/// reverse mistake — deleting the whole series when they meant one night —
/// cannot be undone. So a repeating instance is asked about explicitly, with the
/// number of occurrences on the button so the choice is made on a fact.
///
/// Nothing here decides *whether* the user may delete: that is the caller's job
/// (see the per-event check in `upcoming.dart`), because a screen that cannot
/// write must not offer the button at all rather than fail when pressed.
Future<bool> confirmDeleteEvent(BuildContext context, Event event) async {
  final l10n = AppLocalizations.of(context);
  final repo = context.read<EventRepository>();
  final id = event.id;
  if (id == null || id.isEmpty) return false;

  final seriesId = event.seriesId;
  final isSeries =
      event.isSeriesInstance && seriesId != null && seriesId.isNotEmpty;

  var wholeSeries = false;
  if (isSeries) {
    // Best effort: a failed count still leaves the choice, just without the
    // number. Asking the server first beats recomputing the recurrence locally,
    // which would not know about occurrences the server refused at the time.
    var count = 0;
    try {
      count = await repo.seriesInstanceCount(seriesId);
    } catch (_) {
      // Reported by the dialog wording below, which drops the count.
    }
    if (!context.mounted) return false;

    final choice = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.deleteSeriesTitle),
        content: Text(l10n.deleteSeriesWhat),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.deleteSeriesOne),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(count > 0 ? l10n.deleteSeriesAll(count) : l10n.delete),
          ),
        ],
      ),
    );
    // Dismissing the dialog (barrier tap, back gesture) cancels, which is what
    // null means here — distinct from `false`, which is "only this one".
    if (choice == null || !context.mounted) return false;
    wholeSeries = choice;
  } else {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.confirmDeleteTitle(event.title)),
        content: Text(l10n.confirmDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return false;
  }

  try {
    if (wholeSeries && seriesId != null) {
      await repo.deleteSeries(seriesId);
    } else {
      await repo.delete(id);
    }
  } catch (e) {
    if (context.mounted) {
      // The server's own wording: it may refuse for a reason this screen cannot
      // know (a permission that changed, a record already gone).
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(errorText(l10n, e))));
    }
    return false;
  }

  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.eventDeleted)));
  }
  return true;
}
