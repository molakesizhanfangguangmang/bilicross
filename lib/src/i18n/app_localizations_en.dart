import 'app_localizations.dart';

/// English strings. Keys must stay in sync with [AppLocalizationsZh.data];
/// test/locale_test.dart checks both bundles for the same key set.
class AppLocalizationsEn extends AppLocalizations {
  const AppLocalizationsEn();

  @override
  String get code => kLocaleEnUS;

  static const Map<String, String> data = {
    // App and navigation
    'app.name': 'BiliCross',
    'app.internalBuild': 'Internal Build',
    'settings.animUnlocked': 'Animation tuning unlocked - see Advanced settings',
    'settings.animTitle': 'Page animation',
    'settings.animHint': 'Unlocked debug options; Android only',
    'settings.animDuration': 'Duration',
    'settings.animCurve': 'Curve',
    'settings.animCurve.sine': 'Softest',
    'settings.animCurve.quad': 'Soft',
    'settings.animCurve.cubic': 'Medium',
    'settings.animCurve.quart': 'Sharp',
    'settings.animCurve.expo': 'Sharpest',
    'settings.animStyle': 'Style',
    'settings.animStyle.expand': 'Expand',
    'settings.animStyle.fade': 'Fade',
    'settings.animStyle.scale': 'Scale',
    'risk.title': 'Request blocked by rate limiting',
    'risk.body': 'Bilibili returned -352 and rejected this request. '
        'Downloaded chunks are kept; "Resume" continues from the episode '
        'that stopped and does not re-download completed ones.',
    'risk.later': 'Leave it',
    'risk.resume': 'Resume',
    'manifest.title': 'Season',
    'manifest.summary': '{episodes} episodes · {sections} sections',
    'manifest.countHint': '{episodes} episodes · {sections} sections',
    'manifest.untitled': 'Untitled season',
    'manifest.untitledSection': 'Untitled section',
    'manifest.sectionEpisodes': '{count} episodes',
    'manifest.entryHint': 'This video belongs to the season; open it to pick episodes',
    'manifest.entryOpen': 'Choose episodes',
    'manifest.selectedReady': '{count} selected, ready to add',
    'manifest.enqueueSelected': 'Add tasks ({count} selected)',
    'manifest.preflighting': 'Checking {ready}/{total}',
    'manifest.preflight.missingQuality': 'No such quality',
    'manifest.preflight.unavailable': 'Unavailable',
    'manifest.preflight.riskControl': 'Rate limited',
    'settings.parallelPreflight': 'Parallel preflight',
    'settings.parallelPreflightHint':
        'On = 2 at a time; off = strictly sequential with a delay (safer, slower)',
    'manifest.nothingSelected': 'Select episodes to download first',
    'manifest.batchResult':
        'Added {enqueued}, skipped {skipped}, renamed {renamed}',
    'settings.duplicate': 'Duplicate files',
    'settings.duplicateHint':
        'What to do when the download folder already contains a file with the same name, or the queue has the same target',
    'settings.duplicate.skip': 'Skip',
    'settings.duplicate.overwrite': 'Overwrite',
    'settings.duplicate.rename': 'Auto rename',
    'spaceSheet.seasons': 'Seasons',
    'spaceSheet.series': 'Series',
    'spaceSheet.empty': 'This uploader has no public seasons or series',
    'about.testBuildWarning':
        'This build is for technical validation only. Use with caution, and do not distribute.',
    'nav.download': 'Download',
    'nav.tasks': 'Tasks',
    'nav.account': 'Account',
    'nav.settings': 'Settings',
    'app.initFailed': 'Initialization failed: {error}',
    'app.queueRunning': 'Queue running',
    'app.dartEngine': 'Dart engine',

    // Common
    'common.cancel': 'Cancel',
    'common.close': 'Close',
    'common.yes': 'Yes',
    'common.no': 'No',
    'common.save': 'Save',
    'common.remove': 'Remove',
    'common.clear': 'Clear',
    'common.open': 'Open',
    'common.browserNotOpened': 'Could not open the browser',
    'common.dash': '—',

    // About and updates
    'about.projectUrl': 'Project',
    'about.checkUpdate': 'Check for updates',
    'about.versionUnknown': 'Current version unknown',
    'about.version': 'Current version {version}',
    'about.upToDate': 'Already up to date',
    'about.checkFailed': 'Update check failed',
    'about.updateFound': 'Version {version} available',
    'about.download': 'Download',
    'about.openRelease': 'Open release page',

    // Account and authorization
    'account.title': 'Account & authorization',
    'account.cookieMissing': 'Not set',
    'account.cookieComplete': 'Complete',
    'account.cookieIncomplete': 'Incomplete',
    'account.written': 'Saved',
    'account.pasteCookie': 'Paste cookie',
    'account.importCookie': 'Import cookie.txt',
    'account.webLogin': 'Web login',
    'account.checkStatus': 'Check status',
    'account.clear': 'Clear',
    'account.webLoginHint': 'Web login opens the sign-in page inside the app and '
        'reads the cookie automatically when you are done; you can also keep '
        'pasting or importing instead.',
    'account.noBrowserHint': 'This platform has no built-in browser. Paste or '
        'import cookie.txt instead.',
    'account.webStatusTitle': 'Web account',
    'account.loggedIn': 'Logged in',
    'account.nickname': 'Nickname',
    'account.vip': 'VIP',
    'account.message': 'Response',
    'account.webOnlyHint': 'This status comes from the web cookie. It reflects '
        'the web account only, not whether the app token works.',
    'account.tokenMissing': 'Not obtained',
    'account.tokenReady': 'Obtained',
    'account.expiresAt': 'Expires at',
    'account.auth': 'Authorization',
    'account.openAuth': 'Authorize app',
    'account.cancelAuth': 'Cancel authorization',
    'account.authHint': 'Authorization completes in the system browser: open the '
        'link, confirm with the mobile app by scanning the QR code. The app '
        'polls every 2 seconds and times out after 5 minutes.',
    'account.emptyFile': 'The file is empty',
    'account.cookieWritten': 'Cookie saved',
    'account.authPageOpened': 'Authorization page opened. Confirm in the mobile app.',
    'account.browserFailed': 'Could not open the browser. Visit the authorization link manually.',

    // Membership status
    'vip.none': 'Not a member',
    'vip.annual': 'Annual member',
    'vip.monthly': 'Monthly member',
    'vip.general': 'Member',

    // Parse page
    'download.title': 'New download',
    'download.addressHint': 'Video, bangumi or part URL',
    'download.parse': 'Parse',
    'download.waiting': 'Waiting for parse',
    'download.waitingHint': 'After parsing you get the parts, video streams and '
        'audio streams to choose from.',
    'download.result': 'Parse result',
    'download.id': 'ID',
    'download.uploader': 'Uploader',
    'download.part': 'Part',
    'download.duration': 'Duration',
    'download.videoStreams': 'Video streams',
    'download.noVideo': 'Skip video (audio only)',
    'download.audioStreams': 'Audio streams',
    'download.noAudioTrack': 'This channel has no separate audio stream; video only.',
    'download.noAudio': 'Skip audio (video only)',
    'download.enqueueVideoAudio': 'Enqueue (video + audio)',
    'download.enqueueVideoOnly': 'Enqueue (video only)',
    'download.enqueueAudioOnly': 'Enqueue (audio only)',
    'download.needOneTrack': 'Select at least one track',
    'download.startNow': 'Start download now',
    'download.enqueuedStart': 'Added to the queue. Downloading.',
    'download.enqueuedWait': 'Added to the queue. Start it on the Tasks page.',

    // Tasks page
    'tasks.tabWaiting': 'Waiting ({count})',
    'tasks.tabRunning': 'Downloading ({count})',
    'tasks.tabDone': 'Downloaded ({count})',
    'tasks.stopAll': 'Stop all',
    'tasks.pauseAll': 'Pause all',
    'tasks.cleanDone': 'Clear done',
    'tasks.stopAllWaitingConfirm': 'Discard all {count} waiting tasks? Failed ones are kept for retry.',
    'tasks.stopAllRunningConfirm': 'Terminate all running tasks? Temp chunks will be removed and re-download needed.',
    'tasks.cleanDoneConfirm': 'Remove all {count} completed task records? Downloaded files on disk are untouched.',
    'tasks.groupProgress': '{done}/{total}',
    'tasks.title': 'Downloads',
    'tasks.emptyTitle': 'No tasks',
    'tasks.emptyHint': 'The queue tracks pending, downloading, muxing, done and '
        'failed states. Interrupted tasks resume from their breakpoint on the next launch.',
    'tasks.parallel': 'Parallel {count}',
    'tasks.queueRunning': 'running',
    'tasks.queueIdle': 'idle',
    'tasks.pending': 'Pending {count}',
    'tasks.startQueue': 'Start queue',
    'tasks.progress': 'Progress',
    'tasks.channel': 'Channel',
    'tasks.notRecorded': 'Not recorded',
    'tasks.pagePart': 'Part {page} · cid {cid}',
    'tasks.cidOnly': 'cid {cid}',
    'tasks.engine': 'Engine',
    'tasks.dartEngine': 'Dart built-in',
    'tasks.status': 'Status',
    'tasks.output': 'Output',
    'tasks.pause': 'Pause',
    'tasks.forceStop': 'Force stop',
    'tasks.resume': 'Resume',
    'tasks.retry': 'Retry',
    'tasks.retryMux': 'Retry muxing',
    'tasks.cleanup': 'Clean up',
    'tasks.forceStopConfirm': 'This stops "{title}" and deletes its downloaded '
        'fragments and partial output.',
    'tasks.forceStopWarning': 'Once deleted it cannot resume; you have to download it again.',
    'tasks.cleanedFiles': 'Removed {count} file(s)',
    'tasks.nothingToClean': 'Nothing to clean up',

    // Task stages
    'stage.pending': 'Pending',
    'stage.resolving': 'Resolving',
    'stage.downloading': 'Downloading',
    'stage.muxing': 'Muxing',
    'stage.paused': 'Paused',
    'stage.stopped': 'Stopped',
    'stage.done': 'Done',
    'stage.failed': 'Failed',

    // Task messages (shown on the task card "Status" line)
    'msg.interruptedOnExit': 'Interrupted on last exit; waiting to resume',
    'msg.pausedOnExit': 'Paused on last exit; tap Resume to continue',
    'msg.pausing': 'Pausing…',
    'msg.stopping': 'Stopping…',
    'msg.resuming': 'Resuming from the breakpoint',
    'msg.riskControl': 'Rate limited (-352), paused',
    'msg.paused': 'Paused; fragments kept. Tap Resume to continue.',
    'msg.stopped': 'Force stopped; removed {count} leftover file(s)',
    'msg.waitRetry': 'Waiting to retry',
    'msg.urlExpired': 'URL expired; re-parsing at the recorded quality',
    'msg.downloadVideo': 'Downloading video stream',
    'msg.downloadAudio': 'Downloading audio stream',
    'msg.singleTrackDone': 'Done (single track): {path}',
    'msg.muxing': 'Muxing audio and video',
    'msg.done': 'Done ({engine}): {path}',
    'msg.fragmentsRemoved': ' ({count} fragment(s) removed)',
    'msg.muxFailed': 'Muxing failed; fragments kept, retry later: {error}',
    'msg.singleTrackNoMux': 'This task downloaded a single track; nothing to mux',
    'msg.missingFragments': 'Missing video or audio fragments; download again',
    'msg.videoQualityGone': 'The recorded video quality ({quality}) was not returned this time',
    'msg.noVideoStream': 'No video stream returned this time',
    'msg.audioQualityGone': 'The recorded audio quality ({quality}) was not returned this time',

    // Errors
    'err.noSessdata': 'No SESSDATA field found in the content',
    'err.needWebCookie': 'Save a web cookie first',
    'err.engineMissing': 'The BBDownNext engine is not available yet; use the built-in Dart engine',
    'err.noTrack': 'No track selected for this task',
    'err.emptyVideo': 'Video fragments are empty',
    'err.emptyAudio': 'Audio fragments are empty',

    // Authorization status
    'auth.waiting': 'Waiting for confirmation in the browser',
    'auth.timeout': 'Authorization timed out; please start again',
    'auth.tokenReady': 'App token obtained',
    'auth.pollFailed': 'Polling failed: {error}',

    // Account notices
    'notice.cookieWritten': 'Web cookie saved',
    'notice.cookieWrittenMissing': 'Web cookie saved, but missing {fields}',
    'notice.cookieCleared': 'Web cookie cleared',
    'notice.noCookie': 'No web cookie configured',
    'notice.tokenInvalid': 'App token expired; please sign in again',
    'notice.cookieInvalid': 'Cookie expired; please sign in again',

    // Qualities
    'quality.100': 'AI restoration',
    'quality.126': 'Dolby Vision',
    'quality.30250': 'Dolby Atmos',
    'quality.30251': 'Hi-Res lossless',
    'quality.fallbackVideo': 'Quality {id}',
    'quality.fallbackAudio': 'Audio {id}',
    'quality.unknownBitrate': 'Unknown bitrate',

    // Settings
    'settings.title': 'Settings',
    'settings.download': 'Download',
    'settings.downloadDir': 'Download folder',
    'settings.chooseDir': 'Choose folder',
    'settings.quality': 'Default video quality',
    'settings.audio': 'Default audio quality',
    'settings.parallelTasks': 'Parallel tasks',
    'settings.partsPerFile': 'Connections per file',
    'settings.partsHint': 'Splits one file into several ranges downloaded in '
        'parallel; 1 means a single connection. Falls back to a single '
        'connection when the server rejects ranges or the file is small.',
    'settings.preferApp': 'Prefer the app channel for parsing',
    'settings.preferAppHint': 'Requires an app token; falls back to the web channel on failure',
    'settings.grpcHdr': 'Fetch HDR Vivid via gRPC',
    'settings.grpcHint': 'Requests gRPC PlayView once more after parsing succeeds '
        'to add quality 129 (HDR Vivid). Requires an app token; failures are '
        'logged only and never change the original result.',
    'settings.mux': 'Muxing',
    'settings.builtinMux': 'Built-in',
    'settings.ffmpegReady': 'ffmpeg ready',
    'settings.ffmpegPath': 'ffmpeg executable path',
    'settings.ffmpegPathHint': 'Leave empty to search PATH',
    'settings.detectFfmpeg': 'Detect ffmpeg',
    'settings.preferFfmpeg': 'Prefer ffmpeg for muxing',
    'settings.preferFfmpegHint': 'Off always uses the built-in fragment muxer; '
        'the other path still acts as a fallback either way.',
    'settings.muxExplain': 'Muxing only copies streams, never re-encodes. '
        'Without ffmpeg the built-in muxer interleaves the two streams into an '
        'MP4 by moof/mdat, moving sample data as-is. Only when both paths fail '
        'are fragments kept and reported on the task, and you can retry muxing '
        'from the tasks page.',
    'settings.network': 'Network & advanced',
    'settings.proxy': 'Proxy',
    'settings.uaHint': 'Leave empty to use the built-in short string Mozilla/5.0',
    'settings.uaHelper': 'Applies to web requests and web-URL downloads only; '
        'mobile download URLs always use the built-in short string.',
    'settings.appKeyHint': 'AppKey/AppSec ship with the client and cannot really '
        'be kept secret; they are only used to request an app auth code.',
    'settings.engine': 'Parse engine',
    'settings.engineDart': 'Dart built-in',
    'settings.engineDartDesc': 'All tasks currently run on the built-in Dart engine.',
    'settings.engineFuture': 'The BBDownNext engine (bundled, local serve mode) '
        'is not wired up yet; once it is you can switch per task.',
    'settings.engineOnlyDart': 'Only the built-in Dart engine is available on this platform.',
    'settings.diagnostics': 'Diagnostics',
    'settings.logs': 'Run log',
    'settings.logsHint': 'Which parse channel was used, why it fell back, and '
        'download/mux details',
    'settings.logFile': 'Log file: {path}',
    'settings.save': 'Save settings',
    'settings.about': 'About',
    'settings.aboutHint': 'Version, project URL and update check',
    'settings.saved': 'Settings saved',
    'settings.language': 'Language',
    'settings.languageSystem': 'Follow system',
    'settings.languageZh': '简体中文',
    'settings.languageEn': 'English',
    'settings.advanced': 'Advanced',
    'settings.advancedHint': 'Splash screen, logs and about',

    // Splash screen
    'splash.title': 'Splash screen',
    'splash.enable': 'Show splash screen',
    'splash.enableHint': 'Show your own image while starting up',
    'splash.imageSet': 'Image set',
    'splash.imageNone': 'No image chosen',
    'splash.pickImage': 'Choose image',
    'splash.clearImage': 'Clear image',
    'splash.imageSaved': 'Saved. Takes effect on next launch',
    'splash.imageCleared': 'Cleared',
    'splash.imageFailed': 'Failed to save the image',
    'splash.imageFailedWith': 'Failed to save the image: {error}',
    'splash.seconds': 'Hold for {value} s',
    'splash.hint':
        'The image is copied into the app data folder, so moving or deleting '
        'the original does not affect it.',

    // Log page
    'logs.title': 'Run log',
    'logs.copyAll': 'Copy all',
    'logs.empty': 'No logs yet',
    'logs.copied': 'Copied {count} entries',
    'logs.clear': 'Clear',
    'logs.verbose': 'Verbose log',
    'logs.verboseNoFile': 'Logs request URLs and status codes; this device cannot '
        'write a log file, so entries stay in memory.',
    'logs.verboseWithFile': 'Logs request URLs and status codes, appending to {path}',
    'logs.verboseOn': 'Verbose logging on (credentials always masked)',
    'logs.verboseOff': 'Verbose logging off',
    'logs.section': 'Log',

    // Web login
    'webLogin.title': 'Web login',
    'webLogin.readCookie': 'Read cookie',
    'webLogin.hint': 'The cookie is read automatically after sign-in; you can '
        'also tap Read cookie at the top right.',
    'webLogin.loadFailed': 'Page failed to load: {error}',
    'webLogin.noSessdata': 'No SESSDATA yet. Finish signing in first.',
    'webLogin.readFailed': 'Failed to read cookie: {error}',

    // QR sign-in
    'qr.entry': 'Scan QR to sign in',
    'qr.entryHint': 'Shows a QR code inside the app; scan it with the Bilibili '
        'mobile app. Only the web cookie is taken.',
    'qr.entriesHint': 'Two ways in: scan a QR code, or use web sign-in / paste a '
        'cookie / import cookie.txt.',
    'qr.title': 'QR sign-in',
    'qr.scanHint': 'Scan the QR code with the Bilibili mobile app, then confirm '
        'the sign-in on your phone.',
    'qr.loading': 'Requesting QR code…',
    'qr.waitingScan': 'Waiting for scan',
    'qr.waitingConfirm': 'Scanned — confirm on your phone',
    'qr.success': 'Signed in',
    'qr.expired': 'QR code expired, refresh it',
    'qr.canceled': 'QR sign-in canceled',
    'qr.timeout': 'Timed out — refresh the QR code',
    'qr.networkError': 'Network error, retrying; web sign-in still works',
    'qr.unavailable': 'QR service unavailable — use web sign-in or paste a cookie',
    'qr.incomplete': 'The cookie from the QR code is missing {fields}; scan again '
        'or use web sign-in',
    'qr.refresh': 'Refresh QR code',
    'qr.cancel': 'Cancel sign-in',
    'qr.back': 'Back to account',
    'qr.fallbackHint': 'A failed scan does not affect the other ways in: web '
        'sign-in, pasting a cookie and importing cookie.txt all still work.',

    // Backup & restore (Windows installer and portable editions)
    'settings.backup': 'Backup & restore',
    'backup.hint': 'Export your account information, settings and tasks to move '
        'them between the installer and portable editions. Restoring overwrites '
        'the current data.',
    'backup.export': 'Export backup',
    'backup.restore': 'Restore from backup',
    'backup.working': 'Working…',
    'backup.exported': 'Backup exported: {path}',
    'backup.confirmTitle': 'Confirm restore',
    'backup.confirmBody': 'This backup comes from {source}. Restoring overwrites '
        'the current account, settings and tasks. A rollback copy is saved first. '
        'Continue?',
    'backup.confirmOk': 'Overwrite and restore',
    'backup.restored': 'Restored {count} items',
    'backup.pending': '{count} tasks point to a folder that no longer exists and '
        'need manual attention',
    'backup.failed': 'Restore failed: {error}',
    'backup.noKey': 'This build has no backup key configured, exporting is not '
        'possible',

    // Tray and close behaviour (Windows)
    'tray.show': 'Show window',
    'tray.folder': 'Open download folder',
    'tray.pauseAll': 'Pause all tasks',
    'tray.quit': 'Quit',
    'settings.closeBehavior': 'Close behaviour',
    'settings.closeToTray': 'Minimize to tray on close',
    'settings.closeToExit': 'Exit on close',
    'quit.title': 'Confirm exit',
    'quit.body': 'Tasks are still running and will be interrupted. Quit anyway?',
    'quit.ok': 'Quit',

    // Startup environment self-check
    'startup.title': 'Cannot start',
    'startup.body': 'A required component is missing from the environment. '
        'Please follow the notes below, then open the app again.',
    'startup.check.dataDir': 'Data folder is writable',
    'startup.check.assets': 'Application resources readable',
    'startup.check.webview2': 'WebView2 runtime',
    'startup.reason': 'Reason: {detail}',
    'startup.webview2Hint': 'Web login needs the Microsoft Edge WebView2 runtime '
        'installed on the system. It is available as an Evergreen installer from '
        'Microsoft.',
    'startup.webview2Download': 'Open download page',
    'startup.exit': 'Exit',
  };

  @override
  Map<String, String> get values => data;
}
