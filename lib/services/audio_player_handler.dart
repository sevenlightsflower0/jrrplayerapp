import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:jrrplayerapp/audio/audio_constants.dart';
import 'package:jrrplayerapp/services/audio_player_service.dart';
import 'dart:async';
import 'package:just_audio/just_audio.dart';

class AudioPlayerHandler extends BaseAudioHandler {
  final AudioPlayerService audioPlayerService;
  MediaItem? _currentMediaItem;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<ProcessingState>? _processingSubscription;
  bool _isHandlingControl = false;
  Timer? _commandTimeoutTimer;

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

  void updateMetadata(AudioMetadata metadata) {
    Duration? duration;
    if (audioPlayerService.isPodcastMode && audioPlayerService.currentEpisode != null) {
      duration = audioPlayerService.currentEpisode?.duration;
    }
    
    // ✅ ИСПРАВЛЕНИЕ: Используем дефолтную обложку из сервиса, если artUrl пустая или дефолтная
    String artUrl = metadata.artUrl;
    if (artUrl.isEmpty || 
        artUrl == AudioMetadata.defaultCoverUrl || 
        artUrl.contains('default_cover')) {
      artUrl = audioPlayerService.getDefaultCoverUrlForBackground();
    }
    
    if (_currentMediaItem == null) {
      _currentMediaItem = MediaItem(
        id: metadata.artist == 'Live Stream' ? 'jrr_live_stream' : 'podcast_${DateTime.now().millisecondsSinceEpoch}',
        title: metadata.title,
        artist: metadata.artist,
        album: metadata.album ?? '',
        artUri: _parseArtUri(artUrl), // ✅ Используем новый метод для парсинга URI
        duration: duration,
        extras: {
          'isPodcast': audioPlayerService.isPodcastMode,
          'episodeId': audioPlayerService.currentEpisode?.id,
        },
      );
    } else {
      _currentMediaItem = MediaItem(
        id: _currentMediaItem!.id,
        title: metadata.title,
        artist: metadata.artist,
        album: metadata.album ?? _currentMediaItem!.album,
        artUri: _parseArtUri(artUrl), // ✅ Используем новый метод для парсинга URI
        duration: duration,
        extras: {
          'isPodcast': audioPlayerService.isPodcastMode,
          'episodeId': audioPlayerService.currentEpisode?.id,
          ..._currentMediaItem!.extras ?? {},
        },
      );
    }
    
    mediaItem.add(_currentMediaItem);
    debugPrint('Background audio metadata updated: ${metadata.title}');
    
    _updateControls();
  }

  // Парсит URI для обложки в фоновом режиме
  Uri? _parseArtUri(String artUrl) {
    if (artUrl.isEmpty) {
      debugPrint('⚠️ ArtUrl is empty, using default cover');
      return _getDefaultArtUri();
    }
    
    // Убираем лишние пробелы и проверяем на "null" строку
    artUrl = artUrl.trim();
    if (artUrl == 'null' || artUrl == 'Null' || artUrl == 'NULL') {
      debugPrint('⚠️ ArtUrl is "null" string, using default cover');
      return _getDefaultArtUri();
    }
    
    // Расширяем список префиксов для локальных путей
    final localPrefixes = [
      'assets/',
      'images/',
      'drawable/',
      'ic_',
      'img_',
      'cover',
      'default'
    ];
    
    for (final prefix in localPrefixes) {
      if (artUrl.contains(prefix)) {
        // Для фонового режима нужно использовать схему asset
        if (artUrl.startsWith('assets/')) {
          return Uri.parse('asset:///$artUrl');
        } else if (artUrl.startsWith('images/')) {
          return Uri.parse('asset:///assets/$artUrl');
        } else {
          // Предполагаем, что это asset в папке assets/images/
          return Uri.parse('asset:///assets/images/$artUrl');
        }
      }
    }
    
    // Если это http/https URL
    if (artUrl.startsWith('http://') || artUrl.startsWith('https://')) {
      return Uri.parse(artUrl);
    }
    
    // Если ничего не подошло - используем дефолтную обложку
    debugPrint('⚠️ ArtUrl "$artUrl" not recognized, using default cover');
    return _getDefaultArtUri();
  }

  Uri _getDefaultArtUri() {
    // Гарантированный путь к дефолтной обложке
    return Uri.parse('asset:///assets/images/default_cover.png');
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
    // ✅ ИСПРАВЛЕНИЕ: Используем дефолтную обложку из сервиса
    final defaultCoverUrl = audioPlayerService.getDefaultCoverUrlForBackground();
    
    _currentMediaItem = MediaItem(
      id: 'jrr_live_stream',
      title: 'J-Rock Radio',
      artist: 'Live Stream',
      album: 'Онлайн радио',
      artUri: _parseArtUri(defaultCoverUrl), // ✅ Используем ту же дефолтную обложку
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