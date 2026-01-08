import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:jrrplayerapp/constants/strings.dart';
import 'package:jrrplayerapp/repositories/podcast_repository.dart';
import 'package:just_audio/just_audio.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:developer' as developer;
import 'dart:async'; // Добавляем для Timer
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:jrrplayerapp/models/podcast.dart';
import 'package:jrrplayerapp/services/audio_player_handler.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

class AudioMetadata {
  final String title;
  final String artist;
  final String? album;
  final String? artUrl;
  
  const AudioMetadata({
    required this.title,
    required this.artist,
    this.album,
    this.artUrl,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioMetadata &&
          runtimeType == other.runtimeType &&
          title == other.title &&
          artist == other.artist &&
          album == other.album &&
          artUrl == other.artUrl;

  @override
  int get hashCode =>
      title.hashCode ^ artist.hashCode ^ album.hashCode ^ artUrl.hashCode;

  @override
  String toString() {
    return 'AudioMetadata(title: $title, artist: $artist, album: $album, artUrl: ${artUrl != null ? "has image" : "no image"})';
  }
}

class AudioPlayerService with ChangeNotifier {
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;
  AudioPlayerService._internal();

  AudioPlayer? _player;
  final Connectivity _connectivity = Connectivity();
  AudioHandler? _audioHandler;
  bool _isBackgroundAudioInitialized = false;

  // Состояния
  PlayerState? _playerState;
  bool _isBuffering = false;
  PodcastEpisode? _currentEpisode;
  bool _isPodcastMode = false;
  AudioMetadata? _currentMetadata;
  bool _isDisposed = false;
  bool _isInitialized = false;
  
  // Для метаданных на Web
  Timer? _webMetadataTimer;
  static const Duration _webMetadataPollInterval = Duration(seconds: 15);
  String? _lastWebTrackId;

  // Геттеры
  PlayerState? get playerState => _playerState;
  bool get isBuffering => _isBuffering;
  PodcastEpisode? get currentEpisode => _currentEpisode;
  bool get isPodcastMode => _isPodcastMode;
  AudioMetadata? get currentMetadata => _currentMetadata;
  bool get isInitialized => _isInitialized;
  
  final Map<String, String> _coverCache = {};

  String? _currentOperationId;

  // Добавляем StreamController для уведомлений о состоянии
  final StreamController<bool> _playbackStateController = 
      StreamController<bool>.broadcast();
  
  Stream<bool> get playbackStateStream => _playbackStateController.stream;

  final StreamController<void> _uiUpdateController = 
      StreamController<void>.broadcast();

  Stream<void> get uiUpdateStream => _uiUpdateController.stream;
  
  // Добавьте этот геттер
  AudioHandler? get audioHandler => _audioHandler;
  
  AudioPlayer? getPlayer() {
    return _player;
  }

  Stream<double> getVolumeStream() {
    return getPlayer()?.volumeStream ?? Stream.value(1.0);
  }

  double getVolume() {
    return getPlayer()?.volume ?? 1.0;
  }

  // Добавим эти методы управления громкостью
  Future<void> increaseVolume() async {
    final player = getPlayer();
    if (player != null) {
      double currentVolume = player.volume;
      double newVolume = (currentVolume + 0.1).clamp(0.0, 1.0);
      await player.setVolume(newVolume);
      notifyListeners();
    }
  }

  Future<void> decreaseVolume() async {
    final player = getPlayer();
    if (player != null) {
      double currentVolume = player.volume;
      double newVolume = (currentVolume - 0.1).clamp(0.0, 1.0);
      await player.setVolume(newVolume);
      notifyListeners();
    }
  }

  // Метод для остановки радио/подкаста из уведомления
  Future<void> stopFromNotification() async {
    try {
      debugPrint('Stopping from notification');
      
      // Устанавливаем флаг остановки
      _isRadioStopped = true;

      // Останавливаем воспроизведение
      final player = getPlayer();
      if (player != null) {
        await player.stop();
      }

      // Сбрасываем состояние
      _isPodcastMode = false;
      _currentEpisode = null;
      _lastWebTrackId = null;

      // Сбрасываем метаданные
      resetMetadata();

      // Останавливаем таймер метаданных для Web
      if (kIsWeb) {
        _stopWebMetadataPolling();
      }

      // Обновляем состояние в background audio
      _updateBackgroundAudioPlaybackState(false);

      _notifyListeners();
      debugPrint('Stopped from notification');
    } catch (e) {
      debugPrint('Error stopping from notification: $e');
    }
  }

  void _updateBackgroundAudioPlaybackState(bool isPlaying) {
    if (_audioHandler != null && _audioHandler is AudioPlayerHandler) {
      (_audioHandler as AudioPlayerHandler).updatePlaybackState(isPlaying);
    }
  }

  // Добавьте getter для текущей громкости
  double get currentVolume => _player?.volume ?? 1.0;

  Future<void> setVolumeDirectly(double volume) async {
    try {
      final player = getPlayer();
      if (player != null) {
        await player.setVolume(volume);
        debugPrint('Volume set to: $volume');
      }
    } catch (e) {
      debugPrint('Error setting volume: $e');
      rethrow;
    }
  }

  void _notifyListeners() {
    if (_isDisposed) {
      debugPrint('⚠️ Cannot notify: service disposed');
      return;
    }
    
    debugPrint('🔄 Notifying listeners: isPlaying=$isPlaying, playerPlaying=${_player?.playing}');
    notifyListeners();
    _uiUpdateController.add(null);
  }

  bool? get hasNetworkConnection {
    return _connectivityResult != ConnectivityResult.none;
  }

  ConnectivityResult _connectivityResult = ConnectivityResult.none;

  void _handleNetworkChange(ConnectivityResult result) {
    _connectivityResult = result;
    debugPrint('Network connection changed: $result');
    _notifyListeners();
  }

  Future<void> _initializeBackgroundAudio() async {
    if (_isBackgroundAudioInitialized) return;
    
    try {
      _audioHandler = await AudioService.init(
        builder: () => AudioPlayerHandler(this),
        config: AudioServiceConfig(
          androidNotificationChannelId: 'com.jrrplayerapp.channel.audio',
          androidNotificationChannelName: 'J-Rock Radio',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: false,
          androidNotificationIcon: 'mipmap/ic_launcher',
          notificationColor: Colors.purple,
          androidShowNotificationBadge: true,
        ),
      );
      _isBackgroundAudioInitialized = true;
      debugPrint('Background audio initialized with volume controls');
    } catch (e, stackTrace) {
      developer.log('Error initializing background audio: $e', 
        error: e, stackTrace: stackTrace);

    }
  }

  Future<void> initialize() async {
    if (_isInitialized && !_isDisposed) {
      debugPrint('AudioPlayerService already initialized');
      return;
    }

    if (_isDisposed) {
      _reinitialize();
    }

    try {
      debugPrint('=== initialize() START ===');
      
      // Инициализируем background audio
      await _initializeBackgroundAudio();
      
      // Создаем новый AudioPlayer
      _player = AudioPlayer()
        ..playerStateStream.listen((state) {
          _playerState = state;
          _isBuffering = state.processingState == ProcessingState.buffering;
          
          debugPrint('Player state changed: playing=${state.playing}, '
                    'processing=${state.processingState}');
          
          // Уведомляем о ВСЕХ изменениях состояния
          _notifyListeners();
        })
        ..icyMetadataStream.listen((metadata) {
          debugPrint('ICY Metadata received');
          _handleStreamMetadata(metadata);
        })
        ..sequenceStateStream.listen((sequenceState) {
          debugPrint('Sequence state changed');
          _handleSequenceState(sequenceState);
        })
        ..processingStateStream.listen((state) {
          debugPrint('Processing state: $state');
          if (state == ProcessingState.completed) {
            _handlePlaybackCompleted();
          }
        })
        ..positionStream.listen((position) {
          if (_isPodcastMode && _currentEpisode != null) {
            _saveCurrentPosition(position);
          }
        })
        ..playbackEventStream.listen((event) {
          debugPrint('Playback event: ${event.processingState}');
        });
      
      // Настройка
      await _player?.setLoopMode(LoopMode.off);
      
      _connectivityResult = await _connectivity.checkConnectivity();
      _connectivity.onConnectivityChanged.listen(_handleNetworkChange);

      _isInitialized = true;
      _isDisposed = false;
      
      debugPrint('=== initialize() END - Success ===');
      _notifyListeners();
      
    } catch (e, stackTrace) {
      debugPrint('=== ERROR in initialize() ===');
      debugPrint('Error: $e');
      debugPrint('Stack trace: $stackTrace');
      _isInitialized = false;
    }
  }

  void _reinitialize() {
    _isDisposed = false;
    _isInitialized = false;
    _player?.dispose();
    _player = null;
    _stopWebMetadataPolling();
  }

  // ==================== Background Audio Methods ====================

  void _updateBackgroundAudioMetadata(AudioMetadata metadata) {
    if (_audioHandler != null && _audioHandler is AudioPlayerHandler) {
      (_audioHandler as AudioPlayerHandler).updateMetadata(metadata);
    }
  }

  // ==================== Web Metadata Handling ====================
     
  void updateMetadata(AudioMetadata newMetadata) {
    debugPrint('Updating metadata: ${newMetadata.title}');
    
    if (_currentMetadata == null || _currentMetadata != newMetadata) {
      _currentMetadata = newMetadata;
      debugPrint('Metadata updated: ${newMetadata.title}');
      
      // Обновляем метаданные в background audio
      _updateBackgroundAudioMetadata(newMetadata);
      
      _notifyListeners();
    }
  }
  

  void _startWebMetadataPolling() {
    if (!kIsWeb) return;
    
    _stopWebMetadataPolling();
    debugPrint('Starting web metadata polling...');
    
    _webMetadataTimer = Timer.periodic(_webMetadataPollInterval, (_) {
      _fetchWebMetadata();
    });
    
  }

  void _stopWebMetadataPolling() {
    if (_webMetadataTimer != null) {
      _webMetadataTimer!.cancel();
      _webMetadataTimer = null;
      debugPrint('Stopped web metadata polling');
    }
  }

  Future<void> _fetchWebMetadata() async {
    if (!kIsWeb || _isPodcastMode || (_player?.playing != true && !_isPodcastMode)) {
      return;
    }

    try {
      debugPrint('Fetching web metadata from Icecast API...');
      
      final response = await http.get(
        Uri.parse('https://nradio.net/status-json.xsl'),
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final icestats = data['icestats'];
        
        if (icestats != null && icestats['source'] != null) {
          final source = icestats['source'];
          dynamic actualSource;
          
          if (source is List && source.isNotEmpty) {
            actualSource = source[0];
          } else if (source is Map) {
            actualSource = source;
          }
          
          if (actualSource != null) {
            String? title = actualSource['title']?.toString();
            String? artist = actualSource['artist']?.toString();
            
            // Если нет отдельного артиста, попробуем разобрать из title
            if ((artist == null || artist.isEmpty) && title != null) {
              final parts = _splitArtistAndTitle(title);
              title = parts.$1;
              artist = parts.$2;
            }
            
            artist ??= 'J-Rock Radio';
            title ??= 'Live Stream';
            
            // Проверяем, не тот же ли это трек
            final currentTrackId = '$artist|$title';
            if (_lastWebTrackId == currentTrackId) {
              return; // Тот же трек, не обновляем
            }
            
            _lastWebTrackId = currentTrackId;
            
            if (title.isNotEmpty && title != 'Unknown' && title != '') {
              debugPrint('Web metadata: $artist - $title');
              
              // Ищем обложку
              final artUrl = await _fetchCoverFromDeezer(title, artist);
              
              final metadata = AudioMetadata(
                title: title,
                artist: artist,
                album: 'J-Rock Radio',
                artUrl: artUrl,
              );
              
              updateMetadata(metadata);
            }
          }
        }
      } else {
        debugPrint('Icecast API returned status: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error fetching web metadata: $e');
    }
  }

  // ==================== Metadata Handling ====================

  PodcastRepository? _podcastRepository;
  
  void setPodcastRepository(PodcastRepository repository) {
    _podcastRepository = repository;
  }
  
  void updatePodcastDuration(Duration duration) {
    if (_currentEpisode != null) {
      _currentEpisode = _currentEpisode!.copyWith(duration: duration);
      
      // Обновляем в репозитории
      _podcastRepository?.updateEpisodeDuration(_currentEpisode!.id, duration);
      
      notifyListeners();
    }
  }

  void resetMetadata() {
    _currentMetadata = null;
    _notifyListeners();
  }

  Future<String?> _fetchCoverFromDeezer(String title, String artist) async {
    // Очищаем title от лишнего
    String cleanTitle = title
      .replaceAll(RegExp(r'\([^)]*\)'), '') // Удаляем скобки с содержимым
      .replaceAll(RegExp(r'\[[^\]]*\]'), '') // Удаляем квадратные скобки
      .replaceAll('Official Audio', '')
      .replaceAll('Official Video', '')
      .replaceAll('Music Video', '')
      .trim();
    
    if (cleanTitle.isEmpty) {
      cleanTitle = title;
    }
    
    final cacheKey = '$artist|$cleanTitle';
    if (_coverCache.containsKey(cacheKey)) {
      return _coverCache[cacheKey];
    }

    final query = '${Uri.encodeComponent(artist)} ${Uri.encodeComponent(cleanTitle)}';
    final urls = AppStrings.getDeezerApiUrls(query);
    
    debugPrint('Searching Deezer for: $artist - $cleanTitle');
    
    for (final url in urls) {
      try {
        debugPrint('Trying Deezer API: $url');
        
        final response = await http.get(
          Uri.parse(url),
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          
          if (data['data'] != null && data['data'].isNotEmpty) {
            final track = data['data'][0];
            final album = track['album'];
            
            if (album != null && album['cover_big'] != null) {
              final coverUrl = album['cover_big'].toString();
              _coverCache[cacheKey] = coverUrl;
              debugPrint('Found cover: $coverUrl');
              return coverUrl;
            }
          }
        } else {
          debugPrint('Deezer API returned status: ${response.statusCode}');
        }
      } catch (e) {
        debugPrint('Deezer API $url failed: $e');
        continue;
      }
    }
    
    debugPrint('No cover found for: $artist - $cleanTitle');
    return null;
  }

  void _handleStreamMetadata(IcyMetadata? metadata) async {
    // Игнорируем метаданные потока в режиме подкаста
    if (_isPodcastMode) {
      return;
    }

    // На Web используем отдельный механизм
    if (kIsWeb) return;

    if (metadata != null && metadata.info != null) {
      final title = metadata.info!.title?.trim();
      if (title != null && title.isNotEmpty && title != 'Unknown') {
        final (songTitle, artist) = _splitArtistAndTitle(title);
      
        final cacheKey = '$artist|$songTitle';
        
        // Проверяем кэш
        if (_coverCache.containsKey(cacheKey)) {
          final cachedMetadata = AudioMetadata(
            title: songTitle,
            artist: artist,
            album: 'J-Rock Radio',
            artUrl: _coverCache[cacheKey],
          );
          
          // Обновляем тег в текущем источнике
          final player = getPlayer();
          if (player != null && player.playing) {
            // К сожалению, мы не можем динамически изменить тег существующего источника
            // Просто обновляем метаданные через сервис
          }
          updateMetadata(cachedMetadata);
        } else {
          // Асинхронно загружаем обложку
          final artUrl = await _fetchCoverFromDeezer(songTitle, artist);
          if (artUrl != null) {
            _coverCache[cacheKey] = artUrl;
          }

          final newMetadata = AudioMetadata(
            title: songTitle,
            artist: artist,
            album: 'J-Rock Radio',
            artUrl: artUrl,
          );

          updateMetadata(newMetadata);
        }
      }
    }
  }

  (String, String) _splitArtistAndTitle(String fullTitle) {
    final separators = [' - ', ' – ', ' — ', ' • ', ' | ', ' ~ '];
    
    for (final separator in separators) {
      if (fullTitle.contains(separator)) {
        final parts = fullTitle.split(separator);
        if (parts.length >= 2) {
          String artist = parts[0].trim();
          String title = parts.sublist(1).join(separator).trim();
          
          // Иногда порядок может быть обратным: Title - Artist
          // Проверяем, если в первой части есть типичные слова для названия трека
          if (_looksLikeTitle(artist) && !_looksLikeTitle(title)) {
            // Меняем местами
            final temp = artist;
            artist = title;
            title = temp;
          }
          
          return (title, artist);
        }
      }
    }
    
    // Если разделителей нет, проверяем другие форматы
    if (fullTitle.contains(' by ')) {
      final parts = fullTitle.split(' by ');
      if (parts.length == 2) {
        return (parts[0].trim(), parts[1].trim());
      }
    }
    
    return (fullTitle, 'J-Rock Radio');
  }
  
  bool _looksLikeTitle(String text) {
    final lowerText = text.toLowerCase();
    return lowerText.contains('feat.') || 
           lowerText.contains('ft.') ||
           lowerText.contains('with') ||
           lowerText.contains('featuring') ||
           lowerText.contains('official') ||
           lowerText.contains('music') ||
           lowerText.contains('video') ||
           lowerText.contains('audio') ||
           lowerText.contains('remix') ||
           lowerText.contains('cover') ||
           lowerText.contains('live)') ||
           lowerText.contains('(');
  }

  void _handleSequenceState(SequenceState? sequenceState) {
    if (sequenceState?.currentSource?.tag != null) {
      final metadata = sequenceState!.currentSource!.tag;
      if (metadata is AudioMetadata) {
        updateMetadata(metadata);
      }
    }
  }

  // ==================== Playback Control ====================

  void _handlePlaybackCompleted() {
    if (_isPodcastMode && _currentEpisode != null) {
      _saveCurrentPosition(Duration.zero);
    }
    _notifyListeners();
  }

  bool isPlayingPodcast(PodcastEpisode podcast) {
    return _currentEpisode?.id == podcast.id && 
           _playerState?.playing == true;
  }

  Future<void> togglePodcastPlayback(PodcastEpisode podcast) async {
    if (isPlayingPodcast(podcast)) {
      await pause();
    } else {
      await playPodcast(podcast);
    }
  }

  bool get canSwitchToRadio {
    return _isPodcastMode && _currentEpisode != null;
  }

  Future<void> switchToRadio() async {
    if (!canSwitchToRadio) {
      debugPrint('switchToRadio ignored: not in podcast mode or no episode');
      return;
    }

    if (!_isInitialized || _isDisposed || _player == null) {
      await initialize();
    }

    // Сохраняем позицию текущего подкаста
    await _saveCurrentPosition();

    // Останавливаем таймер метаданных для Web
    if (kIsWeb) {
      _stopWebMetadataPolling();
    }

    // Переключаем режим
    _isPodcastMode = false;
    _currentEpisode = null;
    _currentOperationId = null;
    _lastWebTrackId = null;

    // Останавливаем воспроизведение
    await _player?.stop();
    await _player?.pause();

    // Сбрасываем метаданные
    resetMetadata();

    _notifyListeners();
    debugPrint('Switched to radio mode');
  }

  bool _isRadioStopped = false;

  bool get isPlaying => _player?.playing ?? false;

  bool get isRadioPlaying {
    return !_isPodcastMode && !_isRadioStopped && (_player?.playing == true);
  }

  bool get isRadioPaused {
    return !_isPodcastMode && !_isRadioStopped && (_player?.playing == false);
  }
  
  bool get isRadioStopped {
    return _isRadioStopped;
  }

  Future<void> stopRadio() async {
    try {
      debugPrint('Stopping radio completely');
      
      final player = getPlayer();
      if (player != null) {
        // Останавливаем и сбрасываем источник
        await player.stop();
      
        // Вместо setAudioSource(null) просто очищаем состояние
        // Это безопаснее, так как setAudioSource не принимает null
        if (player.processingState != ProcessingState.idle) {
          // Создаем пустой источник для очистки
          final emptySource = ConcatenatingAudioSource(children: []);
          await player.setAudioSource(emptySource);
        }
                
        // Устанавливаем флаг остановки
        _isRadioStopped = true;
      }
      
      // Останавливаем background audio
      if (_audioHandler != null) {
        await _audioHandler!.stop();
      }
      
      // Останавливаем таймер метаданных для Web
      if (kIsWeb) {
        _stopWebMetadataPolling();
      }
      
      // Сбрасываем метаданные
      resetMetadata();
      
      // Обновляем состояние в background audio
      _updateBackgroundAudioPlaybackState(false);
      
      _notifyListeners();
      debugPrint('Radio stopped completely (needs restart)');
    } catch (e) {
      debugPrint('Error stopping radio: $e');
    }
  }

Future<void> playRadio() async {
  debugPrint('=== playRadio() START ===');
  
  try {
    if (!_isInitialized || _isDisposed || _player == null) {
      debugPrint('Initializing player...');
      await initialize();
    }

    // Если радио уже играет, ничего не делаем
    if (isRadioPlaying) {
      debugPrint('Radio is already playing, ignoring playRadio command');
      return;
    }

    // Сбросим флаг остановки радио
    _isRadioStopped = false;
    
    // Останавливаем таймер метаданных для Web
    if (kIsWeb) {
      _stopWebMetadataPolling();
    }

    _currentOperationId = null;
    _lastWebTrackId = null;

    // Если был подкаст, сохраняем позицию
    if (_currentEpisode != null) {
      await _saveCurrentPosition();
      _isPodcastMode = false;
      _currentEpisode = null;
    }

    // Сбрасываем метаданные
    resetMetadata();
    
    // Создаем MediaItem для радио
    const mediaItem = MediaItem(
      id: 'jrr_live_stream',
      title: 'J-Rock Radio',
      artist: 'Live Stream',
      album: 'Онлайн радио',
      artUri: null,
    );
    
    // Обновляем метаданные
    final initialMetadata = AudioMetadata(
      title: mediaItem.title,
      artist: mediaItem.artist!,
      album: mediaItem.album,
      artUrl: null,
    );
    
    updateMetadata(initialMetadata);
    debugPrint('Metadata updated');

    try {
      debugPrint('Checking current player state...');
      final player = getPlayer();
      
      // Если плеер в состоянии idle или у него нет источника
      if (player == null || player.processingState == ProcessingState.idle) {
        debugPrint('Player is idle, creating new audio source...');
        
        // Создаем аудио-источник
        final audioSource = AudioSource.uri(
          Uri.parse(AppStrings.livestreamUrl),
          tag: mediaItem,
        );
        
        debugPrint('Setting audio source...');
        await player?.setAudioSource(audioSource);
        
        debugPrint('Starting playback...');
        await player?.play();
      } else {
        // У плеера уже есть источник, просто продолжаем воспроизведение
        debugPrint('Player has existing source, resuming playback...');
        await player.play();
      }
      
      debugPrint('Playback started successfully');
      
      // Запускаем таймер метаданных для Web
      if (kIsWeb) {
        _startWebMetadataPolling();
      }
      
      // Немедленно обновляем background audio состояние
      _updateBackgroundAudioPlaybackState(true);
      
      // После успешного запуска уведомляем о состоянии
      _playbackStateController.add(true);
    
      debugPrint('Radio playback successful');
      _notifyListeners();
      
    } catch (e, stackTrace) {
      debugPrint('Error in playRadio: $e');
      debugPrint('Stack trace: $stackTrace');
      rethrow;
    }
    
  } catch (e, stackTrace) {
    debugPrint('=== ERROR in playRadio() ===');
    debugPrint('Error: $e');
    debugPrint('Stack trace: $stackTrace');
    
    _notifyListeners();
    rethrow;
  }
  
  debugPrint('=== playRadio() END ===');
}

Future<void> pauseRadio() async {
  try {
    final player = getPlayer();
    debugPrint('pauseRadio called, player state: ${player?.playing}');
    
    if (player != null && player.playing) {
      await player.pause();
      
      // МГНОВЕННОЕ обновление состояния
      _playbackStateController.add(false);
      
      _updateBackgroundAudioPlaybackState(false);
      
      if (kIsWeb) {
        _stopWebMetadataPolling();
      }
      
      debugPrint('Radio paused (source preserved)');
    } else {
      debugPrint('Radio not playing or player null in pauseRadio');
    }
    
    // Всегда уведомляем слушателей
    _notifyListeners();
  } catch (e) {
    debugPrint('Error pausing radio: $e');
    _notifyListeners();
  }
}

Future<void> resumeRadio() async {
  try {
    debugPrint('Resuming radio from pause');
    
    final player = getPlayer();
    if (player != null && !player.playing) {
      await player.play();
      
      // Обновляем состояние в background audio
      _updateBackgroundAudioPlaybackState(true);
      
      // Запускаем таймер метаданных для Web
      if (kIsWeb) {
        _startWebMetadataPolling();
      }
      
      _notifyListeners();
      debugPrint('Radio resumed');
    } else {
      debugPrint('Cannot resume radio: player is null or already playing');
    }
  } catch (e) {
    debugPrint('Error resuming radio: $e');
  }
}

  Future<void> toggleRadio() async {
    debugPrint('toggleRadio called, isRadioPlaying: $isRadioPlaying, isRadioStopped: $isRadioStopped');
    
    if (isRadioPlaying) {
      // Радио играет, ставим на паузу
      await pauseRadio();
    } else {
      // Радио не играет - либо на паузе, либо остановлено
      final player = getPlayer();
      
      // Проверяем, есть ли активный источник в плеере
      if (player != null && player.processingState != ProcessingState.idle) {
        // У плеера есть источник, просто продолжаем воспроизведение
        await player.play();
        debugPrint('Resumed existing radio stream');
      } else {
        // Плеер в состоянии idle или нет источника - запускаем заново
        await playRadio();
        debugPrint('Started new radio stream');
      }
    }
  }

  Future<void> playPodcast(PodcastEpisode episode) async {
    debugPrint('playPodcast called: ${episode.title}');
    
    if (!_isInitialized || _isDisposed || _player == null) {
      await initialize();
    }

    // Останавливаем таймер метаданных для Web
    if (kIsWeb) {
      _stopWebMetadataPolling();
    }

    final operationId = DateTime.now().millisecondsSinceEpoch.toString();
    _currentOperationId = operationId;
    _lastWebTrackId = null;

    if (_currentEpisode != null && _currentEpisode!.id != episode.id) {
      await _saveCurrentPosition();
    }

    _isPodcastMode = true;
    _currentEpisode = episode;

    try {
      // Создаём MediaItem для подкаста (требуется just_audio_background)
      final artUrl = episode.imageUrl ?? episode.channelImageUrl;
      final mediaItem = MediaItem(
        id: episode.id,
        title: episode.title,
        artist: 'J-Rock Radio',
        album: 'Подкасты',
        artUri: artUrl != null && artUrl.isNotEmpty ? Uri.parse(artUrl) : null,
        duration: episode.duration,
      );

      // Создаём AudioMetadata для внутреннего использования
      final podcastMetadata = AudioMetadata(
        title: episode.title,
        artist: 'J-Rock Radio',
        album: 'Подкаст J-Rock',
        artUrl: artUrl,
      );

      // Обновляем внутреннее состояние
      _currentMetadata = podcastMetadata;
      
      // Обновляем метаданные в background audio
      _updateBackgroundAudioMetadata(podcastMetadata);
      
      _notifyListeners();

      if (_currentOperationId != operationId) return;

      final position = await _getSavedPosition(episode.id);
      debugPrint('Resuming podcast from position: ${position.inSeconds}s');

      await _player?.stop();

      if (_currentOperationId != operationId) return;

      // Используем MediaItem как тег
      final audioSource = AudioSource.uri(
        Uri.parse(episode.audioUrl),
        tag: mediaItem, // Используем MediaItem
      );

      await _player?.setAudioSource(audioSource);

      if (position > Duration.zero) {
        await _player?.seek(position);
      }

      await _player?.play();
      
      // Начинаем воспроизведение в background audio
      await _audioHandler?.play();
      
      debugPrint('Podcast playback started: ${episode.title}');
      _notifyListeners();
    } catch (e, stackTrace) {
      if (_currentOperationId != operationId) return;
      developer.log('Error playing podcast', error: e, stackTrace: stackTrace);
      _notifyListeners();
      rethrow;
    }
  }

  Future<void> playNextPodcast() async {
    if (!_isPodcastMode || _currentEpisode == null || _podcastRepository == null) {
      debugPrint('Cannot play next: not in podcast mode or no repository');
      return;
    }

    try {
      final nextEpisode = await _podcastRepository!.getNextEpisode(_currentEpisode!);
      if (nextEpisode != null) {
        debugPrint('Playing next podcast: ${nextEpisode.title}');
        await playPodcast(nextEpisode);
      } else {
        debugPrint('No next episode available');
        // Если это последний эпизод, остановить воспроизведение
        await stopPodcast();
      }
    } catch (e) {
      debugPrint('Error playing next podcast: $e');
    }
  }

  Future<void> playPreviousPodcast() async {
    if (!_isPodcastMode || _currentEpisode == null || _podcastRepository == null) {
      debugPrint('Cannot play previous: not in podcast mode or no repository');
      return;
    }

    try {
      final previousEpisode = await _podcastRepository!.getPreviousEpisode(_currentEpisode!);
      if (previousEpisode != null) {
        debugPrint('Playing previous podcast: ${previousEpisode.title}');
        await playPodcast(previousEpisode);
      } else {
        debugPrint('No previous episode available');
        // Если это первый эпизод, перейти к началу
        await seekPodcast(Duration.zero);
      }
    } catch (e) {
      debugPrint('Error playing previous podcast: $e');
    }
  }

  bool get mounted => !_isDisposed;

  Future<void> pause() async {
    try {
      final player = getPlayer();
      debugPrint('General pause called, isPodcastMode: $_isPodcastMode, playing: ${player?.playing}');
      
      if (player != null && player.playing) {
        await player.pause();
        
        // МГНОВЕННОЕ обновление состояния
        _playbackStateController.add(false);
        
        // Принудительная синхронизация background
        _updateBackgroundAudioPlaybackState(false);
        
        if (_isPodcastMode) {
          await _saveCurrentPosition();
          debugPrint('Podcast paused and position saved');
        } else {
          debugPrint('Radio paused');
        }
        
        // Немедленно уведомляем слушателей (2 раза для надежности: сразу и с задержкой)
        _notifyListeners();
        await Future.delayed(const Duration(milliseconds: 50));
        _notifyListeners();
      } else {
        debugPrint('Pause ignored: player not playing or null');
      }
    } catch (e) {
      debugPrint('Error in pause: $e');
      _notifyListeners();
    }
  }

  Future<void> _saveCurrentPosition([Duration? position]) async {
    if (_currentEpisode != null) {
      try {
        final currentPosition = position ?? _player?.position ?? Duration.zero;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(
          'position_${_currentEpisode!.id}', 
          currentPosition.inMilliseconds
        );
        debugPrint('Saved position for episode ${_currentEpisode!.id}: ${currentPosition.inSeconds}s');
      } catch (e) {
        debugPrint('Error saving position: $e');
      }
    }
  }

  Future<Duration> _getSavedPosition(String episodeId) async {
    final prefs = await SharedPreferences.getInstance();
    final positionMs = prefs.getInt('position_$episodeId') ?? 0;
    return Duration(milliseconds: positionMs);
  }

  Stream<Duration> get positionStream => _player?.positionStream ?? const Stream<Duration>.empty();

  Stream<Duration?> get durationStream => _player?.durationStream ?? const Stream<Duration?>.empty();

  Future<void> seekPodcast(Duration position) async {
    try {
      debugPrint('Seeking to position: ${position.inSeconds}s');
      await _player?.seek(position);
      await _saveCurrentPosition(position);
    } catch (e) {
      debugPrint('Error seeking podcast: $e');
    }
  }

  Future<void> stopPodcast() async {
    try {
      debugPrint('Stopping podcast');
      await _player?.stop();
      await _saveCurrentPosition();
      
      // Останавливаем background audio
      await _audioHandler?.stop();
      
      // Останавливаем таймер метаданных для Web
      if (kIsWeb) {
        _stopWebMetadataPolling();
      }
      
      _isPodcastMode = false;
      _currentEpisode = null;
      _lastWebTrackId = null;
      _notifyListeners();
    } catch (e) {
      debugPrint('Error stopping podcast: $e');
    }
  }

  Duration get currentPosition => _player?.position ?? Duration.zero;

  PlayerState get podcastPlayerState => _player?.playerState ?? PlayerState(false, ProcessingState.idle);

  @override
  Future<void> dispose() async {
    debugPrint('Disposing AudioPlayerService...');
    _isDisposed = true;
    _isInitialized = false;
    
    await _saveCurrentPosition();
    
    if (kIsWeb) {
      _stopWebMetadataPolling();
    }
    
    // Закрываем StreamController
    await _playbackStateController.close();
    
    await _player?.stop();
    await _player?.dispose();
    _player = null;
    
    await _audioHandler?.stop();
    _audioHandler = null;
    
    super.dispose();
    
    debugPrint('AudioPlayerService disposed');
  }
}