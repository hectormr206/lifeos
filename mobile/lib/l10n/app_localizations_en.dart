// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'LifeOS';

  @override
  String get languageSystem => 'System';

  @override
  String get languageSpanish => 'Español';

  @override
  String get languageEnglish => 'English';

  @override
  String get actionClose => 'Close';

  @override
  String get actionRetry => 'Retry';

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionDelete => 'Delete';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get sectionAppearance => 'Appearance';

  @override
  String get appearanceLight => 'Light';

  @override
  String get appearanceDark => 'Dark';

  @override
  String get appearanceSystem => 'System';

  @override
  String get sectionRegion => 'Region';

  @override
  String get languageTitle => 'Language';

  @override
  String get languageSubtitle => 'Choose the app\'s language';

  @override
  String get sectionGeneral => 'General';

  @override
  String get localModelTitle => 'Local model';

  @override
  String get localModelSubtitle => 'Download and manage the on-device model';

  @override
  String get briefingNavTitle => 'Briefing';

  @override
  String get briefingNavSubtitle => 'Generate a morning briefing on device';

  @override
  String get updatesNavTitle => 'Updates';

  @override
  String get updatesNavSubtitle => 'Check for and install new versions';

  @override
  String get notificationsNavTitle => 'Notifications';

  @override
  String get notificationsNavSubtitle => 'New-version alerts';

  @override
  String get permissionsNavTitle => 'Permissions';

  @override
  String get permissionsNavSubtitle =>
      'Review and manage the app\'s permissions';

  @override
  String get voiceNavTitle => 'Voice';

  @override
  String get voiceNavSubtitle => 'Coming soon';

  @override
  String get sectionAdvanced => 'Advanced';

  @override
  String get engineConfigTitle => 'Engine configuration';

  @override
  String get engineConfigSubtitle => 'Paired-engine parameters';

  @override
  String get sectionAbout => 'About';

  @override
  String appVersionLabel(String name, int build) {
    return 'Version $name ($build)';
  }

  @override
  String get appVersionLoading => 'Version…';

  @override
  String get appTagline => 'Axi, always with you ⚡';

  @override
  String get settingsTooltip => 'Settings';

  @override
  String get homeNotConnected => 'Not connected to any engine yet.';

  @override
  String get homeChatOffline => 'Chat with Axi (offline)';

  @override
  String get homeUseLocalModel => 'Use local model (offline)';

  @override
  String homeConnectedTo(String url) {
    return 'Connected to $url';
  }

  @override
  String get homeEngineReachable => 'Engine reachable';

  @override
  String get homeEngineUnreachable => 'Engine unreachable';

  @override
  String get homeTalkToAxi => 'Talk to Axi';

  @override
  String get homeMyData => 'My data';

  @override
  String get homeHowIsAxi => 'How is Axi?';

  @override
  String get homeReminders => 'Reminders';

  @override
  String get homeSummary => 'Summary';

  @override
  String get homeBulletins => 'Bulletins';

  @override
  String get homeTodaySummary => 'Today\'s summary';

  @override
  String get homeBrain => 'Brain';

  @override
  String get homeSettings => 'Settings';

  @override
  String get homeLocalModel => 'Local model';

  @override
  String get homeMeetings => 'Meetings';

  @override
  String get homeUpdates => 'Updates';

  @override
  String get axiAvatarLabel =>
      'Axi — living agent. Tap an organ to explore it.';

  @override
  String get axiOrganComingSoon => 'Coming soon on your phone';

  @override
  String get brain3dTitle => '3D Brain';

  @override
  String get brain3dEmpty =>
      'No memories in the local graph yet. Chat with Axi and its brain will grow.';

  @override
  String brain3dSummary(int nodes, int edges) {
    return '$nodes nodes · $edges links in the local graph';
  }

  @override
  String get chatTitle => 'Axi';

  @override
  String get chatVoiceReplyTooltip => 'Reply by voice';

  @override
  String get chatVoiceReplyTitle => 'Reply by voice';

  @override
  String get chatVoiceReplySubtitle => 'Coming soon (on-device voice)';

  @override
  String get chatCamera => 'Camera';

  @override
  String get chatGallery => 'Gallery';

  @override
  String chatAttachError(String error) {
    return 'Could not attach the image: $error';
  }

  @override
  String chatAttachLimit(int count) {
    return 'You can attach up to $count images per message.';
  }

  @override
  String get chatHoldToRecord => 'Press and hold to record a voice note';

  @override
  String get chatMicPermissionDenied =>
      'Microphone permission denied. Enable it in Settings to record voice notes.';

  @override
  String get chatReleaseToCancel => 'Release to cancel';

  @override
  String get chatSlideToCancel => 'Slide to cancel';

  @override
  String get chatInputHint => 'Type a message…';

  @override
  String get chatAttachTooltip => 'Attach';

  @override
  String get chatSendTooltip => 'Send';

  @override
  String get chatWebSearchTooltip => 'Search the web';

  @override
  String get chatModelLoading => 'Loading the model…';

  @override
  String get chatModelLoadError =>
      'Could not load the model. Check it and try again.';

  @override
  String get chatTyping => 'Axi is typing…';

  @override
  String get chatStopReading => 'Stop reading';

  @override
  String get chatListenReply => 'Listen to reply';

  @override
  String get chatMetricsTitle => 'Response metrics';

  @override
  String get metricSpeed => 'Speed';

  @override
  String get metricTokens => 'Generated tokens';

  @override
  String get metricTokensApprox => ' (approx.)';

  @override
  String get metricTotalTime => 'Total time';

  @override
  String get metricTtft => 'First token (TTFT)';

  @override
  String get metricUnavailable => 'Not available';

  @override
  String get metricBackend => 'Backend';

  @override
  String get metricModel => 'Model';

  @override
  String get chatTranscriptionPending => 'Transcription pending (STT)';

  @override
  String get sttTranscribing => 'Transcribing…';

  @override
  String get sttDownloadVoiceModel => 'Download voice model';

  @override
  String sttDownloadingVoiceModel(Object percent) {
    return 'Downloading voice model… $percent%';
  }

  @override
  String get sttVoiceModelReady => 'Voice model ready';

  @override
  String get sttVoiceModelFailed =>
      'Couldn\'t download the voice model. Tap to retry.';

  @override
  String get ttsDownloadVoice => 'Download neural voice';

  @override
  String ttsDownloadingVoice(Object percent) {
    return 'Downloading neural voice… $percent%';
  }

  @override
  String get ttsVoiceReady => 'Neural voice ready';

  @override
  String get ttsVoiceFailed =>
      'Couldn\'t download the neural voice. The system voice will be used meanwhile.';

  @override
  String get briefingTitle => 'Briefing';

  @override
  String get briefingSourcesTooltip => 'Sources';

  @override
  String get briefingGenerating => 'Generating…';

  @override
  String get briefingGenerateNow => 'Generate briefing now';

  @override
  String get briefingEmptyTitle => 'No briefing yet';

  @override
  String get briefingEmptyBody =>
      'Tap \"Generate briefing now\" and Axi will read your sources and summarize them on device.';

  @override
  String get briefingHeaderTitle => 'Morning briefing';

  @override
  String briefingGeneratedAt(String datetime) {
    return 'Generated on $datetime';
  }

  @override
  String get briefingLinkCopied => 'Link copied to clipboard';

  @override
  String get briefingScheduleTitle => 'Automatic briefing';

  @override
  String get briefingScheduleSubtitle =>
      'Generates the briefing every day at the chosen time. If the app is closed, you will get a notification to generate it with one tap.';

  @override
  String get briefingScheduleTimeLabel => 'Briefing time';

  @override
  String get chatDeleteMessage => 'Delete message';

  @override
  String get chatDeleteMessagePairNote =>
      'Your message and Axi\'s reply will be deleted.';

  @override
  String get chatDeleteConversation => 'Delete conversation';

  @override
  String get chatDeleteConversationTitle => 'Delete conversation?';

  @override
  String get chatDeleteConversationBody =>
      'This deletes the messages, the memories Axi derived from this conversation, and its voice notes on this device.';

  @override
  String get backupsNavTitle => 'Backups';

  @override
  String get backupsNavSubtitle => 'Create and restore copies of your data';

  @override
  String get backupsTitle => 'Backups';

  @override
  String get backupsCreateNow => 'Create backup now';

  @override
  String get backupsAutoSection => 'Automatic';

  @override
  String get backupsManualSection => 'Manual';

  @override
  String get backupsEmpty =>
      'No backups yet. LifeOS creates one automatically every day when you open the app.';

  @override
  String get backupsCreated => 'Backup created';

  @override
  String get backupsDeleted => 'Backup deleted';

  @override
  String get backupsDeleteTooltip => 'Delete backup';

  @override
  String get backupsPreRestoreLabel => 'Pre-restore copy (your previous data)';

  @override
  String get backupsRestoreTitle => 'Restore this backup?';

  @override
  String get backupsRestoreBody =>
      'Your current data is saved first as a \"pre-restore\" copy, so you can always come back to it from this list.';

  @override
  String get backupsRestoreConfirm => 'Restore';

  @override
  String get backupsRestored =>
      'Backup restored. Your previous data was saved as a pre-restore copy.';

  @override
  String backupsOperationFailed(String error) {
    return 'The operation failed: $error';
  }

  @override
  String get dataControlBusy => 'Wait until Axi finishes before doing this.';

  @override
  String get sectionDangerZone => 'Danger zone';

  @override
  String get wipeNavTitle => 'Delete all my data';

  @override
  String get wipeNavSubtitle =>
      'Erases your data on this device. Models and settings are kept.';

  @override
  String get wipeTitle => 'Delete all my data';

  @override
  String get wipeDeletesTitle => 'This will be deleted';

  @override
  String get wipeDeletesBody =>
      '• Your memory graph (facts, people, conversations, vectors)\n• Chat history\n• Voice notes stored on this device\n• Your last briefing, its schedule and sources\n• Reminders and their scheduled alarms';

  @override
  String get wipeKeepsTitle => 'This is kept';

  @override
  String get wipeKeepsBody =>
      '• Downloaded models (chat, voice, embeddings)\n• App settings (language, theme, onboarding)';

  @override
  String get wipeBackupFirst => 'Create a backup before deleting';

  @override
  String wipeTypePrompt(String word) {
    return 'Type $word to confirm';
  }

  @override
  String wipeCountdownButton(int seconds) {
    return 'Delete ($seconds)';
  }

  @override
  String get wipeConfirmButton => 'Delete everything';

  @override
  String get wipeInProgress => 'Deleting…';

  @override
  String get wipeDone => 'All your data on this device was deleted.';

  @override
  String wipePartialFailure(String targets) {
    return 'Some data could not be deleted: $targets';
  }
}
