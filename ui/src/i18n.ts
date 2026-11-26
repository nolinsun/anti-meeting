export type UiLang = "en" | "zh";

export interface UiStrings {
  tabRecord: string;
  tabHistoryCount: (n: number) => string;
  statusRecording: (dur: string) => string;
  statusFinalizing: string;
  statusStarting: string;
  statusReady: string;
  statusNotInitialized: string;
  statusMacOnly: string;
  statusConnecting: string;
  langToggleAria: string;
  actionFailed: string;
  hostConnectFailed: (msg: string) => string;
  macosOnlyTitle: string;
  macosOnlyDesc: string;
  runtimeInitTitle: string;
  runtimeInitDesc: string;
  runtimeUpdateTitle: string;
  runtimeUpdateDesc: string;
  runtimeInitBtn: string;
  runtimeUpdateBtn: string;
  runtimeBuildingBtn: string;
  runtimeMissingToolchain: string;
  runtimeInitDoneToast: string;
  runtimeUpdateDoneToast: string;
  daemonNotReadyTitle: string;
  retryConnect: string;
  captureModeTitle: string;
  modeDualTitle: string;
  modeDualDesc: string;
  modeMicTitle: string;
  modeMicDesc: string;
  draftTitlePlaceholder: string;
  startingDual: string;
  startingMic: string;
  finalizingChunks: string;
  stopAndFinalize: string;
  startDual: string;
  startMic: string;
  committedChunks: (n: number) => string;
  speakerMeMic: string;
  speakerRemoteSys: string;
  liveHint: string;
  permAudioTitle: string;
  checkAudioPerm: string;
  restartAndRecheck: string;
  restartAndRecheckTitle: string;
  privacySettings: string;
  privacySettingsTitle: string;
  openPrivacySettings: string;
  micLabel: string;
  defaultInputDevice: string;
  sysAudioLabel: string;
  defaultOutputDevice: string;
  audioPlayingBadge: string;
  permGranted: string;
  permPending: string;
  permDenied: string;
  sysVerified: string;
  sysSilentOrDenied: string;
  sysTapFailed: string;
  sysTapReadyPending: string;
  sysPendingCheck: string;
  dismissHintAria: string;
  sysPillGranted: string;
  sysPillSilentOrDenied: string;
  sysPillTapFailed: string;
  sysPillWaiting: string;
  micBannerTitle: string;
  micBannerDenied: (st: string) => string;
  micBannerPrompt: (st: string) => string;
  grantMic: string;
  sysBannerFailedTitle: string;
  sysBannerSilentTitle: string;
  sysBannerFailedDesc: string;
  sysBannerSilentDesc: string;
  recheckSysAudio: string;
  probeOutcomeGranted: string;
  probeOutcomeSilent: string;
  probeOutcomeTapFailed: string;
  probeOutcomeTimeout: string;
  probeOutcomeOtherPlaying: string;
  probeOutcomeTapReadyIdle: string;
  probeBusyRetry: string;
  probeFailed: (err: string) => string;
  probeAfterRestartFailed: (err: string) => string;
  restartedSysOk: string;
  restartedMicOk: string;
  restartedMicPrompt: string;
  restartedMicStillDenied: string;
  micPromptToast: string;
  stoppedEmptyToast: string;
  stoppedPartialError: string;
  stoppedPartialToast: string;
  stoppedOkToast: string;
  postStopTitle: (title: string) => string;
  postStopMeta: (dur: string, chunks: number) => string;
  generatingInSession: string;
  generateNotesNewSession: string;
  viewDetails: string;
  dismiss: string;
  recentRecordingsTitle: string;
  allCountBtn: (n: number) => string;
  emptyMeetingsLive: string;
  modeDualShort: string;
  modeMicShort: string;
  modeDualFull: string;
  modeMicFull: string;
  chunksMeta: (chunks: number, size: string) => string;
  badgeRecording: string;
  badgeFinalizing: string;
  badgeEmpty: string;
  badgeGenerating: string;
  badgePartial: string;
  badgeNotesDone: string;
  badgeTranscribed: (done: number, total: number) => string;
  badgePending: (chunks: number) => string;
  btnResumeMissing: (done: number, total: number) => string;
  btnRegenerateNotes: string;
  btnGenerateNotes: string;
  delete: string;
  confirmDelete: string;
  cancel: string;
  save: string;
  rename: string;
  meetingDeletedToast: string;
  titleUpdatedToast: string;
  copiedToast: string;
  copyFailedToast: string;
  notesGeneratedToast: string;
  jobAlreadyRunningToast: string;
  lockInvalidBanner: string;
  lockInvalidToast: string;
  lockTimeoutBanner: (detail: string) => string;
  lockTimeoutToast: string;
  startedNewSessionIdToast: string;
  startedNewSessionToast: string;
  sentCurrentChatToast: string;
  copiedPromptTitle: string;
  copiedPromptReasonSameChat: (detail: string) => string;
  copiedPromptReasonNoCap: (detail: string) => string;
  copyAgain: string;
  generateInCurrentChat: string;
  copiedPromptToast: string;
  globalViewBannerTitle: string;
  globalViewBannerDesc: string;
  btnCopyPrompt: string;
  copiedPromptGlobalView: string;
  copiedPromptDirectToast: string;
  liveGapTitle: string;
  liveGapSummaryGaps: (count: number, start: string, end: string, reason: string) => string;
  liveGapSummaryFailed: (count: number) => string;
  liveGapTail: string;
  retentionTitle: string;
  retentionDesc: string;
  retentionManual: string;
  retentionAfterNotes: string;
  retentionDays7: string;
  retentionSavedCleanedToast: (count: number, size: string) => string;
  retentionSavedToast: string;
  audioCleanedToast: (size: string) => string;
  searchPlaceholder: string;
  noSearchResults: string;
  noHistoryMeetings: string;
  historySnippet: (chunks: number, statusText: string) => string;
  snippetStatusGenerating: string;
  snippetStatusPartial: string;
  snippetStatusHasNotes: string;
  snippetStatusTranscribed: (done: number, total: number) => string;
  snippetStatusUntranscribed: string;
  listBadgeNotes: string;
  listBadgeTranscript: string;
  listBadgePending: string;
  backToMeetings: string;
  loadingDetail: string;
  durationLabel: (dur: string) => string;
  chunksLabel: (done: number, total: number) => string;
  audioLabel: (text: string) => string;
  audioCleanedLabel: string;
  speakerDistLabel: (me: string, remote: string, both: string) => string;
  partialDetailTitle: string;
  partialDetailGaps: (n: number) => string;
  partialDetailFailed: (n: number) => string;
  tabNotes: string;
  tabTranscript: string;
  copyMarkdown: string;
  confirmCleanupBtn: (chunks: number) => string;
  cleanupAudioBtn: (size: string) => string;
  truncatedTitle: string;
  truncatedChunksSaved: string;
  truncatedFileSaved: string;
  emptyNotesTitle: string;
  emptyTranscriptTitle: string;
  emptyDetailDesc: (dur: string, chunks: number, done: number) => string;
  close: string;
  gapReason: (reason: string) => string;
}

const EN: UiStrings = {
  tabRecord: "Record",
  tabHistoryCount: (n) => `History (${n})`,
  statusRecording: (dur) => `Recording ${dur}`,
  statusFinalizing: "Finalizing",
  statusStarting: "Starting",
  statusReady: "Ready",
  statusNotInitialized: "Setup Required",
  statusMacOnly: "macOS Only",
  statusConnecting: "Connecting",
  langToggleAria: "Switch display language",
  actionFailed: "Operation failed",
  hostConnectFailed: (msg) => `Failed to connect to host view: ${msg}`,
  macosOnlyTitle: "macOS Only for Audio Recording",
  macosOnlyDesc:
    "Local dual-track and microphone recording relies on macOS Core Audio Process Tap & AVFoundation and is not available on Windows or Linux. You can still browse existing history and notes.",
  runtimeInitTitle: "Initialize Local macOS Recorder",
  runtimeInitDesc:
    "To stay lightweight and Apple-notarization-free, MeetingRecorder.app is compiled locally on your Mac from bundled Swift sources on first use (takes ~20–40s).",
  runtimeUpdateTitle: "Local Recorder Update Available",
  runtimeUpdateDesc:
    "Bundled Swift recorder sources were updated. Rebuild locally to apply the latest recorder.",
  runtimeInitBtn: "Initialize Local Recorder",
  runtimeUpdateBtn: "Rebuild Local Recorder",
  runtimeBuildingBtn: "Building on this Mac...",
  runtimeMissingToolchain:
    "Xcode Command Line Tools are required. Run `xcode-select --install` in Terminal, then click retry.",
  runtimeInitDoneToast: "Local recorder built and ready",
  runtimeUpdateDoneToast: "Local recorder updated and ready",
  daemonNotReadyTitle: "Recorder daemon not ready",
  retryConnect: "Retry Connection",
  captureModeTitle: "Capture Mode",
  modeDualTitle: "Dual Track",
  modeDualDesc: "System Audio + Mic (Zoom / Meet / Teams / Feishu / Browser)",
  modeMicTitle: "Mic Only",
  modeMicDesc: "Microphone only (in-person talks / voice notes)",
  draftTitlePlaceholder: "Optional: meeting title (leave blank for timestamp)",
  startingDual: "Starting dual-track capture...",
  startingMic: "Starting microphone...",
  finalizingChunks: "Finalizing audio chunks...",
  stopAndFinalize: "Stop & Finalize",
  startDual: "Start Dual-Track Recording",
  startMic: "Start Mic-Only Recording",
  committedChunks: (n) => `${n} chunk${n === 1 ? "" : "s"} committed (~5 min/chunk)`,
  speakerMeMic: "Me (Microphone)",
  speakerRemoteSys: "Remote (System Audio)",
  liveHint:
    "Recording runs independently in the background—switch conversations freely. Click \"Generate Notes\" to transcribe in a dedicated session.",
  permAudioTitle: "Audio Permissions & Devices",
  checkAudioPerm: "Check Permissions",
  restartAndRecheck: "Restart & Recheck",
  restartAndRecheckTitle: "Restart recorder daemon and re-verify permissions",
  privacySettings: "Privacy Settings",
  privacySettingsTitle: "Open macOS Privacy Settings",
  openPrivacySettings: "Open Privacy Settings",
  micLabel: "Microphone",
  defaultInputDevice: "Default Input Device",
  sysAudioLabel: "System Audio",
  defaultOutputDevice: "Default Output Device",
  audioPlayingBadge: "Audio Playing",
  permGranted: "Granted",
  permPending: "Pending",
  permDenied: "Denied",
  sysVerified: "Audio Verified",
  sysSilentOrDenied: "Silent / Denied",
  sysTapFailed: "Tap Failed",
  sysTapReadyPending: "Tap Ready · Unverified",
  sysPendingCheck: "Not Checked",
  dismissHintAria: "Dismiss message",
  sysPillGranted: "System Audio Active",
  sysPillSilentOrDenied: "System Audio Silent/Denied",
  sysPillTapFailed: "System Audio Degraded",
  sysPillWaiting: "Waiting for System Audio",
  micBannerTitle: "Microphone Permission Required (MeetingRecorder)",
  micBannerDenied: (st) =>
    `Status: ${st}. Enable MeetingRecorder in System Settings → Privacy & Security → Microphone (if already enabled after a rebuild, toggle it off and on), then click "Restart & Recheck".`,
  micBannerPrompt: (st) =>
    `Status: ${st}. Click "Grant Microphone" or enable MeetingRecorder in System Settings → Privacy & Security → Microphone.`,
  grantMic: "Grant Microphone",
  sysBannerFailedTitle: "System Audio Capture Failed (Fell Back to Mic Only)",
  sysBannerSilentTitle: "No System Audio Detected (Muted or Denied)",
  sysBannerFailedDesc:
    "System audio tap failed to start or reconnect. Your mic track is still recorded; check System Audio Recording Only permission or output device.",
  sysBannerSilentDesc:
    "Other apps appear to be playing audio, but the system track is silent. Confirm unmuted output and enable MeetingRecorder under System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only.",
  recheckSysAudio: "Recheck",
  probeOutcomeGranted: "System audio signal captured; dual-track permission verified.",
  probeOutcomeSilent:
    "System audio captured pure silence: enable MeetingRecorder under System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, or verify audio is unmuted, then click \"Restart & Recheck\".",
  probeOutcomeTapFailed:
    "System audio tap failed to start. Check System Audio Recording Only permission or your default output device.",
  probeOutcomeTimeout:
    "System audio tap timed out before verification completed. Please retry or restart the daemon.",
  probeOutcomeOtherPlaying:
    "System audio tap is ready, though no non-silent signal arrived during the probe. Retry or check mute status.",
  probeOutcomeTapReadyIdle:
    "System audio tap is ready (no other app audio playing right now). Play audio and click \"Check Permissions\", or start recording directly.",
  probeBusyRetry: "Recorder daemon is busy or probe did not complete; please retry shortly.",
  probeFailed: (err) => `System audio check failed: ${err}`,
  probeAfterRestartFailed: (err) => `System audio check failed after restart: ${err}`,
  restartedSysOk: "Daemon restarted; system audio permission ready",
  restartedMicOk: "Daemon restarted; microphone permission ready",
  restartedMicPrompt: "Daemon restarted; click \"Grant Microphone\" to authorize",
  restartedMicStillDenied:
    "Daemon restarted, still no mic permission. Toggle MeetingRecorder off/on in Privacy Settings and retry.",
  micPromptToast: "Please click Allow in the macOS microphone prompt",
  stoppedEmptyToast: "No audio captured (empty recording)",
  stoppedPartialError: "Some chunks failed or device interrupted; available audio was saved",
  stoppedPartialToast: "Saved partial recording chunks",
  stoppedOkToast: "Recording finalized safely",
  postStopTitle: (title) => `Saved: ${title}`,
  postStopMeta: (dur, chunks) => `${dur} · ${chunks} chunk${chunks === 1 ? "" : "s"}`,
  generatingInSession: "Generating in session...",
  generateNotesNewSession: "Generate Notes (New Session)",
  viewDetails: "View Details",
  dismiss: "Dismiss",
  recentRecordingsTitle: "Recent Recordings",
  allCountBtn: (n) => `All (${n})`,
  emptyMeetingsLive: "No recordings yet. Click above to start your first recording.",
  modeDualShort: "Dual",
  modeMicShort: "Mic",
  modeDualFull: "Dual Track",
  modeMicFull: "Mic Only",
  chunksMeta: (chunks, size) => `${chunks} chunk${chunks === 1 ? "" : "s"} · ${size}`,
  badgeRecording: "Recording",
  badgeFinalizing: "Finalizing",
  badgeEmpty: "Empty",
  badgeGenerating: "Generating Notes",
  badgePartial: "Partial",
  badgeNotesDone: "Notes Ready",
  badgeTranscribed: (done, total) => `Transcribed ${done}/${total}`,
  badgePending: (chunks) => `Pending (${chunks})`,
  btnResumeMissing: (done, total) => `Resume (${done}/${total})`,
  btnRegenerateNotes: "Regenerate Notes",
  btnGenerateNotes: "Generate Notes",
  delete: "Delete",
  confirmDelete: "Confirm Delete",
  cancel: "Cancel",
  save: "Save",
  rename: "Rename",
  meetingDeletedToast: "Meeting deleted",
  titleUpdatedToast: "Title updated",
  copiedToast: "Copied to clipboard",
  copyFailedToast: "Copy failed; please select and copy manually",
  notesGeneratedToast: "Meeting notes generated",
  jobAlreadyRunningToast: "Notes are already being generated in another session",
  lockInvalidBanner: "Unexpected job lock state; generation was not triggered. Please retry.",
  lockInvalidToast: "Job lock state error, please retry",
  lockTimeoutBanner: (detail) => `Timed out verifying generation job lock (${detail}). Please retry.`,
  lockTimeoutToast: "Job lock check timed out",
  startedNewSessionIdToast: "Started dedicated session to generate notes",
  startedNewSessionToast: "Started generating notes in a new session",
  sentCurrentChatToast: "Sent generation prompt to current chat",
  copiedPromptTitle: "Copied \"Generate Notes\" Prompt",
  copiedPromptReasonSameChat: (detail) =>
    `Failed to launch dedicated background session (${detail}). Prompt copied—paste into a new chat or click "Generate in Current Chat".`,
  copiedPromptReasonNoCap: (detail) =>
    `This view cannot auto-send messages (${detail}). Open Meeting Notes from the side pane "+" menu or paste the copied prompt into any chat.`,
  copyAgain: "Copy Again",
  generateInCurrentChat: "Generate in Current Chat",
  copiedPromptToast: "Cannot start new session directly; prompt copied",
  globalViewBannerTitle: "Global View (Copy-Only for Notes)",
  globalViewBannerDesc:
    "This left-sidebar view is not attached to a conversation, so one-click session launch is unavailable. To generate notes directly, open Meeting Notes from a conversation's right side pane (\"+\" → Meeting Notes), or click \"Copy Prompt\" and paste into any chat.",
  btnCopyPrompt: "Copy Prompt",
  copiedPromptGlobalView:
    "Prompt copied to clipboard. Paste it into any chat to generate notes, or open Meeting Notes from a conversation's right side pane (\"+\" → Meeting Notes) for one-click generation.",
  copiedPromptDirectToast: "Prompt copied—paste into any chat",
  liveGapTitle: "Audio gap detected during recording",
  liveGapSummaryGaps: (count, start, end, reason) =>
    `${count} audio gap${count === 1 ? "" : "s"} recorded (latest: ${start}–${end}, ${reason})`,
  liveGapSummaryFailed: (count) => `${count} chunk${count === 1 ? "" : "s"} failed to write`,
  liveGapTail: ". Remaining audio continues recording and will be noted faithfully.",
  retentionTitle: "Raw Audio Retention",
  retentionDesc:
    "Only removes raw .m4a files while keeping notes, transcripts & speaker stats. Untranscribed audio is never auto-deleted.",
  retentionManual: "Keep forever (manual cleanup)",
  retentionAfterNotes: "Auto-clean after notes generated",
  retentionDays7: "Keep 7 days (notes-completed only)",
  retentionSavedCleanedToast: (count, size) =>
    `Policy saved; auto-cleaned raw audio for ${count} meeting${count === 1 ? "" : "s"} (freed ${size})`,
  retentionSavedToast: "Audio retention policy updated",
  audioCleanedToast: (size) => `Cleaned raw audio (freed ${size})`,
  searchPlaceholder: "Search titles, notes, or transcripts...",
  noSearchResults: "No matching meetings",
  noHistoryMeetings: "No meeting history yet",
  historySnippet: (chunks, statusText) =>
    `${chunks} chunk${chunks === 1 ? "" : "s"} · ${statusText}`,
  snippetStatusGenerating: "Generating notes",
  snippetStatusPartial: "Partial",
  snippetStatusHasNotes: "Notes ready",
  snippetStatusTranscribed: (done, total) => `Transcribed ${done}/${total}`,
  snippetStatusUntranscribed: "Untranscribed",
  listBadgeNotes: "Notes",
  listBadgeTranscript: "Transcript",
  listBadgePending: "Pending",
  backToMeetings: "Back to Meetings",
  loadingDetail: "Loading meeting details...",
  durationLabel: (dur) => `Duration ${dur}`,
  chunksLabel: (done, total) => `Chunks ${done}/${total}`,
  audioLabel: (text) => `Audio ${text}`,
  audioCleanedLabel: "Cleaned",
  speakerDistLabel: (me, remote, both) => `Speakers: Me ${me} · Remote ${remote} · Overlap ${both}`,
  partialDetailTitle: "Partial Recording (Audio or Chunk Gaps)",
  partialDetailGaps: (n) => `${n} gap${n === 1 ? "" : "s"}`,
  partialDetailFailed: (n) => `${n} failed chunk${n === 1 ? "" : "s"}`,
  tabNotes: "Notes",
  tabTranscript: "Transcript",
  copyMarkdown: "Copy Markdown",
  confirmCleanupBtn: (chunks) => `Confirm Clean ${chunks} Chunk${chunks === 1 ? "" : "s"}`,
  cleanupAudioBtn: (size) => `Clean Raw Audio (${size})`,
  truncatedTitle: "Content truncated in view",
  truncatedChunksSaved: "Full chunk files saved locally",
  truncatedFileSaved: "Full file saved locally",
  emptyNotesTitle: "No Meeting Notes Yet",
  emptyTranscriptTitle: "No Transcript Yet",
  emptyDetailDesc: (dur, chunks, done) =>
    `Recorded ${dur} (${chunks} audio chunk${chunks === 1 ? "" : "s"}${done > 0 ? ` · ${done} transcribed` : ""}).`,
  close: "Close",
  gapReason: (reason) => {
    switch (reason) {
      case "audio_device_changed":
        return "Audio device changed";
      case "audio_device_lost":
        return "Audio device lost";
      case "system_audio_tap_failed":
        return "System audio tap failed";
      case "system_audio_reconnecting":
        return "System audio reconnecting";
      case "system_audio_device_changed":
        return "Output device changed";
      case "system_audio_silent":
        return "System audio silent";
      default:
        return reason || "Unknown reason";
    }
  },
};

const ZH: UiStrings = {
  tabRecord: "录制",
  tabHistoryCount: (n) => `历史 (${n})`,
  statusRecording: (dur) => `录制中 ${dur}`,
  statusFinalizing: "封包中",
  statusStarting: "启动中",
  statusReady: "就绪",
  statusNotInitialized: "待初始化",
  statusMacOnly: "仅限 macOS",
  statusConnecting: "待连接",
  langToggleAria: "切换界面语言",
  actionFailed: "操作失败",
  hostConnectFailed: (msg) => `连接宿主视图失败：${msg}`,
  macosOnlyTitle: "本机录音仅支持 macOS",
  macosOnlyDesc:
    "双轨与麦克风录制依赖 macOS Core Audio Process Tap 与 AVFoundation，暂不支持 Windows 或 Linux；历史纪要与逐字稿仍可正常查阅。",
  runtimeInitTitle: "初始化本机 macOS 录音组件",
  runtimeInitDesc:
    "为保持轻量化并免除 Apple 公证拦截，首次使用时将直接在本机从随附 Swift 源码编译并签名 MeetingRecorder.app（约需 20–40 秒）。",
  runtimeUpdateTitle: "检测到本机录音组件更新",
  runtimeUpdateDesc: "随插件附带的 Swift 源码已更新，建议重新本机编译以启用最新版本。",
  runtimeInitBtn: "初始化本机录音组件",
  runtimeUpdateBtn: "更新本机录音组件",
  runtimeBuildingBtn: "正在本机编译...",
  runtimeMissingToolchain:
    "需要先安装 Xcode Command Line Tools：请在终端执行 `xcode-select --install`，完成后重试。",
  runtimeInitDoneToast: "本机录音组件编译完成并已就绪",
  runtimeUpdateDoneToast: "本机录音组件已更新并就绪",
  daemonNotReadyTitle: "采集守护进程未就绪",
  retryConnect: "重试连接",
  captureModeTitle: "采集方式",
  modeDualTitle: "双轨录制",
  modeDualDesc: "系统音频 + 麦克风（Zoom / 飞书 / 腾讯 / Meet / 浏览器）",
  modeMicTitle: "仅麦克风",
  modeMicDesc: "仅采集麦克风（线下讨论 / 语音笔记）",
  draftTitlePlaceholder: "可选：输入会议标题（留空按时间命名）",
  startingDual: "正在启动双轨采集...",
  startingMic: "正在启动麦克风...",
  finalizingChunks: "正在封包音频切片...",
  stopAndFinalize: "停止录制并封包",
  startDual: "开始双轨录制",
  startMic: "开始仅麦克风录制",
  committedChunks: (n) => `已提交 ${n} 个切片（~5 分钟/片）`,
  speakerMeMic: "我方（麦克风）",
  speakerRemoteSys: "对方（系统音频）",
  liveHint:
    "录音在后台独立运行，可随时继续或切换其他 Antigravity 会话；点击「生成纪要」会自动在新独立会话中转写汇总。",
  permAudioTitle: "音频权限与设备",
  checkAudioPerm: "检测音频权限",
  restartAndRecheck: "重启并重检",
  restartAndRecheckTitle: "重启采集服务后重新检测",
  privacySettings: "隐私设置",
  privacySettingsTitle: "系统隐私设置",
  openPrivacySettings: "打开隐私设置",
  micLabel: "麦克风",
  defaultInputDevice: "默认输入设备",
  sysAudioLabel: "系统音频",
  defaultOutputDevice: "默认输出设备",
  audioPlayingBadge: "检测到播音",
  permGranted: "已授权",
  permPending: "待授权",
  permDenied: "未授权",
  sysVerified: "已验证有声",
  sysSilentOrDenied: "静音或未授权",
  sysTapFailed: "Tap 失败",
  sysTapReadyPending: "通道就绪 · 待有声验证",
  sysPendingCheck: "待检测",
  dismissHintAria: "关闭提示",
  sysPillGranted: "系统音频已捕获",
  sysPillSilentOrDenied: "系统音频静音/未授权",
  sysPillTapFailed: "系统音频降级",
  sysPillWaiting: "等待系统音",
  micBannerTitle: "需要麦克风权限（MeetingRecorder）",
  micBannerDenied: (st) =>
    `当前状态：${st}。请在「系统设置 → 隐私与安全性 → 麦克风」中勾选 MeetingRecorder；若开关已是开启状态（常见于重签后），请先关闭再重新开启，然后点击「重启并重检」。`,
  micBannerPrompt: (st) =>
    `当前状态：${st}。请点击「授权麦克风」，或在系统设置麦克风列表中勾选 MeetingRecorder。`,
  grantMic: "授权麦克风",
  sysBannerFailedTitle: "系统音频捕获失败（已自动降级为仅麦克风）",
  sysBannerSilentTitle: "未检测到系统音频（输出静音或未授权）",
  sysBannerFailedDesc:
    "系统音频 Tap 启动或重连失败，本次保留我方麦克风声轨，请检查「仅系统音频录制」权限或输出设备。",
  sysBannerSilentDesc:
    "检测到其他应用可能正在播音但系统轨无声。请确认未静音，并在「系统设置 → 隐私与安全性 → 录屏与系统录音 → 仅系统音频录制」勾选 MeetingRecorder。",
  recheckSysAudio: "重新检测",
  probeOutcomeGranted: "已捕获到系统音频信号，双轨系统音权限正常。",
  probeOutcomeSilent:
    "系统音频采集为全静音：可能是「系统设置 → 隐私与安全性 → 录屏与系统录音 → 仅系统音频录制」未勾选 MeetingRecorder，也可能是系统已静音或当前应用仅打开了静音流。确认授权后请点击「重启并重检」。",
  probeOutcomeTapFailed: "系统音频 Tap 启动失败，请检查「仅系统音频录制」权限或默认输出设备状态。",
  probeOutcomeTimeout: "系统音频 Tap 启动超时，尚未完成通道与权限验证，请稍后重试或重启采集服务。",
  probeOutcomeOtherPlaying:
    "系统音频 Tap 通道就绪，但短时内未收到非静音波形，可重试检测或检查系统静音状态。",
  probeOutcomeTapReadyIdle:
    "系统音频 Tap 通道就绪，当前未检测到其他应用播放音频；可播放声音后再点「检测音频权限」，或直接开始录制。",
  probeBusyRetry: "当前采集服务繁忙或未完成系统音频检测，请稍后重试。",
  probeFailed: (err) => `系统音频检测失败：${err}`,
  probeAfterRestartFailed: (err) => `重启后系统音频检测失败：${err}`,
  restartedSysOk: "采集服务已重启，系统音频权限已就绪",
  restartedMicOk: "采集服务已重启，麦克风权限已就绪",
  restartedMicPrompt: "采集服务已重启，请点击「授权麦克风」完成授权",
  restartedMicStillDenied:
    "已重启采集服务但仍无麦克风权限。请在隐私设置中关闭再开启 MeetingRecorder 后重试。",
  micPromptToast: "请在系统弹窗中点击允许访问麦克风",
  stoppedEmptyToast: "未录到有效语音（空录音）",
  stoppedPartialError: "部分切片封包失败或发生设备中断，已保存可用内容",
  stoppedPartialToast: "已保存部分录音切片",
  stoppedOkToast: "录音已安全封包",
  postStopTitle: (title) => `录音已封包：${title}`,
  postStopMeta: (dur, chunks) => `${dur} · ${chunks} 片`,
  generatingInSession: "独立会话生成中...",
  generateNotesNewSession: "新建会话生成纪要",
  viewDetails: "查看详情",
  dismiss: "收起",
  recentRecordingsTitle: "最近录制",
  allCountBtn: (n) => `全部 (${n})`,
  emptyMeetingsLive: "还没有会议记录，点击上方按钮开始第一次录制。",
  modeDualShort: "双轨",
  modeMicShort: "仅麦",
  modeDualFull: "双轨录制",
  modeMicFull: "仅麦克风",
  chunksMeta: (chunks, size) => `${chunks} 片 · ${size}`,
  badgeRecording: "录制中",
  badgeFinalizing: "封包中",
  badgeEmpty: "空录音",
  badgeGenerating: "独立会话生成中",
  badgePartial: "部分完成",
  badgeNotesDone: "已完成纪要",
  badgeTranscribed: (done, total) => `已转写 ${done}/${total}`,
  badgePending: (chunks) => `待转写 (${chunks} 片)`,
  btnResumeMissing: (done, total) => `补转缺失 (${done}/${total})`,
  btnRegenerateNotes: "重新生成纪要",
  btnGenerateNotes: "生成纪要",
  delete: "删除",
  confirmDelete: "确认删除",
  cancel: "取消",
  save: "保存",
  rename: "重命名",
  meetingDeletedToast: "会议已删除",
  titleUpdatedToast: "标题已更新",
  copiedToast: "已复制到剪贴板",
  copyFailedToast: "复制失败，请手动选中文本复制",
  notesGeneratedToast: "会议纪要已生成",
  jobAlreadyRunningToast: "该会议已在另一会话中生成纪要",
  lockInvalidBanner: "任务占锁返回异常，未发送生成请求，请稍后重试。",
  lockInvalidToast: "任务占锁状态异常，请重试",
  lockTimeoutBanner: (detail) => `确认生成任务状态超时或失败（${detail}），请稍后重试。`,
  lockTimeoutToast: "任务锁确认超时，请稍后重试",
  startedNewSessionIdToast: "已开启独立会话生成纪要",
  startedNewSessionToast: "已在新独立会话中开始生成纪要",
  sentCurrentChatToast: "已发送至当前对话生成纪要",
  copiedPromptTitle: "已复制「生成会议纪要」指令",
  copiedPromptReasonSameChat: (detail) =>
    `独立后台会话触发失败（${detail}），已复制生成指令；你可直接粘贴到新对话，或点击「改在当前对话生成」。`,
  copiedPromptReasonNoCap: (detail) =>
    `当前视图暂不支持自动发送消息（${detail}）；请在右侧边栏「+ → Meeting Notes」中点击「生成纪要」，或粘贴已复制指令到任意对话。`,
  copyAgain: "再次复制",
  generateInCurrentChat: "改在当前对话生成",
  copiedPromptToast: "暂无法直连新会话，已自动复制生成指令",
  globalViewBannerTitle: "全局视图（仅支持复制指令）",
  globalViewBannerDesc:
    "当前从左侧边栏打开的全局视图未绑定对话，无法直接拉起生成会话。如需一键生成纪要，请从任意对话右侧边栏「+ → Meeting Notes」打开；也可点击「复制生成指令」粘贴到任意对话。",
  btnCopyPrompt: "复制生成指令",
  copiedPromptGlobalView:
    "已复制生成指令，粘贴到任意对话即可生成纪要；如需一键生成，请从对话右侧边栏「+ → Meeting Notes」打开。",
  copiedPromptDirectToast: "已复制生成指令，请粘贴到任意对话",
  liveGapTitle: "录制过程中发生音频缺口",
  liveGapSummaryGaps: (count, start, end, reason) =>
    `已记录 ${count} 处音频缺口（最近：${start}–${end}，${reason}）`,
  liveGapSummaryFailed: (count) => `${count} 个切片写入失败`,
  liveGapTail: "。已保存或恢复后的其余音频会继续录制并在纪要中如实标注。",
  retentionTitle: "原音频留存策略",
  retentionDesc: "仅清理原始 .m4a，保留纪要、逐字稿与发言统计；未转写音频绝不自动删除。",
  retentionManual: "永久保留（手动清理）",
  retentionAfterNotes: "生成纪要后自动清理",
  retentionDays7: "保留 7 天（仅清理已完成纪要）",
  retentionSavedCleanedToast: (count, size) =>
    `策略已保存，已自动清理 ${count} 场已完成会议原音频（释放 ${size}）`,
  retentionSavedToast: "原音频留存策略已更新",
  audioCleanedToast: (size) => `已清理原音频，释放 ${size}`,
  searchPlaceholder: "搜索标题、纪要或逐字稿...",
  noSearchResults: "没有匹配的会议记录",
  noHistoryMeetings: "暂无历史会议",
  historySnippet: (chunks, statusText) => `${chunks} 片 · ${statusText}`,
  snippetStatusGenerating: "独立会话生成中",
  snippetStatusPartial: "部分完成",
  snippetStatusHasNotes: "已有纪要",
  snippetStatusTranscribed: (done, total) => `已转写 ${done}/${total}`,
  snippetStatusUntranscribed: "未转写",
  listBadgeNotes: "纪要",
  listBadgeTranscript: "逐字稿",
  listBadgePending: "待处理",
  backToMeetings: "返回会议列表",
  loadingDetail: "正在加载会议详情...",
  durationLabel: (dur) => `时长 ${dur}`,
  chunksLabel: (done, total) => `切片 ${done}/${total}`,
  audioLabel: (text) => `音频 ${text}`,
  audioCleanedLabel: "已清理",
  speakerDistLabel: (me, remote, both) => `发言分布 我方 ${me} · 对方 ${remote} · 重叠 ${both}`,
  partialDetailTitle: "部分完成（存在声轨或切片缺口）",
  partialDetailGaps: (n) => `缺口 ${n} 处`,
  partialDetailFailed: (n) => `异常切片 ${n} 个`,
  tabNotes: "会议纪要",
  tabTranscript: "逐字稿",
  copyMarkdown: "复制 Markdown",
  confirmCleanupBtn: (chunks) => `确认清理 ${chunks} 组原音`,
  cleanupAudioBtn: (size) => `清理原音频 (${size})`,
  truncatedTitle: "内容过长已截断显示",
  truncatedChunksSaved: "完整分片文件已保存在本机目录",
  truncatedFileSaved: "完整文件已保存在本机",
  emptyNotesTitle: "尚未生成会议纪要",
  emptyTranscriptTitle: "尚未生成逐字稿",
  emptyDetailDesc: (dur, chunks, done) =>
    `本场会议已录制 ${dur}（${chunks} 个音频切片${done > 0 ? ` · 已转写 ${done} 片` : ""}）。`,
  close: "关闭",
  gapReason: (reason) => {
    switch (reason) {
      case "audio_device_changed":
        return "音频设备切换";
      case "audio_device_lost":
        return "音频设备中断";
      case "system_audio_tap_failed":
        return "系统音频捕获失败";
      case "system_audio_reconnecting":
        return "系统音频重连";
      case "system_audio_device_changed":
        return "系统输出设备切换";
      case "system_audio_silent":
        return "系统音频无信号";
      default:
        return reason || "未知原因";
    }
  },
};

export function getStrings(lang: UiLang): UiStrings {
  return lang === "zh" ? ZH : EN;
}
