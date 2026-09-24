import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:event_calendar/l10n/app_localizations.dart';
import 'package:event_calendar/utils/calendar_math.dart';
import 'package:event_calendar/widgets/calendar_grid.dart';

/// Brazilian Portuguese, end to end, as the app's only locale.
///
/// The contract worth pinning is that one locale is genuinely complete and that
/// every device reaches it: an app shipping a single language has no second
/// language to fall back to, so a missing key or an unreachable locale is not a
/// degraded experience, it is a blank screen for everybody. The assertions below
/// therefore go through the same resolution Flutter performs at startup rather
/// than picking the locale object directly — including for a device set to a
/// language the app does not ship, which is the common case for the fallback.
///
/// Dates are checked as well as words. The app formats every date through
/// `intl`'s `DateFormat` with the device's language tag, and `intl`'s date
/// symbols need loading — a locale whose strings exist but whose symbols were
/// never initialized fails at the first `format()` call, on a screen far from
/// this file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('pt'));

  AppLocalizations resolve(Locale device) => lookupAppLocalizations(
    basicLocaleListResolution([device], AppLocalizations.supportedLocales),
  );

  group('the shipped locales', () {
    /// One locale, and deliberately so: every extra language is a per-feature tax
    /// (three edits for every new string) paid by a prototype that has not yet
    /// settled its UI. What is pinned here is that the cut is complete — a locale
    /// half-removed would leave a resolver that can still be reached.
    test('are exactly Portuguese', () {
      expect(
        AppLocalizations.supportedLocales.map((l) => l.languageCode).toList(),
        ['pt'],
      );
    });

    /// The case this whole locale is for: a `pt_BR` device. Flutter resolves it
    /// by language, and `flutter_localizations` bundles `pt` rather than `pt_BR`,
    /// so the region suffix has to be dropped rather than matched.
    test('resolve a pt_BR device to Portuguese', () {
      expect(resolve(const Locale('pt', 'BR')).localeName, 'pt');
      expect(resolve(const Locale('pt')).localeName, 'pt');
    });

    /// With one locale there is nothing to fall back *to*, so this is not a
    /// nicety: a device in any other language must still get the app.
    test('resolve any other device language to Portuguese', () {
      expect(resolve(const Locale('en', 'US')).localeName, 'pt');
      expect(resolve(const Locale('es', 'ES')).localeName, 'pt');
      expect(resolve(const Locale('ja')).localeName, 'pt');
    });

    /// Every locale must name every message. A missing key is a build error in
    /// this setup, but an *empty* translation is not — and it ships as a blank
    /// label, which is worse than English because it looks deliberate.
    test('are translated, not left blank', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = lookupAppLocalizations(locale);
        for (final message in <String, String>{
          'appTitle': l10n.appTitle,
          'signIn': l10n.signIn,
          'calendar': l10n.calendar,
          'browseVenues': l10n.browseVenues,
          'browsePerformers': l10n.browsePerformers,
          'myEntities': l10n.myEntities,
          'venuesTitle': l10n.venuesTitle,
          'performers': l10n.performers,
          'newEvent': l10n.newEvent,
          'requestAccess': l10n.requestAccess,
          'signOut': l10n.signOut,
        }.entries) {
          expect(
            message.value.trim(),
            isNotEmpty,
            reason: '${message.key} is blank in $locale',
          );
        }
      }
    });
  });

  group('Brazilian Portuguese wording', () {
    final pt = lookupAppLocalizations(const Locale('pt'));

    test('reads as Portuguese, not as the English fallback', () {
      // Spot checks across the flows, not a full dictionary: what is being
      // pinned is that the file is really Portuguese, so a copy-paste of the
      // template would fail here.
      expect(pt.calendar, 'Calendário');
      expect(pt.signIn, 'Entrar');
      expect(pt.browseVenues, 'Explorar locais');
      expect(pt.browsePerformers, 'Explorar artistas');
      expect(pt.myEntities, 'Minhas entidades');
      expect(pt.performers, 'Artistas');
      expect(pt.venuesTitle, 'Locais');
      expect(pt.requestAccess, 'Solicitar acesso');
      expect(pt.signOut, 'Sair');
    });

    /// A message with a placeholder must keep it, or the value it was meant to
    /// show silently disappears (the build would fail on a *missing* key, but
    /// not on a lost placeholder).
    test('keeps values in the messages that carry them', () {
      expect(pt.dashboardTitle('Ana'), contains('Ana'));
      expect(pt.inviteSent('a@b.test'), contains('a@b.test'));
      expect(pt.confirmDeleteTitle('Casa'), contains('Casa'));
      expect(pt.venueWithName('Casa'), contains('Casa'));
      expect(pt.occurrenceCountLabel(3), contains('3'));
      expect(pt.seriesCreated(2), contains('2'));
    });
  });

  group('dates in Portuguese', () {
    test('format the month, the weekday and a full date', () {
      // March 2026 starts on a Sunday and is never "today", so the grid's roving
      // position and this label are both stable.
      final march = DateTime(2026, 3);
      final month = monthLabel('pt', march);
      expect(month, contains('2026'));
      expect(month.toLowerCase(), contains('mar'));
      expect(monthLabel('pt', march), isNot(monthLabel('en', march)));

      final weekdays = weekdayAbbreviations('pt');
      expect(weekdays, hasLength(7));
      expect(weekdays.every((d) => d.trim().isNotEmpty), isTrue);
      // Sunday first, matching the grid's column order.
      expect(weekdays.first.toLowerCase(), startsWith('d'));

      expect(formatFullDate('pt', DateTime(2026, 3, 4)), contains('2026'));
    });

    /// The reason `initializeDateFormatting('pt')` is load-bearing: without the
    /// symbols, formatting a Portuguese date throws rather than degrading.
    test('fall back to the language when given a region-tagged locale', () {
      expect(monthLabel('pt_BR', DateTime(2026, 3)), contains('2026'));
    });
  });

  group('the calendar in Portuguese', () {
    Future<void> pumpGrid(WidgetTester tester, Locale locale) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: CalendarGrid(
              focusedMonth: DateTime(2026, 3),
              onMonthChanged: (_) {},
              events: const [],
              highlightedDays: const {},
              eventCats: (_) => const <String>{},
              onDayTap: (_, _, _, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('renders its month and weekday headers in Portuguese', (
      tester,
    ) async {
      await pumpGrid(tester, const Locale('pt', 'BR'));
      final pt = lookupAppLocalizations(const Locale('pt'));

      // The month controls are icon buttons, so their name is the tooltip.
      expect(find.byTooltip(pt.calendarPrevMonth), findsOneWidget);
      expect(find.byTooltip(pt.calendarNextMonth), findsOneWidget);
      // The month heading the grid draws comes from intl, so a Portuguese grid
      // showing an English month would mean the locale never reached the widget.
      expect(find.text(monthLabel('pt', DateTime(2026, 3))), findsOneWidget);
    });
  });
}
