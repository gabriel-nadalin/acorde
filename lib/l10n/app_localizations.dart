import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_pt.dart';

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
  static const List<Locale> supportedLocales = <Locale>[Locale('pt')];

  /// No description provided for @appTitle.
  ///
  /// In pt, this message translates to:
  /// **'Acorde'**
  String get appTitle;

  /// No description provided for @signIn.
  ///
  /// In pt, this message translates to:
  /// **'Entrar'**
  String get signIn;

  /// No description provided for @email.
  ///
  /// In pt, this message translates to:
  /// **'E-mail'**
  String get email;

  /// No description provided for @password.
  ///
  /// In pt, this message translates to:
  /// **'Senha'**
  String get password;

  /// No description provided for @enterEmailAndPassword.
  ///
  /// In pt, this message translates to:
  /// **'Informe seu e-mail e sua senha.'**
  String get enterEmailAndPassword;

  /// No description provided for @invalidCredentials.
  ///
  /// In pt, this message translates to:
  /// **'E-mail ou senha incorretos.'**
  String get invalidCredentials;

  /// No description provided for @backendUnreachable.
  ///
  /// In pt, this message translates to:
  /// **'Não foi possível acessar o servidor. Verifique sua conexão e tente de novo.'**
  String get backendUnreachable;

  /// No description provided for @sessionExpired.
  ///
  /// In pt, this message translates to:
  /// **'Sua sessão expirou. Entre novamente.'**
  String get sessionExpired;

  /// No description provided for @requestTimedOut.
  ///
  /// In pt, this message translates to:
  /// **'O servidor demorou demais para responder.'**
  String get requestTimedOut;

  /// No description provided for @serverError.
  ///
  /// In pt, this message translates to:
  /// **'O servidor retornou um erro.'**
  String get serverError;

  /// No description provided for @forbidden.
  ///
  /// In pt, this message translates to:
  /// **'Você não tem permissão para fazer isso.'**
  String get forbidden;

  /// No description provided for @notFound.
  ///
  /// In pt, this message translates to:
  /// **'Esse item não existe mais.'**
  String get notFound;

  /// No description provided for @signUpTitle.
  ///
  /// In pt, this message translates to:
  /// **'Criar conta'**
  String get signUpTitle;

  /// No description provided for @signUpAction.
  ///
  /// In pt, this message translates to:
  /// **'Criar conta'**
  String get signUpAction;

  /// No description provided for @haveAccountSignIn.
  ///
  /// In pt, this message translates to:
  /// **'Já tem uma conta? Entrar'**
  String get haveAccountSignIn;

  /// No description provided for @nameLabel.
  ///
  /// In pt, this message translates to:
  /// **'Nome (opcional)'**
  String get nameLabel;

  /// No description provided for @confirmPassword.
  ///
  /// In pt, this message translates to:
  /// **'Confirmar senha'**
  String get confirmPassword;

  /// No description provided for @emailRequired.
  ///
  /// In pt, this message translates to:
  /// **'Informe seu e-mail'**
  String get emailRequired;

  /// No description provided for @passwordMinLength.
  ///
  /// In pt, this message translates to:
  /// **'Use pelo menos 8 caracteres'**
  String get passwordMinLength;

  /// No description provided for @passwordsDoNotMatch.
  ///
  /// In pt, this message translates to:
  /// **'As senhas não coincidem'**
  String get passwordsDoNotMatch;

  /// No description provided for @signUpFailed.
  ///
  /// In pt, this message translates to:
  /// **'Não foi possível criar a conta.'**
  String get signUpFailed;

  /// No description provided for @forgotPassword.
  ///
  /// In pt, this message translates to:
  /// **'Esqueceu a senha?'**
  String get forgotPassword;

  /// No description provided for @guestSignIn.
  ///
  /// In pt, this message translates to:
  /// **'Entrar como visitante'**
  String get guestSignIn;

  /// No description provided for @guestSignInHint.
  ///
  /// In pt, this message translates to:
  /// **'Cria uma conta temporária, sem e-mail nem senha.'**
  String get guestSignInHint;

  /// No description provided for @guestAccountName.
  ///
  /// In pt, this message translates to:
  /// **'Visitante'**
  String get guestAccountName;

  /// No description provided for @resetPasswordTitle.
  ///
  /// In pt, this message translates to:
  /// **'Redefinir senha'**
  String get resetPasswordTitle;

  /// No description provided for @resetPasswordIntro.
  ///
  /// In pt, this message translates to:
  /// **'Informe seu e-mail e enviaremos um link para você escolher uma nova senha.'**
  String get resetPasswordIntro;

  /// No description provided for @sendResetLink.
  ///
  /// In pt, this message translates to:
  /// **'Enviar link'**
  String get sendResetLink;

  /// No description provided for @resetLinkSent.
  ///
  /// In pt, this message translates to:
  /// **'Se esse endereço tiver uma conta, o link de redefinição está a caminho.'**
  String get resetLinkSent;

  /// No description provided for @resetMailUnavailable.
  ///
  /// In pt, this message translates to:
  /// **'Este servidor não tem e-mail configurado, então o link não pode ser enviado. Peça a um administrador para redefinir sua senha.'**
  String get resetMailUnavailable;

  /// No description provided for @newPasswordTitle.
  ///
  /// In pt, this message translates to:
  /// **'Escolha uma nova senha'**
  String get newPasswordTitle;

  /// No description provided for @setNewPassword.
  ///
  /// In pt, this message translates to:
  /// **'Definir nova senha'**
  String get setNewPassword;

  /// No description provided for @passwordChanged.
  ///
  /// In pt, this message translates to:
  /// **'Senha alterada. Entre com a nova senha.'**
  String get passwordChanged;

  /// No description provided for @resetLinkIncomplete.
  ///
  /// In pt, this message translates to:
  /// **'Este link de redefinição está incompleto. Abra novamente o link do seu e-mail.'**
  String get resetLinkIncomplete;

  /// No description provided for @browseVenues.
  ///
  /// In pt, this message translates to:
  /// **'Explorar locais'**
  String get browseVenues;

  /// No description provided for @venuesTitle.
  ///
  /// In pt, this message translates to:
  /// **'Locais'**
  String get venuesTitle;

  /// No description provided for @signOut.
  ///
  /// In pt, this message translates to:
  /// **'Sair'**
  String get signOut;

  /// No description provided for @retry.
  ///
  /// In pt, this message translates to:
  /// **'Tentar de novo'**
  String get retry;

  /// No description provided for @couldNotLoadData.
  ///
  /// In pt, this message translates to:
  /// **'Não foi possível carregar os dados'**
  String get couldNotLoadData;

  /// No description provided for @cancel.
  ///
  /// In pt, this message translates to:
  /// **'Cancelar'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In pt, this message translates to:
  /// **'Excluir'**
  String get delete;

  /// No description provided for @save.
  ///
  /// In pt, this message translates to:
  /// **'Salvar'**
  String get save;

  /// No description provided for @titleRequired.
  ///
  /// In pt, this message translates to:
  /// **'Informe um título'**
  String get titleRequired;

  /// No description provided for @dashboardTitle.
  ///
  /// In pt, this message translates to:
  /// **'Painel — {name}'**
  String dashboardTitle(Object name);

  /// No description provided for @userFallback.
  ///
  /// In pt, this message translates to:
  /// **'Usuário'**
  String get userFallback;

  /// No description provided for @untitled.
  ///
  /// In pt, this message translates to:
  /// **'Sem título'**
  String get untitled;

  /// No description provided for @myPerformers.
  ///
  /// In pt, this message translates to:
  /// **'Meus artistas'**
  String get myPerformers;

  /// No description provided for @performers.
  ///
  /// In pt, this message translates to:
  /// **'Artistas'**
  String get performers;

  /// No description provided for @myVenues.
  ///
  /// In pt, this message translates to:
  /// **'Meus locais'**
  String get myVenues;

  /// No description provided for @noPerformerProfiles.
  ///
  /// In pt, this message translates to:
  /// **'Nenhum perfil de artista atribuído'**
  String get noPerformerProfiles;

  /// No description provided for @noVenueProfiles.
  ///
  /// In pt, this message translates to:
  /// **'Nenhum perfil de local atribuído'**
  String get noVenueProfiles;

  /// No description provided for @myEntities.
  ///
  /// In pt, this message translates to:
  /// **'Minhas entidades'**
  String get myEntities;

  /// No description provided for @addVenue.
  ///
  /// In pt, this message translates to:
  /// **'Adicionar local'**
  String get addVenue;

  /// No description provided for @addPerformer.
  ///
  /// In pt, this message translates to:
  /// **'Adicionar artista'**
  String get addPerformer;

  /// No description provided for @manageVenue.
  ///
  /// In pt, this message translates to:
  /// **'Gerenciar local'**
  String get manageVenue;

  /// No description provided for @managePerformer.
  ///
  /// In pt, this message translates to:
  /// **'Gerenciar artista'**
  String get managePerformer;

  /// No description provided for @pendingInvites.
  ///
  /// In pt, this message translates to:
  /// **'Convites pendentes'**
  String get pendingInvites;

  /// No description provided for @calendar.
  ///
  /// In pt, this message translates to:
  /// **'Calendário'**
  String get calendar;

  /// No description provided for @combined.
  ///
  /// In pt, this message translates to:
  /// **'Combinado'**
  String get combined;

  /// No description provided for @performer.
  ///
  /// In pt, this message translates to:
  /// **'Artista'**
  String get performer;

  /// No description provided for @venue.
  ///
  /// In pt, this message translates to:
  /// **'Local'**
  String get venue;

  /// No description provided for @both.
  ///
  /// In pt, this message translates to:
  /// **'Ambos'**
  String get both;

  /// No description provided for @newEvent.
  ///
  /// In pt, this message translates to:
  /// **'Novo evento'**
  String get newEvent;

  /// No description provided for @newEventForPerformer.
  ///
  /// In pt, this message translates to:
  /// **'Novo evento (artista)'**
  String get newEventForPerformer;

  /// No description provided for @newEventForVenue.
  ///
  /// In pt, this message translates to:
  /// **'Novo evento (local)'**
  String get newEventForVenue;

  /// No description provided for @createForPerformer.
  ///
  /// In pt, this message translates to:
  /// **'Criar para artista'**
  String get createForPerformer;

  /// No description provided for @createForVenue.
  ///
  /// In pt, this message translates to:
  /// **'Criar para local'**
  String get createForVenue;

  /// No description provided for @calendarPrevMonth.
  ///
  /// In pt, this message translates to:
  /// **'Mês anterior'**
  String get calendarPrevMonth;

  /// No description provided for @calendarNextMonth.
  ///
  /// In pt, this message translates to:
  /// **'Próximo mês'**
  String get calendarNextMonth;

  /// No description provided for @calendarDayFree.
  ///
  /// In pt, this message translates to:
  /// **'{date}, sem eventos'**
  String calendarDayFree(Object date);

  /// No description provided for @calendarDayPerformer.
  ///
  /// In pt, this message translates to:
  /// **'{date}, evento de artista'**
  String calendarDayPerformer(Object date);

  /// No description provided for @calendarDayVenue.
  ///
  /// In pt, this message translates to:
  /// **'{date}, evento de local'**
  String calendarDayVenue(Object date);

  /// No description provided for @calendarDayBoth.
  ///
  /// In pt, this message translates to:
  /// **'{date}, eventos de artista e de local'**
  String calendarDayBoth(Object date);

  /// No description provided for @calendarDayOther.
  ///
  /// In pt, this message translates to:
  /// **'{date}, evento'**
  String calendarDayOther(Object date);

  /// No description provided for @calendarGridLabel.
  ///
  /// In pt, this message translates to:
  /// **'Calendário de {month}'**
  String calendarGridLabel(Object month);

  /// No description provided for @calendarHint.
  ///
  /// In pt, this message translates to:
  /// **'Use as teclas de seta para navegar entre os dias e Enter para abrir um dia.'**
  String get calendarHint;

  /// No description provided for @createEvent.
  ///
  /// In pt, this message translates to:
  /// **'Criar evento'**
  String get createEvent;

  /// No description provided for @editEvent.
  ///
  /// In pt, this message translates to:
  /// **'Editar evento'**
  String get editEvent;

  /// No description provided for @titleLabel.
  ///
  /// In pt, this message translates to:
  /// **'Título'**
  String get titleLabel;

  /// No description provided for @descriptionLabel.
  ///
  /// In pt, this message translates to:
  /// **'Descrição'**
  String get descriptionLabel;

  /// No description provided for @startLabel.
  ///
  /// In pt, this message translates to:
  /// **'Início'**
  String get startLabel;

  /// No description provided for @endLabel.
  ///
  /// In pt, this message translates to:
  /// **'Término'**
  String get endLabel;

  /// No description provided for @endMustBeAfterStart.
  ///
  /// In pt, this message translates to:
  /// **'O término deve ser depois do início'**
  String get endMustBeAfterStart;

  /// No description provided for @eventCreated.
  ///
  /// In pt, this message translates to:
  /// **'Evento criado'**
  String get eventCreated;

  /// No description provided for @eventUpdated.
  ///
  /// In pt, this message translates to:
  /// **'Evento atualizado'**
  String get eventUpdated;

  /// No description provided for @eventVenueMissing.
  ///
  /// In pt, this message translates to:
  /// **'O local não existe mais'**
  String get eventVenueMissing;

  /// No description provided for @eventPerformerMissing.
  ///
  /// In pt, this message translates to:
  /// **'O artista não existe mais'**
  String get eventPerformerMissing;

  /// No description provided for @lastUpdated.
  ///
  /// In pt, this message translates to:
  /// **'Atualizado em {date}'**
  String lastUpdated(Object date);

  /// No description provided for @errorWithMessage.
  ///
  /// In pt, this message translates to:
  /// **'Erro: {message}'**
  String errorWithMessage(Object message);

  /// No description provided for @searchVenues.
  ///
  /// In pt, this message translates to:
  /// **'Buscar locais'**
  String get searchVenues;

  /// No description provided for @searchPerformers.
  ///
  /// In pt, this message translates to:
  /// **'Buscar artistas'**
  String get searchPerformers;

  /// No description provided for @noVenuesFound.
  ///
  /// In pt, this message translates to:
  /// **'Nenhum local encontrado'**
  String get noVenuesFound;

  /// No description provided for @noPerformersFound.
  ///
  /// In pt, this message translates to:
  /// **'Nenhum artista encontrado'**
  String get noPerformersFound;

  /// No description provided for @couldNotLoadVenues.
  ///
  /// In pt, this message translates to:
  /// **'Não foi possível carregar os locais'**
  String get couldNotLoadVenues;

  /// No description provided for @couldNotLoadPerformers.
  ///
  /// In pt, this message translates to:
  /// **'Não foi possível carregar os artistas'**
  String get couldNotLoadPerformers;

  /// No description provided for @noVenueSelected.
  ///
  /// In pt, this message translates to:
  /// **'Nenhum local selecionado'**
  String get noVenueSelected;

  /// No description provided for @noneSelected.
  ///
  /// In pt, this message translates to:
  /// **'Nenhum selecionado'**
  String get noneSelected;

  /// No description provided for @venueWithName.
  ///
  /// In pt, this message translates to:
  /// **'Local: {name}'**
  String venueWithName(Object name);

  /// No description provided for @venueCalendar.
  ///
  /// In pt, this message translates to:
  /// **'Calendário do local'**
  String get venueCalendar;

  /// No description provided for @myCalendar.
  ///
  /// In pt, this message translates to:
  /// **'Meu calendário'**
  String get myCalendar;

  /// No description provided for @performerCalendar.
  ///
  /// In pt, this message translates to:
  /// **'Calendário do artista'**
  String get performerCalendar;

  /// No description provided for @couldNotLoadEvents.
  ///
  /// In pt, this message translates to:
  /// **'Não foi possível carregar os eventos'**
  String get couldNotLoadEvents;

  /// No description provided for @offlineShowingCached.
  ///
  /// In pt, this message translates to:
  /// **'Offline — exibindo eventos em cache'**
  String get offlineShowingCached;

  /// No description provided for @localCacheCorrupt.
  ///
  /// In pt, this message translates to:
  /// **'Os dados em cache estavam ilegíveis e foram descartados'**
  String get localCacheCorrupt;

  /// No description provided for @noEvents.
  ///
  /// In pt, this message translates to:
  /// **'Nenhum evento'**
  String get noEvents;

  /// No description provided for @addEvent.
  ///
  /// In pt, this message translates to:
  /// **'Adicionar evento'**
  String get addEvent;

  /// No description provided for @createVenue.
  ///
  /// In pt, this message translates to:
  /// **'Criar local'**
  String get createVenue;

  /// No description provided for @editVenue.
  ///
  /// In pt, this message translates to:
  /// **'Editar local'**
  String get editVenue;

  /// No description provided for @createPerformer.
  ///
  /// In pt, this message translates to:
  /// **'Criar artista'**
  String get createPerformer;

  /// No description provided for @editPerformer.
  ///
  /// In pt, this message translates to:
  /// **'Editar artista'**
  String get editPerformer;

  /// No description provided for @venueNameLabel.
  ///
  /// In pt, this message translates to:
  /// **'Nome do local'**
  String get venueNameLabel;

  /// No description provided for @performerNameLabel.
  ///
  /// In pt, this message translates to:
  /// **'Nome do artista'**
  String get performerNameLabel;

  /// No description provided for @addressLabel.
  ///
  /// In pt, this message translates to:
  /// **'Endereço'**
  String get addressLabel;

  /// No description provided for @contactLabel.
  ///
  /// In pt, this message translates to:
  /// **'Contato'**
  String get contactLabel;

  /// No description provided for @capacityLabel.
  ///
  /// In pt, this message translates to:
  /// **'Capacidade'**
  String get capacityLabel;

  /// No description provided for @timezoneLabel.
  ///
  /// In pt, this message translates to:
  /// **'Fuso horário'**
  String get timezoneLabel;

  /// No description provided for @typeLabel.
  ///
  /// In pt, this message translates to:
  /// **'Tipo'**
  String get typeLabel;

  /// No description provided for @entityCreated.
  ///
  /// In pt, this message translates to:
  /// **'Salvo'**
  String get entityCreated;

  /// No description provided for @entityUpdated.
  ///
  /// In pt, this message translates to:
  /// **'Salvo'**
  String get entityUpdated;

  /// No description provided for @entityDeleted.
  ///
  /// In pt, this message translates to:
  /// **'Excluído'**
  String get entityDeleted;

  /// No description provided for @confirmDeleteTitle.
  ///
  /// In pt, this message translates to:
  /// **'Excluir {name}?'**
  String confirmDeleteTitle(Object name);

  /// No description provided for @confirmDeleteBody.
  ///
  /// In pt, this message translates to:
  /// **'Isso não pode ser desfeito.'**
  String get confirmDeleteBody;

  /// No description provided for @managerSectionTitle.
  ///
  /// In pt, this message translates to:
  /// **'Gestores'**
  String get managerSectionTitle;

  /// No description provided for @memberSectionTitle.
  ///
  /// In pt, this message translates to:
  /// **'Membros'**
  String get memberSectionTitle;

  /// No description provided for @addManager.
  ///
  /// In pt, this message translates to:
  /// **'Convidar gestor'**
  String get addManager;

  /// No description provided for @addMember.
  ///
  /// In pt, this message translates to:
  /// **'Convidar membro'**
  String get addMember;

  /// No description provided for @inviteEmailLabel.
  ///
  /// In pt, this message translates to:
  /// **'E-mail da conta'**
  String get inviteEmailLabel;

  /// No description provided for @inviteSent.
  ///
  /// In pt, this message translates to:
  /// **'Convite enviado para {email}'**
  String inviteSent(Object email);

  /// No description provided for @emailInvalid.
  ///
  /// In pt, this message translates to:
  /// **'Informe um e-mail válido'**
  String get emailInvalid;

  /// No description provided for @couldNotInvite.
  ///
  /// In pt, this message translates to:
  /// **'Não foi possível enviar o convite'**
  String get couldNotInvite;

  /// No description provided for @listEmpty.
  ///
  /// In pt, this message translates to:
  /// **'Nada por aqui ainda'**
  String get listEmpty;

  /// No description provided for @repeatLabel.
  ///
  /// In pt, this message translates to:
  /// **'Repetir'**
  String get repeatLabel;

  /// No description provided for @repeatNone.
  ///
  /// In pt, this message translates to:
  /// **'Não se repete'**
  String get repeatNone;

  /// No description provided for @repeatDaily.
  ///
  /// In pt, this message translates to:
  /// **'Diariamente'**
  String get repeatDaily;

  /// No description provided for @repeatWeekly.
  ///
  /// In pt, this message translates to:
  /// **'Semanalmente'**
  String get repeatWeekly;

  /// No description provided for @repeatMonthly.
  ///
  /// In pt, this message translates to:
  /// **'Mensalmente'**
  String get repeatMonthly;

  /// No description provided for @repeatIntervalLabel.
  ///
  /// In pt, this message translates to:
  /// **'Intervalo'**
  String get repeatIntervalLabel;

  /// No description provided for @repeatEndsLabel.
  ///
  /// In pt, this message translates to:
  /// **'Termina'**
  String get repeatEndsLabel;

  /// No description provided for @repeatEndsNever.
  ///
  /// In pt, this message translates to:
  /// **'Nunca'**
  String get repeatEndsNever;

  /// No description provided for @repeatEndsCount.
  ///
  /// In pt, this message translates to:
  /// **'Depois de um número de ocorrências'**
  String get repeatEndsCount;

  /// No description provided for @repeatEndsUntil.
  ///
  /// In pt, this message translates to:
  /// **'Em uma data'**
  String get repeatEndsUntil;

  /// No description provided for @repeatCountLabel.
  ///
  /// In pt, this message translates to:
  /// **'Ocorrências'**
  String get repeatCountLabel;

  /// No description provided for @repeatUntilLabel.
  ///
  /// In pt, this message translates to:
  /// **'Até'**
  String get repeatUntilLabel;

  /// No description provided for @occurrenceCountLabel.
  ///
  /// In pt, this message translates to:
  /// **'Ocorrências: {count}'**
  String occurrenceCountLabel(Object count);

  /// No description provided for @seriesCreated.
  ///
  /// In pt, this message translates to:
  /// **'Eventos criados: {count}'**
  String seriesCreated(Object count);

  /// No description provided for @seriesPartial.
  ///
  /// In pt, this message translates to:
  /// **'Criados: {created}. Já reservados: {failed}.'**
  String seriesPartial(Object created, Object failed);

  /// No description provided for @seriesPartialDetail.
  ///
  /// In pt, this message translates to:
  /// **'Não criados: {dates}'**
  String seriesPartialDetail(Object dates);

  /// No description provided for @repeatCountInvalid.
  ///
  /// In pt, this message translates to:
  /// **'Informe um número entre 1 e 200'**
  String get repeatCountInvalid;

  /// No description provided for @duplicateExistsTitle.
  ///
  /// In pt, this message translates to:
  /// **'{type} já existe: {name}'**
  String duplicateExistsTitle(Object name, Object type);

  /// No description provided for @duplicateClaimBody.
  ///
  /// In pt, this message translates to:
  /// **'Registros duplicados dividem as reservas — a verificação de conflito de agenda compara os ids dos registros, então dois registros do mesmo lugar nunca veem os eventos um do outro. Se for o mesmo, reivindique este.'**
  String get duplicateClaimBody;

  /// No description provided for @duplicateAlreadyMineBody.
  ///
  /// In pt, this message translates to:
  /// **'Você já gerencia este.'**
  String get duplicateAlreadyMineBody;

  /// No description provided for @claimEntityAction.
  ///
  /// In pt, this message translates to:
  /// **'Reivindicar'**
  String get claimEntityAction;

  /// No description provided for @openEntityAction.
  ///
  /// In pt, this message translates to:
  /// **'Abrir'**
  String get openEntityAction;

  /// No description provided for @createAnywayAction.
  ///
  /// In pt, this message translates to:
  /// **'Criar mesmo assim'**
  String get createAnywayAction;

  /// No description provided for @claimSucceeded.
  ///
  /// In pt, this message translates to:
  /// **'Agora você gerencia {name}'**
  String claimSucceeded(Object name);

  /// No description provided for @rosterApprove.
  ///
  /// In pt, this message translates to:
  /// **'Aprovar'**
  String get rosterApprove;

  /// No description provided for @rosterReject.
  ///
  /// In pt, this message translates to:
  /// **'Recusar'**
  String get rosterReject;

  /// No description provided for @rosterYou.
  ///
  /// In pt, this message translates to:
  /// **'Você'**
  String get rosterYou;

  /// No description provided for @roleManager.
  ///
  /// In pt, this message translates to:
  /// **'Gestor'**
  String get roleManager;

  /// No description provided for @roleMember.
  ///
  /// In pt, this message translates to:
  /// **'Membro'**
  String get roleMember;

  /// No description provided for @changeRole.
  ///
  /// In pt, this message translates to:
  /// **'Alterar função'**
  String get changeRole;

  /// No description provided for @inviteNeedsAcceptance.
  ///
  /// In pt, this message translates to:
  /// **'A pessoa precisa aceitar o convite antes de agir sobre isto.'**
  String get inviteNeedsAcceptance;

  /// No description provided for @awaitingAcceptance.
  ///
  /// In pt, this message translates to:
  /// **'Aguardando o aceite'**
  String get awaitingAcceptance;

  /// No description provided for @rosterRequested.
  ///
  /// In pt, this message translates to:
  /// **'Solicitou acesso'**
  String get rosterRequested;

  /// No description provided for @requestAccess.
  ///
  /// In pt, this message translates to:
  /// **'Solicitar acesso'**
  String get requestAccess;

  /// No description provided for @requestSent.
  ///
  /// In pt, this message translates to:
  /// **'Solicitação enviada — um gestor precisa aprová-la'**
  String get requestSent;

  /// No description provided for @requestPending.
  ///
  /// In pt, this message translates to:
  /// **'Sua solicitação aguarda aprovação'**
  String get requestPending;

  /// No description provided for @withdrawRequest.
  ///
  /// In pt, this message translates to:
  /// **'Retirar solicitação'**
  String get withdrawRequest;

  /// No description provided for @accountExists.
  ///
  /// In pt, this message translates to:
  /// **'{name} já tem uma conta — será pedido que aceite'**
  String accountExists(Object name);

  /// No description provided for @incomingRequestsTitle.
  ///
  /// In pt, this message translates to:
  /// **'Solicitações de acesso'**
  String get incomingRequestsTitle;

  /// No description provided for @approveRequest.
  ///
  /// In pt, this message translates to:
  /// **'Aprovar'**
  String get approveRequest;

  /// No description provided for @rejectRequest.
  ///
  /// In pt, this message translates to:
  /// **'Recusar'**
  String get rejectRequest;

  /// No description provided for @decideRequestAction.
  ///
  /// In pt, this message translates to:
  /// **'Revisar'**
  String get decideRequestAction;

  /// No description provided for @browsePerformers.
  ///
  /// In pt, this message translates to:
  /// **'Explorar artistas'**
  String get browsePerformers;

  /// No description provided for @upcomingEvents.
  ///
  /// In pt, this message translates to:
  /// **'Próximos eventos'**
  String get upcomingEvents;

  /// No description provided for @upcomingTitle.
  ///
  /// In pt, this message translates to:
  /// **'Próximos'**
  String get upcomingTitle;

  /// No description provided for @openInCalendar.
  ///
  /// In pt, this message translates to:
  /// **'Abrir no calendário'**
  String get openInCalendar;

  /// No description provided for @noUpcoming.
  ///
  /// In pt, this message translates to:
  /// **'Não há nada por vir'**
  String get noUpcoming;

  /// No description provided for @upcomingNothingOfYours.
  ///
  /// In pt, this message translates to:
  /// **'Nada seu por enquanto. Encontre o seu local ou artista para começar a acompanhar a agenda.'**
  String get upcomingNothingOfYours;

  /// No description provided for @deleteEvent.
  ///
  /// In pt, this message translates to:
  /// **'Excluir evento'**
  String get deleteEvent;

  /// No description provided for @eventDeleted.
  ///
  /// In pt, this message translates to:
  /// **'Evento excluído'**
  String get eventDeleted;

  /// No description provided for @deleteSeriesTitle.
  ///
  /// In pt, this message translates to:
  /// **'Este evento se repete'**
  String get deleteSeriesTitle;

  /// No description provided for @deleteSeriesWhat.
  ///
  /// In pt, this message translates to:
  /// **'O que deve ser excluído?'**
  String get deleteSeriesWhat;

  /// No description provided for @deleteSeriesOne.
  ///
  /// In pt, this message translates to:
  /// **'Somente este evento'**
  String get deleteSeriesOne;

  /// No description provided for @deleteSeriesAll.
  ///
  /// In pt, this message translates to:
  /// **'A série inteira ({count})'**
  String deleteSeriesAll(Object count);

  /// No description provided for @upcomingSeeAll.
  ///
  /// In pt, this message translates to:
  /// **'Ver tudo'**
  String get upcomingSeeAll;

  /// No description provided for @back.
  ///
  /// In pt, this message translates to:
  /// **'Voltar'**
  String get back;

  /// No description provided for @backToHome.
  ///
  /// In pt, this message translates to:
  /// **'Voltar para minhas entidades'**
  String get backToHome;
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
      <String>['pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'pt':
      return AppLocalizationsPt();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
