import 'dart:async';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/services/player/external_playback_launcher.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/pages/player/controller/player_debug_controller.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/pages/player/controller/player_seek_controller.dart';
import 'package:kazumi/pages/player/controller/player_aspect_ratio.dart';
import 'package:kazumi/pages/player/controller/player_panel_controller.dart';
import 'package:kazumi/pages/player/controller/player_playback_controller.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';
import 'package:kazumi/pages/player/controller/player_screenshot_controller.dart';
import 'package:kazumi/pages/player/controller/track_choice.dart';
import 'package:kazumi/services/subject/subject_local_store.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/utils/async_session.dart';
import 'package:kazumi/utils/device.dart';

export 'package:kazumi/pages/player/controller/player_models.dart';

class PlayerController implements Disposable {
  PlayerController(
    this.shaderAssetService,
    DownloadController downloadController,
    this.audioController,
  ) {
    danmaku = PlayerDanmakuController(
      isLocalPlayback: () => isLocalPlayback,
      downloadController: downloadController,
    );
  }

  final ShaderAssetService shaderAssetService;
  final AudioController audioController;
  bool Function(String error)? onPlaybackError;
  final AsyncSessionOwner _initializations = AsyncSessionOwner();
  Future<void>? _shutdownFuture;
  final PlayerPanelController panel = PlayerPanelController();
  final PlayerScreenshotController screenshots = PlayerScreenshotController();
  final PlayerDebugController debug = PlayerDebugController();

  late final PlayerDanmakuController danmaku;
  late final PlayerPlaybackController playback = PlayerPlaybackController(
    shaderAssetService: shaderAssetService,
    debug: debug,
    videoUrl: () => videoUrl,
    isLocalPlayback: () => isLocalPlayback,
    onPlaybackError: (error) => onPlaybackError?.call(error) ?? false,
  );
  late final PlayerSyncPlayController syncplay = PlayerSyncPlayController(
    bangumiId: () => bangumiId,
    currentEpisode: () => currentEpisode,
    currentRoad: () => currentRoad,
    playing: () => playback.playing,
    currentPosition: () => playback.currentPosition,
    playerPosition: () => playback.playerPosition,
    duration: () => playback.duration,
    pause: pause,
    play: play,
    seek: seek,
  );
  late final PlayerSeekController seeking = PlayerSeekController(
    playback: playback,
    danmaku: danmaku,
    pause: pause,
    play: play,
    onSeekCompleted: _onSeekCompleted,
  );
  late final ExternalPlaybackLauncher externalPlayback =
      ExternalPlaybackLauncher(
        videoUrl: () => videoUrl,
        referer: () => referer,
      );

  late int bangumiId;
  late int currentEpisode;
  late int currentDanmakuEpisodeNumber;
  late int currentRoad;
  late String referer;
  String? coverUrl;
  String videoUrl = '';
  bool isLocalPlayback = false;
  bool isTorrentStream = false;
  Timer? hideVolumeUITimer;
  Timer? _volumeGestureSyncTimer;
  double? _pendingGestureVolume;

  bool muted = false;
  double _preMuteVolume = 100;

  Future<void> toggleMute() async {
    if (!muted && playback.volume > 0) {
      _preMuteVolume = playback.volume;
      muted = true;
      _persistMuteState();
      await setVolume(0);
    } else {
      muted = false;
      _persistMuteState();
      await setVolume(_preMuteVolume > 0 ? _preMuteVolume : 100);
    }
  }

  void _persistMuteState() {
    if (!isDesktop()) {
      return;
    }
    unawaited(GStorage.putSetting<bool>(SettingsKeys.playerMuted, muted));
  }

  /// 在音量被主动调高（手势 / 按键 / 滚轮）时退出静音状态。
  void _clearMuteIfNeeded(double value) {
    if (muted && value > 0) {
      muted = false;
      _persistMuteState();
    }
  }

  void setVolumeDuringGesture(double value) {
    _pendingGestureVolume = value.clamp(0.0, 100.0);
    playback.updateVolume(_pendingGestureVolume!);
    _volumeGestureSyncTimer?.cancel();
    _volumeGestureSyncTimer = Timer(const Duration(milliseconds: 80), () {
      final vol = _pendingGestureVolume;
      if (vol == null) {
        return;
      }
      unawaited(playback.syncVolumeToDevice(vol));
    });
  }

  Future<void> finishVolumeGesture() async {
    _volumeGestureSyncTimer?.cancel();
    _volumeGestureSyncTimer = null;
    final vol = _pendingGestureVolume;
    _pendingGestureVolume = null;
    if (vol != null) {
      playback.volume = vol;
    }
    playback.invalidatePreciseVolume();
    await playback.syncVolumeToDevice(vol);
    final resolved = vol ?? playback.volume;
    _clearMuteIfNeeded(resolved);
    _persistDesktopVolume(resolved);
  }

  void _persistDesktopVolume(double value) {
    if (!isDesktop()) {
      return;
    }
    if (muted) {
      return;
    }
    final clamped = value.clamp(0.0, 100.0);
    final stored = GStorage.getSetting(SettingsKeys.defaultVolume);
    if (stored.round() == clamped.round()) {
      return;
    }
    unawaited(GStorage.putSetting<double>(SettingsKeys.defaultVolume, clamped));
  }

  Future<bool> init(PlaybackInitParams params) async {
    if (_initializations.isClosed) {
      return false;
    }
    final initialization = _initializations.begin();

    videoUrl = params.videoUrl;
    isLocalPlayback = params.isLocalPlayback;
    isTorrentStream = params.isTorrentStream;
    bangumiId = params.bangumiId;
    currentEpisode = params.episode;
    currentDanmakuEpisodeNumber = params.danmakuEpisodeNumber;
    currentRoad = params.currentRoad;
    referer = params.referer;

    KazumiLogger().i(
      'PlayerController: ${params.isLocalPlayback ? "local" : "online"} playback, url: ${params.videoUrl}',
    );

    playback.resetForInit();
    debug.playerLogLevel = GStorage.getSetting(SettingsKeys.playerLogLevel);
    playback.playerSpeed =
        rememberedChoices.speed ??
        GStorage.getSetting(SettingsKeys.defaultPlaySpeed);
    panel.aspectRatioMode = PlayerAspectRatio.fromStorageValue(
      GStorage.getSetting(SettingsKeys.defaultAspectRatioType),
    );

    playback.buttonSkipTime = GStorage.getSetting(SettingsKeys.buttonSkipTime);
    playback.arrowKeySkipTime = GStorage.getSetting(
      SettingsKeys.arrowKeySkipTime,
    );
    try {
      await _releasePlaybackResources();
    } catch (_) {}
    if (initialization.isStale) {
      return false;
    }

    final Player? player;
    try {
      player = await playback.createVideoController(
        params.httpHeaders,
        params.adBlockerEnabled,
        canInstall: () => initialization.isActive,
        offset: params.offset,
        videoSourceFormat: params.videoSourceFormat,
        isTorrentStream: params.isTorrentStream,
        publicNetworkOnly: params.publicNetworkOnly,
      );
    } catch (e) {
      if (initialization.isStale) {
        return false;
      }
      playback.loading = false;
      KazumiLogger().e(
        'PlayerController: failed to initialize video',
        error: e,
      );
      return false;
    }
    if (player == null || !_ownsInitialization(initialization, player)) {
      return false;
    }

    if (isDesktop()) {
      final freshStart = playback.volume == -1;
      if (freshStart) {
        muted = GStorage.getSetting(SettingsKeys.playerMuted);
        final remembered = GStorage.getSetting(SettingsKeys.defaultVolume);
        _preMuteVolume = remembered > 0 ? remembered : 100;
        playback.volume = muted ? 0 : remembered;
      }
      await setVolume(playback.volume);
      if (!_ownsInitialization(initialization, player)) {
        return false;
      }
    } else {
      await FlutterVolumeController.getVolume().then((value) {
        playback.volume = (value ?? 0.0) * 100;
      });
      if (!_ownsInitialization(initialization, player)) {
        return false;
      }

      await FlutterVolumeController.updateShowSystemUI(false);
      if (!_ownsInitialization(initialization, player)) {
        await FlutterVolumeController.updateShowSystemUI(true);
        return false;
      }

      FlutterVolumeController.addListener(
        (volume) {
          if (player == null || !_ownsInitialization(initialization, player)) {
            return;
          }
          if (panel.volumeSeeking) {
            return;
          }
          playback.applyExternalVolume(volume * 100);
          if (!Platform.isAndroid && !panel.volumeSeeking) {
            panel.showVolume = true;
            hideVolumeUITimer?.cancel();
            hideVolumeUITimer = Timer(const Duration(seconds: 1), () {
              panel.showVolume = false;
              hideVolumeUITimer = null;
            });
          }
        },
        category: AudioSessionCategory.playback,
        emitOnStart: false,
      );
      if (!_ownsInitialization(initialization, player)) {
        return false;
      }
    }
    await setPlaybackSpeed(playback.playerSpeed);
    if (!_ownsInitialization(initialization, player)) {
      return false;
    }
    KazumiLogger().i('PlayerController: video initialized');
    playback.loading = false;
    _applyRememberedTracks(player, initialization);

    coverUrl = params.coverUrl;

    if (syncplay.syncplayController?.isConnected ?? false) {
      if (syncplay.syncplayController!.currentFileName !=
          "$bangumiId[$currentEpisode]") {
        setSyncPlayPlayingBangumi(
          forceSyncPlaying: true,
          forceSyncPosition: 0.0,
        );
      }
    }
    return true;
  }

  bool _ownsInitialization(AsyncSession initialization, Player player) {
    return initialization.isActive && playback.isCurrentPlayer(player);
  }

  Future<void> setShader(SuperResolutionMode mode, {Player? player}) async {
    await playback.setShader(mode, player: player);
  }

  Future<void> setPlaybackSpeed(double playerSpeed) async {
    await playback.setPlaybackSpeed(playerSpeed);
    try {
      updateDanmakuSpeed();
    } catch (_) {}
  }

  StreamSubscription<Tracks>? _trackSubscription;

  // Tests and previews may run without the app's modules.
  SubjectPlayerChoices? get _choices {
    try {
      return inject<SubjectPlayerChoices>();
    } catch (_) {
      return null;
    }
  }

  /// What the current show remembers: speed, danmaku and tracks.
  PlayerChoices get rememberedChoices => bangumiId > 0
      ? (_choices?.choicesFor(bangumiId) ?? const PlayerChoices())
      : const PlayerChoices();

  /// A speed the user picked; the show keeps it. Temporary speeds such as a
  /// long press use [setPlaybackSpeed] instead.
  Future<void> chooseSpeed(double speed) async {
    await setPlaybackSpeed(speed);
    if (bangumiId > 0) unawaited(_choices?.update(bangumiId, speed: speed));
  }

  void rememberDanmaku(bool enabled) {
    if (bangumiId > 0) unawaited(_choices?.update(bangumiId, danmaku: enabled));
  }

  static List<TrackInfo> _audioInfos(List<AudioTrack> tracks) => [
    for (final track in tracks)
      (id: track.id, title: track.title, language: track.language),
  ];

  static List<TrackInfo> _subtitleInfos(List<SubtitleTrack> tracks) => [
    for (final track in tracks)
      (id: track.id, title: track.title, language: track.language),
  ];

  static List<AudioTrack> realAudioTracks(Tracks tracks) => [
    for (final track in tracks.audio)
      if (isRealTrack(track.id) && !track.uri) track,
  ];

  static List<SubtitleTrack> realSubtitleTracks(Tracks tracks) => [
    for (final track in tracks.subtitle)
      if (isRealTrack(track.id) && !track.uri && !track.data) track,
  ];

  Future<void> chooseAudioTrack(AudioTrack track) async {
    final player = playback.mediaPlayer;
    if (player == null) return;
    await player.setAudioTrack(track);
    final real = realAudioTracks(player.state.tracks);
    final index = real.indexWhere((candidate) => candidate.id == track.id);
    if (index >= 0 && bangumiId > 0) {
      unawaited(
        _choices?.update(bangumiId, audio: choiceFor(_audioInfos(real), index)),
      );
    }
  }

  /// Subtitles from the file are remembered by language and title; turning
  /// them off is remembered too. External files are not.
  Future<void> chooseSubtitleTrack(SubtitleTrack track) async {
    final player = playback.mediaPlayer;
    if (player == null) return;
    await player.setSubtitleTrack(track);
    if (bangumiId <= 0 || track.uri || track.data) return;
    if (track.id == 'no') {
      unawaited(
        _choices?.update(bangumiId, subtitle: const TrackChoice(off: true)),
      );
      return;
    }
    final real = realSubtitleTracks(player.state.tracks);
    final index = real.indexWhere((candidate) => candidate.id == track.id);
    if (index >= 0) {
      unawaited(
        _choices?.update(
          bangumiId,
          subtitle: choiceFor(_subtitleInfos(real), index),
        ),
      );
    }
  }

  Future<void> loadExternalSubtitle(String path, {String? title}) async {
    final player = playback.mediaPlayer;
    if (player == null) return;
    await player.setSubtitleTrack(SubtitleTrack.uri(path, title: title));
  }

  /// Once the file's tracks are known, selects what the show used before and
  /// stops listening.
  void _applyRememberedTracks(Player player, AsyncSession initialization) {
    unawaited(_trackSubscription?.cancel());
    _trackSubscription = null;
    final choices = rememberedChoices;
    var audioDone = choices.audio == null;
    var subtitleDone = choices.subtitle == null;
    if (audioDone && subtitleDone) return;
    void apply(Tracks tracks) {
      if (!_ownsInitialization(initialization, player)) {
        audioDone = subtitleDone = true;
      }
      if (!audioDone) {
        final real = realAudioTracks(tracks);
        if (real.isNotEmpty) {
          audioDone = true;
          final index = matchTrackIndex(_audioInfos(real), choices.audio!);
          if (index != null && real.length > 1) {
            unawaited(player.setAudioTrack(real[index]));
          }
        }
      }
      if (!subtitleDone) {
        final real = realSubtitleTracks(tracks);
        if (real.isNotEmpty) {
          subtitleDone = true;
          final choice = choices.subtitle!;
          if (choice.off) {
            unawaited(player.setSubtitleTrack(SubtitleTrack.no()));
          } else if (matchTrackIndex(_subtitleInfos(real), choice)
              case final index?) {
            unawaited(player.setSubtitleTrack(real[index]));
          }
        }
      }
      if (audioDone && subtitleDone) {
        unawaited(_trackSubscription?.cancel());
        _trackSubscription = null;
      }
    }

    apply(player.state.tracks);
    if (!audioDone || !subtitleDone) {
      _trackSubscription = player.stream.tracks.listen(apply);
    }
  }

  void updateDanmakuSpeed() {
    danmaku.updateDanmakuSpeed(playback.playerSpeed);
  }

  Future<void> setVolume(double value) async {
    await playback.setVolume(value);
    _clearMuteIfNeeded(value);
    _persistDesktopVolume(value);
  }

  void syncPlaybackState() {
    playback.syncPlaybackState();
  }

  Future<void> playOrPause() async {
    await playback.playOrPause(pause: pause, play: play);
  }

  Future<void> seek(Duration duration, {bool enableSync = true}) =>
      seeking.seekTo(duration, enableSync: enableSync);

  Future<void> seekBy(Duration offset, {bool enableSync = true}) =>
      seeking.seekBy(offset, enableSync: enableSync);

  Future<void> _onSeekCompleted(bool enableSync) async {
    if (syncplay.hasSession) {
      setSyncPlayCurrentPosition();
      if (enableSync) {
        await requestSyncPlaySync(doSeek: true);
      }
    }
  }

  Future<void> pause({bool enableSync = true}) async {
    final player = playback.mediaPlayer;
    if (player == null) return;
    danmaku.canvasController.pause();
    try {
      await player.pause();
    } catch (_) {
      return;
    }
    playback.playing = false;
    if (syncplay.hasSession) {
      setSyncPlayCurrentPosition();
      if (enableSync) {
        await requestSyncPlaySync();
      }
    }
  }

  Future<void> play({bool enableSync = true}) async {
    final player = playback.mediaPlayer;
    if (player == null) return;
    danmaku.canvasController.resume();
    try {
      await player.play();
    } catch (_) {
      return;
    }
    playback.playing = true;
    if (syncplay.hasSession) {
      setSyncPlayCurrentPosition();
      if (enableSync) {
        await requestSyncPlaySync();
      }
    }
  }

  @override
  void dispose() {
    beginShutdown();
  }

  /// Starts the idempotent player shutdown without blocking route navigation.
  ///
  /// Native media and audio-session cleanup may finish after the route is
  /// removed. Immediate ownership detachment happens synchronously before this
  /// method returns.
  void beginShutdown() {
    _initializations.close();
    if (_shutdownFuture != null) {
      return;
    }
    screenshots.dispose();
    final shutdown = _shutdownResources();
    _shutdownFuture = shutdown;
    unawaited(
      shutdown.catchError((Object error, StackTrace stackTrace) {
        KazumiLogger().e(
          'PlayerController: failed to dispose asynchronously',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  Future<void> _shutdownResources() async {
    await Future.wait([_releasePlaybackResources(), syncplay.dispose()]);
  }

  Future<void> _releasePlaybackResources() async {
    unawaited(_trackSubscription?.cancel());
    _trackSubscription = null;
    hideVolumeUITimer?.cancel();
    _volumeGestureSyncTimer?.cancel();
    FlutterVolumeController.removeListener();
    await Future.wait([
      audioController.deactivate(),
      playback.stop(),
      _restoreSystemVolumeUi(),
    ]);
  }

  Future<void> _restoreSystemVolumeUi() async {
    try {
      await FlutterVolumeController.updateShowSystemUI(true);
    } catch (error, stackTrace) {
      KazumiLogger().w(
        'PlayerController: failed to restore the system volume UI',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> stop() async {
    _initializations.cancel();
    await _releasePlaybackResources();
  }

  Future<Uint8List?> screenshotPng() => playback.screenshotPng();

  void setButtonForwardTime(int time) {
    playback.buttonSkipTime = time;
    GStorage.putSetting(SettingsKeys.buttonSkipTime, time);
  }

  void setArrowKeyForwardTime(int time) {
    playback.arrowKeySkipTime = time;
    GStorage.putSetting(SettingsKeys.arrowKeySkipTime, time);
  }

  Future<void> launchExternalPlayer() async {
    if (isTorrentStream) {
      KazumiDialog.showToast(message: 'RSS 视频正在本机下载，请使用内置播放器');
      return;
    }
    await externalPlayback.launch();
  }

  Future<void> createSyncPlayRoom(
    String room,
    String username,
    Future<void> Function(int episode, {int currentRoad, int offset})
    changeEpisode,
  ) async {
    await syncplay.createRoom(room, username, changeEpisode);
  }

  void setSyncPlayCurrentPosition({
    bool? forceSyncPlaying,
    double? forceSyncPosition,
  }) {
    syncplay.setCurrentPosition(
      forceSyncPlaying: forceSyncPlaying,
      forceSyncPosition: forceSyncPosition,
    );
  }

  Future<void> setSyncPlayPlayingBangumi({
    bool? forceSyncPlaying,
    double? forceSyncPosition,
  }) async {
    await syncplay.setPlayingBangumi(
      forceSyncPlaying: forceSyncPlaying,
      forceSyncPosition: forceSyncPosition,
    );
  }

  Future<void> requestSyncPlaySync({bool? doSeek}) async {
    await syncplay.requestSync(doSeek: doSeek);
  }

  Future<void> sendSyncPlayChatMessage(String message) async {
    await syncplay.sendChatMessage(message);
  }

  Future<void> exitSyncPlayRoom() async {
    await syncplay.exitRoom();
  }
}
