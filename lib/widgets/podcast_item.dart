import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:jrrplayerapp/repositories/podcast_repository.dart';
import 'package:provider/provider.dart';
import 'package:jrrplayerapp/constants/app_colors.dart';
import 'package:jrrplayerapp/models/podcast.dart';
import 'package:jrrplayerapp/services/audio_player_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:just_audio/just_audio.dart';

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
  late PodcastRepository _podcastRepo;
  Duration? _cachedDuration;
  StreamSubscription<Duration>? _positionSubscription;

  @override
  void initState() {
    super.initState();
    _audioService = Provider.of<AudioPlayerService>(context, listen: false);
    _podcastRepo = Provider.of<PodcastRepository>(context, listen: false);
    
    // Загружаем сохраненную позицию для этого подкаста
    _loadSavedPosition();
    
    // Слушаем изменения метаданных для обновления длительности
    _audioService.addListener(_onAudioServiceUpdate);
    // Слушаем изменения в репозитории
    _podcastRepo.addListener(_onPodcastRepoUpdate);
  }

  Future<void> _loadSavedPosition() async {
    // Загружаем сохраненную позицию из репозитория
    final savedPosition = _podcastRepo.getEpisodePosition(widget.podcast.id);
    if (savedPosition != null && mounted) {
      setState(() {
        _currentPosition = savedPosition;
        // Вычисляем значение для слайдера
        final actualDuration = _getActualDuration();
        if (actualDuration != null && actualDuration.inMilliseconds > 0) {
          _sliderValue = savedPosition.inMilliseconds / actualDuration.inMilliseconds;
        }
      });
    }
  }

  void _onPodcastRepoUpdate() {
    // Обновляем позицию, если она изменилась в репозитории
    final savedPosition = _podcastRepo.getEpisodePosition(widget.podcast.id);
    if (savedPosition != null && savedPosition != _currentPosition && !_isSeeking) {
      setState(() {
        _currentPosition = savedPosition;
        // Вычисляем значение для слайдера
        final actualDuration = _getActualDuration();
        if (actualDuration != null && actualDuration.inMilliseconds > 0) {
          _sliderValue = savedPosition.inMilliseconds / actualDuration.inMilliseconds;
        }
      });
    }
  }

  void _onAudioServiceUpdate() {
    if (!mounted) return;
    
    // Обновляем длительность, если текущий подкаст активен
    if (_audioService.currentEpisode?.id == widget.podcast.id) {
      final currentDuration = _audioService.currentEpisode?.duration;
      if (currentDuration != null && currentDuration > Duration.zero) {
        setState(() {
          _cachedDuration = currentDuration;
        });
      }
    }
  }

  @override
  void dispose() {
    _audioService.removeListener(_onAudioServiceUpdate);
    _podcastRepo.removeListener(_onPodcastRepoUpdate);
    _positionSubscription?.cancel();
    super.dispose();
  }

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
    final Duration? actualDuration = _getActualDuration();
    if (actualDuration == null || actualDuration.inMilliseconds == 0) return;
    
    final newPosition = Duration(
      milliseconds: (value * actualDuration.inMilliseconds).round()
    );
    
    // Сразу обновляем UI
    setState(() {
      _currentPosition = newPosition;
      _sliderValue = value;
    });
    
    // Сохраняем позицию в репозитории
    _podcastRepo.updateEpisodePosition(widget.podcast.id, newPosition);
    
    // Ищем в аудио
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

  String _formatDuration(Duration? duration) {
    if (duration == null) return "--:--";
    
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

  Duration? _getActualDuration() {
    // 1. Проверяем кэшированную длительность из сервиса
    if (_cachedDuration != null && _cachedDuration! > Duration.zero) {
      return _cachedDuration;
    }
    
    // 2. Проверяем длительность из виджета
    if (widget.podcast.duration != null && widget.podcast.duration! > Duration.zero) {
      return widget.podcast.duration;
    }
    
    // 3. Возвращаем null если длительность неизвестна
    return null;
  }

  // Определяем состояние воспроизведения для конкретного подкаста
  bool _isPodcastPlaying(AudioPlayerService audioService) {
    return audioService.currentEpisode?.id == widget.podcast.id && 
           audioService.isPodcastMode &&
           audioService.playerState?.playing == true;
  }

  bool _isPodcastBuffering(AudioPlayerService audioService) {
    return audioService.currentEpisode?.id == widget.podcast.id && 
           audioService.isPodcastMode &&
           (audioService.playerState?.processingState == ProcessingState.buffering ||
            audioService.playerState?.processingState == ProcessingState.loading ||
            audioService.isBuffering);
  }

  @override
  Widget build(BuildContext context) {
    final audioService = Provider.of<AudioPlayerService>(context, listen: true);
    
    // Получаем эпизод из репозитория
    final podcast = _podcastRepo.getEpisodeById(widget.podcast.id);
    if (podcast == null) {
      debugPrint('Podcast not found in repository: ${widget.podcast.id}');
      return const SizedBox();
    }
    
    final bool isPlaying = _isPodcastPlaying(audioService);
    final bool isBuffering = _isPodcastBuffering(audioService);
    final Duration? actualDuration = _getActualDuration();

    // Подписываемся на поток позиции только если этот подкаст играет
    if (isPlaying && _positionSubscription == null) {
      _positionSubscription = audioService.positionStream.listen((position) {
        if (!_isSeeking && mounted) {
          setState(() {
            _currentPosition = position;
            if (actualDuration != null && actualDuration.inMilliseconds > 0) {
              _sliderValue = position.inMilliseconds / actualDuration.inMilliseconds;
            }
          });
          
          // Автоматически сохраняем позицию каждые 5 секунд
          // чтобы не перегружать хранилище
          if (position.inSeconds % 5 == 0) {
            _podcastRepo.updateEpisodePosition(widget.podcast.id, position);
          }
        }
      });
    } else if (!isPlaying && _positionSubscription != null) {
      _positionSubscription?.cancel();
      _positionSubscription = null;
      
      // Сохраняем финальную позицию при остановке воспроизведения
      _podcastRepo.updateEpisodePosition(widget.podcast.id, _currentPosition);
    }

    final progress = actualDuration?.inMilliseconds != null && actualDuration!.inMilliseconds > 0 
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
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.podcast.title,
                    style: const TextStyle(
                      color: Colors.white, 
                      fontSize: 12,
                      height: 1.2
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _isLoading || isBuffering
                    ? const Padding(
                        padding: EdgeInsets.all(8.0),
                        child: SizedBox(
                          width: 16,
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
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                      ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                // Проигранное время (слева)
                Text(
                  _formatDuration(_currentPosition),
                  style: const TextStyle(
                    color: Colors.white, 
                    fontSize: 10,
                    fontWeight: FontWeight.bold
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 6,
                      thumbShape: const CustomVerticalThumbShape(),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
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
                      onChanged: actualDuration != null && actualDuration.inMilliseconds > 0
                          ? (value) {
                              setState(() {
                                _isSeeking = true;
                                _sliderValue = value;
                              });
                            }
                          : null,
                      onChangeEnd: actualDuration != null && actualDuration.inMilliseconds > 0
                        ? (value) {
                            _seekPodcast(value, audioService);
                            setState(() {
                              _isSeeking = false;
                            });
                          }
                        : null,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Оставшееся время (справа)
                Text(
                  _formatDuration(actualDuration),
                  style: const TextStyle(
                    color: Colors.white, 
                    fontSize: 10,
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
}

// Thumb в виде вертикальной полосы, равной по высоте полосе прогресса
class CustomVerticalThumbShape extends SliderComponentShape {
  const CustomVerticalThumbShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return const Size(12, 18);
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
      width: 3,
      height: 6,
    );
    
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(2));
    
    canvas.drawRRect(rrect, fillPaint);
    canvas.drawRRect(rrect, borderPaint);
  }
}