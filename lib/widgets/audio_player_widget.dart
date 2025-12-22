import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:jrrplayerapp/constants/app_colors.dart';
import 'dart:async';
import 'package:jrrplayerapp/services/audio_player_service.dart';
import 'package:provider/provider.dart';

/// A tiny wrapper that turns a [Stream<T>] into a [ValueListenable<T>].
/// It listens to the stream and notifies listeners on every emission.
class _StreamValueNotifier<T> extends ValueNotifier<T> {
  final Stream<T> _stream;
  late final StreamSubscription<T> _subscription;

  _StreamValueNotifier(this._stream, T initialValue) : super(initialValue) {
    _subscription = _stream.listen((value) => this.value = value);
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

class AudioPlayerWidget extends StatefulWidget {
  const AudioPlayerWidget({super.key});

  @override
  State<AudioPlayerWidget> createState() => _AudioPlayerWidgetState();
}

class _AudioPlayerWidgetState extends State<AudioPlayerWidget> {
  late AudioPlayerService _audioService;
  late final ValueNotifier<bool> _playingNotifier;
  late final ValueNotifier<Duration?> _positionNotifier;
  late final ValueNotifier<Duration?> _durationNotifier;
  late final ValueNotifier<AudioMetadata?> _metadataNotifier;
  late final ValueNotifier<int> _imageUpdateNotifier;
  late final ValueNotifier<double> _volumeNotifier;
  bool _isToggling = false;

  @override
  void initState() {
    super.initState();
    
    _audioService = Provider.of<AudioPlayerService>(context, listen: false);
    debugPrint('🎵 AudioPlayerWidget initState');
    debugPrint('🎵 Initial metadata - Title: "${_audioService.currentMetadata?.title}", Artist: "${_audioService.currentMetadata?.artist}"');
    debugPrint('🎵 Current episode: ${_audioService.currentEpisode?.title}');
    debugPrint('🎵 Is podcast mode: ${_audioService.isPodcastMode}');
    debugPrint('🎵 AudioHandler available: ${_audioService.audioHandler != null}');
    
     // Восстанавливаем состояние из сервиса при инициализации
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncPlayerState();
    });

    _initializeNotifiers();
    _setupDurationSync();
      
    // Добавляем периодическую проверку состояния
    _setupStateSync();    
  }

  void _setupStateSync() {
    // Проверяем состояние каждые 500мс (на всякий случай)
    Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (mounted) {
        // Только логируем, не обновляем UI каждый раз
        final player = _audioService.getPlayer();
        if (player != null && _playingNotifier.value != player.playing) {
          debugPrint('State mismatch detected, syncing...');
          _syncPlayerState();
        }
      } else {
        timer.cancel();
      }
    });
  }

  void _initializeNotifiers() {
    final player = _audioService.getPlayer();
    debugPrint('🎵 Player state: playing=${player?.playing}, position=${player?.position}');

    _playingNotifier = _StreamValueNotifier<bool>(
      player?.playingStream ?? Stream.value(false),
      player?.playing ?? false,
    );

    _positionNotifier = _StreamValueNotifier<Duration?>(
      player?.positionStream ?? Stream.value(Duration.zero),
      player?.position ?? Duration.zero,
    );

    _durationNotifier = _StreamValueNotifier<Duration?>(
      player?.durationStream ?? Stream.value(null),
      player?.duration,
    );

    _volumeNotifier = _StreamValueNotifier<double>(
      player?.volumeStream ?? Stream.value(1.0),
      player?.volume ?? 1.0,
    );

    _metadataNotifier = ValueNotifier(_audioService.currentMetadata);
    _imageUpdateNotifier = ValueNotifier(0);

    _audioService.addListener(_onAudioServiceUpdate);
  }

  void _setupDurationSync() {
    // Синхронизируем длительность из плеера с моделью подкаста
    _durationNotifier.addListener(() {
      final duration = _durationNotifier.value;
      if (duration != null && duration > Duration.zero) {
        _audioService.updatePodcastDuration(duration);
      }
    });
  }

  void _onAudioServiceUpdate() {
    if (!mounted) return;
    
    debugPrint('🎵 AudioService update received');
    
    // Синхронизируем состояние плеера при любом обновлении сервиса
    _syncPlayerState();
    
    // Обновляем метаданные
    final newMetadata = _audioService.currentMetadata;
    _metadataNotifier.value = newMetadata;
    _imageUpdateNotifier.value++;
    
    // Принудительное обновление UI
    setState(() {});
  }

  Future<void> _playRadio() async {
    try {
      await _audioService.playRadio();
      if (mounted) {
        _syncPlayerState();
        setState(() {});
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error playing radio: $e')),
      );
    }
  }

  Future<void> _togglePlayPause() async {
    if (_isToggling) return;
    _isToggling = true;

    try {
      final isCurrentlyPlaying = _audioService.isPlaying;

      if (isCurrentlyPlaying) {
        debugPrint('Pausing playback');
        await _audioService.pause();
      } else {
        debugPrint('Resuming playback');
        if (_audioService.isPodcastMode && _audioService.currentEpisode != null) {
          await _audioService.getPlayer()?.play();
        } else {
          await _audioService.playRadio();
        }
      }

      // После операции синхронизируем состояние — это источник истины
      if (mounted) {
        _syncPlayerState();
      }
    } catch (e) {
      debugPrint('Error in toggle: $e');
      if (mounted) {
        _syncPlayerState(); // Восстанавливаем реальное состояние
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка воспроизведения: $e')),
        );
      }
    } finally {
      _isToggling = false;
    }
  }

  void _syncPlayerState() {
    final player = _audioService.getPlayer();
    if (player != null) {
      final isPlaying = player.playing;
      final position = player.position;
      final duration = player.duration;
      
      debugPrint('🎵 Syncing player state:');
      debugPrint('🎵   Playing: $isPlaying');
      debugPrint('🎵   Position: $position');
      debugPrint('🎵   Duration: $duration');
      
      // Обновляем все нотифаеры только если значения изменились
      if (_playingNotifier.value != isPlaying) {
        _playingNotifier.value = isPlaying;
      }
      
      if (_positionNotifier.value != position) {
        _positionNotifier.value = position;
      }
      
      if (_durationNotifier.value != duration) {
        _durationNotifier.value = duration;
      }
      
      // Обновляем UI только если действительно нужно
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {});
          }
        });
      }
    }
  }

  Future<void> _setVolume(double volume) async {
    try {
      final player = _audioService.getPlayer();
      await player?.setVolume(volume);
      _volumeNotifier.value = volume;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error setting volume: $e')),
      );
    }
  }

  // Добавляем аннотацию @pragma чтобы избежать предупреждения о неиспользуемом методе
  @pragma('vm:prefer-inline')
  Future<void> _increaseVolume() async {
    try {
      final currentVolume = _volumeNotifier.value;
      final newVolume = (currentVolume + 0.1).clamp(0.0, 1.0);
      await _setVolume(newVolume);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error increasing volume: $e')),
      );
    }
  }

  // Добавляем аннотацию @pragma чтобы избежать предупреждения о неиспользуемом методе
  @pragma('vm:prefer-inline')
  Future<void> _decreaseVolume() async {
    try {
      final currentVolume = _volumeNotifier.value;
      final newVolume = (currentVolume - 0.1).clamp(0.0, 1.0);
      await _setVolume(newVolume);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error decreasing volume: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Адаптивные размеры в зависимости от доступного пространства
        final bool isCompact = constraints.maxHeight < 400;
        final double coverSize = isCompact ? 48.0 : 64.0;
        final double iconSize = isCompact ? 40.0 : 50.0;
        final double smallSpacing = isCompact ? 4.0 : 8.0;
        final double mediumSpacing = isCompact ? 8.0 : 12.0;
        final double largeSpacing = isCompact ? 12.0 : 16.0;

        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Кнопки управления
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Кнопка "Предыдущий"
                    IconButton(
                      icon: const Icon(Icons.skip_previous, size: 30),
                      onPressed: _audioService.isPodcastMode 
                          ? _playPreviousPodcast
                          : null, // Для радио можно сделать переключение станций
                      color: _audioService.isPodcastMode ? Colors.white : Colors.grey,
                    ),
                    SizedBox(width: mediumSpacing),
                    
                    // Кнопка воспроизведения/паузы
                    ValueListenableBuilder<bool>(
                      valueListenable: _playingNotifier,
                      builder: (context, playing, __) {
                        // Получаем фактическое состояние из сервиса как источник истины
                        final actualPlaying = _audioService.isPlaying;
                        
                        // Синхронизируем, если есть расхождение
                        if (playing != actualPlaying && !_isToggling) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              _playingNotifier.value = actualPlaying;
                            }
                          });
                        }
                        
                        return IconButton(
                          icon: Icon(
                            playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
                            size: iconSize,
                          ),
                          onPressed: () async {
                            // Отключаем кнопку на время выполнения операции
                            if (_isToggling) return;
                            _isToggling = true;
                            
                            try {
                              await _togglePlayPause();
                            } finally {
                              _isToggling = false;
                            }
                          },
                          color: Colors.white,
                        );
                      },
                    ),
                    SizedBox(width: mediumSpacing),
                    
                    // Кнопка "Следующий"
                    IconButton(
                      icon: const Icon(Icons.skip_next, size: 30),
                      onPressed: _audioService.isPodcastMode 
                          ? _playNextPodcast
                          : null, // Для радио можно сделать переключение станций
                      color: _audioService.isPodcastMode ? AppColors.customWhite : Colors.grey,
                    ),
                  ],
                ),
                SizedBox(height: largeSpacing),

                // Регулятор громкости с кнопками
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: largeSpacing),
                  child: Row(
                    children: [
                      // Кнопка "Тише"
                      IconButton(
                        icon: const Icon(Icons.volume_down),
                        onPressed: _decreaseVolume, // Метод используется здесь
                        color: AppColors.customWhite,
                        iconSize: 24,
                        tooltip: 'Тише',
                      ),
                      SizedBox(width: smallSpacing),
                      
                      // Ползунок громкости
                      Expanded(
                        child: ValueListenableBuilder<double>(
                          valueListenable: _volumeNotifier,
                          builder: (_, volume, __) {
                            return Slider(
                              value: volume,
                              min: 0.0,
                              max: 1.0,
                              divisions: 10,
                              onChanged: (value) {
                                _volumeNotifier.value = value;
                              },
                              onChangeEnd: (value) {
                                _setVolume(value);
                              },
                              activeColor: Theme.of(context).colorScheme.primary,
                              inactiveColor: Colors.grey[700],
                            );
                          },
                        ),
                      ),
                      SizedBox(width: smallSpacing),
                      
                      // Кнопка "Громче"
                      IconButton(
                        icon: const Icon(Icons.volume_up),
                        onPressed: _increaseVolume, // Метод используется здесь
                        color: AppColors.customWhite,
                        iconSize: 24,
                        tooltip: 'Громче',
                      ),
                    ],
                  ),
                ),
                SizedBox(height: largeSpacing),
               
                // Прогресс-бар (только для подкастов)
                if (_audioService.isPodcastMode) ...[
                  SizedBox(
                    width: 300,
                    child: Column(
                      children: [
                        ValueListenableBuilder2<Duration?, Duration?>(
                          first: _positionNotifier,
                          second: _durationNotifier,
                          builder: (_, position, duration, __) {
                            final pos = position ?? Duration.zero;
                            final dur = duration ?? Duration.zero;
                            final progress = dur.inMilliseconds > 0
                                ? pos.inMilliseconds / dur.inMilliseconds
                                : 0.0;

                            return LinearProgressIndicator(
                              value: progress,
                              backgroundColor: AppColors.customWhiteTransp,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Theme.of(context).colorScheme.primary,
                              ),
                            );
                          },
                        ),
                        SizedBox(height: smallSpacing),
                        
                        ValueListenableBuilder2<Duration?, Duration?>(
                          first: _positionNotifier,
                          second: _durationNotifier,
                          builder: (_, position, duration, __) {
                            final pos = position ?? Duration.zero;
                            final dur = duration ?? Duration.zero;
                            return Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _format(pos),
                                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                                ),
                                Text(
                                  _format(dur),
                                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: largeSpacing),
                ],
                
                // Название трека с названием альбома
                ValueListenableBuilder<AudioMetadata?>(
                  valueListenable: _metadataNotifier,
                  builder: (_, metadata, __) {
                    String trackText = metadata?.title ?? 'J-Rock Radio';
                    if (metadata?.album != null && metadata!.album!.isNotEmpty) {
                      trackText = '${metadata.title} - ${metadata.album}';
                    }
                    
                    return Padding(
                      padding: EdgeInsets.symmetric(horizontal: largeSpacing),
                      child: Text(
                        trackText,
                        style: TextStyle(
                          fontSize: isCompact ? 12 : 14,
                          color: AppColors.customWhite,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
                SizedBox(height: mediumSpacing),
                
                // Обложка альбома
                ValueListenableBuilder<int>(
                  valueListenable: _imageUpdateNotifier,
                  builder: (_, imageVersion, __) {
                    return ValueListenableBuilder<AudioMetadata?>(
                      valueListenable: _metadataNotifier,
                      builder: (_, metadata, __) {
                        return Container(
                          width: coverSize,
                          height: coverSize,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: const [
                              BoxShadow(
                                color: AppColors.customStyleShadow,
                                blurRadius: 6,
                                offset: Offset(0, 3),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: _buildCoverImage(metadata, imageVersion),
                          ),
                        );
                      },
                    );
                  },
                ),
                SizedBox(height: mediumSpacing),
                
                // Исполнитель
                ValueListenableBuilder<AudioMetadata?>(
                  valueListenable: _metadataNotifier,
                  builder: (_, metadata, __) {
                    return Text(
                      metadata?.artist ?? 'Live Stream',
                      style: TextStyle(
                        fontSize: isCompact ? 16 : 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.customWhite,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    );
                  },
                ),
                
                SizedBox(height: largeSpacing),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCoverImage(AudioMetadata? metadata, int imageVersion) {
    String? imageUrl = _getImageUrl(metadata);
    
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return Image.network(
        imageUrl,
        fit: BoxFit.cover,
        key: ValueKey('$imageUrl$imageVersion'),
        // Используем cacheWidth для оптимизации
        cacheWidth: 150, // Оптимальный размер для маленьких обложек
        filterQuality: FilterQuality.low,
        errorBuilder: (context, error, stackTrace) {
          return _buildDefaultCover();
        },
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          // Упрощенный индикатор загрузки
          return Container(
            color: Colors.grey[300],
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: loadingProgress.expectedTotalBytes != null
                      ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                      : null,
                ),
              ),
            ),
          );
        },
      );
    } else {
      return _buildDefaultCover();
    }
  }

  String? _getImageUrl(AudioMetadata? metadata) {
    if (metadata?.artUrl != null && metadata!.artUrl!.isNotEmpty) {
      return metadata.artUrl;
    }
    
    final episode = _audioService.currentEpisode;
    if (episode != null) {
      if (episode.imageUrl != null && episode.imageUrl!.isNotEmpty) {
        return episode.imageUrl;
      }
      if (episode.channelImageUrl != null && episode.channelImageUrl!.isNotEmpty) {
        return episode.channelImageUrl;
      }
    }
    
    return null;
  }

  Widget _buildDefaultCover() {
    return Image.asset(
      'assets/images/default_cover.png',
      fit: BoxFit.cover,
    );
  }

  String _format(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    
    if (d.inHours > 0) {
      final hours = d.inHours.toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    } else {
      return '$minutes:$seconds';
    }
  }

  Future<void> _playNextPodcast() async {
    try {
      await _audioService.playNextPodcast();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error playing next podcast: $e')),
      );
    }
  }

  Future<void> _playPreviousPodcast() async {
    try {
      await _audioService.playPreviousPodcast();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error playing previous podcast: $e')),
      );
    }
  }

  @override
  void dispose() {
    _playingNotifier.dispose();
    _positionNotifier.dispose();
    _durationNotifier.dispose();
    _metadataNotifier.dispose();
    _imageUpdateNotifier.dispose();
    _volumeNotifier.dispose();
    _audioService.removeListener(_onAudioServiceUpdate);
    super.dispose();
  }
}

// Вспомогательный класс для двух ValueNotifier
class ValueListenableBuilder2<A, B> extends StatelessWidget {
  final ValueListenable<A> first;
  final ValueListenable<B> second;
  final Widget Function(BuildContext context, A a, B b, Widget? child) builder;
  final Widget? child;

  const ValueListenableBuilder2({
    super.key, // Исправлено: используем super.key
    required this.first,
    required this.second,
    required this.builder,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<A>(
      valueListenable: first,
      builder: (_, a, __) {
        return ValueListenableBuilder<B>(
          valueListenable: second,
          builder: (context, b, __) {
            return builder(context, a, b, child);
          },
        );
      },
    );
  }
}