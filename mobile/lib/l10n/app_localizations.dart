import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

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
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'LifeOS'**
  String get appTitle;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get languageSystem;

  /// No description provided for @languageSpanish.
  ///
  /// In en, this message translates to:
  /// **'Español'**
  String get languageSpanish;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @actionClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get actionClose;

  /// No description provided for @actionRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get actionRetry;

  /// No description provided for @actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// No description provided for @actionDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get actionDelete;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @sectionAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get sectionAppearance;

  /// No description provided for @appearanceLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get appearanceLight;

  /// No description provided for @appearanceDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get appearanceDark;

  /// No description provided for @appearanceSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get appearanceSystem;

  /// No description provided for @sectionRegion.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get sectionRegion;

  /// No description provided for @languageTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageTitle;

  /// No description provided for @languageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose the app\'s language'**
  String get languageSubtitle;

  /// No description provided for @sectionGeneral.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get sectionGeneral;

  /// No description provided for @localModelTitle.
  ///
  /// In en, this message translates to:
  /// **'Local model'**
  String get localModelTitle;

  /// No description provided for @localModelSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Download and manage the on-device model'**
  String get localModelSubtitle;

  /// No description provided for @briefingNavTitle.
  ///
  /// In en, this message translates to:
  /// **'Briefing'**
  String get briefingNavTitle;

  /// No description provided for @briefingNavSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Generate a morning briefing on device'**
  String get briefingNavSubtitle;

  /// No description provided for @webSearchNavTitle.
  ///
  /// In en, this message translates to:
  /// **'Web search'**
  String get webSearchNavTitle;

  /// No description provided for @webSearchNavSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose your search provider'**
  String get webSearchNavSubtitle;

  /// No description provided for @webSearchSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Web search'**
  String get webSearchSettingsTitle;

  /// No description provided for @webSearchSettingsIntro.
  ///
  /// In en, this message translates to:
  /// **'Choose how the chat searches the web when the globe is on.'**
  String get webSearchSettingsIntro;

  /// No description provided for @webSearchProviderDuckduckgo.
  ///
  /// In en, this message translates to:
  /// **'DuckDuckGo'**
  String get webSearchProviderDuckduckgo;

  /// No description provided for @webSearchProviderDuckduckgoDesc.
  ///
  /// In en, this message translates to:
  /// **'Public, no setup, best-effort. Only your query leaves the device.'**
  String get webSearchProviderDuckduckgoDesc;

  /// No description provided for @webSearchProviderSearxng.
  ///
  /// In en, this message translates to:
  /// **'Your own SearXNG'**
  String get webSearchProviderSearxng;

  /// No description provided for @webSearchProviderSearxngDesc.
  ///
  /// In en, this message translates to:
  /// **'A SearXNG instance you host. Private: the query goes to a server you control.'**
  String get webSearchProviderSearxngDesc;

  /// No description provided for @webSearchProviderNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get webSearchProviderNone;

  /// No description provided for @webSearchProviderNoneDesc.
  ///
  /// In en, this message translates to:
  /// **'Web search off. No outbound search request is ever made.'**
  String get webSearchProviderNoneDesc;

  /// No description provided for @webSearchSearxngUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Your SearXNG instance URL'**
  String get webSearchSearxngUrlLabel;

  /// No description provided for @webSearchTestConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get webSearchTestConnection;

  /// No description provided for @webSearchTesting.
  ///
  /// In en, this message translates to:
  /// **'Testing…'**
  String get webSearchTesting;

  /// No description provided for @webSearchTestSuccess.
  ///
  /// In en, this message translates to:
  /// **'Connection successful'**
  String get webSearchTestSuccess;

  /// No description provided for @webSearchTestFailure.
  ///
  /// In en, this message translates to:
  /// **'Could not connect'**
  String get webSearchTestFailure;

  /// No description provided for @updatesNavTitle.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get updatesNavTitle;

  /// No description provided for @updatesNavSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Check for and install new versions'**
  String get updatesNavSubtitle;

  /// No description provided for @notificationsNavTitle.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notificationsNavTitle;

  /// No description provided for @notificationsNavSubtitle.
  ///
  /// In en, this message translates to:
  /// **'New-version alerts'**
  String get notificationsNavSubtitle;

  /// No description provided for @permissionsNavTitle.
  ///
  /// In en, this message translates to:
  /// **'Permissions'**
  String get permissionsNavTitle;

  /// No description provided for @permissionsNavSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Review and manage the app\'s permissions'**
  String get permissionsNavSubtitle;

  /// No description provided for @voiceNavTitle.
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get voiceNavTitle;

  /// No description provided for @voiceNavSubtitle.
  ///
  /// In en, this message translates to:
  /// **'How Axi speaks: natural voice and auto-read'**
  String get voiceNavSubtitle;

  /// No description provided for @voiceScreenTitle.
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get voiceScreenTitle;

  /// No description provided for @voiceAutoSpeakTitle.
  ///
  /// In en, this message translates to:
  /// **'Reply by voice'**
  String get voiceAutoSpeakTitle;

  /// No description provided for @voiceAutoSpeakSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Axi reads every reply aloud'**
  String get voiceAutoSpeakSubtitle;

  /// No description provided for @voiceStatusReady.
  ///
  /// In en, this message translates to:
  /// **'Natural voice active'**
  String get voiceStatusReady;

  /// No description provided for @voiceStatusReadyDetail.
  ///
  /// In en, this message translates to:
  /// **'Axi speaks with the on-device neural voice.'**
  String get voiceStatusReadyDetail;

  /// No description provided for @voiceStatusDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading the natural voice… {percent}%'**
  String voiceStatusDownloading(int percent);

  /// No description provided for @voiceStatusAbsent.
  ///
  /// In en, this message translates to:
  /// **'Using the system voice'**
  String get voiceStatusAbsent;

  /// No description provided for @voiceStatusAbsentDetail.
  ///
  /// In en, this message translates to:
  /// **'Download the natural voice so Axi sounds more human.'**
  String get voiceStatusAbsentDetail;

  /// No description provided for @voiceStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t download the natural voice'**
  String get voiceStatusFailed;

  /// No description provided for @voiceDownloadButton.
  ///
  /// In en, this message translates to:
  /// **'Download natural voice'**
  String get voiceDownloadButton;

  /// No description provided for @voiceRetryButton.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get voiceRetryButton;

  /// No description provided for @voiceRateLabel.
  ///
  /// In en, this message translates to:
  /// **'Speed'**
  String get voiceRateLabel;

  /// No description provided for @voiceRateSlow.
  ///
  /// In en, this message translates to:
  /// **'Slow'**
  String get voiceRateSlow;

  /// No description provided for @voiceRateFast.
  ///
  /// In en, this message translates to:
  /// **'Fast'**
  String get voiceRateFast;

  /// No description provided for @voiceTestButton.
  ///
  /// In en, this message translates to:
  /// **'Test voice'**
  String get voiceTestButton;

  /// No description provided for @voiceSampleText.
  ///
  /// In en, this message translates to:
  /// **'Hi, I\'m Axi. This is how my voice will sound when I read your replies.'**
  String get voiceSampleText;

  /// No description provided for @voiceLanguageNote.
  ///
  /// In en, this message translates to:
  /// **'The voice follows the app language (Region / Language).'**
  String get voiceLanguageNote;

  /// No description provided for @voiceCatalogNavTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose a voice'**
  String get voiceCatalogNavTitle;

  /// No description provided for @voiceCatalogNavSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Browse, preview and download more voices'**
  String get voiceCatalogNavSubtitle;

  /// No description provided for @voiceCatalogTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose voice'**
  String get voiceCatalogTitle;

  /// No description provided for @voiceCatalogGroupSpanish.
  ///
  /// In en, this message translates to:
  /// **'Spanish'**
  String get voiceCatalogGroupSpanish;

  /// No description provided for @voiceCatalogGroupEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get voiceCatalogGroupEnglish;

  /// No description provided for @voiceCatalogPreviewButton.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get voiceCatalogPreviewButton;

  /// No description provided for @voiceCatalogUseButton.
  ///
  /// In en, this message translates to:
  /// **'Use this voice'**
  String get voiceCatalogUseButton;

  /// No description provided for @voiceCatalogSelectedBadge.
  ///
  /// In en, this message translates to:
  /// **'Selected'**
  String get voiceCatalogSelectedBadge;

  /// No description provided for @voiceCatalogDownloadButton.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get voiceCatalogDownloadButton;

  /// No description provided for @voiceCatalogStatusInstalled.
  ///
  /// In en, this message translates to:
  /// **'Downloaded'**
  String get voiceCatalogStatusInstalled;

  /// No description provided for @voiceCatalogStatusAbsent.
  ///
  /// In en, this message translates to:
  /// **'Not downloaded'**
  String get voiceCatalogStatusAbsent;

  /// No description provided for @voiceCatalogStatusDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading… {percent}%'**
  String voiceCatalogStatusDownloading(int percent);

  /// No description provided for @voiceCatalogStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed'**
  String get voiceCatalogStatusFailed;

  /// No description provided for @voiceCatalogSampleEs.
  ///
  /// In en, this message translates to:
  /// **'Hola, soy Axi, tu asistente personal.'**
  String get voiceCatalogSampleEs;

  /// No description provided for @voiceCatalogSampleEn.
  ///
  /// In en, this message translates to:
  /// **'Hi, I\'m Axi, your personal assistant.'**
  String get voiceCatalogSampleEn;

  /// No description provided for @voiceCatalogRegionMexico.
  ///
  /// In en, this message translates to:
  /// **'Mexico'**
  String get voiceCatalogRegionMexico;

  /// No description provided for @voiceCatalogRegionSpain.
  ///
  /// In en, this message translates to:
  /// **'Spain'**
  String get voiceCatalogRegionSpain;

  /// No description provided for @voiceCatalogRegionArgentina.
  ///
  /// In en, this message translates to:
  /// **'Argentina'**
  String get voiceCatalogRegionArgentina;

  /// No description provided for @voiceCatalogRegionUnitedStates.
  ///
  /// In en, this message translates to:
  /// **'United States'**
  String get voiceCatalogRegionUnitedStates;

  /// No description provided for @voiceCatalogRegionUnitedKingdom.
  ///
  /// In en, this message translates to:
  /// **'United Kingdom'**
  String get voiceCatalogRegionUnitedKingdom;

  /// No description provided for @voiceCatalogDeleteButton.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get voiceCatalogDeleteButton;

  /// No description provided for @voiceCatalogDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this voice?'**
  String get voiceCatalogDeleteTitle;

  /// No description provided for @voiceCatalogDeleteMessage.
  ///
  /// In en, this message translates to:
  /// **'The files for {voice} will be removed from this device. You can download it again anytime.'**
  String voiceCatalogDeleteMessage(String voice);

  /// No description provided for @voiceCatalogDeleteSelectedMessage.
  ///
  /// In en, this message translates to:
  /// **'{voice} is your active voice. It will be removed from this device and the app will use another downloaded voice, or your device\'s voice if none remain.'**
  String voiceCatalogDeleteSelectedMessage(String voice);

  /// No description provided for @voiceCatalogDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get voiceCatalogDeleteConfirm;

  /// No description provided for @voiceCatalogDeleteCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get voiceCatalogDeleteCancel;

  /// No description provided for @sectionAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get sectionAdvanced;

  /// No description provided for @engineConfigTitle.
  ///
  /// In en, this message translates to:
  /// **'Engine configuration'**
  String get engineConfigTitle;

  /// No description provided for @engineConfigSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Paired-engine parameters'**
  String get engineConfigSubtitle;

  /// No description provided for @sectionAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get sectionAbout;

  /// No description provided for @appVersionLabel.
  ///
  /// In en, this message translates to:
  /// **'Version {name} ({build})'**
  String appVersionLabel(String name, int build);

  /// No description provided for @appVersionLoading.
  ///
  /// In en, this message translates to:
  /// **'Version…'**
  String get appVersionLoading;

  /// No description provided for @appTagline.
  ///
  /// In en, this message translates to:
  /// **'Axi, always with you ⚡'**
  String get appTagline;

  /// No description provided for @aboutSlogan.
  ///
  /// In en, this message translates to:
  /// **'Your life, your machine, not their cloud.'**
  String get aboutSlogan;

  /// No description provided for @aboutAuthor.
  ///
  /// In en, this message translates to:
  /// **'Created by Héctor Martínez'**
  String get aboutAuthor;

  /// No description provided for @aboutLandingLink.
  ///
  /// In en, this message translates to:
  /// **'lifeos.hectormr.com'**
  String get aboutLandingLink;

  /// No description provided for @requiredModelsSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Required models'**
  String get requiredModelsSectionTitle;

  /// No description provided for @requiredModelsSectionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'LifeOS works fully offline once these four models are installed.'**
  String get requiredModelsSectionSubtitle;

  /// No description provided for @requiredModelsDownloadAll.
  ///
  /// In en, this message translates to:
  /// **'Download all'**
  String get requiredModelsDownloadAll;

  /// No description provided for @requiredModelsContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue download'**
  String get requiredModelsContinue;

  /// No description provided for @requiredModelsWifiNote.
  ///
  /// In en, this message translates to:
  /// **'We recommend connecting to Wi-Fi for the initial download (~2.9 GB).'**
  String get requiredModelsWifiNote;

  /// No description provided for @requiredModelsOverall.
  ///
  /// In en, this message translates to:
  /// **'Getting LifeOS ready — {ready} of {total} · {percent}%'**
  String requiredModelsOverall(int ready, int total, int percent);

  /// No description provided for @requiredModelStatusInstalled.
  ///
  /// In en, this message translates to:
  /// **'Installed'**
  String get requiredModelStatusInstalled;

  /// No description provided for @requiredModelStatusDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading {percent}%'**
  String requiredModelStatusDownloading(int percent);

  /// No description provided for @requiredModelStatusAvailable.
  ///
  /// In en, this message translates to:
  /// **'Available to download'**
  String get requiredModelStatusAvailable;

  /// No description provided for @requiredModelStatusError.
  ///
  /// In en, this message translates to:
  /// **'Download error'**
  String get requiredModelStatusError;

  /// No description provided for @modelNameBrain.
  ///
  /// In en, this message translates to:
  /// **'Brain'**
  String get modelNameBrain;

  /// No description provided for @modelNameStt.
  ///
  /// In en, this message translates to:
  /// **'Hearing (speech to text)'**
  String get modelNameStt;

  /// No description provided for @modelNameTts.
  ///
  /// In en, this message translates to:
  /// **'Voice (Piper)'**
  String get modelNameTts;

  /// No description provided for @modelNameEmbed.
  ///
  /// In en, this message translates to:
  /// **'Memory (embeddings)'**
  String get modelNameEmbed;

  /// No description provided for @chatPreparingTitle.
  ///
  /// In en, this message translates to:
  /// **'Getting LifeOS ready'**
  String get chatPreparingTitle;

  /// No description provided for @chatPreparingBody.
  ///
  /// In en, this message translates to:
  /// **'Download the required models to chat offline.'**
  String get chatPreparingBody;

  /// No description provided for @settingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTooltip;

  /// No description provided for @homeChatOffline.
  ///
  /// In en, this message translates to:
  /// **'Chat with Axi (offline)'**
  String get homeChatOffline;

  /// No description provided for @homeUseLocalModel.
  ///
  /// In en, this message translates to:
  /// **'Use local model (offline)'**
  String get homeUseLocalModel;

  /// No description provided for @homeConnectedTo.
  ///
  /// In en, this message translates to:
  /// **'Connected to {url}'**
  String homeConnectedTo(String url);

  /// No description provided for @homeEngineReachable.
  ///
  /// In en, this message translates to:
  /// **'Engine reachable'**
  String get homeEngineReachable;

  /// No description provided for @homeEngineUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Engine unreachable'**
  String get homeEngineUnreachable;

  /// No description provided for @homeTalkToAxi.
  ///
  /// In en, this message translates to:
  /// **'Talk to Axi'**
  String get homeTalkToAxi;

  /// No description provided for @homeMyData.
  ///
  /// In en, this message translates to:
  /// **'My data'**
  String get homeMyData;

  /// No description provided for @homeMyLife.
  ///
  /// In en, this message translates to:
  /// **'My life'**
  String get homeMyLife;

  /// No description provided for @homeHowIsAxi.
  ///
  /// In en, this message translates to:
  /// **'How is Axi?'**
  String get homeHowIsAxi;

  /// No description provided for @homeReminders.
  ///
  /// In en, this message translates to:
  /// **'Reminders'**
  String get homeReminders;

  /// No description provided for @homeSummary.
  ///
  /// In en, this message translates to:
  /// **'Summary'**
  String get homeSummary;

  /// No description provided for @homeBulletins.
  ///
  /// In en, this message translates to:
  /// **'Bulletins'**
  String get homeBulletins;

  /// No description provided for @homeTodaySummary.
  ///
  /// In en, this message translates to:
  /// **'Today\'s summary'**
  String get homeTodaySummary;

  /// No description provided for @homeBrain.
  ///
  /// In en, this message translates to:
  /// **'Brain'**
  String get homeBrain;

  /// No description provided for @homeSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get homeSettings;

  /// No description provided for @homeLocalModel.
  ///
  /// In en, this message translates to:
  /// **'Local model'**
  String get homeLocalModel;

  /// No description provided for @homeMeetings.
  ///
  /// In en, this message translates to:
  /// **'Meetings'**
  String get homeMeetings;

  /// No description provided for @homeUpdates.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get homeUpdates;

  /// No description provided for @axiAvatarLabel.
  ///
  /// In en, this message translates to:
  /// **'Axi — living agent. Tap an organ to explore it.'**
  String get axiAvatarLabel;

  /// No description provided for @axiOrganComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Coming soon on your phone'**
  String get axiOrganComingSoon;

  /// No description provided for @brain3dTitle.
  ///
  /// In en, this message translates to:
  /// **'3D Brain'**
  String get brain3dTitle;

  /// No description provided for @brain3dEmpty.
  ///
  /// In en, this message translates to:
  /// **'No memories in the local graph yet. Chat with Axi and its brain will grow.'**
  String get brain3dEmpty;

  /// No description provided for @brain3dSummary.
  ///
  /// In en, this message translates to:
  /// **'{nodes} nodes · {edges} links in the local graph'**
  String brain3dSummary(int nodes, int edges);

  /// No description provided for @chatTitle.
  ///
  /// In en, this message translates to:
  /// **'Axi'**
  String get chatTitle;

  /// No description provided for @chatVoiceReplyTooltip.
  ///
  /// In en, this message translates to:
  /// **'Reply by voice'**
  String get chatVoiceReplyTooltip;

  /// No description provided for @chatVoiceReplyTitle.
  ///
  /// In en, this message translates to:
  /// **'Reply by voice'**
  String get chatVoiceReplyTitle;

  /// No description provided for @chatVoiceReplySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Axi reads each new reply aloud.'**
  String get chatVoiceReplySubtitle;

  /// No description provided for @chatCamera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get chatCamera;

  /// No description provided for @chatGallery.
  ///
  /// In en, this message translates to:
  /// **'Gallery'**
  String get chatGallery;

  /// No description provided for @chatAttachError.
  ///
  /// In en, this message translates to:
  /// **'Could not attach the image: {error}'**
  String chatAttachError(String error);

  /// No description provided for @chatAttachLimit.
  ///
  /// In en, this message translates to:
  /// **'You can attach up to {count} images per message.'**
  String chatAttachLimit(int count);

  /// No description provided for @chatHoldToRecord.
  ///
  /// In en, this message translates to:
  /// **'Press and hold to record a voice note'**
  String get chatHoldToRecord;

  /// No description provided for @chatMicPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Microphone permission denied. Enable it in Settings to record voice notes.'**
  String get chatMicPermissionDenied;

  /// No description provided for @chatReleaseToCancel.
  ///
  /// In en, this message translates to:
  /// **'Release to cancel'**
  String get chatReleaseToCancel;

  /// No description provided for @chatSlideToCancel.
  ///
  /// In en, this message translates to:
  /// **'Slide to cancel'**
  String get chatSlideToCancel;

  /// No description provided for @chatInputHint.
  ///
  /// In en, this message translates to:
  /// **'Type a message…'**
  String get chatInputHint;

  /// No description provided for @chatAttachTooltip.
  ///
  /// In en, this message translates to:
  /// **'Attach'**
  String get chatAttachTooltip;

  /// No description provided for @chatSendTooltip.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get chatSendTooltip;

  /// No description provided for @chatWebSearchTooltip.
  ///
  /// In en, this message translates to:
  /// **'Search the web'**
  String get chatWebSearchTooltip;

  /// No description provided for @chatModelLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading the model…'**
  String get chatModelLoading;

  /// No description provided for @chatModelLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could not load the model. Check it and try again.'**
  String get chatModelLoadError;

  /// No description provided for @chatTyping.
  ///
  /// In en, this message translates to:
  /// **'Axi is typing…'**
  String get chatTyping;

  /// No description provided for @chatStopReading.
  ///
  /// In en, this message translates to:
  /// **'Stop reading'**
  String get chatStopReading;

  /// No description provided for @chatListenReply.
  ///
  /// In en, this message translates to:
  /// **'Listen to reply'**
  String get chatListenReply;

  /// No description provided for @chatMetricsTitle.
  ///
  /// In en, this message translates to:
  /// **'Response metrics'**
  String get chatMetricsTitle;

  /// No description provided for @metricSpeed.
  ///
  /// In en, this message translates to:
  /// **'Speed'**
  String get metricSpeed;

  /// No description provided for @metricTokens.
  ///
  /// In en, this message translates to:
  /// **'Generated tokens'**
  String get metricTokens;

  /// No description provided for @metricTokensApprox.
  ///
  /// In en, this message translates to:
  /// **' (approx.)'**
  String get metricTokensApprox;

  /// No description provided for @metricTotalTime.
  ///
  /// In en, this message translates to:
  /// **'Total time'**
  String get metricTotalTime;

  /// No description provided for @metricTtft.
  ///
  /// In en, this message translates to:
  /// **'First token (TTFT)'**
  String get metricTtft;

  /// No description provided for @metricUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Not available'**
  String get metricUnavailable;

  /// No description provided for @metricBackend.
  ///
  /// In en, this message translates to:
  /// **'Backend'**
  String get metricBackend;

  /// No description provided for @metricModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get metricModel;

  /// No description provided for @chatTranscriptionPending.
  ///
  /// In en, this message translates to:
  /// **'Transcription pending (STT)'**
  String get chatTranscriptionPending;

  /// No description provided for @chatShowTranscription.
  ///
  /// In en, this message translates to:
  /// **'Show transcription'**
  String get chatShowTranscription;

  /// No description provided for @chatHideTranscription.
  ///
  /// In en, this message translates to:
  /// **'Hide transcription'**
  String get chatHideTranscription;

  /// No description provided for @sttTranscribing.
  ///
  /// In en, this message translates to:
  /// **'Transcribing…'**
  String get sttTranscribing;

  /// No description provided for @sttDownloadVoiceModel.
  ///
  /// In en, this message translates to:
  /// **'Download voice model'**
  String get sttDownloadVoiceModel;

  /// No description provided for @sttDownloadingVoiceModel.
  ///
  /// In en, this message translates to:
  /// **'Downloading voice model… {percent}%'**
  String sttDownloadingVoiceModel(Object percent);

  /// No description provided for @sttVoiceModelReady.
  ///
  /// In en, this message translates to:
  /// **'Voice model ready'**
  String get sttVoiceModelReady;

  /// No description provided for @sttVoiceModelFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t download the voice model. Tap to retry.'**
  String get sttVoiceModelFailed;

  /// No description provided for @ttsDownloadVoice.
  ///
  /// In en, this message translates to:
  /// **'Download neural voice'**
  String get ttsDownloadVoice;

  /// No description provided for @ttsDownloadingVoice.
  ///
  /// In en, this message translates to:
  /// **'Downloading neural voice… {percent}%'**
  String ttsDownloadingVoice(Object percent);

  /// No description provided for @ttsVoiceReady.
  ///
  /// In en, this message translates to:
  /// **'Neural voice ready'**
  String get ttsVoiceReady;

  /// No description provided for @ttsVoiceFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t download the neural voice. The system voice will be used meanwhile.'**
  String get ttsVoiceFailed;

  /// No description provided for @briefingTitle.
  ///
  /// In en, this message translates to:
  /// **'Briefing'**
  String get briefingTitle;

  /// No description provided for @briefingSourcesTooltip.
  ///
  /// In en, this message translates to:
  /// **'Sources'**
  String get briefingSourcesTooltip;

  /// No description provided for @briefingGenerating.
  ///
  /// In en, this message translates to:
  /// **'Generating…'**
  String get briefingGenerating;

  /// No description provided for @briefingGenerateNow.
  ///
  /// In en, this message translates to:
  /// **'Generate briefing now'**
  String get briefingGenerateNow;

  /// No description provided for @briefingEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No briefing yet'**
  String get briefingEmptyTitle;

  /// No description provided for @briefingEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Tap \"Generate briefing now\" and Axi will read your sources and summarize them on device.'**
  String get briefingEmptyBody;

  /// No description provided for @briefingHeaderTitle.
  ///
  /// In en, this message translates to:
  /// **'Morning briefing'**
  String get briefingHeaderTitle;

  /// No description provided for @briefingGeneratedAt.
  ///
  /// In en, this message translates to:
  /// **'Generated on {datetime}'**
  String briefingGeneratedAt(String datetime);

  /// No description provided for @briefingLinkCopied.
  ///
  /// In en, this message translates to:
  /// **'Link copied to clipboard'**
  String get briefingLinkCopied;

  /// No description provided for @briefingScheduleTitle.
  ///
  /// In en, this message translates to:
  /// **'Automatic briefing'**
  String get briefingScheduleTitle;

  /// No description provided for @briefingScheduleSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Generates the briefing every day at the chosen time. If the app is closed, you will get a notification to generate it with one tap.'**
  String get briefingScheduleSubtitle;

  /// No description provided for @briefingScheduleTimeLabel.
  ///
  /// In en, this message translates to:
  /// **'Briefing time'**
  String get briefingScheduleTimeLabel;

  /// No description provided for @briefingOpenArticle.
  ///
  /// In en, this message translates to:
  /// **'Read full article →'**
  String get briefingOpenArticle;

  /// No description provided for @briefingFullSummary.
  ///
  /// In en, this message translates to:
  /// **'See full summary'**
  String get briefingFullSummary;

  /// No description provided for @briefingHideFullSummary.
  ///
  /// In en, this message translates to:
  /// **'Hide full summary'**
  String get briefingHideFullSummary;

  /// No description provided for @briefingCommentsSummary.
  ///
  /// In en, this message translates to:
  /// **'See comments summary'**
  String get briefingCommentsSummary;

  /// No description provided for @briefingHideCommentsSummary.
  ///
  /// In en, this message translates to:
  /// **'Hide comments summary'**
  String get briefingHideCommentsSummary;

  /// No description provided for @briefingSummarizing.
  ///
  /// In en, this message translates to:
  /// **'Summarizing…'**
  String get briefingSummarizing;

  /// No description provided for @briefingSummarizingComments.
  ///
  /// In en, this message translates to:
  /// **'Summarizing comments…'**
  String get briefingSummarizingComments;

  /// No description provided for @briefingTranslating.
  ///
  /// In en, this message translates to:
  /// **'Translating…'**
  String get briefingTranslating;

  /// No description provided for @briefingNoSummaryHint.
  ///
  /// In en, this message translates to:
  /// **'No summary — tap \"See full summary\".'**
  String get briefingNoSummaryHint;

  /// No description provided for @briefingSkippedSources.
  ///
  /// In en, this message translates to:
  /// **'No news today: {sources}'**
  String briefingSkippedSources(String sources);

  /// No description provided for @chatDeleteMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete message'**
  String get chatDeleteMessage;

  /// Shown under the delete action when deleting a user message also deletes the Axi reply that answered it.
  ///
  /// In en, this message translates to:
  /// **'Your message and Axi\'s reply will be deleted.'**
  String get chatDeleteMessagePairNote;

  /// No description provided for @chatDeleteConversation.
  ///
  /// In en, this message translates to:
  /// **'Delete conversation'**
  String get chatDeleteConversation;

  /// No description provided for @chatDeleteConversationTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete conversation?'**
  String get chatDeleteConversationTitle;

  /// No description provided for @chatDeleteConversationBody.
  ///
  /// In en, this message translates to:
  /// **'This deletes the messages, the memories Axi derived from this conversation, and its voice notes on this device.'**
  String get chatDeleteConversationBody;

  /// No description provided for @backupsNavTitle.
  ///
  /// In en, this message translates to:
  /// **'Backups'**
  String get backupsNavTitle;

  /// No description provided for @backupsNavSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Create and restore copies of your data'**
  String get backupsNavSubtitle;

  /// No description provided for @backupsTitle.
  ///
  /// In en, this message translates to:
  /// **'Backups'**
  String get backupsTitle;

  /// No description provided for @backupsCreateNow.
  ///
  /// In en, this message translates to:
  /// **'Create backup now'**
  String get backupsCreateNow;

  /// No description provided for @backupsAutoSection.
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get backupsAutoSection;

  /// No description provided for @backupsManualSection.
  ///
  /// In en, this message translates to:
  /// **'Manual'**
  String get backupsManualSection;

  /// No description provided for @backupsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No backups yet. LifeOS creates one automatically every day when you open the app.'**
  String get backupsEmpty;

  /// No description provided for @backupsCreated.
  ///
  /// In en, this message translates to:
  /// **'Backup created'**
  String get backupsCreated;

  /// No description provided for @backupsDeleted.
  ///
  /// In en, this message translates to:
  /// **'Backup deleted'**
  String get backupsDeleted;

  /// No description provided for @backupsDeleteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete backup'**
  String get backupsDeleteTooltip;

  /// No description provided for @backupsPreRestoreLabel.
  ///
  /// In en, this message translates to:
  /// **'Pre-restore copy (your previous data)'**
  String get backupsPreRestoreLabel;

  /// No description provided for @backupsRestoreTitle.
  ///
  /// In en, this message translates to:
  /// **'Restore this backup?'**
  String get backupsRestoreTitle;

  /// No description provided for @backupsRestoreBody.
  ///
  /// In en, this message translates to:
  /// **'Your current data is saved first as a \"pre-restore\" copy, so you can always come back to it from this list.'**
  String get backupsRestoreBody;

  /// No description provided for @backupsRestoreConfirm.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get backupsRestoreConfirm;

  /// No description provided for @backupsRestored.
  ///
  /// In en, this message translates to:
  /// **'Backup restored. Your previous data was saved as a pre-restore copy.'**
  String get backupsRestored;

  /// No description provided for @backupsOperationFailed.
  ///
  /// In en, this message translates to:
  /// **'The operation failed: {error}'**
  String backupsOperationFailed(String error);

  /// No description provided for @dataControlBusy.
  ///
  /// In en, this message translates to:
  /// **'Wait until Axi finishes before doing this.'**
  String get dataControlBusy;

  /// No description provided for @sectionDangerZone.
  ///
  /// In en, this message translates to:
  /// **'Danger zone'**
  String get sectionDangerZone;

  /// No description provided for @wipeNavTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete all my data'**
  String get wipeNavTitle;

  /// No description provided for @wipeNavSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Erases your data on this device. Models and settings are kept.'**
  String get wipeNavSubtitle;

  /// No description provided for @wipeTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete all my data'**
  String get wipeTitle;

  /// No description provided for @wipeDeletesTitle.
  ///
  /// In en, this message translates to:
  /// **'This will be deleted'**
  String get wipeDeletesTitle;

  /// No description provided for @wipeDeletesBody.
  ///
  /// In en, this message translates to:
  /// **'• Your memory graph (facts, people, conversations, vectors)\n• Chat history\n• Voice notes stored on this device\n• Your last briefing, its schedule and sources\n• Reminders and their scheduled alarms'**
  String get wipeDeletesBody;

  /// No description provided for @wipeKeepsTitle.
  ///
  /// In en, this message translates to:
  /// **'This is kept'**
  String get wipeKeepsTitle;

  /// No description provided for @wipeKeepsBody.
  ///
  /// In en, this message translates to:
  /// **'• Downloaded models (chat, voice, embeddings)\n• App settings (language, theme, onboarding)'**
  String get wipeKeepsBody;

  /// No description provided for @wipeBackupFirst.
  ///
  /// In en, this message translates to:
  /// **'Create a backup before deleting'**
  String get wipeBackupFirst;

  /// No description provided for @wipeTypePrompt.
  ///
  /// In en, this message translates to:
  /// **'Type {word} to confirm'**
  String wipeTypePrompt(String word);

  /// No description provided for @wipeCountdownButton.
  ///
  /// In en, this message translates to:
  /// **'Delete ({seconds})'**
  String wipeCountdownButton(int seconds);

  /// No description provided for @wipeConfirmButton.
  ///
  /// In en, this message translates to:
  /// **'Delete everything'**
  String get wipeConfirmButton;

  /// No description provided for @wipeInProgress.
  ///
  /// In en, this message translates to:
  /// **'Deleting…'**
  String get wipeInProgress;

  /// No description provided for @wipeDone.
  ///
  /// In en, this message translates to:
  /// **'All your data on this device was deleted.'**
  String get wipeDone;

  /// No description provided for @wipePartialFailure.
  ///
  /// In en, this message translates to:
  /// **'Some data could not be deleted: {targets}'**
  String wipePartialFailure(String targets);
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
      <String>['en', 'es'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
