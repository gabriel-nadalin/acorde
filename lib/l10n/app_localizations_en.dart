// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Event Calendar';

  @override
  String get signIn => 'Sign In';

  @override
  String get email => 'Email';

  @override
  String get password => 'Password';

  @override
  String get enterEmailAndPassword => 'Enter your email and password.';

  @override
  String get loginFailed => 'Login failed — check your email and password.';

  @override
  String get signUpTitle => 'Create account';

  @override
  String get signUpAction => 'Create account';

  @override
  String get haveAccountSignIn => 'Already have an account? Sign in';

  @override
  String get nameLabel => 'Name (optional)';

  @override
  String get confirmPassword => 'Confirm password';

  @override
  String get emailRequired => 'Enter your email';

  @override
  String get passwordMinLength => 'Use at least 8 characters';

  @override
  String get passwordsDoNotMatch => 'Passwords do not match';

  @override
  String get signUpFailed => 'Could not create the account.';

  @override
  String get browseVenues => 'Browse venues';

  @override
  String get venuesTitle => 'Venues';

  @override
  String get signOut => 'Sign out';

  @override
  String get retry => 'Retry';

  @override
  String get couldNotLoadData => 'Could not load data';

  @override
  String dashboardTitle(String name) {
    return 'Dashboard — $name';
  }

  @override
  String get userFallback => 'User';

  @override
  String get untitled => 'Untitled';

  @override
  String get myPerformers => 'My Performers';

  @override
  String get performers => 'Performers';

  @override
  String get myVenues => 'My Venues';

  @override
  String get noPerformerProfiles => 'No performer profiles assigned';

  @override
  String get noVenueProfiles => 'No venue profiles assigned';

  @override
  String get calendar => 'Calendar';

  @override
  String get combined => 'Combined';

  @override
  String get performer => 'Performer';

  @override
  String get venue => 'Venue';

  @override
  String get both => 'Both';

  @override
  String get newEvent => 'New event';

  @override
  String get newEventForPerformer => 'New event (performer)';

  @override
  String get newEventForVenue => 'New event (venue)';

  @override
  String get createForPerformer => 'Create for performer';

  @override
  String get createForVenue => 'Create for venue';

  @override
  String get calendarPrevMonth => 'Previous month';

  @override
  String get calendarNextMonth => 'Next month';

  @override
  String calendarDayFree(String date) {
    return '$date, no bookings';
  }

  @override
  String calendarDayPerformer(String date) {
    return '$date, performer booking';
  }

  @override
  String calendarDayVenue(String date) {
    return '$date, venue booking';
  }

  @override
  String calendarDayBoth(String date) {
    return '$date, performer and venue bookings';
  }

  @override
  String calendarDayOther(String date) {
    return '$date, event';
  }

  @override
  String get createEvent => 'Create Event';

  @override
  String get editEvent => 'Edit Event';

  @override
  String get titleLabel => 'Title';

  @override
  String get descriptionLabel => 'Description';

  @override
  String get startLabel => 'Start';

  @override
  String get endLabel => 'End';

  @override
  String get save => 'Save';

  @override
  String get titleRequired => 'Enter a title';

  @override
  String get endMustBeAfterStart => 'End must be after start';

  @override
  String get eventCreated => 'Event created';

  @override
  String get eventUpdated => 'Event updated';

  @override
  String errorWithMessage(String message) {
    return 'Error: $message';
  }

  @override
  String get searchVenues => 'Search venues';

  @override
  String get searchPerformers => 'Search performers';

  @override
  String get noVenuesFound => 'No venues found';

  @override
  String get noPerformersFound => 'No performers found';

  @override
  String get couldNotLoadVenues => 'Could not load venues';

  @override
  String get couldNotLoadPerformers => 'Could not load performers';

  @override
  String get noVenueSelected => 'No venue selected';

  @override
  String get noneSelected => 'None selected';

  @override
  String venueWithName(String name) {
    return 'Venue: $name';
  }

  @override
  String get venueCalendar => 'Venue Calendar';

  @override
  String get myCalendar => 'My Calendar';

  @override
  String get performerCalendar => 'Performer Calendar';

  @override
  String get couldNotLoadEvents => 'Could not load events';

  @override
  String get offlineShowingCached => 'Offline — showing cached events';

  @override
  String get noEvents => 'No events';

  @override
  String get addEvent => 'Add Event';
}
