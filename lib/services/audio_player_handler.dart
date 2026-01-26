import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart'; // ADDED: Import for WidgetsBinding
import 'package:jrrplayerapp/services/audio_player_service.dart';
import 'dart:async';
import 'package:just_audio/just_audio.dart';

class AudioPlayerHandler extends BaseAudioHandler {
  final AudioPlayerService audioPlayerService;
  MediaItem? _currentMediaItem;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription; // NEW: Listener for playing state
  StreamSubscription<ProcessingState>? _processingSubscription; // NEW: Listener for processing state
  bool _isHandlingControl = false;

  AudioPlayerHandler(this.audioPlayerService) {
    // Инициализируем начальное состояние
    _updateMediaItem();
    
    // Слушаем изменения состояния из AudioPlayerService
    audioPlayerService.addListener(_onAudioServiceUpdate);
    
    // Подписываемся на потоки позиции и длительности
    _setupStreams(); // CHANGED: Combined setup
  }

  void _setupStreams() {
    // Отписываемся от старых подписок если есть
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
      
      // Слушаем изменения состояния playing
      _playingSubscription = player.playingStream.listen((isPlaying) {
        debugPrint('Background: playingStream changed to $isPlaying');
        updatePlaybackState(isPlaying); // CHANGED: Removed delay for faster sync
      });
      
      // Слушаем изменения состояния обработки
      _processingSubscription = player.processingStateStream.listen((state) {
        debugPrint('Background: processingState changed to $state');
        updatePlaybackState(player.playing); // CHANGED: Removed delay for faster sync
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

  List<MediaControl> get _controls => const [
    MediaControl(
      androidIcon: 'drawable/ic_skip_previous',
      label: 'Предыдущий',
      action: MediaAction.skipToPrevious,
    ),
    MediaControl(
      androidIcon: 'drawable/ic_rewind_30s',
      label: '30 секунд назад',
      action: MediaAction.rewind,
    ),
    MediaControl(
      androidIcon: 'drawable/ic_play',
      label: 'Воспроизвести',
      action: MediaAction.play,
    ),
    MediaControl(
      androidIcon: 'drawable/ic_pause',
      label: 'Пауза',
      action: MediaAction.pause,
    ),
    MediaControl(
      androidIcon: 'drawable/ic_fast_forward_30s',
      label: '30 секунд вперед',
      action: MediaAction.fastForward,
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
  ];

  void _updateControls() {
    final currentState = playbackState.value;
    final isPlaying = currentState.playing;
    
    // Создаем динамические контролы как в updatePlaybackState
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
      updatePlaybackState(player.playing);
      _setupStreams(); // Переподписываемся на потоки
    }
  }

  void updateMetadata(AudioMetadata metadata) {
    // Для подкастов добавляем длительность в MediaItem
    Duration? duration;
    if (audioPlayerService.isPodcastMode && audioPlayerService.currentEpisode != null) {
      duration = audioPlayerService.currentEpisode?.duration;
    }
    
    if (_currentMediaItem == null) {
      _currentMediaItem = MediaItem(
        id: metadata.artist == 'Live Stream' ? 'jrr_live_stream' : 'podcast_${DateTime.now().millisecondsSinceEpoch}',
        title: metadata.title,
        artist: metadata.artist,
        album: metadata.album ?? '',
        artUri: Uri.parse(metadata.artUrl),
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
        artUri: Uri.parse(metadata.artUrl),
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

  void updatePlaybackState(bool isPlaying) {
    final player = audioPlayerService.getPlayer();
    final position = player?.position ?? Duration.zero;
    final duration = player?.duration;
    
    // Создаем список доступных действий
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
    
    // Для радио отключаем некоторые элементы управления
    if (!audioPlayerService.isPodcastMode) {
      actions.remove(MediaAction.seek);
      actions.remove(MediaAction.skipToNext);
      actions.remove(MediaAction.skipToPrevious);
    }

    // Динамические controls: заменяем play/pause в зависимости от isPlaying
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
      if (!isPlaying)  // Только play, если не играет
        const MediaControl(
          androidIcon: 'drawable/ic_play',
          label: 'Воспроизвести',
          action: MediaAction.play,
        ),
      if (isPlaying)  // Только pause, если играет
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

    // Обновите compact indices динамически
    final List<int> compactIndices = isPlaying 
        ? [0, 3, 6]  // prev, pause, stop (индексы в dynamicControls)
        : [0, 2, 6]; // prev, play, stop  
    
    // CHANGED: Map just_audio ProcessingState to audio_service AudioProcessingState
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
    _currentMediaItem = MediaItem(
      id: 'jrr_live_stream',
      title: 'J-Rock Radio',
      artist: 'Live Stream',
      album: 'Онлайн радио',
      artUri: Uri.parse('https://jrradio.ru/images/logo512.png'),
      extras: {'isRadio': true},
    );
    mediaItem.add(_currentMediaItem);
    
    // Обновляем состояние с правильными контролами
    updatePlaybackState(false); // По умолчанию не играет
  }

  @override
  Future<void> play() async {
    if (_isHandlingControl) return;
    _isHandlingControl = true;
    
    debugPrint('🎵 Background audio: play called, isPodcastMode: ${audioPlayerService.isPodcastMode}');
    try {
      // Гарантируем инициализацию сервиса
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
        // Подкаст
        debugPrint('🎵 Background: Playing podcast');
        final player = audioPlayerService.getPlayer();
        if (player != null && !player.playing) {
          await player.play();
          debugPrint('🎵 Podcast resumed from background');
        }
      } else {
        // Радио
        debugPrint('🎵 Background: Handling radio play');
        
        // ✅ ИСПРАВЛЕНИЕ: Используем метод toggleRadio, который сам решит что делать
        await audioPlayerService.toggleRadio();
      }
      
      // ✅ ИСПРАВЛЕНИЕ: Обновляем состояние СРАЗУ без задержки
      final newPlayingState = audioPlayerService.isPlaying;
      debugPrint('🎵 Background: Updating playback state to $newPlayingState');
      updatePlaybackState(newPlayingState);
      
    } catch (e, stackTrace) {
      debugPrint('🎵 Error in background play: $e');
      debugPrint('Stack trace: $stackTrace');
      updatePlaybackState(false);
    } finally {
      _isHandlingControl = false;
    }
  }

  @override
  Future<void> pause() async {
    if (_isHandlingControl) return;
    _isHandlingControl = true;
    
    debugPrint('🎵 Background audio: pause called, isPodcastMode: ${audioPlayerService.isPodcastMode}');
    try {
      final player = audioPlayerService.getPlayer();
      final wasPlaying = player?.playing ?? false;
      
      debugPrint('🎵 Background pause: player was playing = $wasPlaying');
      
      if (wasPlaying) {
        // ✅ ИСПРАВЛЕНИЕ: Для радио используем pauseRadio(), для подкаста - pause()
        if (audioPlayerService.isPodcastMode) {
          await audioPlayerService.pause();
        } else {
          await audioPlayerService.pauseRadio();
        }
        
        debugPrint('🎵 Background pause: audio paused successfully');
      } else {
        debugPrint('🎵 Background pause: player was already paused');
      }
      
      // ✅ ИСПРАВЛЕНИЕ: Обновляем состояние СРАЗУ
      updatePlaybackState(false);
      
    } catch (e, stackTrace) {
      debugPrint('🎵 Error in background pause: $e');
      debugPrint('Stack trace: $stackTrace');
      updatePlaybackState(false);
    } finally {
      _isHandlingControl = false;
    }
  }
    
  // Новый метод для принудительного обновления UI
  void forceUpdateUI(bool isPlaying) {
    updatePlaybackState(isPlaying);
    _updateControls();
  }

  @override
  Future<void> stop() async {
    if (_isHandlingControl) return;
    _isHandlingControl = true;
    
    debugPrint('Background audio: stop called, isPodcastMode: ${audioPlayerService.isPodcastMode}');
    try {
      // Для радио и подкаста останавливаем через сервис
      if (audioPlayerService.isPodcastMode) {
        await audioPlayerService.stopPodcast();
      } else {
        // Для радио останавливаем полностью
        await audioPlayerService.stopRadio();
      }
      // Обновляем состояние в UI
      updatePlaybackState(false);
      // Дополнительная синхронизация
      _onAudioServiceUpdate();
    } catch (e) {
      debugPrint('Error in background stop: $e');
    } finally {
      _isHandlingControl = false;
    }
  }

  @override
  Future<void> seek(Duration position) async {
    if (_isHandlingControl) return;
    _isHandlingControl = true;
    
    debugPrint('Background audio: seek to $position');
    try {
      if (audioPlayerService.isPodcastMode) {
        await audioPlayerService.seekPodcast(position);
      }
    } catch (e) {
      debugPrint('Error in background seek: $e');
    } finally {
      _isHandlingControl = false;
      // REMOVED: Delayed update
    }
  }

  @override
  Future<void> skipToNext() async {
    if (_isHandlingControl) return;
    _isHandlingControl = true;
    
    debugPrint('Background audio: skipToNext');
    try {
      if (audioPlayerService.isPodcastMode) {
        await audioPlayerService.playNextPodcast();
      }
    } catch (e) {
      debugPrint('Error in background skipToNext: $e');
    } finally {
      _isHandlingControl = false;
      // REMOVED: Delayed update
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_isHandlingControl) return;
    _isHandlingControl = true;
    
    debugPrint('Background audio: skipToPrevious');
    try {
      if (audioPlayerService.isPodcastMode) {
        await audioPlayerService.playPreviousPodcast();
      }
    } catch (e) {
      debugPrint('Error in background skipToPrevious: $e');
    } finally {
      _isHandlingControl = false;
      // REMOVED: Delayed update
    }
  }

  @override
  Future<void> rewind() async {
    if (_isHandlingControl) return;
    _isHandlingControl = true;
    
    debugPrint('Background audio: rewind');
    try {
      if (audioPlayerService.isPodcastMode) {
        final player = audioPlayerService.getPlayer();
        final currentPosition = player?.position ?? Duration.zero;
        final newPosition = currentPosition - const Duration(seconds: 15);
        if (newPosition > Duration.zero) {
          await audioPlayerService.seekPodcast(newPosition);
        } else {
          await audioPlayerService.seekPodcast(Duration.zero);
        }
      }
    } catch (e) {
      debugPrint('Error in background rewind: $e');
    } finally {
      _isHandlingControl = false;
      // REMOVED: Delayed update
    }
  }

  @override
  Future<void> fastForward() async {
    if (_isHandlingControl) return;
    _isHandlingControl = true;
    
    debugPrint('Background audio: fastForward');
    try {
      if (audioPlayerService.isPodcastMode) {
        final player = audioPlayerService.getPlayer();
        final currentPosition = player?.position ?? Duration.zero;
        final duration = player?.duration ?? const Duration(hours: 1);
        final newPosition = currentPosition + const Duration(seconds: 30);
        if (newPosition < duration) {
          await audioPlayerService.seekPodcast(newPosition);
        } else {
          await audioPlayerService.seekPodcast(duration - const Duration(seconds: 1));
        }
      }
    } catch (e) {
      debugPrint('Error in background fastForward: $e');
    } finally {
      _isHandlingControl = false;
      // REMOVED: Delayed update
    }
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    if (_isHandlingControl) return;
    _isHandlingControl = true;
    
    debugPrint('Background audio: playMediaItem ${mediaItem.title}');
    try {
      this.mediaItem.add(mediaItem);
      playbackState.add(playbackState.value.copyWith(
        playing: true,
        processingState: AudioProcessingState.ready,
        controls: _controls,
      ));
    } finally {
      _isHandlingControl = false;
    }
  }

  @override
  Future<void> onTaskRemoved() async {
    await super.onTaskRemoved();
    audioPlayerService.removeListener(_onAudioServiceUpdate);
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel(); // NEW
    _processingSubscription?.cancel(); // NEW
  }
}