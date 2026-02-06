import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:jrrplayerapp/audio/audio_constants.dart';
import 'package:jrrplayerapp/services/audio_player_service.dart';
import 'dart:async';
import 'dart:io'; 
import 'package:just_audio/just_audio.dart';
import 'package:http/http.dart' as http; 
import 'package:path_provider/path_provider.dart'; 
import 'package:shared_preferences/shared_preferences.dart'; 

class AudioPlayerHandler extends BaseAudioHandler {
  final AudioPlayerService audioPlayerService;
  MediaItem? _currentMediaItem;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<ProcessingState>? _processingSubscription;
  bool _isHandlingControl = false;
  Timer? _commandTimeoutTimer;
  final Map<String, Uri> _artUriCache = {}; // Кэш для быстрого доступа
  static const String _defaultArtUriString = 'asset:///assets/images/default_cover.png';
  static final Uri _defaultArtUri = Uri.parse(_defaultArtUriString);
  
  // iOS-специфичный кэш для изображений
  final Map<String, String> _iosImageCache = {};


  AudioPlayerHandler(this.audioPlayerService) {
    _updateMediaItem();
    audioPlayerService.addListener(_onAudioServiceUpdate);
    _setupStreams();
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
      mediaItem.add(_currentMediaItem);
    }
  }

  void _updateControls() {
    final currentState = playbackState.value;
    final isPlaying = currentState.playing;
    
    final List<MediaControl> dynamicControls = [
      const MediaControl(
        androidIcon: 'drawable/ic_skip_previous',
        label: 'Предыдущий',
        action: MediaAction.skipToPrevious,
      ),
      const MediaControl(
        androidIcon: 'drawable/ic_rewind_30s',
        label: '30 секунд назад',
        action: MediaAction.rewind,
      ),
      if (!isPlaying)
        const MediaControl(
          androidIcon: 'drawable/ic_play',
          label: 'Воспроизвести',
          action: MediaAction.play,
        ),
      if (isPlaying)
        const MediaControl(
          androidIcon: 'drawable/ic_pause',
          label: 'Пауза',
          action: MediaAction.pause,
        ),
      const MediaControl(
        androidIcon: 'drawable/ic_fast_forward_30s',
        label: '30 секунд вперед',
        action: MediaAction.fastForward,
      ),
      const MediaControl(
        androidIcon: 'drawable/ic_skip_next',
        label: 'Следующий',
        action: MediaAction.skipToNext,
      ),
      const MediaControl(
        androidIcon: 'drawable/ic_stop',
        label: 'Стоп',
        action: MediaAction.stop,
      ),
    ];
    
    playbackState.add(currentState.copyWith(
      controls: dynamicControls,
    ));
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

  Future<void> updateMetadata(AudioMetadata metadata) async {
    debugPrint('🎵 updateMetadata called with raw artUrl: ${metadata.artUrl}');

    Duration? duration;
    if (audioPlayerService.isPodcastMode && audioPlayerService.currentEpisode != null) {
      duration = audioPlayerService.currentEpisode?.duration;
    }

    // Получаем подготовленный URL
    String preparedArtUrl = audioPlayerService.getPreparedArtUrl(metadata.artUrl);
    debugPrint('🎵 Prepared artUrl: $preparedArtUrl');
    
    // ВМЕСТО сложной логики с Connectivity для iOS, используем кэшированный парсинг
    Uri? artUri = _parseArtUri(preparedArtUrl);
    
    // ✅ ИСПРАВЛЕНИЕ ДЛЯ iOS
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final uriString = artUri.toString();
      
      // Для iOS: используем только локальные ресурсы или закэшированные изображения
      if (uriString.startsWith('http://') || uriString.startsWith('https://')) {
        debugPrint('⚠️ iOS: Network URL detected, trying to use cached version');
        
        // Пробуем получить закэшированный путь
        final cachedPath = await _getCachedImagePathForIOS(uriString, metadata.title);
        if (cachedPath != null && await File(cachedPath).exists()) {
          debugPrint('✅ iOS: Using cached image at: $cachedPath');
          artUri = Uri.file(cachedPath);
        } else {
          // Если нет в кэше, используем дефолт
          debugPrint('❌ iOS: No cached image, using default');
          artUri = _defaultArtUri;
          
          // Асинхронно загружаем в кэш для будущего использования
          _preloadAndCacheImageForIOS(uriString, metadata.title);
        }
      } else if (uriString.startsWith('asset://')) {
        // Конвертируем asset:// в формат для iOS
        final assetPath = uriString.replaceFirst('asset:///', '');
        artUri = Uri.parse('asset://$assetPath');
      }
    }

    // Обновляем или создаём MediaItem
    if (_currentMediaItem == null) {
      _currentMediaItem = MediaItem(
        id: metadata.artist == 'Live Stream' ? 'jrr_live_stream' : 'podcast_${DateTime.now().millisecondsSinceEpoch}',
        title: metadata.title,
        artist: metadata.artist,
        album: metadata.album ?? 'J-Rock Radio',
        artUri: artUri,
        duration: duration,
        extras: {
          'isPodcast': audioPlayerService.isPodcastMode,
          'episodeId': audioPlayerService.currentEpisode?.id,
          'artUrlRaw': metadata.artUrl,
        },
      );
    } else {
      _currentMediaItem = _currentMediaItem!.copyWith(
        title: metadata.title,
        artist: metadata.artist,
        album: metadata.album ?? _currentMediaItem!.album,
        artUri: artUri,
        duration: duration,
        extras: {
          ...?_currentMediaItem!.extras,
          'isPodcast': audioPlayerService.isPodcastMode,
          'episodeId': audioPlayerService.currentEpisode?.id,
          'artUrlRaw': metadata.artUrl,
        },
      );
    }

    debugPrint('🎵 Final MediaItem → artUri: ${artUri.toString()}');
    mediaItem.add(_currentMediaItem!);
    _updateControls();
  }

  // ✅ МЕТОД ДЛЯ ПРЕДВАРИТЕЛЬНОЙ ЗАГРУЗКИ И КЭШИРОВАНИЯ ИЗОБРАЖЕНИЙ ДЛЯ iOS
  Future<void> _preloadAndCacheImageForIOS(String imageUrl, String cacheKey) async {
    try {
      // Генерируем ключ кэша на основе URL и названия трека
      final safeCacheKey = 'ios_${_generateCacheKey(imageUrl, cacheKey)}';
      
      // Проверяем, не загружаем ли мы уже это изображение
      if (_iosImageCache.containsKey(safeCacheKey)) {
        return;
      }
      
      debugPrint('🔄 iOS: Preloading image: $imageUrl');
      
      final response = await http.get(Uri.parse(imageUrl));
      if (response.statusCode == 200) {
        // Сохраняем во временный файл
        final tempDir = await getTemporaryDirectory();
        final fileName = '${DateTime.now().millisecondsSinceEpoch}_${safeCacheKey.hashCode}.jpg';
        final filePath = '${tempDir.path}/$fileName';
        final file = File(filePath);
        await file.writeAsBytes(response.bodyBytes);
        
        // Сохраняем в памяти
        _iosImageCache[safeCacheKey] = filePath;
        
        // Сохраняем в SharedPreferences для будущих сессий
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(safeCacheKey, filePath);
        
        debugPrint('✅ iOS: Image cached at: $filePath');
      }
    } catch (e) {
      debugPrint('❌ iOS: Failed to cache image $imageUrl: $e');
    }
  }

  // ✅ МЕТОД ДЛЯ ПОЛУЧЕНИЯ ЗАКЭШИРОВАННОГО ПУТИ ДЛЯ iOS
  Future<String?> _getCachedImagePathForIOS(String imageUrl, String cacheKey) async {
    try {
      final safeCacheKey = 'ios_${_generateCacheKey(imageUrl, cacheKey)}';
      
      // Сначала проверяем кэш в памяти
      if (_iosImageCache.containsKey(safeCacheKey)) {
        final cachedPath = _iosImageCache[safeCacheKey]!;
        if (await File(cachedPath).exists()) {
          return cachedPath;
        }
      }
      
      // Затем проверяем SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final cachedPath = prefs.getString(safeCacheKey);
      
      if (cachedPath != null && await File(cachedPath).exists()) {
        // Обновляем кэш в памяти
        _iosImageCache[safeCacheKey] = cachedPath;
        return cachedPath;
      }
      
      return null;
    } catch (e) {
      debugPrint('❌ iOS: Error getting cached path: $e');
      return null;
    }
  }

  // ✅ ВСПОМОГАТЕЛЬНЫЙ МЕТОД ДЛЯ ГЕНЕРАЦИИ КЛЮЧА КЭША
  String _generateCacheKey(String imageUrl, String title) {
    // Создаем хэш из URL и названия трека
    final key = '${imageUrl}_$title';
    return key.hashCode.toRadixString(16);
  }

  // Парсит URI для обложки в фоновом режиме
  Uri? _parseArtUri(String artUrl) {
    // Самый быстрый вариант - если URL уже правильный
    if (artUrl == 'asset:///assets/images/default_cover.png') {
      return _defaultArtUri;
    }

    // Быстрая проверка
    if (artUrl.isEmpty || artUrl.length < 3) {
      return _defaultArtUri;
    }
    
    // Кэш
    if (_artUriCache.containsKey(artUrl)) {
      return _artUriCache[artUrl];
    }
    
    Uri result;
    
    try {
      // Просто парсим URI, так как getPreparedArtUrl уже подготовил его
      result = Uri.parse(artUrl);
    } catch (e) {
      debugPrint('❌ Error parsing artUrl "$artUrl": $e');
      result = _defaultArtUri;
    }
    
    _artUriCache[artUrl] = result;
    return result;
  }

  void updatePlaybackState(bool isPlaying) {
    final player = audioPlayerService.getPlayer();
    final position = player?.position ?? Duration.zero;
    final duration = player?.duration;
    
    List<MediaAction> actions = [
      MediaAction.seek,
      MediaAction.seekForward,
      MediaAction.seekBackward,
      MediaAction.skipToNext,
      MediaAction.skipToPrevious,
      MediaAction.play,
      MediaAction.pause,
      MediaAction.stop,
      MediaAction.rewind,
      MediaAction.fastForward,
    ];
    
    if (!audioPlayerService.isPodcastMode) {
      actions.remove(MediaAction.seek);
      actions.remove(MediaAction.skipToNext);
      actions.remove(MediaAction.skipToPrevious);
    }

    final List<MediaControl> dynamicControls = [
      const MediaControl(
        androidIcon: 'drawable/ic_skip_previous',
        label: 'Предыдущий',
        action: MediaAction.skipToPrevious,
      ),
      const MediaControl(
        androidIcon: 'drawable/ic_rewind_30s',
        label: '30 секунд назад',
        action: MediaAction.rewind,
      ),
      if (!isPlaying)
        const MediaControl(
          androidIcon: 'drawable/ic_play',
          label: 'Воспроизвести',
          action: MediaAction.play,
        ),
      if (isPlaying)
        const MediaControl(
          androidIcon: 'drawable/ic_pause',
          label: 'Пауза',
          action: MediaAction.pause,
        ),
      const MediaControl(
        androidIcon: 'drawable/ic_fast_forward_30s',
        label: '30 секунд вперед',
        action: MediaAction.fastForward,
      ),
      const MediaControl(
        androidIcon: 'drawable/ic_skip_next',
        label: 'Следующий',
        action: MediaAction.skipToNext,
      ),
      const MediaControl(
        androidIcon: 'drawable/ic_stop',
        label: 'Стоп',
        action: MediaAction.stop,
      ),
    ];

    final List<int> compactIndices = isPlaying 
        ? [0, 3, 6]  // prev, pause, stop
        : [0, 2, 6]; // prev, play, stop  
    
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
      systemActions: actions.toSet(),
      androidCompactActionIndices: compactIndices,
      playing: isPlaying,
      updatePosition: position,
      bufferedPosition: duration ?? Duration.zero,
      speed: 1.0,
      queueIndex: 0,
      processingState: processingState,
    ));
  }

  void _updateMediaItem() {
    const defaultCoverUrl = 'asset:///assets/images/default_cover.png';
    debugPrint('🎵 _updateMediaItem with cover: $defaultCoverUrl');
    
    _currentMediaItem = MediaItem(
      id: 'jrr_live_stream',
      title: 'J-Rock Radio',
      artist: 'Live Stream',
      album: 'Онлайн радио',
      artUri: _parseArtUri(defaultCoverUrl),
      extras: {'isRadio': true},
    );
    mediaItem.add(_currentMediaItem);
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
    _updateControls();
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