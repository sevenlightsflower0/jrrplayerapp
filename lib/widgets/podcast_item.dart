import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:jrrplayerapp/repositories/podcast_repository.dart';
import 'package:provider/provider.dart';
import 'package:jrrplayerapp/constants/app_colors.dart';
import 'package:jrrplayerapp/models/podcast.dart';
import 'package:jrrplayerapp/services/audio_player_service.dart';
import 'package:cached_network_image/cached_network_image.dart';

class PodcastItem extends StatefulWidget {
  final PodcastEpisode podcast;

  const PodcastItem({super.key, required this.podcast});

  @override
  State<PodcastItem> createState() => _PodcastItemState();
}

class _PodcastItemState extends State<PodcastItem> {
  bool _isLoading = false;
  bool _isSeeking = false;
  double _sliderValue = 0.0;
  Duration _currentPosition = Duration.zero;
  late AudioPlayerService _audioService;

  @override
  void initState() {
    super.initState();
    _audioService = Provider.of<AudioPlayerService>(context, listen: false);
    _currentPosition = widget.podcast.currentPosition;
  
    // Слушаем изменения метаданных для обновления длительности
    _audioService.addListener(_onAudioServiceUpdate);
  }

  void _onAudioServiceUpdate() {
    if (mounted) {
      // Обновляем длительность, если текущий подкаст активен
      if (_audioService.currentEpisode?.id == widget.podcast.id) {
        final currentDuration = _audioService.currentEpisode?.duration;
        if (currentDuration != null && currentDuration > Duration.zero) {
          setState(() {
            // Обновляем длительность в виджете
          });
        }
      }
    }
  }

  @override
  void dispose() {
    _audioService.removeListener(_onAudioServiceUpdate);
    super.dispose();
  }

  // ДОБАВЛЕННЫЕ МЕТОДЫ:

  Widget _buildImage() {
    if (widget.podcast.imageUrl != null && widget.podcast.imageUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CachedNetworkImage(
          imageUrl: widget.podcast.imageUrl!,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorWidget: (context, url, error) => _buildDefaultImage(),
          placeholder: (context, url) => _buildDefaultImage(),
        ),
      );
    } else {
      return _buildDefaultImage();
    }
  }

  Widget _buildDefaultImage() {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.grey[800],
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Icon(
        Icons.audiotrack,
        color: Colors.white,
        size: 20,
      ),
    );
  }

  Future<void> _togglePlayPause(AudioPlayerService audioService) async {
    setState(() {
      _isLoading = true;
    });

    try {
      await audioService.togglePodcastPlayback(widget.podcast);
    } catch (e) {
      if (mounted) {
        _showErrorSnackBar('Ошибка воспроизведения: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _seekPodcast(double value, AudioPlayerService audioService) {
    final newPosition = Duration(
      milliseconds: (value * widget.podcast.duration.inMilliseconds).round()
    );
    setState(() {
      _currentPosition = newPosition;
    });
    audioService.seekPodcast(newPosition);
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _formatDuration(Duration duration) {
  String twoDigits(int n) => n.toString().padLeft(2, "0");
  
  // Для длительности более часа показываем часы
  if (duration.inHours > 0) {
    return "${duration.inHours}:${twoDigits(duration.inMinutes.remainder(60))}:${twoDigits(duration.inSeconds.remainder(60))}";
  }
  // Для менее часа показываем только минуты и секунды
  else {
    return "${twoDigits(duration.inMinutes)}:${twoDigits(duration.inSeconds.remainder(60))}";
  }
}

  @override
  Widget build(BuildContext context) {
    final audioService = Provider.of<AudioPlayerService>(context);
    final podcastRepo = Provider.of<PodcastRepository>(context);
    
    // Получаем эпизод из репозитория
    final podcast = podcastRepo.getEpisodeById(widget.podcast.id);
    if (podcast == null) {
      debugPrint('Podcast not found in repository: ${widget.podcast.id}');
      return const SizedBox();
    }
    
    final bool isPlaying = audioService.isPlayingPodcast(widget.podcast);
  
    // Получаем актуальную длительность из сервиса, если доступна
    Duration actualDuration = widget.podcast.duration;
      if (audioService.currentEpisode?.id == widget.podcast.id) {
        final serviceDuration = audioService.currentEpisode?.duration;
        if (serviceDuration != null && serviceDuration > Duration.zero) {
          actualDuration = serviceDuration;
        } else {
          // Если в сервисе нет длительности, используем из репозитория
          final repoPodcast = podcastRepo.getEpisodeById(widget.podcast.id);
          if (repoPodcast != null && repoPodcast.duration > Duration.zero) {
            actualDuration = repoPodcast.duration;
          }
        }
    }

    return StreamBuilder<Duration>(
      stream: isPlaying ? audioService.positionStream : null,
      builder: (context, snapshot) {
        
        // Обновляем текущую позицию если не в процессе перетаскивания
        if (!_isSeeking && snapshot.hasData) {
          _currentPosition = snapshot.data!;
        }

        final progress = actualDuration.inMilliseconds > 0 
            ? _currentPosition.inMilliseconds / actualDuration.inMilliseconds 
            : 0.0;

        // Обновляем значение слайдера, если не в процессе перетаскивания
        if (!_isSeeking) {
          _sliderValue = progress.clamp(0.0, 1.0);
        }

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          elevation: 2,
          color: const Color.fromRGBO(255, 255, 255, 0.3),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Row(
                  children: [
                    _buildImage(),
                    const SizedBox(width: 8), // Увеличил отступ для лучшего вида
                    Expanded(
                      child: Text(
                        widget.podcast.title,
                        style: const TextStyle(
                          color: Colors.white, 
                          fontSize: 12,
                          height: 1.2 // Уменьшаем межстрочный интервал
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _isLoading
                        ? const Padding(
                            padding: EdgeInsets.all(8.0),
                            child: SizedBox(
                              width: 16, // Уменьшил размер индикатора
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            ),
                          )
                        : IconButton(
                            icon: SvgPicture.asset(
                              isPlaying 
                                ? 'assets/icons/icon_pause_podcast.svg'
                                : 'assets/icons/icon_play_podcast.svg',
                              width: 20,
                              height: 20,
                              colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                            ),
                            onPressed: () => _togglePlayPause(audioService),
                            padding: EdgeInsets.zero, // Уменьшаем отступы
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                          ),
                  ],
                ),

                const SizedBox(height: 6), // Уменьшил отступ
                Row(
                  children: [
                    // Проигранное время (слева)
                    Text(
                      _formatDuration(_currentPosition),
                      style: const TextStyle(
                        color: Colors.white, 
                        fontSize: 10, // Уменьшил шрифт
                        fontWeight: FontWeight.bold
                      ),
                    ),
                    const SizedBox(width: 6), // Уменьшил отступ
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 6, // Уменьшил высоту трека
                          thumbShape: const CustomVerticalThumbShape(), // Убрал подчеркивание
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12), // Уменьшил область касания
                          activeTrackColor: AppColors.customWhite,
                          inactiveTrackColor: AppColors.customWhiteTransp,
                          thumbColor: Colors.white,
                          activeTickMarkColor: AppColors.customBackgr, 
                          inactiveTickMarkColor: Colors.transparent,
                        ),
                        child: Slider(
                          value: _sliderValue,
                          min: 0.0,
                          max: 1.0,
                          onChanged: (value) {
                            setState(() {
                              _isSeeking = true;
                              _sliderValue = value;
                            });
                          },
                          onChangeEnd: (value) {
                            _seekPodcast(value, audioService);
                            setState(() {
                              _isSeeking = false;
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 6), // Уменьшил отступ
                    // Оставшееся время (справа)
                    Text(
                      _formatDuration(actualDuration),
                      style: const TextStyle(
                        color: Colors.white, 
                        fontSize: 10, // Уменьшил шрифт
                        fontWeight: FontWeight.bold
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }
    );
  }
}

// ВЫНЕСЕННЫЙ ОТДЕЛЬНЫЙ КЛАСС (не внутри _PodcastItemState)
// Thumb в виде вертикальной полосы, равной по высоте полосе прогресса
class CustomVerticalThumbShape extends SliderComponentShape {
  const CustomVerticalThumbShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return const Size(12, 18); // Уменьшил область касания
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final fillPaint = Paint()
      ..color = sliderTheme.thumbColor ?? Colors.white
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = AppColors.customBackgr
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // Рисуем вертикальную полосу высотой 6 (как trackHeight) и шириной 3
    final rect = Rect.fromCenter(
      center: center,
      width: 3, // Уменьшил ширину
      height: 6, // Уменьшил высоту
    );
    
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(2));
    
    canvas.drawRRect(rrect, fillPaint);
    canvas.drawRRect(rrect, borderPaint);
  }
}