import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;

class AudioMetadata {
  static const String defaultCoverUrl = 'assets/images/default_cover.png';

  final String title;
  final String artist;
  final String? album;
  final String artUrl;

  const AudioMetadata({
    required this.title,
    required this.artist,
    this.album,
    String? artUrl,
  }) : artUrl = artUrl ?? defaultCoverUrl;


  @override
  String toString() {
    return 'AudioMetadata(title: $title, artist: $artist, album: ${album ?? 'null'}, artUrl: $artUrl)';
  }
}

class AudioPlayerService with ChangeNotifier, WidgetsBindingObserver {
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

  final Map<String, String?> _coverCache = {};

  String? _currentOperationId;

  // Добавляем StreamController для уведомлений о состоянии
  final StreamController<bool> _playbackStateController = 
      StreamController<bool>.broadcast();

  Stream<bool> get playbackStateStream => _playbackStateController.stream;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('🎵 App lifecycle state changed: $state');
    
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        setAppInBackground(true);
        break;
      case AppLifecycleState.resumed:
        setAppInBackground(false);
        break;
      default:
        break;
    }
  }
  
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
    if (_isDisposed) return;
    notifyListeners();
  }

  void notifyListenersSafe() {
    if (_isDisposed) return;
    notifyListeners();
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
      // Проверяем, не инициализирован ли уже AudioService
      // Вместо deprecated AudioService.running используем try-catch
      try {
        // Пытаемся получить текущий хендлер
        if (_audioHandler != null && _audioHandler is AudioPlayerHandler) {
          debugPrint('AudioHandler already exists');
          _isBackgroundAudioInitialized = true;
          return;
        }
      } catch (e) {
        // Игнорируем
      }
      
      _audioHandler = await AudioService.init(
        builder: () => AudioPlayerHandler(this),
        config: AudioServiceConfig(
          androidNotificationChannelId: 'com.jrrplayerapp.channel.audio',
          androidNotificationChannelName: 'J-Rock Radio',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: false,
          rewindInterval: const Duration(seconds: 30),
          fastForwardInterval: const Duration(seconds: 30),
          androidNotificationIcon: 'mipmap/ic_launcher',
          notificationColor: Colors.purple,
          androidShowNotificationBadge: true,
        ),
      );
      _isBackgroundAudioInitialized = true;
      debugPrint('Background audio initialized successfully');
    } catch (e, stackTrace) {
      developer.log('Error initializing background audio: $e', 
        error: e, stackTrace: stackTrace);
      _isBackgroundAudioInitialized = true;
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

      // Создаем новый AudioPlayer, если его нет
      if (_player == null) {
        _player = AudioPlayer()
          ..playerStateStream.listen((state) {
            _playerState = state;
            _isBuffering = state.processingState == ProcessingState.buffering;

            debugPrint('Player state changed: '
              'playing=${state.playing}, '
              'processing=${state.processingState}, '
              'isBuffering=$_isBuffering, '
              'isPodcastMode=$_isPodcastMode');
            
            // Если в режиме подкаста и состояние изменилось, сохраняем позицию
            if (_isPodcastMode && _currentEpisode != null) {
              if (state.processingState == ProcessingState.ready && 
                  state.playing == false) {
                // Автосохранение при паузе
                _saveCurrentPosition();
              }
            }

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
      }

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
      // Не выбрасываем исключение, чтобы не крашить приложение
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
    debugPrint('🎵 [Service] updateMetadata called with raw artUrl: ${newMetadata.artUrl}');
    debugPrint('🎵 [Service] Title: ${newMetadata.title}, Artist: ${newMetadata.artist}');

    // Для радио всегда обновляем метаданные, даже если они кажутся одинаковыми, 
    // потому что обложка могла измениться (дефолтная -> найденная)
    if (!_isPodcastMode) {
      _currentMetadata = newMetadata;
      debugPrint('🎵 [Service] Radio metadata updated with artUrl: ${newMetadata.artUrl}');

      // Обновляем метаданные в background audio
      _updateBackgroundAudioMetadata(newMetadata);

      // Принудительно уведомляем слушателей
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isDisposed) {
          notifyListeners();
          debugPrint('🎵 [Service] Listeners notified');
        }
      });
      return;
    }

    // Для подкастов используем сравнение
    if (_currentMetadata == null || 
        _currentMetadata!.title != newMetadata.title ||
        _currentMetadata!.artist != newMetadata.artist ||
        _currentMetadata!.artUrl != newMetadata.artUrl) {
      
      _currentMetadata = newMetadata;
      debugPrint('🎵 [Service] Podcast metadata updated with artUrl: ${newMetadata.artUrl}');

      // Обновляем метаданные в background audio
      _updateBackgroundAudioMetadata(newMetadata);

      _notifyListeners();
    } else {
      debugPrint('🎵 [Service] Metadata not updated (same as current)');
    }
  }

  String getPreparedArtUrl(String? rawArtUrl) {
    if (rawArtUrl == null || rawArtUrl.isEmpty) {
      // Для дефолтной обложки всегда используем asset путь
      return 'assets/images/default_cover.png';
    }

    // Если это уже готовый URL или asset путь
    if (rawArtUrl.startsWith('http://') ||
        rawArtUrl.startsWith('https://') ||
        rawArtUrl.startsWith('asset:///') ||
        rawArtUrl.startsWith('assets/')) {
      return rawArtUrl;
    }

    // Для iOS: просто возвращаем raw URL, обработка будет в Handler
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return rawArtUrl;
    }

    // Для Android и других платформ: добавляем asset:// префикс
    // Если это локальный путь к изображению
    if (rawArtUrl.contains('/')) {
      // Предполагаем, что это локальный файл
      return 'asset:///$rawArtUrl';
    } else {
      // Предполагаем, что это имя файла в assets/images
      return 'asset:///assets/images/$rawArtUrl';
    }
  }

  void updateCoverOnly(String newArtUrl) {
    if (_currentMetadata != null && _audioHandler != null) {
      debugPrint('🔄 [Service] Updating cover only: $newArtUrl');
      
      // Создаем новые метаданные с обновленной обложкой
      final updatedMetadata = AudioMetadata(
        title: _currentMetadata!.title,
        artist: _currentMetadata!.artist,
        album: _currentMetadata!.album,
        artUrl: newArtUrl,
      );
      
      // Обновляем локально
      _currentMetadata = updatedMetadata;
      
      // 1. Обновляем через стандартный метод (он уже содержит mediaItem.add)
      _updateBackgroundAudioMetadata(updatedMetadata);

      // 2. **ДОБАВЛЯЕМ ПРИНУДИТЕЛЬНОЕ ОБНОВЛЕНИЕ ЧЕРЕЗ HANDLER**
      //    Без этого на некоторых версиях Android обложка не обновляется.
      if (_audioHandler is AudioPlayerHandler) {
        (_audioHandler as AudioPlayerHandler).forceUpdateCover(newArtUrl);
      }
      
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

            final cacheKey = '$artist|$title';
            String? cachedCoverUrl;
            if (_coverCache.containsKey(cacheKey)) {
              cachedCoverUrl = _coverCache[cacheKey];
              if (cachedCoverUrl != null && cachedCoverUrl.isNotEmpty && cachedCoverUrl != 'null') {
                debugPrint('✅ Using cached web cover: $cachedCoverUrl');
              } else {
                _coverCache.remove(cacheKey);
                cachedCoverUrl = null;
              }
            }

            // Проверяем, не тот же ли это трек
            final currentTrackId = '$artist|$title';
            if (_lastWebTrackId == currentTrackId) {
              return; // Тот же трек, не обновляем
            }

            _lastWebTrackId = currentTrackId;

            if (title.isNotEmpty && title != 'Unknown' && title != '') {
              debugPrint('Web metadata: $artist - $title');

              // Ищем обложку
              final artUrl = await _fetchCoverFromiTunes(title, artist);

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

  // Replace the old _fetchCoverFromDeezer with this
  Future<String?> _fetchCoverFromiTunes(String title, String artist) async {
    // Clean title as before
    String cleanTitle = title
        .replaceAll(RegExp(r'\([^)]*\)'), '')
        .replaceAll(RegExp(r'\[[^\]]*\]'), '')
        .replaceAll('Official Audio', '')
        .replaceAll('Official Video', '')
        .replaceAll('Music Video', '')
        .trim();

    if (cleanTitle.isEmpty) cleanTitle = title;

    final cacheKey = '$artist|$cleanTitle';
    if (_coverCache.containsKey(cacheKey)) {
      final cachedUrl = _coverCache[cacheKey];
      if (cachedUrl != null && cachedUrl.isNotEmpty && cachedUrl != 'null') {
        debugPrint('✅ Using cached iTunes cover for $artist - $cleanTitle: $cachedUrl');
        return cachedUrl;
      } else {
        _coverCache.remove(cacheKey);
      }
    }

    final bool isInBackground = await _isAppInBackground();
    final query = Uri.encodeComponent('$artist $cleanTitle');
    final url = 'https://itunes.apple.com/search?term=$query&media=music&entity=song&limit=1';

    try {
      debugPrint('🔍 Searching iTunes for: $artist - $cleanTitle');
      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'JRRPlayer/1.0'},
      ).timeout(isInBackground ? const Duration(seconds: 3) : const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final results = data['results'] as List?;
        if (results != null && results.isNotEmpty) {
          final track = results.first;
          // Get the 100x100 artwork URL and replace with 600x600 for higher quality
          String? artUrl = track['artworkUrl100'];
          if (artUrl != null) {
            artUrl = artUrl.replaceFirst('100x100', '600x600');
            _coverCache[cacheKey] = artUrl;
            debugPrint('✅ Found iTunes cover: $artUrl');
            return artUrl;
          }
        }
      }
    } catch (e) {
      debugPrint('⚠️ iTunes search failed: $e');
    }

    debugPrint('❌ No cover found on iTunes for $artist - $cleanTitle');
    _coverCache[cacheKey] = null;
    return null;
  }
  
  bool _isInBackground = false;

  Future<bool> _isAppInBackground() async {
    try {
      // Используем MethodChannel для проверки состояния приложения
      const platform = MethodChannel('com.jrrplayerapp/app_lifecycle');
      final bool result = await platform.invokeMethod('isInBackground') ?? false;
      return result;
    } catch (e) {
      debugPrint('Error checking app state: $e');
      return _isInBackground;
    }
  }

  void setAppInBackground(bool inBackground) {
    _isInBackground = inBackground;
    debugPrint('📱 App background state changed: $inBackground');
  }

  void clearCoverCache() {
    _coverCache.clear();
    debugPrint('🔄 Cover cache cleared');
  }

  void _handleStreamMetadata(IcyMetadata? metadata) async {
    if (_isPodcastMode) return;
    if (kIsWeb) return;

    if (metadata != null && metadata.info != null) {
      final title = metadata.info!.title?.trim();
      if (title != null && title.isNotEmpty && title != 'Unknown') {
        final (songTitle, artist) = _splitArtistAndTitle(title);
        
        debugPrint('🎵 New track detected: $artist - $songTitle');

        // ---------- ПРОВЕРКА КЭША ----------
        final cacheKey = '$artist|$songTitle';
        String? cachedCoverUrl;
        if (_coverCache.containsKey(cacheKey)) {
          cachedCoverUrl = _coverCache[cacheKey];
          if (cachedCoverUrl != null && cachedCoverUrl.isNotEmpty && cachedCoverUrl != 'null') {
            debugPrint('✅ Using cached cover for $cacheKey: $cachedCoverUrl');
          } else {
            _coverCache.remove(cacheKey);
            cachedCoverUrl = null;
          }
        }

        final metadata = AudioMetadata(
          title: songTitle,
          artist: artist,
          album: 'J-Rock Radio',
          artUrl: cachedCoverUrl ?? AudioMetadata.defaultCoverUrl,
        );

        // Обновляем метаданные сразу (с обложкой из кэша или дефолтной)
        updateMetadata(metadata);

        // Если обложки в кэше не было – запускаем асинхронный поиск
        if (cachedCoverUrl == null) {
          
          try {
            debugPrint('🔄 Searching cover for: $artist - $songTitle');
            final artUrl = await _fetchCoverFromiTunes(songTitle, artist);
            if (artUrl != null && artUrl.isNotEmpty) {
              debugPrint('✅ Found cover, updating: $artUrl');
              updateCoverOnly(artUrl);
            }
          } catch (e) {
            debugPrint('❌ Error updating cover: $e');
        
          }
        }
      }
    }
  }

  // Добавьте этот новый метод в класс AudioPlayerService
  void updateMetadataWithId(AudioMetadata metadata, String trackId) {
    debugPrint('🎵 Updating metadata with ID $trackId: ${metadata.title}');
    
    // Создаем копию метаданных с уникальным ID в extras
    final metadataWithId = AudioMetadata(
      title: metadata.title,
      artist: metadata.artist,
      album: metadata.album,
      artUrl: metadata.artUrl,
    );
    
    // Обновляем метаданные
    _currentMetadata = metadataWithId;
    
    // Обновляем метаданные в background audio
    _updateBackgroundAudioMetadata(metadataWithId);

    // Принудительно уведомляем слушателей
    _notifyListeners();
    
    debugPrint('✅ Metadata updated with artUrl: ${metadata.artUrl}');
  }

  (String, String) _splitArtistAndTitle(String fullTitle) {
    debugPrint('🎵 Splitting title: "$fullTitle"');
    
    final separators = [' - ', ' – ', ' — ', ' • ', ' | ', ' ~ '];

    for (final separator in separators) {
      if (fullTitle.contains(separator)) {
        final parts = fullTitle.split(separator);
        if (parts.length >= 2) {
          String artist = parts[0].trim();
          String title = parts.sublist(1).join(separator).trim();

          debugPrint('🎵 Split with "$separator": Artist="$artist", Title="$title"');
          
          // Иногда порядок может быть обратным: Title - Artist
          // Проверяем, если в первой части есть типичные слова для названия трека
          if (_looksLikeTitle(artist) && !_looksLikeTitle(title)) {
            // Меняем местами
            final temp = artist;
            artist = title;
            title = temp;
            debugPrint('🎵 Swapped: Artist="$artist", Title="$title"');
          }

          return (title, artist);
        }
      }
    }

    // Если разделителей нет, проверяем другие форматы
    if (fullTitle.contains(' by ')) {
      final parts = fullTitle.split(' by ');
      if (parts.length == 2) {
        debugPrint('🎵 Split with "by": Artist="${parts[1].trim()}", Title="${parts[0].trim()}"');
        return (parts[0].trim(), parts[1].trim());
      }
    }

    debugPrint('🎵 No separator found, using full title as title');
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

  bool get isPlaying {
    return _player?.playing == true;
  }

  bool get isRadioPaused {
      return !_isPodcastMode && 
            !_isRadioStopped && 
            (_player?.playing == false) &&
            (_player?.processingState != ProcessingState.idle);
  }

  bool get isRadioPlaying {
      return !_isPodcastMode && 
            !_isRadioStopped && 
            (_player?.playing == true);
  }

  bool get isRadioStopped {
    return _isRadioStopped;
  }

  Future<void> stopRadio() async {
    try {
      debugPrint('Stopping radio completely');
      
      final player = getPlayer();
      if (player != null) {
        await player.stop();
        
        // Только при полной остановке очищаем источник
        if (player.processingState != ProcessingState.idle) {
          final emptySource = ConcatenatingAudioSource(children: []);
          await player.setAudioSource(emptySource);
        }
        
        // Устанавливаем флаг остановки только при полной остановке
        _isRadioStopped = true;
      }
      
      // Останавливаем таймер метаданных для Web
      if (kIsWeb) {
        _stopWebMetadataPolling();
      }
      
      // Сбрасываем метаданные
      resetMetadata();
      
      // Обновляем состояние в background audio
      _updateBackgroundAudioPlaybackState(false);
      
      // Уведомляем о состоянии воспроизведения
      _playbackStateController.add(false);
      
      _notifyListeners();
      debugPrint('Radio stopped completely');
    } catch (e) {
      debugPrint('Error stopping radio: $e');
    }
  }

  Future<void> playRadio() async {
    debugPrint('=== playRadio() START ===');
    
    try {
      // Гарантируем инициализацию
      if (!_isInitialized || _isDisposed || _player == null) {
        debugPrint('Re-initializing player...');
        await initialize();
      }
      
      final player = getPlayer();
      if (player == null) {
        debugPrint('Player is null, cannot play radio');
        return;
      }
      
      // Проверяем разные состояния
      debugPrint('Radio state check:');
      debugPrint('  isRadioStopped: $_isRadioStopped');
      debugPrint('  player.playing: ${player.playing}');
      debugPrint('  processingState: ${player.processingState}');
      
      // Если радио было остановлено полностью (не пауза), запускаем заново
      
      if (isRadioPaused) {
        // Радио на паузе - просто возобновляем
        debugPrint('Radio was paused - resuming');
        await player.play();
        _isRadioStopped = false;
      } else if (_isRadioStopped || player.processingState == ProcessingState.idle) {
        debugPrint('Radio was stopped or idle - starting fresh');
        
        // Сбрасываем флаг остановки
        _isRadioStopped = false;
        
        // Останавливаем таймер метаданных для Web
        if (kIsWeb) {
          _stopWebMetadataPolling();
        }
        
        // Если был подкаст, сохраняем позицию и сбрасываем
        if (_currentEpisode != null) {
          await _saveCurrentPosition();
          _isPodcastMode = false;
          _currentEpisode = null;
        }
        
        // Сбрасываем метаданные
        resetMetadata();
        
        // Останавливаем текущее воспроизведение если что-то играет
        if (player.processingState != ProcessingState.idle) {
          await player.stop();
        }
        
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
        
        // Создаем новый аудио-источник
        debugPrint('Creating new audio source for radio...');
        
        final audioSource = AudioSource.uri(
          Uri.parse(AppStrings.livestreamUrl),
          tag: mediaItem,
        );
        
        debugPrint('Setting audio source...');
        await player.setAudioSource(audioSource);
        
        debugPrint('Starting playback...');
        await player.play();
        
        debugPrint('Playback started successfully');
        
        // Запускаем таймер метаданных для Web
        if (kIsWeb) {
          _startWebMetadataPolling();
        }
        
        debugPrint('Radio playback started fresh');
      } else if (!player.playing) {
        // Если радио на паузе, просто возобновляем
        debugPrint('Radio was paused - resuming playback');
        await player.play();
        
        // Обновляем флаг остановки
        _isRadioStopped = false;
        
        // Запускаем таймер метаданных для Web
        if (kIsWeb) {
          _startWebMetadataPolling();
        }
        
        debugPrint('Radio resumed from pause');
      } else {
        debugPrint('Radio is already playing, ignoring play command');
        return;
      }
      
      // Немедленно обновляем background audio состояние
      _updateBackgroundAudioPlaybackState(true);
      
      // Уведомляем о состоянии
      _playbackStateController.add(true);
      _notifyListeners();
      
      debugPrint('Radio playback successful');
      
    } catch (e, stackTrace) {
      debugPrint('=== ERROR in playRadio() ===');
      debugPrint('Error: $e');
      debugPrint('Stack trace: $stackTrace');
      
      _notifyListeners();
      rethrow;
    }
    
    debugPrint('=== playRadio() END ===');
  }

  void _forceNotifyPlaybackState(bool isPlaying) {
    if (_isDisposed) return;
    
    // Уведомляем через контроллер состояния воспроизведения
    if (!_playbackStateController.isClosed) {
      try {
        _playbackStateController.add(isPlaying);
      } catch (e) {
        debugPrint('Error in _playbackStateController.add: $e');
      }
    }
    
    // Уведомляем слушателей ChangeNotifier
    notifyListeners();
    
    // Обновляем background audio состояние
    _updateBackgroundAudioPlaybackState(isPlaying);
    
    debugPrint('Force notified playback state: $isPlaying');
  }

  // Добавьте этот метод в класс AudioPlayerService
  Map<String, dynamic> getRadioState() {
    final player = getPlayer();
    return {
      'isPlaying': player?.playing ?? false,
      'isRadioPlaying': isRadioPlaying,
      'isRadioPaused': isRadioPaused,
      'isRadioStopped': isRadioStopped,
      'processingState': player?.processingState.toString() ?? 'null',
      'isPodcastMode': _isPodcastMode,
      'hasPlayer': player != null,
    };
  }

  // Обновите метод pauseRadio() для лучшей синхронизации:
  Future<void> pauseRadio() async {
    try {
      final player = getPlayer();
      debugPrint('🎵 pauseRadio called, player state: ${player?.playing}');
      
      if (player != null) {
        // Проверяем, играет ли радио на самом деле
        if (player.playing && !_isPodcastMode) {
          await player.pause();
          
          // ✅ Ключевое изменение: НЕ вызываем stop(), только паузу
          _isRadioStopped = false; // Важно: не останавливаем полностью!
          
          // Останавливаем таймер метаданных для Web
          if (kIsWeb) {
            _stopWebMetadataPolling();
          }
          
          debugPrint('🎵 Radio paused successfully (not stopped)');
          
          // Синхронизация с UI
          await _syncStateWithUI(false);
        } else {
          debugPrint('🎵 Radio not playing or in podcast mode, ignoring pauseRadio');
          await _syncStateWithUI(false);
        }
      } else {
        debugPrint('🎵 Player is null in pauseRadio');
        await _syncStateWithUI(false);
      }
    } catch (e) {
      debugPrint('🎵 Error pausing radio: $e');
      await _syncStateWithUI(false);
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
    debugPrint('🎵 toggleRadio called');
    debugPrint('🎵   isRadioPlaying: $isRadioPlaying');
    debugPrint('🎵   isRadioPaused: $isRadioPaused');
    debugPrint('🎵   isRadioStopped: $isRadioStopped');
    debugPrint('🎵   player.playing: ${_player?.playing}');
    debugPrint('🎵   processingState: ${_player?.processingState}');
    
    getPlayer();
    
    if (isRadioPlaying) {
      // Радио играет, ставим на паузу
      debugPrint('🎵 Radio is playing -> pausing');
      await pauseRadio();
    } else if (isRadioPaused) {
      // Радио на паузе, возобновляем
      debugPrint('🎵 Radio is paused -> resuming');
      await resumeRadioFromPause();
    } else {
      // Радио остановлено, запускаем заново
      debugPrint('🎵 Radio is stopped -> playing fresh');
      await playRadio();
    }
  }

  Future<void> playPodcastFromPosition(PodcastEpisode episode, Duration position) async {
    debugPrint('playPodcastFromPosition called: ${episode.title} at ${position.inSeconds}s');

    if (!_isInitialized || _isDisposed || _player == null) {
      await initialize();
    }

    // Останавливаем таймер метаданных для Web
    if (kIsWeb) {
      _stopWebMetadataPolling();
    }

    // Сбрасываем последний трек для Web
    _lastWebTrackId = null;

    // Сохраняем позицию текущего эпизода, если он отличается
    if (_currentEpisode != null && _currentEpisode!.id != episode.id) {
      await _saveCurrentPosition();
    }

    _isPodcastMode = true;
    _currentEpisode = episode;

    try {
      // Создаём MediaItem для подкаста
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

      // Останавливаем текущее воспроизведение
      await _player?.stop();

      // Создаем источник аудио с тегом MediaItem
      final audioSource = AudioSource.uri(
        Uri.parse(episode.audioUrl),
        tag: mediaItem,
      );

      // Устанавливаем источник
      await _player?.setAudioSource(audioSource);

      // Перематываем на сохраненную позицию
      if (position > Duration.zero) {
        await _player?.seek(position);
      }

      // Начинаем воспроизведение
      await _player?.play();

      // Обновляем background audio
      if (_audioHandler != null && _audioHandler is AudioPlayerHandler) {
        (_audioHandler as AudioPlayerHandler).updateMetadata(podcastMetadata);
        (_audioHandler as AudioPlayerHandler).updatePlaybackState(true);
      }

      _playbackStateController.add(true);
      _notifyListeners();

      debugPrint('Podcast playback started from position: ${episode.title} at ${position.inSeconds}s');

    } catch (e, stackTrace) {
      debugPrint('Error playing podcast from position: $e');
      debugPrint('Stack trace: $stackTrace');
      _isBuffering = false;
      _notifyListeners();
      rethrow;
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

    // Создаем новую операцию для отмены предыдущей
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

      // Ищем сохраненную позицию
      final position = await _getSavedPosition(episode.id);
      debugPrint('Resuming podcast from position: ${position.inSeconds}s');

      await _player?.stop();

      if (_currentOperationId != operationId) return;

      // Создаем источник аудио с тегом MediaItem
      final audioSource = AudioSource.uri(
        Uri.parse(episode.audioUrl),
        tag: mediaItem, // Используем MediaItem
      );

      // Устанавливаем источник
      await _player?.setAudioSource(audioSource);


      if (position > Duration.zero) {
        await _player?.seek(position);
      }

      // Начинаем воспроизведение
      await _player?.play();

      // Обновляем background audio
      if (_audioHandler != null && _audioHandler is AudioPlayerHandler) {
        (_audioHandler as AudioPlayerHandler).updateMetadata(
          AudioMetadata(
            title: episode.title,
            artist: episode.channelTitle,
            album: 'J-Rock Radio Podcast',
            artUrl: episode.imageUrl ?? episode.channelImageUrl,
          )
        );
        (_audioHandler as AudioPlayerHandler).updatePlaybackState(true);
      }

      _playbackStateController.add(true);
      _notifyListeners();

      debugPrint('Podcast playback started: ${episode.title}');

    } catch (e, stackTrace) {
      if (_currentOperationId != operationId) return;
      
      debugPrint('Error playing podcast: $e');
      debugPrint('Stack trace: $stackTrace');
      
      // Сбрасываем состояние при ошибке
      _isBuffering = false;
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

  Future<void> syncWithBackgroundHandler(bool isPlaying) async {
    if (_isDisposed) return;
    
    debugPrint('🎵 Syncing with background handler: $isPlaying');
    
    // Обновляем состояние сервиса
    _forceNotifyPlaybackState(isPlaying);
    
    // Уведомляем UI
    notifyListeners();
    
    // Синхронизируем с handler если он существует
    if (_audioHandler != null && _audioHandler is AudioPlayerHandler) {
      (_audioHandler as AudioPlayerHandler).forceUpdateUI(isPlaying);
    }
  }

  // ✅ НОВЫЙ МЕТОД: Принудительная синхронизация для фонового режима
  Future<void> forceSyncFromBackground() async {
    debugPrint('🎵 Force sync from background called');
    
    try {
      final player = getPlayer();
      if (player != null) {
        final isPlaying = player.playing;
        debugPrint('🎵 Force sync: player.playing = $isPlaying');
        
        // Синхронизируем состояние с UI
        await _syncStateWithUI(isPlaying);
        
        // Также обновляем background audio handler
        _updateBackgroundAudioPlaybackState(isPlaying);
      }
    } catch (e) {
      debugPrint('🎵 Error in forceSyncFromBackground: $e');
    }
  }

  Future<void> _syncStateWithUI(bool isPlaying) async {
    if (!_isInitialized || _isDisposed) return;
    
    debugPrint('Syncing state with UI: isPlaying=$isPlaying, isRadioPaused=$isRadioPaused');
    
    try {
      // ✅ ИСПРАВЛЕНИЕ: Правильно обновляем флаг остановки
      if (!isPlaying && !_isPodcastMode) {
        // Если радио не играет, но не в режиме подкаста
        if (_player?.processingState == ProcessingState.ready) {
          _isRadioStopped = false; // Это пауза, а не полная остановка
          debugPrint('Radio state: Paused (ready)');
        } else if (_player?.processingState == ProcessingState.idle) {
          _isRadioStopped = true; // Полная остановка
          debugPrint('Radio state: Stopped (idle)');
        }
      }
      
      // СИНХРОННОЕ уведомление
      _forceNotifyPlaybackState(isPlaying);
      
      // Дополнительная синхронизация для надежности
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isDisposed) {
          notifyListeners();
        }
      });
      
    } catch (e) {
      debugPrint('Error in _syncStateWithUI: $e');
    }
  }

  // ✅ ДОБАВЬТЕ ЭТОТ ПУБЛИЧНЫЙ МЕТОД (вставьте в класс AudioPlayerService)
  Future<void> notifyPlaybackState(bool isPlaying) async {
    if (_isDisposed) return;
    
    try {
      // Используем существующий приватный метод
      _forceNotifyPlaybackState(isPlaying);
      
      // Также вызываем синхронизацию
      await _syncStateWithUI(isPlaying);
    } catch (e) {
      debugPrint('Error in notifyPlaybackState: $e');
    }
  }

  // Модифицируйте метод pause():
  Future<void> pause() async {
    try {
      final player = getPlayer();
      debugPrint('🎵 General pause called, isPodcastMode: $_isPodcastMode, playing: ${player?.playing}');
      
      if (player != null) {
        // Если плеер играет, ставим на паузу
        if (player.playing) {
          await player.pause();
          
          // ✅ ОСТАНОВКА ПОЛУЧЕНИЯ МЕТАДАННЫХ
          if (!_isPodcastMode) {
            // Для радио: устанавливаем флаг паузы
            _isRadioStopped = false;
            debugPrint('🎵 Radio paused (isRadioStopped set to false)');
            
            // Останавливаем таймер метаданных для Web
            if (kIsWeb) {
              _stopWebMetadataPolling();
            }
          } else {
            // Для подкаста: сохраняем позицию
            await _saveCurrentPosition();
            debugPrint('🎵 Podcast paused and position saved');
          }
          
          // ✅ ПРЯМАЯ СИНХРОНИЗАЦИЯ С UI
          await _syncStateWithUI(false);
          
        } else {
          debugPrint('🎵 Pause ignored: player already paused');
          // Все равно синхронизируем состояние
          await _syncStateWithUI(false);
        }
      } else {
        debugPrint('🎵 Pause: player is null');
        await _syncStateWithUI(false);
      }
      
    } catch (e, stackTrace) {
      debugPrint('🎵 Error in pause: $e');
      debugPrint('Stack trace: $stackTrace');
      await _syncStateWithUI(false);
    }
  }
  
  // Добавьте этот метод в класс AudioPlayerService
  bool get isRadioPausedManually {
    return !_isPodcastMode && 
          !_isRadioStopped && 
          (_player?.playing == false) &&
          (_player?.processingState == ProcessingState.ready);
  }

  Future<void> resumeRadioFromPause() async {
    try {
      debugPrint('🎵 resumeRadioFromPause called');
      
      final player = getPlayer();
      if (player != null) {
        // Проверяем, что радио действительно на паузе
        if (!player.playing && isRadioPaused) {
          debugPrint('🎵 Resuming radio from pause - confirmed paused state');
          await player.play();
          
          // Запускаем таймер метаданных для Web
          if (kIsWeb) {
            _startWebMetadataPolling();
          }
          
          // Обновляем флаги
          _isRadioStopped = false;
          
          // Обновляем состояние в background audio
          _updateBackgroundAudioPlaybackState(true);
          
          // Уведомляем UI
          _forceNotifyPlaybackState(true);
          
          debugPrint('🎵 Radio resumed from pause');
        } else {
          debugPrint('🎵 Cannot resume radio: not paused or already playing');
          // Если состояние не соответствует, запускаем заново
          await playRadio();
        }
      } else {
        debugPrint('🎵 Cannot resume radio: player is null');
      }
    } catch (e) {
      debugPrint('🎵 Error resuming radio from pause: $e');
      // При ошибке пытаемся запустить заново
      try {
        await playRadio();
      } catch (e2) {
        debugPrint('🎵 Failed to restart radio: $e2');
      }
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

  bool get isDisposed => _isDisposed;

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

    WidgetsBinding.instance.removeObserver(this as WidgetsBindingObserver);

    super.dispose();

    debugPrint('AudioPlayerService disposed');
  }

  /// Возвращает URL дефолтной обложки для использования в фоновом режиме
  String getDefaultCoverUrlForBackground() {
    // Возвращаем уже подготовленный полный путь
    return 'asset:///assets/images/default_cover.png';
  }
}