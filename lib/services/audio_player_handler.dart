import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart'; 
import 'package:jrrplayerapp/services/audio_player_service.dart';

class AudioPlayerHandler extends BaseAudioHandler {
  final AudioPlayerService audioPlayerService;
  MediaItem? _currentMediaItem;

  AudioPlayerHandler(this.audioPlayerService) {
    // Инициализируем начальное состояние
    _updateMediaItem();
    
    // Слушаем изменения состояния из AudioPlayerService
    audioPlayerService.addListener(_onAudioServiceUpdate);
  }

  // Элементы управления для уведомления (Android) - только стандартные
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
  ];

  // Устанавливаем элементы управления в состоянии воспроизведения
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
    }
  }

  void updateMetadata(AudioMetadata metadata) {
    if (_currentMediaItem == null) {
      // Создаём новый MediaItem с базовыми данными
      _currentMediaItem = MediaItem(
        id: metadata.artist == 'Live Stream' ? 'jrr_live_stream' : 'podcast_${DateTime.now().millisecondsSinceEpoch}',
        title: metadata.title,
        artist: metadata.artist,
        album: metadata.album ?? '',
        artUri: metadata.artUrl != null ? Uri.parse(metadata.artUrl!) : null,
      );
    } else {
      // Обновляем существующий MediaItem
      _currentMediaItem = MediaItem(
        id: _currentMediaItem!.id,
        title: metadata.title,
        artist: metadata.artist,
        album: metadata.album ?? _currentMediaItem!.album,
        artUri: metadata.artUrl != null ? Uri.parse(metadata.artUrl!) : _currentMediaItem!.artUri,
      );
    }
    
    // Обновляем уведомление
    mediaItem.add(_currentMediaItem);
    debugPrint('Background audio metadata updated: ${metadata.title}');
    
    // Обновляем элементы управления
    _updateControls();
  }

  void updatePlaybackState(bool isPlaying) {
    playbackState.add(playbackState.value.copyWith(
      playing: isPlaying,
      processingState: isPlaying ? AudioProcessingState.ready : AudioProcessingState.idle,
      controls: _controls,
    ));
  }

  void _updateMediaItem() {
    // Создаём начальный MediaItem для радио
    _currentMediaItem = MediaItem(
      id: 'jrr_live_stream',
      title: 'J-Rock Radio',
      artist: 'Live Stream',
      album: 'Онлайн радио',
      artUri: Uri.parse('https://jrradio.ru/images/logo512.png'),
    );
    mediaItem.add(_currentMediaItem);
    
    // Устанавливаем начальные элементы управления
    _updateControls();
  }

  @override
  Future<void> play() async {
    debugPrint('Background audio: play');
    playbackState.add(playbackState.value.copyWith(
      playing: true,
      processingState: AudioProcessingState.ready,
      controls: _controls,
    ));
  }

  @override
  Future<void> pause() async {
    debugPrint('Background audio: pause');
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.ready,
      controls: _controls,
    ));
  }

  @override
  Future<void> stop() async {
    debugPrint('Background audio: stop');
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.idle,
      controls: _controls,
    ));
  }

  @override
  Future<void> seek(Duration position) async {
    debugPrint('Background audio: seek to $position');
    playbackState.add(playbackState.value.copyWith(
      updatePosition: position,
    ));
  }

  @override
  Future<void> skipToNext() async {
    // Реализация для переключения на следующий трек (если нужно)
  }

  @override
  Future<void> skipToPrevious() async {
    // Реализация для переключения на предыдущий трек (если нужно)
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    debugPrint('Background audio: playMediaItem ${mediaItem.title}');
    this.mediaItem.add(mediaItem);
    playbackState.add(playbackState.value.copyWith(
      playing: true,
      processingState: AudioProcessingState.ready,
      controls: _controls,
    ));
  }

  @override
  Future<void> onTaskRemoved() async {
    await super.onTaskRemoved();
    audioPlayerService.removeListener(_onAudioServiceUpdate);
  }
}