import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:jrrplayerapp/services/audio_player_service.dart';
import 'package:jrrplayerapp/constants/app_colors.dart';
import 'dart:math';

class RadioButtonWithWaves extends StatelessWidget {
  final double screenWidth;

  const RadioButtonWithWaves({
    super.key,
    required this.screenWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<AudioPlayerService>(
      builder: (context, audioService, child) {
        final bool isPlaying = audioService.playerState?.playing ?? false;
        final bool isBuffering = audioService.isBuffering;
        final bool hasConnection = audioService.hasNetworkConnection ?? true;
        
        final double buttonSize = screenWidth * 0.25;
        
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 16),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Анимированные волны (игнорируем нажатия)
              if (!isBuffering) 
                ..._buildWaveLayers(buttonSize, audioService, isPlaying, hasConnection).map(
                  (wave) => IgnorePointer(child: wave)
                ),
              
              // Перечеркивающая линия при отсутствии интернета
              if (!hasConnection && !isBuffering)
                _CrossLine(
                  size: buttonSize * 0.8,
                  verticalOffset: -buttonSize * 0.15,
                ),
              
              // Круглая кнопка
              Container(
                width: buttonSize,
                height: buttonSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    if (isPlaying && !isBuffering && hasConnection)
                      BoxShadow(
                        color: _getWaveColor(hasConnection).withAlpha(77),
                        blurRadius: 10,
                        spreadRadius: 2,
                      ),
                  ],
                ),
                child: ElevatedButton(
                  onPressed: () => audioService.switchToRadio(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    foregroundColor: AppColors.customBackgr,
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                    elevation: 0,
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Основная иконка
                      Image.asset(
                        'assets/images/icon_jrockradio_custom_style.png',
                        width: buttonSize * 0.9,
                        height: buttonSize * 0.9,
                        fit: BoxFit.contain,
                      ),
                      
                      // Индикатор загрузки
                      if (isBuffering)
                        CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(
                            _getWaveColor(hasConnection),
                          ),
                          strokeWidth: 2,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildWaveLayers(double buttonSize, AudioPlayerService audioService, bool isPlaying, bool hasConnection) {
    final waveColor = _getWaveColor(hasConnection);
    return [
      // Первая волна (самая большая)
      _AnimatedWave(
        color: waveColor,
        size: buttonSize * 0.50,
        delay: 0,
        verticalOffset: -buttonSize * 0.15,
        isPlaying: isPlaying,
      ),
      // Вторая волна
      _AnimatedWave(
        color: waveColor,
        size: buttonSize * 0.30,
        delay: 500,
        verticalOffset: -buttonSize * 0.15,
        isPlaying: isPlaying,
      ),
      // Третья волна
      _AnimatedWave(
        color: waveColor,
        size: buttonSize * 0.10,
        delay: 1000,
        verticalOffset: -buttonSize * 0.15,
        isPlaying: isPlaying,
      ),
    ];
  }

  Color _getWaveColor(bool hasConnection) {
    if (!hasConnection) {
      return Colors.red; // Красный при отсутствии соединения
    }
    
    return Colors.green; // Зеленый при нормальной работе
  }
}

class _AnimatedWave extends StatefulWidget {
  final Color color;
  final double size;
  final int delay;
  final double verticalOffset;
  final bool isPlaying;

  const _AnimatedWave({
    required this.color,
    required this.size,
    required this.delay,
    required this.verticalOffset,
    required this.isPlaying,
  });

  @override
  _AnimatedWaveState createState() => _AnimatedWaveState();
}

class _AnimatedWaveState extends State<_AnimatedWave> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  bool _animationStarted = false;

  @override
  void initState() {
    super.initState();
    
    _controller = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );

    _animation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOut,
      ),
    );

    // Задержка для создания эффекта последовательных волн
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted && widget.isPlaying) {
        _controller.repeat(reverse: false);
        _animationStarted = true;
      }
    });
  }

  @override
  void didUpdateWidget(_AnimatedWave oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // Управление анимацией в зависимости от состояния воспроизведения
    if (widget.isPlaying && !_controller.isAnimating) {
      if (!_animationStarted) {
        // Если анимация еще не начиналась, запускаем с задержкой
        Future.delayed(Duration(milliseconds: widget.delay), () {
          if (mounted) {
            _controller.repeat(reverse: false);
            _animationStarted = true;
          }
        });
      } else {
        // Если анимация уже была запущена, продолжаем с текущей позиции
        _controller.repeat(reverse: false);
      }
    } else if (!widget.isPlaying && _controller.isAnimating) {
      // Останавливаем анимацию, но сохраняем текущее состояние
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        // Вычисляем альфа-канал вместо использования withOpacity
        final double opacityValue = 0.7 - (_animation.value * 0.6);
        final int alpha = (opacityValue * 255).round();
        final Color animatedColor = widget.color.withAlpha(alpha);
        
        return Transform.translate(
          offset: Offset(0, widget.verticalOffset),
          child: Opacity(
            opacity: 1.0 - _animation.value,
            child: Transform.rotate(
              angle: 120 * (pi / 180),
              child: CustomPaint(
                size: Size(widget.size, widget.size),
                painter: _WaveArcPainter(
                  color: animatedColor,
                  startAngle: 120 * (pi / 180),
                  sweepAngle: 60 * (pi / 180),
                  animationValue: _animation.value,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WaveArcPainter extends CustomPainter {
  final Color color;
  final double startAngle;
  final double sweepAngle;
  final double animationValue;

  const _WaveArcPainter({
    required this.color,
    required this.startAngle,
    required this.sweepAngle,
    required this.animationValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 + (animationValue * 0.5)
      ..strokeCap = StrokeCap.round;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - paint.strokeWidth) / 2;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _CrossLine extends StatelessWidget {
  final double size;
  final double verticalOffset;

  const _CrossLine({
    required this.size,
    required this.verticalOffset,
  });

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: Offset(0, verticalOffset),
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _CrossLinePainter(),
        ),
      ),
    );
  }
}

class _CrossLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    // Рисуем диагональную линию под углом 45 градусов
    canvas.drawLine(
      const Offset(0, 0),
      Offset(size.width, size.height),
      paint,
    );

    // Рисуем вторую диагональную линию под углом 45 градусов (в другую сторону)
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(0, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}