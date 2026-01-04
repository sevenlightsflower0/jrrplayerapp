import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart'; 
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
    _playingSubscription?.cancel(); // NEW
    _processingSubscription?.cancel(); // NEW
    
    final player = audioPlayerService.getPlayer();
    if (player != null) {
      _positionSubscription = player.positionStream.listen((position) {
        _updatePlaybackPosition(position);
      });
      
      _durationSubscription = player.durationStream.listen((duration) {
        _updatePlaybackDuration(duration);
      });
      
      // NEW: Listen to playing state changes
      _playingSubscription = player.playingStream.listen((isPlaying) {
        updatePlaybackState(isPlaying);
      });
      
      // NEW: Listen to processing state changes
      _processingSubscription = player.processingStateStream.listen((state) {
        updatePlaybackState(player.playing);
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

  // Элементы управления для уведомления (Android)
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
    playbackState.add(currentState.copyWith(
      controls: _controls,
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
        artUri: metadata.artUrl != null ? Uri.parse(metadata.artUrl!) : null,
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
        artUri: metadata.artUrl != null ? Uri.parse(metadata.artUrl!) : _currentMediaItem!.artUri,
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
      controls: _controls,
      systemActions: actions.toSet(),
      androidCompactActionIndices: const [2, 3, 6], // play/pause, stop
      playing: isPlaying,
      updatePosition: position,
      bufferedPosition: duration ?? Duration.zero,
      speed: 1.0,
      queueIndex: 0,
      processingState: processingState,
    ));
    
    // NEW: Refresh controls after state update
    _updateControls();
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
    
    _updateControls();
  }

  @override
  Future<void> play() async {
    if (_isHandlingControl) return;
    _isHandlingControl = true;
    
    debugPrint('Background audio: play called, isPodcastMode: ${audioPlayerService.isPodcastMode}');
    try {
      final player = audioPlayerService.getPlayer();
      
      if (audioPlayerService.isPodcastMode && audioPlayerService.currentEpisode != null) {
        // Подкаст: просто возобновляем
        if (player != null && !player.playing) {
          await player.play();
        }
      } else {
        // Радио: явно запускаем радио
        await audioPlayerService.playRadio();
      }
    } catch (e) {
      debugPrint('Error in background play: $e');
    } finally {
      _isHandlingControl = false;
      // REMOVED: Delayed update (handled by streams now)
    }
  }

  @override
  Future<void> pause() async {
    if (_isHandlingControl) return;
    _isHandlingControl = true;
    
    debugPrint('Background audio: pause called, isPodcastMode: ${audioPlayerService.isPodcastMode}');
    try {
      await audioPlayerService.pause();
    } catch (e) {
      debugPrint('Error in background pause: $e');
    } finally {
      _isHandlingControl = false;
      // REMOVED: Delayed update
    }
  }

  // REMOVED: _updatePlaybackStateAfterAction() (replaced by stream listeners)

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
    } catch (e) {
      debugPrint('Error in background stop: $e');
    } finally {
      _isHandlingControl = false;
      // REMOVED: Delayed update
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