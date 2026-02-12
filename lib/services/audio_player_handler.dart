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
  MediaItem? _currentMediaItem;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<ProcessingState>? _processingSubscription;
  bool _isHandlingControl = false;
  Timer? _commandTimeoutTimer;

  // Кэш для быстрого доступа к арт-URI
  final Map<String, Uri> _artUriCache = {};

  // Для Android: packageName (получается асинхронно)
  static String? _androidPackageName;
  // Для iOS: закэшированный локальный URI дефолтной обложки
  static Uri? _cachedLocalDefaultCoverUri;

  AudioPlayerHandler(this.audioPlayerService) {
    _initDefaultArtUris(); // асинхронная инициализация дефолтной обложки
    _updateMediaItem();
    audioPlayerService.addListener(_onAudioServiceUpdate);
    _setupStreams();
  }

  // Инициализация дефолтных URI для разных платформ
  Future<void> _initDefaultArtUris() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final packageInfo = await PackageInfo.fromPlatform();
      _androidPackageName = packageInfo.packageName;
      debugPrint('📦 Android packageName: $_androidPackageName');
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _initLocalDefaultCover();
    }
  }

  // Копирование дефолтной обложки в локальную директорию (iOS)
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

  // Возвращает корректный URI для дефолтной обложки (синхронно)
  Uri _getDefaultArtUri() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      if (_androidPackageName != null) {
        return Uri.parse(
            'android.resource://$_androidPackageName/drawable/default_cover');
      } else {
        // Fallback: asset (пока пакет не получен – маловероятно)
        return Uri.parse('asset:///assets/images/default_cover.png');
      }
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      if (_cachedLocalDefaultCoverUri != null) {
        return _cachedLocalDefaultCoverUri!;
      } else {
        // Fallback: asset (пока файл не скопирован)
        return Uri.parse('asset:///assets/images/default_cover.png');
      }
    } else {
      // Web / другие
      return Uri.parse('asset:///assets/images/default_cover.png');
    }
  }

  void _resetCommandLock() {
    if (_isHandlingControl) {
      debugPrint('🔄 Resetting command lock (timeout or error)');
      _isHandlingControl = false;
    }
    _commandTimeoutTimer?.cancel();
    _commandTimeoutTimer = null;
  }

  Future<void> _executeCommand(Future<void> Function() command, String commandName) async {
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
      if (player != null) {
        updatePlaybackState(player.playing);
      }
      
      rethrow;
    } finally {
      _resetCommandLock();
    }
  }

  void _setupStreams() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
    _processingSubscription?.cancel();
    
    final player = audioPlayerService.getPlayer();
    if (player != null) {
      _positionSubscription = player.positionStream.listen((position) {
        _updatePlaybackPosition(position);
      });
      
      _durationSubscription = player.durationStream.listen((duration) {
        _updatePlaybackDuration(duration);
      });
      
      _playingSubscription = player.playingStream.listen((isPlaying) {
        debugPrint('Background: playingStream changed to $isPlaying');
        
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!audioPlayerService.isDisposed) {
            updatePlaybackState(isPlaying);
            audioPlayerService.notifyListenersSafe();
          }
        });
      });
      
      _processingSubscription = player.processingStateStream.listen((state) {
        debugPrint('Background: processingState changed to $state');
        
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!audioPlayerService.isDisposed) {
            updatePlaybackState(player.playing);
            audioPlayerService.notifyListenersSafe();
          }
        });
      });
    }
  }

  void _updatePlaybackPosition(Duration position) {
    playbackState.add(playbackState.value.copyWith(
      updatePosition: position,
    ));
  }

  void _updatePlaybackDuration(Duration? duration) {
    if (_currentMediaItem != null && duration != null) {
      _currentMediaItem = _currentMediaItem!.copyWith(
        duration: duration,
      );
      mediaItem.add(_currentMediaItem!);
    }
  }

  void _onAudioServiceUpdate() {
    final metadata = audioPlayerService.currentMetadata;
    final player = audioPlayerService.getPlayer();
    
    if (metadata != null) {
      updateMetadata(metadata);
    }
    
    if (player != null) {
      final actualPlayingState = audioPlayerService.isPlaying;
      updatePlaybackState(actualPlayingState);
      _setupStreams();
    }
  }

  void forceUpdateMediaItem() {
    if (_currentMediaItem != null) {
      // Создаем копию с полностью новым extras
      MediaItem updatedItem = MediaItem(
        id: _currentMediaItem!.id,
        title: _currentMediaItem!.title,
        artist: _currentMediaItem!.artist!,
        album: _currentMediaItem!.album ?? 'J-Rock Radio',
        artUri: _currentMediaItem!.artUri,
        duration: _currentMediaItem!.duration,
        extras: {
          ..._currentMediaItem!.extras ?? {},
          'forceUpdate': DateTime.now().millisecondsSinceEpoch,
          'updatedAt': DateTime.now().toIso8601String(),
        },
      );
      
      _currentMediaItem = updatedItem;
      mediaItem.add(_currentMediaItem!);
      
      debugPrint('🔄 [Handler] Force updated MediaItem with artUri: ${_currentMediaItem!.artUri}');
      
      // Для iOS дополнительно обновляем состояние
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          playbackState.add(playbackState.value.copyWith(
            updatePosition: playbackState.value.position,
          ));
        });
      }
      
      // Для Android также принудительно обновляем состояние
      if (defaultTargetPlatform == TargetPlatform.android) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final currentState = playbackState.value;
          playbackState.add(currentState.copyWith(
            updatePosition: currentState.position,
            bufferedPosition: currentState.bufferedPosition,
          ));
        });
      }
    }
  }

  Future<void> forceUpdateCover(String artUrl) async {
    debugPrint('🔄 [Handler] Force updating cover: $artUrl');
    
    if (_currentMediaItem != null) {
      // Получаем artUri с корректным cache-buster (уже есть в _getArtUriForPlatform)
      Uri? newArtUri = _getArtUriForPlatform(artUrl);
      
      MediaItem updatedItem = MediaItem(
        id: _currentMediaItem!.id,
        title: _currentMediaItem!.title,
        artist: _currentMediaItem!.artist!,
        album: _currentMediaItem!.album ?? 'J-Rock Radio',
        artUri: newArtUri,
        duration: _currentMediaItem!.duration,
        extras: {
          ..._currentMediaItem!.extras ?? {},
          'forceCoverUpdate': DateTime.now().millisecondsSinceEpoch,
          'originalArtUrl': artUrl,
        },
      );
      
      _currentMediaItem = updatedItem;
      mediaItem.add(_currentMediaItem!);
      
      debugPrint('✅ [Handler] Cover force updated to: $newArtUri');
    }
  }

  Future<void> updateMetadata(AudioMetadata metadata) async {
    debugPrint('🎵 [Handler] updateMetadata called with raw artUrl: ${metadata.artUrl}');

    Duration? duration;
    if (audioPlayerService.isPodcastMode && audioPlayerService.currentEpisode != null) {
      duration = audioPlayerService.currentEpisode?.duration;
    }

    // Получаем подготовленный URL
    String preparedArtUrl = audioPlayerService.getPreparedArtUrl(metadata.artUrl);
    debugPrint('🎵 [Handler] Prepared artUrl: $preparedArtUrl');
    
    // Для радио используем фиксированный ID для лучшей стабильности в уведомлениях
    String mediaId;
    bool isRadio = metadata.artist == 'Live Stream' || !audioPlayerService.isPodcastMode;
    
    if (isRadio) {
      // Для радио используем фиксированный ID, но добавляем временную метку для уникальности
      mediaId = 'jrr_live_stream_${DateTime.now().millisecondsSinceEpoch}';
    } else {
      // Для подкастов используем ID эпизода
      mediaId = 'podcast_${audioPlayerService.currentEpisode?.id ?? DateTime.now().millisecondsSinceEpoch}';
    }
    
    // Получаем artUri через унифицированный метод
    Uri? artUri = _getArtUriForPlatform(preparedArtUrl);
    
    // Создаем MediaItem с правильным artUri
    MediaItem newMediaItem = MediaItem(
      id: mediaId,
      title: metadata.title,
      artist: metadata.artist,
      album: metadata.album ?? 'J-Rock Radio',
      artUri: artUri,
      duration: duration,
      extras: {
        'isPodcast': audioPlayerService.isPodcastMode,
        'episodeId': audioPlayerService.currentEpisode?.id,
        'artUrlRaw': metadata.artUrl,
        'artUrlPrepared': preparedArtUrl,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'isRadio': isRadio,
        'forceUpdate': DateTime.now().millisecondsSinceEpoch,
      },
    );

    _currentMediaItem = newMediaItem;
    
    // Принудительно обновляем медиа-элемент
    mediaItem.add(_currentMediaItem!);
    
    // Синхронизируем состояние воспроизведения
    final player = audioPlayerService.getPlayer();
    if (player != null) {
      updatePlaybackState(player.playing);
    }
    
    debugPrint('🎵 [Handler] MediaItem updated with artUri: ${_currentMediaItem!.artUri}');
    debugPrint('🎵 [Handler] MediaItem ID: ${_currentMediaItem!.id}');
    
    // Только для iOS — дополнительное принуждение
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        forceUpdateMediaItem();
      });
    }
  }

  // Метод для получения artUri с учетом платформы и кэширования
  Uri? _getArtUriForPlatform(String artUrl) {
    // Добавляем временную метку к URL для предотвращения кэширования
    String cacheBusterArtUrl = artUrl;
    
    if (!artUrl.contains('?') && 
        (artUrl.startsWith('http://') || artUrl.startsWith('https://'))) {
      cacheBusterArtUrl = '$artUrl?t=${DateTime.now().millisecondsSinceEpoch}';
    }
    
    // Проверка кэша (с новым URL)
    if (_artUriCache.containsKey(cacheBusterArtUrl)) {
      return _artUriCache[cacheBusterArtUrl];
    }
    
    // Проверяем, является ли это дефолтной обложкой
    if (artUrl.isEmpty || 
        artUrl == 'assets/images/default_cover.png' || 
        artUrl == AudioMetadata.defaultCoverUrl) {
      final defaultUri = _getDefaultArtUri();
      _artUriCache[cacheBusterArtUrl] = defaultUri;
      return defaultUri;
    }

    try {
      Uri result;
      
      // Для iOS: особый случай для asset путей
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        if (artUrl.startsWith('http://') || artUrl.startsWith('https://')) {
          result = Uri.parse(cacheBusterArtUrl);
        } else if (artUrl.startsWith('assets/')) {
          // iOS ожидает: asset:///FlutterAssets/assets/...
          result = Uri.parse('asset:///FlutterAssets/$artUrl');
        } else if (artUrl.startsWith('asset://')) {
          result = Uri.parse(artUrl);
        } else {
          // Для iOS возвращаем дефолтную обложку
          result = _getDefaultArtUri();
        }
      } else {
        // Для Android и других платформ
        if (artUrl.startsWith('http://') || artUrl.startsWith('https://')) {
          result = Uri.parse(cacheBusterArtUrl);
        } else if (artUrl.startsWith('assets/')) {
          // Android ожидает: asset:///assets/...
          result = Uri.parse('asset:///$artUrl');
        } else if (artUrl.startsWith('asset://')) {
          result = Uri.parse(artUrl);
        } else {
          // Для Android возвращаем дефолтную обложку
          result = _getDefaultArtUri();
        }
      }
      
      _artUriCache[cacheBusterArtUrl] = result;
      return result;
    } catch (e) {
      debugPrint('❌ Error creating artUri for $artUrl: $e');
      final defaultUri = _getDefaultArtUri();
      _artUriCache[cacheBusterArtUrl] = defaultUri;
      return defaultUri;
    }
  }

  void updatePlaybackState(bool isPlaying) {
    final player = audioPlayerService.getPlayer();
    final position = player?.position ?? Duration.zero;
    final duration = player?.duration;
    final isPodcast = audioPlayerService.isPodcastMode;

    // Системные действия (разрешённые)
    Set<MediaAction> systemActions = {
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
      // Для радио убираем seek и переключение треков
      systemActions.remove(MediaAction.seek);
      systemActions.remove(MediaAction.skipToNext);
      systemActions.remove(MediaAction.skipToPrevious);
    }

    // Динамические контролы – 30 секунд ТОЛЬКО для подкастов
    final List<MediaControl> dynamicControls = [];
    dynamicControls.add(const MediaControl(
      androidIcon: 'drawable/ic_skip_previous',
      label: 'Предыдущий',
      action: MediaAction.skipToPrevious,
    ));
    if (isPodcast) {
      dynamicControls.add(const MediaControl(
        androidIcon: 'drawable/ic_rewind_30s',
        label: '30 секунд назад',
        action: MediaAction.rewind,
      ));
    }
    if (!isPlaying) {
      dynamicControls.add(const MediaControl(
        androidIcon: 'drawable/ic_play',
        label: 'Воспроизвести',
        action: MediaAction.play,
      ));
    } else {
      dynamicControls.add(const MediaControl(
        androidIcon: 'drawable/ic_pause',
        label: 'Пауза',
        action: MediaAction.pause,
      ));
    }
    if (isPodcast) {
      dynamicControls.add(const MediaControl(
        androidIcon: 'drawable/ic_fast_forward_30s',
        label: '30 секунд вперед',
        action: MediaAction.fastForward,
      ));
    }
    dynamicControls.add(const MediaControl(
      androidIcon: 'drawable/ic_skip_next',
      label: 'Следующий',
      action: MediaAction.skipToNext,
    ));
    dynamicControls.add(const MediaControl(
      androidIcon: 'drawable/ic_stop',
      label: 'Стоп',
      action: MediaAction.stop,
    ));

    // Компактные индексы для Android (всегда 3 кнопки)
    List<int> compactIndices;
    if (isPodcast) {
      compactIndices = isPlaying ? [0, 3, 6] : [0, 2, 6];
    } else {
      compactIndices = [0, 1, 2];
    }

    // ProcessingState
    AudioProcessingState processingState = AudioProcessingState.idle;
    if (player != null) {
      switch (player.processingState) {
        case ProcessingState.idle:
          processingState = AudioProcessingState.idle;
          break;
        case ProcessingState.loading:
          processingState = AudioProcessingState.loading;
          break;
        case ProcessingState.buffering:
          processingState = AudioProcessingState.buffering;
          break;
        case ProcessingState.ready:
          processingState = AudioProcessingState.ready;
          break;
        case ProcessingState.completed:
          processingState = AudioProcessingState.completed;
          break;
      }
    }

    playbackState.add(PlaybackState(
      controls: dynamicControls,
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

  void clearArtUriCache() {
    _artUriCache.clear();
    debugPrint('🔄 ArtUri cache cleared');
  }

  void refreshArtUriForNewTrack(String newArtUrl) {
    // Очищаем кэш для старого трека
    if (_currentMediaItem?.extras?['artUrlRaw'] != null) {
      final oldArtUrl = _currentMediaItem!.extras!['artUrlRaw'] as String;
      if (_artUriCache.containsKey(oldArtUrl)) {
        _artUriCache.remove(oldArtUrl);
        debugPrint('🔄 Cleared artUri cache for old track: $oldArtUrl');
      }
    }
    
    // Предзагружаем URI для нового трека
    if (newArtUrl.isNotEmpty) {
      _getArtUriForPlatform(newArtUrl);
      debugPrint('🔄 Pre-cached artUri for new track: $newArtUrl');
    }
  }

  void _updateMediaItem() {
    const defaultCoverUrl = AudioMetadata.defaultCoverUrl;
    debugPrint('🎵 _updateMediaItem with cover: $defaultCoverUrl');
    
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

  @override
  Future<void> play() async {
    return _executeCommand(() async {
      debugPrint('🎵 Background audio: play called, isPodcastMode: ${audioPlayerService.isPodcastMode}');
      
      if (!audioPlayerService.isInitialized || audioPlayerService.isDisposed) {
        debugPrint('🎵 Background audio: service not initialized, initializing...');
        await audioPlayerService.initialize();
        await Future.delayed(const Duration(milliseconds: 500));
      }
      
      final player = audioPlayerService.getPlayer();
      final isCurrentlyPlaying = player?.playing ?? false;
      
      debugPrint('🎵 Background play: current playing state = $isCurrentlyPlaying');
      debugPrint('🎵 Background play: isRadioPlaying = ${audioPlayerService.isRadioPlaying}');
      debugPrint('🎵 Background play: isRadioPaused = ${audioPlayerService.isRadioPaused}');
      debugPrint('🎵 Background play: isRadioStopped = ${audioPlayerService.isRadioStopped}');
      
      if (audioPlayerService.isPodcastMode && audioPlayerService.currentEpisode != null) {
        debugPrint('🎵 Background: Playing podcast');
        if (player != null && !player.playing) {
          await player.play();
          debugPrint('🎵 Podcast resumed from background');
        }
      } else {
        debugPrint('🎵 Background: Handling radio play');
        await audioPlayerService.playRadio();
      }
      
      final newPlayingState = audioPlayerService.isPlaying;
      debugPrint('🎵 Background: Updating playback state to $newPlayingState');
      updatePlaybackState(newPlayingState);
      
    }, 'play');
  }

  @override
  Future<void> pause() async {
    return _executeCommand(() async {
      debugPrint('🎵 Background audio: pause called, isPodcastMode: ${audioPlayerService.isPodcastMode}');
      
      final player = audioPlayerService.getPlayer();
      final wasPlaying = player?.playing ?? false;
      
      debugPrint('🎵 Background pause: player was playing = $wasPlaying');
      
      if (wasPlaying) {
        await audioPlayerService.pause();
        debugPrint('🎵 Background pause: audio paused successfully');
      } else {
        debugPrint('🎵 Background pause: player was already paused/stopped');
      }
      
      updatePlaybackState(false);
      
    }, 'pause');
  }
    
  void forceUpdateUI(bool isPlaying) {
    updatePlaybackState(isPlaying);
  }

  @override
  Future<void> stop() async {
    return _executeCommand(() async {
      debugPrint('Background audio: stop called, isPodcastMode: ${audioPlayerService.isPodcastMode}');
      
      if (audioPlayerService.isPodcastMode) {
        await audioPlayerService.stopPodcast();
      } else {
        await audioPlayerService.stopRadio();
      }
      
      updatePlaybackState(false);
      _onAudioServiceUpdate();
      
    }, 'stop');
  }

  @override
  Future<void> seek(Duration position) async {
    return _executeCommand(() async {
      debugPrint('Background audio: seek to $position');
      
      if (audioPlayerService.isPodcastMode) {
        await audioPlayerService.seekPodcast(position);
      }
      
    }, 'seek');
  }

  @override
  Future<void> skipToNext() async {
    return _executeCommand(() async {
      debugPrint('Background audio: skipToNext');
      
      if (audioPlayerService.isPodcastMode) {
        await audioPlayerService.playNextPodcast();
      }
      
    }, 'skipToNext');
  }

  @override
  Future<void> skipToPrevious() async {
    return _executeCommand(() async {
      debugPrint('Background audio: skipToPrevious');
      
      if (audioPlayerService.isPodcastMode) {
        await audioPlayerService.playPreviousPodcast();
      }
      
    }, 'skipToPrevious');
  }

  @override
  Future<void> rewind() async {
    return _executeCommand(() async {
      debugPrint('Background audio: rewind');
      
      if (audioPlayerService.isPodcastMode) {
        final player = audioPlayerService.getPlayer();
        final currentPosition = player?.position ?? Duration.zero;
        final newPosition = currentPosition - Duration(seconds: kPodcastRewindInterval.inSeconds);
        if (newPosition > Duration.zero) {
          await audioPlayerService.seekPodcast(newPosition);
        } else {
          await audioPlayerService.seekPodcast(Duration.zero);
        }
      }
      
    }, 'rewind');
  }

  @override
  Future<void> fastForward() async {
    return _executeCommand(() async {
      debugPrint('Background audio: fastForward');
      
      if (audioPlayerService.isPodcastMode) {
        final player = audioPlayerService.getPlayer();
        final currentPosition = player?.position ?? Duration.zero;
        final duration = player?.duration ?? const Duration(hours: 1);
        final newPosition = currentPosition + Duration(seconds: kPodcastFastForwardInterval.inSeconds);
        if (newPosition < duration) {
          await audioPlayerService.seekPodcast(newPosition);
        } else {
          await audioPlayerService.seekPodcast(duration - const Duration(seconds: 1));
        }
      }
      
    }, 'fastForward');
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    return _executeCommand(() async {
      debugPrint('Background audio: playMediaItem ${mediaItem.title}');
      
      this.mediaItem.add(mediaItem);
      playbackState.add(playbackState.value.copyWith(
        playing: true,
        processingState: AudioProcessingState.ready,
        controls: const [
          MediaControl(
            androidIcon: 'drawable/ic_skip_previous',
            label: 'Предыдущий',
            action: MediaAction.skipToPrevious,
          ),
          MediaControl(
            androidIcon: 'drawable/ic_pause',
            label: 'Пауза',
            action: MediaAction.pause,
          ),
          MediaControl(
            androidIcon: 'drawable/ic_skip_next',
            label: 'Следующий',
            action: MediaAction.skipToNext,
          ),
          MediaControl(
            androidIcon: 'drawable/ic_stop',
            label: 'Стоп',
            action: MediaAction.stop,
          ),
        ],
      ));
      
    }, 'playMediaItem');
  }

  @override
  Future<void> onTaskRemoved() async {
    await super.onTaskRemoved();
    _cleanupResources();
  }
  
  void _cleanupResources() {
    _resetCommandLock();
    _commandTimeoutTimer?.cancel();
    _commandTimeoutTimer = null;
    
    audioPlayerService.removeListener(_onAudioServiceUpdate);
    
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
    _processingSubscription?.cancel();
    
    _positionSubscription = null;
    _durationSubscription = null;
    _playingSubscription = null;
    _processingSubscription = null;
    
    debugPrint('AudioPlayerHandler resources cleaned up');
  }
}