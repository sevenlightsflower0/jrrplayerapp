import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:jrrplayerapp/repositories/podcast_repository.dart';
import 'package:jrrplayerapp/services/audio_player_service.dart';
import 'package:provider/provider.dart';
import 'package:xml/xml.dart' as xml;
import 'package:jrrplayerapp/models/podcast.dart';
import 'package:jrrplayerapp/widgets/podcast_item.dart';
import 'package:flutter/foundation.dart';
import 'package:jrrplayerapp/constants/strings.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int pageSize = 10;
const String _rssCacheKey = 'cached_rss_response';
const String _cacheTimestampKey = 'rss_cache_timestamp';
const Duration cacheDuration = Duration(hours: 1);

enum ConnectionType { wifi, mobile, offline }

// Оптимизированный парсер для медленных соединений
List<PodcastEpisode> _parseRssQuickly(String responseBody, {int limit = 20}) {
  try {
    final document = xml.XmlDocument.parse(responseBody);
    
    // Быстрый поиск items
    var items = document.findAllElements('item').toList();
    if (items.isEmpty) {
      final channel = document.findAllElements('channel').firstOrNull;
      items = channel?.findElements('item').toList() ?? [];
    }
    
    if (items.isEmpty) return [];

    List<PodcastEpisode> podcasts = [];
    int parsedCount = 0;

    for (var item in items) {
      if (parsedCount >= limit) break;
      
      try {
        // Только необходимые поля для быстрой загрузки
        final title = item.findElements('title').firstOrNull?.innerText.trim() ?? 'Без названия';
        final audioUrl = item.findElements('enclosure').firstOrNull?.getAttribute('url') ?? '';
        
        if (audioUrl.isEmpty) continue;
        
        final guid = item.findElements('guid').firstOrNull?.innerText.trim() ?? '${parsedCount}_${DateTime.now().millisecondsSinceEpoch}';
        
        podcasts.add(PodcastEpisode(
          id: guid,
          title: title,
          audioUrl: audioUrl,
          imageUrl: null,
          channelImageUrl: null,
          description: '', // Пропускаем для скорости
          duration: Duration.zero,
          publishedDate: DateTime.now(),
          channelId: 'jrr_podcast_channel',
          channelTitle: 'J-Rock Radio Podcasts',
        ));
        
        parsedCount++;
      } catch (_) {
        continue;
      }
    }

    return podcasts;
  } catch (e) {
    debugPrint('Quick parse error: $e');
    return [];
  }
}

// Полный парсер для качественной загрузки
List<PodcastEpisode> _parseRssFull(String responseBody) {
  try {
    final document = xml.XmlDocument.parse(responseBody);
    var items = document.findAllElements('item').toList();
    
    if (items.isEmpty) {
      final channel = document.findAllElements('channel').firstOrNull;
      items = channel?.findElements('item').toList() ?? [];
    }

    List<PodcastEpisode> podcasts = [];

    for (var item in items) {
      try {
        final titleElement = item.findElements('title').firstOrNull;
        final enclosureElement = item.findElements('enclosure').firstOrNull;

        if (titleElement == null || enclosureElement == null) continue;

        final title = titleElement.innerText.trim();
        final audioUrl = enclosureElement.getAttribute('url') ?? '';
        
        if (audioUrl.isEmpty) continue;

        final descriptionElement = item.findElements('description').firstOrNull;
        final durationElement = item.findElements('itunes:duration').firstOrNull;
        final guidElement = item.findElements('guid').firstOrNull;
        final pubDateElement = item.findElements('pubDate').firstOrNull;

        // Упрощенный парсинг
        final description = descriptionElement?.innerText.trim() ?? '';
        final durationString = durationElement?.innerText.trim() ?? '0:00:00';
        final guid = guidElement?.innerText.trim() ?? '${podcasts.length}_${DateTime.now().millisecondsSinceEpoch}';
        
        // Парсинг длительности
        final duration = _parseDuration(durationString);
        
        // Парсинг даты
        DateTime publishedDate = DateTime.now();
        if (pubDateElement != null) {
          publishedDate = _parseDate(pubDateElement.innerText.trim());
        }

        podcasts.add(PodcastEpisode(
          id: guid,
          title: title,
          audioUrl: audioUrl,
          imageUrl: null,
          channelImageUrl: null,
          description: description,
          duration: duration,
          publishedDate: publishedDate,
          channelId: 'jrr_podcast_channel',
          channelTitle: 'J-Rock Radio Podcasts',
        ));
      } catch (e) {
        // Игнорируем ошибки парсинга отдельных элементов
        continue;
      }
    }

    return podcasts;
  } catch (e) {
    debugPrint('Full parse error: $e');
    return [];
  }
}

Duration _parseDuration(String durationString) {
  try {
    if (!durationString.contains(':')) {
      final seconds = int.tryParse(durationString) ?? 0;
      return Duration(seconds: seconds);
    }

    final parts = durationString.split(':');
    
    if (parts.length == 2) {
      final minutes = int.tryParse(parts[0]) ?? 0;
      final seconds = int.tryParse(parts[1]) ?? 0;
      return Duration(minutes: minutes, seconds: seconds);
    } else if (parts.length >= 3) {
      final hours = int.tryParse(parts[0]) ?? 0;
      final minutes = int.tryParse(parts[1]) ?? 0;
      final seconds = int.tryParse(parts[2]) ?? 0;
      return Duration(hours: hours, minutes: minutes, seconds: seconds);
    }
    
    return Duration.zero;
  } catch (e) {
    return Duration.zero;
  }
}

DateTime _parseDate(String dateString) {
  try {
    return DateTime.parse(dateString);
  } catch (e) {
    try {
      final parts = dateString.split(' ');
      if (parts.length >= 3) {
        final day = int.tryParse(parts[1]) ?? 1;
        final month = _parseMonth(parts[2]);
        final year = int.tryParse(parts[3]) ?? DateTime.now().year;
        return DateTime(year, month, day);
      }
    } catch (e2) {
      // Если не удалось распарсить, возвращаем текущую дату
    }
    return DateTime.now();
  }
}

int _parseMonth(String month) {
  const months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4,
    'May': 5, 'Jun': 6, 'Jul': 7, 'Aug': 8,
    'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12
  };
  return months[month] ?? 1;
}

class PodcastListScreen extends StatefulWidget {
  const PodcastListScreen({super.key});

  @override
  State<PodcastListScreen> createState() => _PodcastListScreenState();
}

class _PodcastListScreenState extends State<PodcastListScreen> {
  List<PodcastEpisode> podcasts = [];
  bool isLoading = true;
  bool isLoadingMore = false;
  bool hasMore = true;
  int currentPage = 1;
  String errorMessage = '';
  
  // Улучшенная система прокси
  final List<String> _failedProxies = [];
  final Map<String, Duration> _proxyResponseTimes = {};
  
  // Состояние загрузки
  bool _isDownloading = false;
  String _downloadStatus = '';
  ConnectionType _connectionType = ConnectionType.offline;
  
  // Контроллеры
  final ScrollController _scrollController = ScrollController();
  final Connectivity _connectivity = Connectivity();
  late StreamSubscription<ConnectivityResult> _connectivitySubscription;
  
  // Таймер для обновления статуса
  Timer? _statusUpdateTimer;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    // Инициализация соединения
    await _initConnectivity();
    
    // Настройка слушателя соединения
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(_updateConnectionStatus);
    
    // Настройка скролла
    _scrollController.addListener(_scrollListener);
    
    // Предварительное тестирование прокси
    _testProxiesInBackground();
    
    // Загрузка подкастов
    await _loadPodcasts();
  }

  Future<void> _initConnectivity() async {
    try {
      final result = await _connectivity.checkConnectivity();
      _updateConnectionType(result);
    } catch (e) {
      debugPrint('Connectivity check error: $e');
    }
  }

  void _updateConnectionType(ConnectivityResult result) {
    setState(() {
      switch (result) {
        case ConnectivityResult.wifi:
          _connectionType = ConnectionType.wifi;
          break;
        case ConnectivityResult.mobile:
          _connectionType = ConnectionType.mobile;
          break;
        default:
          _connectionType = ConnectionType.offline;
      }
    });
  }

  void _updateConnectionStatus(ConnectivityResult result) {
    _updateConnectionType(result);
    
    // Автозагрузка при восстановлении соединения
    if (result != ConnectivityResult.none && podcasts.isEmpty) {
      _loadPodcasts();
    }
  }

  Future<void> _testProxiesInBackground() async {
    final proxies = AppStrings.corsProxies.take(3);
    
    for (final proxy in proxies) {
      if (_failedProxies.contains(proxy)) continue;
      
      try {
        final startTime = DateTime.now();
        final testUrl = '$proxy${Uri.encodeFull('https://httpbin.org/get')}';
        
        final response = await http.get(Uri.parse(testUrl)).timeout(
          const Duration(seconds: 3),
        );
        
        if (response.statusCode == 200) {
          final duration = DateTime.now().difference(startTime);
          _proxyResponseTimes[proxy] = duration;
          _failedProxies.remove(proxy);
        } else {
          _failedProxies.add(proxy);
        }
      } catch (e) {
        _failedProxies.add(proxy);
      }
    }
  }

  Future<String> _getBestProxyUrl() async {
    const originalUrl = AppStrings.podcastRssOriginalUrl;
    const proxies = AppStrings.corsProxies;
    
    // Используем самый быстрый рабочий прокси
    if (_proxyResponseTimes.isNotEmpty) {
      final workingProxies = _proxyResponseTimes.entries
        .where((entry) => !_failedProxies.contains(entry.key))
        .toList();
      
      if (workingProxies.isNotEmpty) {
        workingProxies.sort((a, b) => a.value.compareTo(b.value));
        final fastest = workingProxies.first.key;
        return '$fastest${Uri.encodeFull(originalUrl)}';
      }
    }
    
    // Ищем первый рабочий прокси
    for (final proxy in proxies) {
      if (!_failedProxies.contains(proxy)) {
        return '$proxy${Uri.encodeFull(originalUrl)}';
      }
    }
    
    // Возвращаем первый, даже если провален
    return '${proxies.first}${Uri.encodeFull(originalUrl)}';
  }

  Future<void> _loadPodcasts() async {
    if (_isDownloading) return;
    
    _isDownloading = true;
    _startStatusUpdates();
    
    try {
      switch (_connectionType) {
        case ConnectionType.wifi:
          await _loadWithWiFi();
          break;
        case ConnectionType.mobile:
          await _loadWithMobile();
          break;
        case ConnectionType.offline:
          await _loadFromCache();
          break;
      }
    } catch (e) {
      debugPrint('Load podcasts error: $e');
      
      if (mounted) {
        setState(() {
          errorMessage = 'Ошибка загрузки: ${e.toString()}';
          isLoading = false;
        });
      }
    } finally {
      _stopStatusUpdates();
      _isDownloading = false;
    }
  }

  Future<void> _loadWithWiFi() async {
    _updateStatus('Загрузка через Wi-Fi...');
    
    // Сначала пробуем кэш для быстрого отображения
    if (podcasts.isEmpty) {
      await _loadFromCache(showOnlyIfValid: true);
    }
    
    // Загружаем полную версию
    await _fetchFullPodcasts();
  }

  Future<void> _loadWithMobile() async {
    _updateStatus('Оптимизированная загрузка...');
    
    // 1. Загружаем быстрый минимум
    await _loadQuickPodcasts();
    
    // 2. Если есть что показать, загружаем остальное в фоне
    if (podcasts.isNotEmpty) {
      _fetchFullPodcastsInBackground();
    } else {
      // 3. Если минимум не загрузился, пробуем полную загрузку
      await _fetchFullPodcasts();
    }
  }

  Future<void> _loadQuickPodcasts() async {
    try {
      _updateStatus('Загрузка быстрого доступа...');
      
      final proxyUrl = await _getBestProxyUrl();
      final client = http.Client();
      
      final response = await client.send(
        http.Request('GET', Uri.parse(proxyUrl))
          ..headers['Accept-Encoding'] = 'gzip'
      ).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        // Читаем только первые 50KB
        final bytes = await _readStreamBytes(response.stream, limit: 50000);
        final responseBody = utf8.decode(bytes);
        
        // Быстрый парсинг
        List<PodcastEpisode> quickPodcasts;
        if (kIsWeb) {
          quickPodcasts = _parseRssQuickly(responseBody, limit: 10);
        } else {
          quickPodcasts = await compute(
            (body) => _parseRssQuickly(body, limit: 10),
            responseBody
          );
        }
        
        if (quickPodcasts.isNotEmpty && mounted) {
          final podcastRepo = Provider.of<PodcastRepository>(context, listen: false);
          podcastRepo.setEpisodes(quickPodcasts);
          
          setState(() {
            podcasts = quickPodcasts.take(pageSize).toList();
            isLoading = false;
            hasMore = quickPodcasts.length > pageSize;
            errorMessage = '';
          });
          
          await _saveToCache(responseBody);
        }
      }
      
      client.close();
    } catch (e) {
      debugPrint('Quick load error: $e');
      // Пробуем кэш
      await _loadFromCache();
    }
  }

  Future<List<int>> _readStreamBytes(Stream<List<int>> stream, {int? limit}) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
      if (limit != null && bytes.length >= limit) {
        break;
      }
    }
    return bytes;
  }

  Future<void> _fetchFullPodcasts() async {
    try {
      _updateStatus('Загрузка полного списка...');
      
      final proxyUrl = await _getBestProxyUrl();
      final client = http.Client();
      
      final response = await client.send(
        http.Request('GET', Uri.parse(proxyUrl))
          ..headers['Accept-Encoding'] = 'gzip'
          ..headers['Connection'] = 'keep-alive'
      ).timeout(_connectionType == ConnectionType.mobile 
          ? const Duration(seconds: 20) 
          : const Duration(seconds: 30));
      
      if (response.statusCode == 200) {
        final bytes = await _readStreamBytes(response.stream);
        final responseBody = utf8.decode(bytes);
        
        // Сохраняем в кэш
        await _saveToCache(responseBody);
        
        // Парсим полную версию
        List<PodcastEpisode> fullPodcasts;
        if (kIsWeb) {
          fullPodcasts = _parseRssFull(responseBody);
        } else {
          fullPodcasts = await compute(_parseRssFull, responseBody)
            .timeout(const Duration(seconds: 5), onTimeout: () => []);
        }
        
        if (fullPodcasts.isNotEmpty && mounted) {
          final podcastRepo = Provider.of<PodcastRepository>(context, listen: false);
          podcastRepo.setEpisodes(fullPodcasts);
          
          fullPodcasts.sort((a, b) => b.publishedDate.compareTo(a.publishedDate));
          final initialPodcasts = fullPodcasts.take(pageSize).toList();
          
          setState(() {
            podcasts = initialPodcasts;
            isLoading = false;
            hasMore = fullPodcasts.length > pageSize;
            errorMessage = '';
          });
        }
      }
      
      client.close();
    } catch (e) {
      debugPrint('Full fetch error: $e');
      if (podcasts.isEmpty) {
        await _loadFromCache();
      }
    }
  }

  void _fetchFullPodcastsInBackground() {
    Future.microtask(() async {
      try {
        await _fetchFullPodcasts();
      } catch (e) {
        debugPrint('Background fetch error: $e');
      }
    });
  }

  Future<void> _loadFromCache({bool showOnlyIfValid = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedData = prefs.getString(_rssCacheKey);
      final cacheTime = prefs.getString(_cacheTimestampKey);
      
      if (cachedData != null && cacheTime != null) {
        final cacheDateTime = DateTime.parse(cacheTime);
        final now = DateTime.now();
        
        if (!showOnlyIfValid || now.difference(cacheDateTime) < cacheDuration) {
          _updateStatus('Загрузка из кэша...');
          
          List<PodcastEpisode> cachedPodcasts;
          if (kIsWeb) {
            cachedPodcasts = _parseRssFull(cachedData);
          } else {
            cachedPodcasts = await compute(_parseRssFull, cachedData)
              .timeout(const Duration(seconds: 3), onTimeout: () => []);
          }
          
          if (cachedPodcasts.isNotEmpty && mounted) {
            final podcastRepo = Provider.of<PodcastRepository>(context, listen: false);
            podcastRepo.setEpisodes(cachedPodcasts);
            
            cachedPodcasts.sort((a, b) => b.publishedDate.compareTo(a.publishedDate));
            final initialPodcasts = cachedPodcasts.take(pageSize).toList();
            
            setState(() {
              podcasts = initialPodcasts;
              isLoading = false;
              hasMore = cachedPodcasts.length > pageSize;
              errorMessage = showOnlyIfValid ? '' : 'Используются кэшированные данные';
            });
            
            return;
          }
        }
      }
      
      if (!showOnlyIfValid && mounted) {
        setState(() {
          errorMessage = 'Нет кэшированных данных';
          isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Cache load error: $e');
      if (!showOnlyIfValid && mounted) {
        setState(() {
          errorMessage = 'Ошибка загрузки кэша';
          isLoading = false;
        });
      }
    }
  }

  Future<void> _saveToCache(String rssData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_rssCacheKey, rssData);
      await prefs.setString(_cacheTimestampKey, DateTime.now().toIso8601String());
    } catch (e) {
      debugPrint('Cache save error: $e');
    }
  }

  void _startStatusUpdates() {
    _statusUpdateTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_isDownloading && mounted) {
        setState(() {
          _downloadStatus = _getRandomStatusMessage();
        });
      } else {
        timer.cancel();
      }
    });
  }

  void _stopStatusUpdates() {
    _statusUpdateTimer?.cancel();
    _statusUpdateTimer = null;
    if (mounted) {
      setState(() {
        _downloadStatus = '';
      });
    }
  }

  String _getRandomStatusMessage() {
    const messages = [
      'Оптимизация загрузки...',
      'Обработка данных...',
      'Подготовка к воспроизведению...',
      'Настройка качества звука...',
      'Проверка доступности...',
    ];
    return messages[Random().nextInt(messages.length)];
  }

  void _updateStatus(String status) {
    if (mounted && _isDownloading) {
      setState(() {
        _downloadStatus = status;
      });
    }
  }

  void _scrollListener() {
    if (_scrollController.position.pixels >= 
        _scrollController.position.maxScrollExtent - 300) {
      if (!isLoadingMore && hasMore && !isLoading) {
        _loadMorePodcasts();
      }
    }
  }

  Future<void> _loadMorePodcasts() async {
    if (isLoadingMore || !hasMore) return;
    
    if (!mounted) return;
    
    setState(() {
      isLoadingMore = true;
    });

    try {
      await Future.delayed(const Duration(milliseconds: 300));
      
      if (!mounted) return;
      
      final podcastRepo = Provider.of<PodcastRepository>(context, listen: false);
      final allEpisodes = podcastRepo.getSortedEpisodes();
      
      final startIndex = currentPage * pageSize;
      final endIndex = startIndex + pageSize;
      
      if (startIndex < allEpisodes.length) {
        final morePodcasts = allEpisodes.sublist(
          startIndex, 
          endIndex < allEpisodes.length ? endIndex : allEpisodes.length
        );
        
        if (mounted) {
          setState(() {
            podcasts.addAll(morePodcasts);
            currentPage++;
            hasMore = endIndex < allEpisodes.length;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            hasMore = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Load more error: $e');
    } finally {
      if (mounted) {
        setState(() {
          isLoadingMore = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _connectivitySubscription.cancel();
    _scrollController.dispose();
    _statusUpdateTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Инициализация аудио-сервиса
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final audioService = Provider.of<AudioPlayerService>(context, listen: false);
      final podcastRepo = Provider.of<PodcastRepository>(context, listen: false);
      audioService.setPodcastRepository(podcastRepo);
    });

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Подкасты'),
            const SizedBox(width: 8),
            _buildConnectionIndicator(),
          ],
        ),
        backgroundColor: Colors.black,
        actions: [
          if (_downloadStatus.isEmpty)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadPodcasts,
              tooltip: 'Обновить',
            ),
          if (_connectionType == ConnectionType.offline)
            IconButton(
              icon: const Icon(Icons.wifi_off),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Работаем в офлайн-режиме'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              tooltip: 'Офлайн режим',
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildConnectionIndicator() {
    IconData icon;
    Color color;
    
    switch (_connectionType) {
      case ConnectionType.wifi:
        icon = Icons.wifi;
        color = Colors.green;
        break;
      case ConnectionType.mobile:
        icon = Icons.network_cell;
        color = Colors.orange;
        break;
      case ConnectionType.offline:
        icon = Icons.wifi_off;
        color = Colors.red;
        break;
    }
    
    return Icon(icon, size: 16, color: color);
  }

  Widget _buildBody() {
    if (isLoading && _downloadStatus.isNotEmpty) {
      return _buildLoadingScreen();
    }

    if (errorMessage.isNotEmpty) {
      return _buildErrorScreen();
    }

    if (podcasts.isEmpty) {
      return _buildEmptyScreen();
    }

    return _buildPodcastList();
  }

  Widget _buildLoadingScreen() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              Text(
                _downloadStatus,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              if (_connectionType == ConnectionType.mobile)
                const Text(
                  'Используется оптимизированный режим для медленного соединения',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildErrorScreen() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _connectionType == ConnectionType.offline 
                ? Icons.wifi_off 
                : Icons.error_outline,
              size: 64,
              color: Colors.white54,
            ),
            const SizedBox(height: 16),
            Text(
              errorMessage,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: _loadPodcasts,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Повторить'),
                ),
                const SizedBox(width: 16),
                if (_connectionType != ConnectionType.offline && podcasts.isNotEmpty)
                  OutlinedButton(
                    onPressed: () {
                      setState(() {
                        errorMessage = '';
                      });
                    },
                    child: const Text('Продолжить'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyScreen() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.podcasts, size: 64, color: Colors.white54),
          const SizedBox(height: 16),
          const Text(
            'Нет доступных подкастов',
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text(
            _connectionType == ConnectionType.offline
                ? 'Подключитесь к интернету для загрузки'
                : 'Проверьте соединение и попробуйте снова',
            style: const TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _loadPodcasts,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
            child: const Text('Загрузить подкасты'),
          ),
        ],
      ),
    );
  }

  Widget _buildPodcastList() {
    return RefreshIndicator(
      onRefresh: () => _loadPodcasts(),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(8),
        itemCount: podcasts.length + (hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == podcasts.length && hasMore) {
            return _buildLoadMoreIndicator();
          }
          
          return PodcastItem(
            key: ValueKey(podcasts[index].id),
            podcast: podcasts[index],
          );
        },
      ),
    );
  }

  Widget _buildLoadMoreIndicator() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Center(
        child: isLoadingMore
            ? Column(
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    _connectionType == ConnectionType.mobile
                        ? 'Загрузка... (может занять время)'
                        : 'Загрузка...',
                    style: const TextStyle(color: Colors.white54),
                  ),
                ],
              )
            : ElevatedButton(
                onPressed: _loadMorePodcasts,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Загрузить еще'),
              ),
      ),
    );
  }
}