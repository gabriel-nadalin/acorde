import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Event Calendar'**
  String get appTitle;

  /// No description provided for @signIn.
  ///
  /// In en, this message translates to:
  /// **'Sign In'**
  String get signIn;

  /// No description provided for @email.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get email;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @enterEmailAndPassword.
  ///
  /// In en, this message translates to:
  /// **'Enter your email and password.'**
  String get enterEmailAndPassword;

  /// No description provided for @loginFailed.
  ///
  /// In en, this message translates to:
  /// **'Login failed — check your email and password.'**
  String get loginFailed;

  /// No description provided for @signUpTitle.
  ///
  /// In en, this message translates to:
  /// **'Create account'**
  String get signUpTitle;

  /// No description provided for @signUpAction.
  ///
  /// In en, this message translates to:
  /// **'Create account'**
  String get signUpAction;

  /// No description provided for @haveAccountSignIn.
  ///
  /// In en, this message translates to:
  /// **'Already have an account? Sign in'**
  String get haveAccountSignIn;

  /// No description provided for @nameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name (optional)'**
  String get nameLabel;

  /// No description provided for @confirmPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm password'**
  String get confirmPassword;

  /// No description provided for @emailRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter your email'**
  String get emailRequired;

  /// No description provided for @passwordMinLength.
  ///
  /// In en, this message translates to:
  /// **'Use at least 8 characters'**
  String get passwordMinLength;

  /// No description provided for @passwordsDoNotMatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match'**
  String get passwordsDoNotMatch;

  /// No description provided for @signUpFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not create the account.'**
  String get signUpFailed;

  /// No description provided for @browseVenues.
  ///
  /// In en, this message translates to:
  /// **'Browse venues'**
  String get browseVenues;

  /// No description provided for @venuesTitle.
  ///
  /// In en, this message translates to:
  /// **'Venues'**
  String get venuesTitle;

  /// No description provided for @signOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get signOut;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @couldNotLoadData.
  ///
  /// In en, this message translates to:
  /// **'Could not load data'**
  String get couldNotLoadData;

  /// No description provided for @dashboardTitle.
  ///
  /// In en, this message translates to:
  /// **'Dashboard — {name}'**
  String dashboardTitle(String name);

  /// No description provided for @userFallback.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get userFallback;

  /// No description provided for @untitled.
  ///
  /// In en, this message translates to:
  /// **'Untitled'**
  String get untitled;

  /// No description provided for @myPerformers.
  ///
  /// In en, this message translates to:
  /// **'My Performers'**
  String get myPerformers;

  /// No description provided for @performers.
  ///
  /// In en, this message translates to:
  /// **'Performers'**
  String get performers;

  /// No description provided for @myVenues.
  ///
  /// In en, this message translates to:
  /// **'My Venues'**
  String get myVenues;

  /// No description provided for @noPerformerProfiles.
  ///
  /// In en, this message translates to:
  /// **'No performer profiles assigned'**
  String get noPerformerProfiles;

  /// No description provided for @noVenueProfiles.
  ///
  /// In en, this message translates to:
  /// **'No venue profiles assigned'**
  String get noVenueProfiles;

  /// No description provided for @calendar.
  ///
  /// In en, this message translates to:
  /// **'Calendar'**
  String get calendar;

  /// No description provided for @combined.
  ///
  /// In en, this message translates to:
  /// **'Combined'**
  String get combined;

  /// No description provided for @performer.
  ///
  /// In en, this message translates to:
  /// **'Performer'**
  String get performer;

  /// No description provided for @venue.
  ///
  /// In en, this message translates to:
  /// **'Venue'**
  String get venue;

  /// No description provided for @both.
  ///
  /// In en, this message translates to:
  /// **'Both'**
  String get both;

  /// No description provided for @newEvent.
  ///
  /// In en, this message translates to:
  /// **'New event'**
  String get newEvent;

  /// No description provided for @newEventForPerformer.
  ///
  /// In en, this message translates to:
  /// **'New event (performer)'**
  String get newEventForPerformer;

  /// No description provided for @newEventForVenue.
  ///
  /// In en, this message translates to:
  /// **'New event (venue)'**
  String get newEventForVenue;

  /// No description provided for @createForPerformer.
  ///
  /// In en, this message translates to:
  /// **'Create for performer'**
  String get createForPerformer;

  /// No description provided for @createForVenue.
  ///
  /// In en, this message translates to:
  /// **'Create for venue'**
  String get createForVenue;

  /// No description provided for @calendarPrevMonth.
  ///
  /// In en, this message translates to:
  /// **'Previous month'**
  String get calendarPrevMonth;

  /// No description provided for @calendarNextMonth.
  ///
  /// In en, this message translates to:
  /// **'Next month'**
  String get calendarNextMonth;

  /// No description provided for @calendarDayFree.
  ///
  /// In en, this message translates to:
  /// **'{date}, no bookings'**
  String calendarDayFree(String date);

  /// No description provided for @calendarDayPerformer.
  ///
  /// In en, this message translates to:
  /// **'{date}, performer booking'**
  String calendarDayPerformer(String date);

  /// No description provided for @calendarDayVenue.
  ///
  /// In en, this message translates to:
  /// **'{date}, venue booking'**
  String calendarDayVenue(String date);

  /// No description provided for @calendarDayBoth.
  ///
  /// In en, this message translates to:
  /// **'{date}, performer and venue bookings'**
  String calendarDayBoth(String date);

  /// No description provided for @calendarDayOther.
  ///
  /// In en, this message translates to:
  /// **'{date}, event'**
  String calendarDayOther(String date);

  /// No description provided for @createEvent.
  ///
  /// In en, this message translates to:
  /// **'Create Event'**
  String get createEvent;

  /// No description provided for @editEvent.
  ///
  /// In en, this message translates to:
  /// **'Edit Event'**
  String get editEvent;

  /// No description provided for @titleLabel.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get titleLabel;

  /// No description provided for @descriptionLabel.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get descriptionLabel;

  /// No description provided for @startLabel.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get startLabel;

  /// No description provided for @endLabel.
  ///
  /// In en, this message translates to:
  /// **'End'**
  String get endLabel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @titleRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a title'**
  String get titleRequired;

  /// No description provided for @endMustBeAfterStart.
  ///
  /// In en, this message translates to:
  /// **'End must be after start'**
  String get endMustBeAfterStart;

  /// No description provided for @eventCreated.
  ///
  /// In en, this message translates to:
  /// **'Event created'**
  String get eventCreated;

  /// No description provided for @eventUpdated.
  ///
  /// In en, this message translates to:
  /// **'Event updated'**
  String get eventUpdated;

  /// No description provided for @errorWithMessage.
  ///
  /// In en, this message translates to:
  /// **'Error: {message}'**
  String errorWithMessage(String message);

  /// No description provided for @searchVenues.
  ///
  /// In en, this message translates to:
  /// **'Search venues'**
  String get searchVenues;

  /// No description provided for @searchPerformers.
  ///
  /// In en, this message translates to:
  /// **'Search performers'**
  String get searchPerformers;

  /// No description provided for @noVenuesFound.
  ///
  /// In en, this message translates to:
  /// **'No venues found'**
  String get noVenuesFound;

  /// No description provided for @noPerformersFound.
  ///
  /// In en, this message translates to:
  /// **'No performers found'**
  String get noPerformersFound;

  /// No description provided for @couldNotLoadVenues.
  ///
  /// In en, this message translates to:
  /// **'Could not load venues'**
  String get couldNotLoadVenues;

  /// No description provided for @couldNotLoadPerformers.
  ///
  /// In en, this message translates to:
  /// **'Could not load performers'**
  String get couldNotLoadPerformers;

  /// No description provided for @noVenueSelected.
  ///
  /// In en, this message translates to:
  /// **'No venue selected'**
  String get noVenueSelected;

  /// No description provided for @noneSelected.
  ///
  /// In en, this message translates to:
  /// **'None selected'**
  String get noneSelected;

  /// No description provided for @venueWithName.
  ///
  /// In en, this message translates to:
  /// **'Venue: {name}'**
  String venueWithName(String name);

  /// No description provided for @venueCalendar.
  ///
  /// In en, this message translates to:
  /// **'Venue Calendar'**
  String get venueCalendar;

  /// No description provided for @myCalendar.
  ///
  /// In en, this message translates to:
  /// **'My Calendar'**
  String get myCalendar;

  /// No description provided for @performerCalendar.
  ///
  /// In en, this message translates to:
  /// **'Performer Calendar'**
  String get performerCalendar;

  /// No description provided for @couldNotLoadEvents.
  ///
  /// In en, this message translates to:
  /// **'Could not load events'**
  String get couldNotLoadEvents;

  /// No description provided for @offlineShowingCached.
  ///
  /// In en, this message translates to:
  /// **'Offline — showing cached events'**
  String get offlineShowingCached;

  /// No description provided for @noEvents.
  ///
  /// In en, this message translates to:
  /// **'No events'**
  String get noEvents;

  /// No description provided for @addEvent.
  ///
  /// In en, this message translates to:
  /// **'Add Event'**
  String get addEvent;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
