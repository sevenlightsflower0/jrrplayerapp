import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:jrrplayerapp/audio/audio_constants.dart';
import 'package:jrrplayerapp/services/audio_player_service.dart';
import 'dart:async';
import 'dart:io';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';

class AudioPlayerHandler extends BaseAudioHandler {
  final AudioPlayerService audioPlayerService;

  // --- Текущий MediaItem, показываемый в уведомлении ---
  MediaItem? _currentMediaItem;

  // --- Ожидающие метаданные (ещё без обложки) ---
  AudioMetadata? _pendingMetadata;
  Timer? _pendingMetadataTimer;
  static const Duration _pendingTimeout = Duration(seconds: 2);

  // --- Подписки на стримы плеера ---
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<ProcessingState>? _processingSubscription;

  // --- Блокировка команд и таймаут ---
  bool _isHandlingControl = false;
  Timer? _commandTimeoutTimer;

  // --- Debounce для состояния воспроизведения ---
  Timer? _playbackStateDebounceTimer;

  // --- Кэш для artUri (ключ – оригинальный URL без cache-buster) ---
  final Map<String, Uri> _artUriCache = {};

  // --- Дефолтная обложка для разных платформ ---
  static String? _androidPackageName;
  static Uri? _cachedLocalDefaultCoverUri;

  AudioPlayerHandler(this.audioPlayerService) {
    _initDefaultArtUris();
    _updateInitialMediaItem();
    audioPlayerService.addListener(_onAudioServiceUpdate);
    _setupStreams();
  }

  // ==================== ИНИЦИАЛИЗАЦИЯ ДЕФОЛТНОЙ ОБЛОЖКИ ====================

  Future<void> _initDefaultArtUris() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final packageInfo = await PackageInfo.fromPlatform();
      _androidPackageName = packageInfo.packageName;
      debugPrint('📦 Android packageName: $_androidPackageName');
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _initLocalDefaultCover();
    }
  }

  static Future<void> _initLocalDefaultCover() async {
    if (_cachedLocalDefaultCoverUri != null) return;
    const assetPath = 'assets/images/default_cover.png';
    final dir = await getApplicationDocumentsDirectory();
    final localFile = File('${dir.path}/default_cover.png');
    if (!await localFile.exists()) {
      final byteData = await rootBundle.load(assetPath);
      await localFile.writeAsBytes(byteData.buffer.asUint8List());
    }
    _cachedLocalDefaultCoverUri = Uri.file(localFile.path);
    debugPrint('🍏 iOS default cover ready: $_cachedLocalDefaultCoverUri');
  }

  Uri _getDefaultArtUri() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      if (_androidPackageName != null) {
        return Uri.parse(
            'android.resource://$_androidPackageName/drawable/default_cover');
      }
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      if (_cachedLocalDefaultCoverUri != null) {
        return _cachedLocalDefaultCoverUri!;
      }
    }
    return Uri.parse('asset:///assets/images/default_cover.png');
  }

  // ==================== УПРАВЛЕНИЕ КОМАНДАМИ ====================

  void _resetCommandLock() {
    if (_isHandlingControl) {
      debugPrint('🔄 Resetting command lock (timeout or error)');
      _isHandlingControl = false;
    }
    _commandTimeoutTimer?.cancel();
    _commandTimeoutTimer = null;
  }

  Future<void> _executeCommand(
      Future<void> Function() command, String commandName) async {
    if (_isHandlingControl) {
      debugPrint('⚠️ Command $commandName: previous command still executing, resetting lock');
      _resetCommandLock();
    }

    _isHandlingControl = true;
    _commandTimeoutTimer = Timer(const Duration(seconds: 5), () {
      debugPrint('⏰ Command $commandName timeout - resetting lock');
      _resetCommandLock();
    });

    try {
      debugPrint('🎵 Background: Executing $commandName');
      await command();
      debugPrint('✅ Background: $commandName completed successfully');
    } catch (e, stackTrace) {
      debugPrint('❌ Error in background $commandName: $e');
      debugPrint('Stack trace: $stackTrace');
      final player = audioPlayerService.getPlayer();
      if (player != null) updatePlaybackState(player.playing);
      rethrow;
    } finally {
      _resetCommandLock();
    }
  }

  // ==================== ПОДПИСКИ НА СОСТОЯНИЕ ПЛЕЕРА ====================

  void _setupStreams() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
    _processingSubscription?.cancel();

    final player = audioPlayerService.getPlayer();
    if (player == null) return;

    _positionSubscription = player.positionStream.listen(_updatePlaybackPosition);
    _durationSubscription = player.durationStream.listen(_updatePlaybackDuration);
    _playingSubscription = player.playingStream.listen((isPlaying) {
      debugPrint('Background: playingStream changed to $isPlaying');
      _debouncedUpdatePlaybackState(isPlaying);
    });
    _processingSubscription = player.processingStateStream.listen((state) {
      debugPrint('Background: processingState changed to $state');
      _debouncedUpdatePlaybackState(player.playing);
    });
  }

  void _debouncedUpdatePlaybackState(bool isPlaying) {
    _playbackStateDebounceTimer?.cancel();
    _playbackStateDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (!audioPlayerService.isDisposed) {
        updatePlaybackState(isPlaying);
        audioPlayerService.notifyListenersSafe();
      }
    });
  }

  void _updatePlaybackPosition(Duration position) {
    playbackState.add(playbackState.value.copyWith(
      updatePosition: position,
    ));
  }

  void _updatePlaybackDuration(Duration? duration) {
    if (_currentMediaItem != null && duration != null) {
      if (_currentMediaItem!.duration != duration) {
        _currentMediaItem = _currentMediaItem!.copyWith(duration: duration);
        mediaItem.add(_currentMediaItem!);
      }
    }
  }

  // ==================== ОБНОВЛЕНИЕ МЕТАДАННЫХ (С ДЕБАНСОМ) ====================

  Future<void> updateMetadata(AudioMetadata metadata) async {
    debugPrint('🎵 [Handler] updateMetadata called: ${metadata.title}');

    // Для радио – фиксированный ID, чтобы не пересоздавать уведомление
    final bool isRadio = !audioPlayerService.isPodcastMode;
    final String mediaId = isRadio
        ? 'jrr_live_stream'
        : 'podcast_${audioPlayerService.currentEpisode?.id ?? DateTime.now().millisecondsSinceEpoch}';

    final Duration? duration = audioPlayerService.isPodcastMode
        ? audioPlayerService.currentEpisode?.duration
        : null;

    // Подготовленный URL обложки (без cache-buster)
    final String preparedArtUrl = audioPlayerService.getPreparedArtUrl(metadata.artUrl);
    final Uri? artUri = _getArtUriForPlatform(preparedArtUrl);
    final bool isDefaultCover = metadata.artUrl.isEmpty ||
        metadata.artUrl == 'assets/images/default_cover.png' ||
        metadata.artUrl == AudioMetadata.defaultCoverUrl;

    // --- Если обложка уже известна (не дефолтная), обновляем сразу ---
    if (!isDefaultCover) {
      _cancelPendingMetadata();
      _applyMediaItem(mediaId, metadata, artUri, duration);
      return;
    }

    // --- Если пришла дефолтная обложка, возможно, настоящая ещё не найдена ---
    // Проверяем, действительно ли изменился трек
    if (_currentMediaItem != null &&
        _currentMediaItem!.title == metadata.title &&
        _currentMediaItem!.artist == metadata.artist) {
      // Тот же трек – игнорируем дефолтную обложку, оставляем старую
      debugPrint('🎵 [Handler] Same track, ignoring default cover');
      return;
    }

    // Новый трек: откладываем обновление, даём шанс найти обложку
    _pendingMetadata = metadata;
    _pendingMetadataTimer?.cancel();
    _pendingMetadataTimer = Timer(_pendingTimeout, () {
      debugPrint('⏰ [Handler] Pending metadata timeout – applying with default cover');
      _applyMediaItem(mediaId, _pendingMetadata!, artUri, duration);
      _pendingMetadata = null;
    });

    debugPrint('🎵 [Handler] Waiting for cover, current artUri: ${_currentMediaItem?.artUri}');
  }

  /// Принудительное обновление обложки (вызывается, когда найдена реальная)
  Future<void> forceUpdateCover(String artUrl) async {
    debugPrint('🔄 [Handler] Force update cover: $artUrl');

    // Если есть ожидающие метаданные – применяем их с новой обложкой
    if (_pendingMetadata != null) {
      _cancelPendingMetadata();

      final bool isRadio = !audioPlayerService.isPodcastMode;
      final String mediaId = isRadio ? 'jrr_live_stream' : 
          'podcast_${audioPlayerService.currentEpisode?.id ?? DateTime.now().millisecondsSinceEpoch}';

      final String preparedArtUrl = audioPlayerService.getPreparedArtUrl(artUrl);
      final Uri? newArtUri = _getArtUriForPlatform(preparedArtUrl);
      final Duration? duration = audioPlayerService.isPodcastMode
          ? audioPlayerService.currentEpisode?.duration
          : null;

      _applyMediaItem(mediaId, _pendingMetadata!, newArtUri, duration);
      _pendingMetadata = null;
      return;
    }

    // Нет ожидающих метаданных – обновляем только обложку у текущего MediaItem
    if (_currentMediaItem != null) {
      final Uri? newArtUri = _getArtUriForPlatform(artUrl);
      if (_currentMediaItem!.artUri?.toString() == newArtUri?.toString()) {
        debugPrint('✅ [Handler] Cover unchanged, skipping');
        return;
      }

      final updatedItem = _currentMediaItem!.copyWith(
        artUri: newArtUri,
        extras: {
          ...?_currentMediaItem!.extras,
          'coverUpdatedAt': DateTime.now().millisecondsSinceEpoch, // только для логирования
        },
      );

      _currentMediaItem = updatedItem;
      mediaItem.add(_currentMediaItem!);
      debugPrint('✅ [Handler] Cover force updated to: $newArtUri');
    }
  }

  void _cancelPendingMetadata() {
    _pendingMetadataTimer?.cancel();
    _pendingMetadataTimer = null;
    _pendingMetadata = null;
  }

  void _applyMediaItem(String mediaId, AudioMetadata metadata, Uri? artUri, Duration? duration) {
    final bool isRadio = !audioPlayerService.isPodcastMode;

    final newItem = MediaItem(
      id: mediaId,
      title: metadata.title,
      artist: metadata.artist,
      album: metadata.album ?? (isRadio ? 'Онлайн радио' : 'J-Rock Radio'),
      artUri: artUri,
      duration: duration,
      extras: {
        'isPodcast': audioPlayerService.isPodcastMode,
        'episodeId': audioPlayerService.currentEpisode?.id,
        'artUrlRaw': metadata.artUrl,
        'isRadio': isRadio,
        // Убраны все динамические временные метки, которые меняются при каждом обновлении
      },
    );

    // Сравниваем только значимые поля (всё, кроме extras)
    if (_currentMediaItem != null &&
        _currentMediaItem!.id == newItem.id &&
        _currentMediaItem!.title == newItem.title &&
        _currentMediaItem!.artist == newItem.artist &&
        _currentMediaItem!.album == newItem.album &&
        _currentMediaItem!.artUri?.toString() == newItem.artUri?.toString() &&
        _currentMediaItem!.duration == newItem.duration) {
      debugPrint('🎵 [Handler] MediaItem unchanged, skipping');
      return;
    }

    _currentMediaItem = newItem;
    mediaItem.add(_currentMediaItem!);
    debugPrint('🎵 [Handler] MediaItem applied: ${_currentMediaItem!.artUri}');

    // Синхронизируем состояние воспроизведения
    final player = audioPlayerService.getPlayer();
    if (player != null) updatePlaybackState(player.playing);
  }

  // ==================== ART URI (БЕЗ CACHE-BUSTER) ====================

  Uri? _getArtUriForPlatform(String artUrl) {
    // Используем оригинальный URL как ключ кэша (без добавления timestamp)
    final String cacheKey = artUrl;

    if (_artUriCache.containsKey(cacheKey)) {
      return _artUriCache[cacheKey];
    }

    if (artUrl.isEmpty ||
        artUrl == 'assets/images/default_cover.png' ||
        artUrl == AudioMetadata.defaultCoverUrl) {
      final defaultUri = _getDefaultArtUri();
      _artUriCache[cacheKey] = defaultUri;
      return defaultUri;
    }

    try {
      Uri result;
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        if (artUrl.startsWith('http://') || artUrl.startsWith('https://')) {
          result = Uri.parse(artUrl); // без cache-buster
        } else if (artUrl.startsWith('assets/')) {
          result = Uri.parse('asset:///FlutterAssets/$artUrl');
        } else if (artUrl.startsWith('asset://')) {
          result = Uri.parse(artUrl);
        } else {
          result = _getDefaultArtUri();
        }
      } else {
        if (artUrl.startsWith('http://') || artUrl.startsWith('https://')) {
          result = Uri.parse(artUrl);
        } else if (artUrl.startsWith('assets/')) {
          result = Uri.parse('asset:///$artUrl');
        } else if (artUrl.startsWith('asset://')) {
          result = Uri.parse(artUrl);
        } else {
          result = _getDefaultArtUri();
        }
      }
      _artUriCache[cacheKey] = result;
      return result;
    } catch (e) {
      debugPrint('❌ Error creating artUri for $artUrl: $e');
      final defaultUri = _getDefaultArtUri();
      _artUriCache[cacheKey] = defaultUri;
      return defaultUri;
    }
  }

  // ==================== PLAYBACK STATE ====================

  void updatePlaybackState(bool isPlaying) {
    final player = audioPlayerService.getPlayer();
    final position = player?.position ?? Duration.zero;
    final duration = player?.duration;
    final isPodcast = audioPlayerService.isPodcastMode;

    // System actions (what the OS knows is supported)
    final systemActions = <MediaAction>{
      MediaAction.seek,
      MediaAction.seekForward,
      MediaAction.seekBackward,
      MediaAction.skipToNext,
      MediaAction.skipToPrevious,
      MediaAction.play,
      MediaAction.pause,
      MediaAction.stop,
    };
    if (!isPodcast) {
      systemActions.remove(MediaAction.seek);
      systemActions.remove(MediaAction.skipToNext);
      systemActions.remove(MediaAction.skipToPrevious);
    }

    // Visible controls in the notification
    final controls = <MediaControl>[];

    // Previous – only for podcast
    if (isPodcast) {
      controls.add(const MediaControl(
        androidIcon: 'drawable/ic_skip_previous',
        label: 'Предыдущий',
        action: MediaAction.skipToPrevious,
      ));
    }

    // Rewind – only for podcast
    if (isPodcast) {
      controls.add(const MediaControl(
        androidIcon: 'drawable/ic_rewind_30s',
        label: '30 секунд назад',
        action: MediaAction.rewind,
      ));
    }

    // Play / Pause – always
    controls.add(isPlaying
        ? const MediaControl(
            androidIcon: 'drawable/ic_pause',
            label: 'Пауза',
            action: MediaAction.pause,
          )
        : const MediaControl(
            androidIcon: 'drawable/ic_play',
            label: 'Воспроизвести',
            action: MediaAction.play,
          ));

    // Fast forward – only for podcast
    if (isPodcast) {
      controls.add(const MediaControl(
        androidIcon: 'drawable/ic_fast_forward_30s',
        label: '30 секунд вперед',
        action: MediaAction.fastForward,
      ));
    }

    // Next – only for podcast
    if (isPodcast) {
      controls.add(const MediaControl(
        androidIcon: 'drawable/ic_skip_next',
        label: 'Следующий',
        action: MediaAction.skipToNext,
      ));
    }

    // Stop – always
    controls.add(const MediaControl(
      androidIcon: 'drawable/ic_stop',
      label: 'Стоп',
      action: MediaAction.stop,
    ));

    // Compact indices – adjusted for the actual number of controls
    final List<int> compactIndices;
    if (isPodcast) {
      // For podcast: we usually show previous, play/pause, next in compact mode
      // Order in controls: [prev?, rewind?, play/pause, ff?, next?, stop]
      // We want indices of prev, play/pause, next
      int prevIndex = 0; // first control is prev
      int playIndex = isPodcast ? 2 : 0; // after prev and rewind (if both present)
      int nextIndex = controls.length - 2; // before stop
      compactIndices = [prevIndex, playIndex, nextIndex];
    } else {
      // For radio: only play/pause and stop are present
      // Order: [play/pause, stop]
      // Show only play/pause in compact mode (index 0)
      compactIndices = [0];
    }

    // Processing state
    AudioProcessingState processingState = AudioProcessingState.idle;
    if (player != null) {
      processingState = switch (player.processingState) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      };
    }

    playbackState.add(PlaybackState(
      controls: controls,
      systemActions: systemActions,
      androidCompactActionIndices: compactIndices,
      playing: isPlaying,
      updatePosition: position,
      bufferedPosition: duration ?? Duration.zero,
      speed: 1.0,
      queueIndex: 0,
      processingState: processingState,
    ));
  }

  // ==================== ОБРАБОТЧИКИ СОБЫТИЙ СЕРВИСА ====================

  void _onAudioServiceUpdate() {
    final metadata = audioPlayerService.currentMetadata;
    final player = audioPlayerService.getPlayer();

    if (metadata != null) {
      // Проверяем, действительно ли изменился трек (по названию и исполнителю)
      final trackChanged = _currentMediaItem == null ||
          _currentMediaItem!.title != metadata.title ||
          _currentMediaItem!.artist != metadata.artist;
      if (trackChanged) {
        updateMetadata(metadata);
      }
    }

    if (player != null) {
      if (playbackState.value.playing != player.playing) {
        updatePlaybackState(player.playing);
      }
      _setupStreams();
    }
  }

  void _updateInitialMediaItem() {
    final defaultCoverUrl = AudioMetadata.defaultCoverUrl;
    _currentMediaItem = MediaItem(
      id: 'jrr_live_stream',
      title: 'J-Rock Radio',
      artist: 'Live Stream',
      album: 'Онлайн радио',
      artUri: _getArtUriForPlatform(defaultCoverUrl),
      extras: {'isRadio': true},
    );
    mediaItem.add(_currentMediaItem!);
    updatePlaybackState(false);
  }

  // ==================== МЕТОДЫ ДЛЯ ВНЕШНЕГО ВЫЗОВА ====================

  void forceUpdateMediaItem() {
    // Устарело, оставлено для совместимости
  }

  void forceUpdateUI(bool isPlaying) {
    updatePlaybackState(isPlaying);
  }

  void clearArtUriCache() {
    _artUriCache.clear();
  }

  void refreshArtUriForNewTrack(String newArtUrl) {
    // Очистка кэша для старого трека
    if (_currentMediaItem?.extras?['artUrlRaw'] != null) {
      final oldArtUrl = _currentMediaItem!.extras!['artUrlRaw'] as String;
      _artUriCache.remove(oldArtUrl);
    }
    if (newArtUrl.isNotEmpty) {
      _getArtUriForPlatform(newArtUrl);
    }
  }

  // ==================== КОМАНДЫ ====================

  @override
  Future<void> play() => _executeCommand(() async {
    debugPrint('🎵 Background: play');
    if (!audioPlayerService.isInitialized || audioPlayerService.isDisposed) {
      await audioPlayerService.initialize();
    }
    if (audioPlayerService.isPodcastMode) {
      final player = audioPlayerService.getPlayer();
      if (player != null && !player.playing) await player.play();
    } else {
      await audioPlayerService.playRadio();
    }
    updatePlaybackState(audioPlayerService.isPlaying);
  }, 'play');

  @override
  Future<void> pause() => _executeCommand(() async {
    debugPrint('🎵 Background: pause');
    await audioPlayerService.pause();
    updatePlaybackState(false);
  }, 'pause');

  @override
  Future<void> stop() => _executeCommand(() async {
    debugPrint('Background: stop');
    if (audioPlayerService.isPodcastMode) {
      await audioPlayerService.stopPodcast();
    } else {
      await audioPlayerService.stopRadio();
    }
    updatePlaybackState(false);
    _onAudioServiceUpdate();
  }, 'stop');

  @override
  Future<void> seek(Duration position) => _executeCommand(() async {
    debugPrint('Background: seek to $position');
    if (audioPlayerService.isPodcastMode) {
      await audioPlayerService.seekPodcast(position);
    }
  }, 'seek');

  @override
  Future<void> skipToNext() => _executeCommand(() async {
    debugPrint('Background: skipToNext');
    if (audioPlayerService.isPodcastMode) {
      await audioPlayerService.playNextPodcast();
    }
  }, 'skipToNext');

  @override
  Future<void> skipToPrevious() => _executeCommand(() async {
    debugPrint('Background: skipToPrevious');
    if (audioPlayerService.isPodcastMode) {
      await audioPlayerService.playPreviousPodcast();
    }
  }, 'skipToPrevious');

  @override
  Future<void> rewind() => _executeCommand(() async {
    debugPrint('Background: rewind');
    if (audioPlayerService.isPodcastMode) {
      final player = audioPlayerService.getPlayer();
      final pos = (player?.position ?? Duration.zero) - kPodcastRewindInterval;
      await audioPlayerService.seekPodcast(pos > Duration.zero ? pos : Duration.zero);
    }
  }, 'rewind');

  @override
  Future<void> fastForward() => _executeCommand(() async {
    debugPrint('Background: fastForward');
    if (audioPlayerService.isPodcastMode) {
      final player = audioPlayerService.getPlayer();
      final pos = (player?.position ?? Duration.zero) + kPodcastFastForwardInterval;
      final dur = player?.duration ?? const Duration(hours: 1);
      await audioPlayerService.seekPodcast(pos < dur ? pos : dur - const Duration(seconds: 1));
    }
  }, 'fastForward');

  @override
  Future<void> playMediaItem(MediaItem mediaItem) => _executeCommand(() async {
    debugPrint('Background: playMediaItem ${mediaItem.title}');
    this.mediaItem.add(mediaItem);
    playbackState.add(playbackState.value.copyWith(
      playing: true,
      processingState: AudioProcessingState.ready,
    ));
  }, 'playMediaItem');

  @override
  Future<void> onTaskRemoved() async {
    await super.onTaskRemoved();
    _cleanupResources();
  }

  void _cleanupResources() {
    _resetCommandLock();
    _commandTimeoutTimer?.cancel();
    _playbackStateDebounceTimer?.cancel();
    _cancelPendingMetadata();

    audioPlayerService.removeListener(_onAudioServiceUpdate);

    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
    _processingSubscription?.cancel();
    _positionSubscription = _durationSubscription = _playingSubscription = _processingSubscription = null;

    debugPrint('AudioPlayerHandler cleaned up');
  }
}