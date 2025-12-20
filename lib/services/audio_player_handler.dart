import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart'; 
import 'package:jrrplayerapp/services/audio_player_service.dart';
import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

class AudioPlayerHandler extends BaseAudioHandler {
  final AudioPlayerService audioPlayerService;
  MediaItem? _currentMediaItem;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  bool _isHandlingControl = false; // Флаг для предотвращения циклов

  AudioPlayerHandler(this.audioPlayerService) {
    // Инициализируем начальное состояние
    _updateMediaItem();
    
    // Слушаем изменения состояния из AudioPlayerService
    audioPlayerService.addListener(_onAudioServiceUpdate);
    
    // Подписываемся на потоки позиции и длительности
    _setupPositionStream();
  }

  void _setupPositionStream() {
    // Отписываемся от старых подписок если есть
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    
    final player = audioPlayerService.getPlayer();
    if (player != null) {
      _positionSubscription = player.positionStream.listen((position) {
        _updatePlaybackPosition(position);
      });
      
      _durationSubscription = player.durationStream.listen((duration) {
        _updatePlaybackDuration(duration);
      });
    }
  }

  void _updatePlaybackPosition(Duration position) {
    // Обновляем позицию в состоянии воспроизведения
    playbackState.add(playbackState.value.copyWith(
      updatePosition: position,
    ));
  }

  void _updatePlaybackDuration(Duration? duration) {
    // Обновляем длительность в MediaItem
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
      androidIcon: 'drawable/ic_rewind',
      label: 'Назад',
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
      androidIcon: 'drawable/ic_fast_forward',
      label: 'Вперед',
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
    // Игнорируем обновления, если мы сами вызвали управление
    if (_isHandlingControl) return;
    
    final metadata = audioPlayerService.currentMetadata;
    final player = audioPlayerService.getPlayer();
    
    if (metadata != null) {
      updateMetadata(metadata);
    }
    
    if (player != null) {
      updatePlaybackState(player.playing);
      _setupPositionStream(); // Переподписываемся на потоки
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
    
    playbackState.add(PlaybackState(
      controls: _controls,
      systemActions: actions.toSet(),
      androidCompactActionIndices: const [2, 3, 6], // play/pause, stop
      playing: isPlaying,
      updatePosition: position,
      bufferedPosition: duration ?? Duration.zero,
      speed: 1.0,
      queueIndex: 0,
      processingState: isPlaying 
          ? AudioProcessingState.ready 
          : AudioProcessingState.idle,
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
    
    _updateControls();
  }

  @override
  Future<void> play() async {
    if (_isHandlingControl) return;
    _isHandlingControl = true;
    
    debugPrint('Background audio: play called, isPodcastMode: ${audioPlayerService.isPodcastMode}');
    try {
      // ВОЗОБНОВЛЯЕМ воспроизведение через сервис
      if (audioPlayerService.isPodcastMode && audioPlayerService.currentEpisode != null) {
        final player = audioPlayerService.getPlayer();
        if (player != null && !player.playing) {
          await player.play();
        }
      } else {
        // Для радио: ВСЕГДА перезапускаем, даже если плеер существует
        // Это важно, потому что после паузы радио могло быть полностью остановлено
        await audioPlayerService.playRadio();
      }
    } catch (e) {
      debugPrint('Error in background play: $e');
    } finally {
      _isHandlingControl = false;
    }
  }

  @override
  Future<void> pause() async {
    if (_isHandlingControl) return;
    _isHandlingControl = true;
    
    debugPrint('Background audio: pause called, isPodcastMode: ${audioPlayerService.isPodcastMode}');
    try {
      // Для радио останавливаем полностью, для подкаста - пауза
      if (audioPlayerService.isPodcastMode) {
        // Подкаст: ставим на паузу через player
        final player = audioPlayerService.getPlayer();
        if (player != null && player.playing) {
          await player.pause();
          // Сохраняем позицию для подкастов
          if (audioPlayerService.currentEpisode != null) {
            final position = player.position;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setInt(
              'position_${audioPlayerService.currentEpisode!.id}', 
              position.inMilliseconds
            );
          }
        }
      } else {
        // Радио: останавливаем полностью через сервис
        await audioPlayerService.pause();
      }
    } catch (e) {
      debugPrint('Error in background pause: $e');
    } finally {
      _isHandlingControl = false;
    }
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
        // Для радио вызываем специальный метод остановки
        await audioPlayerService.pause(); // pause уже останавливает радио
      }
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
    }
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    if (_isHandlingControl) return;
    _isHandlingControl = true;
    
    debugPrint('Background audio: playMediaItem ${mediaItem.title}');
    this.mediaItem.add(mediaItem);
    playbackState.add(playbackState.value.copyWith(
      playing: true,
      processingState: AudioProcessingState.ready,
      controls: _controls,
    ));
    
    _isHandlingControl = false;
  }

  @override
  Future<void> onTaskRemoved() async {
    await super.onTaskRemoved();
    audioPlayerService.removeListener(_onAudioServiceUpdate);
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
  }
}