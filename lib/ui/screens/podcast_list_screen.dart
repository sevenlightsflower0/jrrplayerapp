import 'dart:async';
import 'dart:convert';

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

const int initialPageSize = 10;
const int loadMorePageSize = 10;
const String _rssCacheKey = 'cached_rss_response';
const String _cacheTimestampKey = 'rss_cache_timestamp';
const Duration cacheDuration = Duration(hours: 1); // Кэшируем на 1 час

// Функция для парсинга RSS в фоновом потоке
List<PodcastEpisode> _parseRssInBackground(String responseBody) {
  try {
    final document = xml.XmlDocument.parse(responseBody);
    
    // Пробуем разные пути к элементам item
    var items = document.findAllElements('item').toList();
    
    // Если items пуст, пробуем найти в channel
    if (items.isEmpty) {
      final channel = document.findAllElements('channel').firstOrNull;
      if (channel != null) {
        items = channel.findElements('item').toList();
      }
    }
    
    debugPrint('Found ${items.length} items in RSS feed');

    List<PodcastEpisode> podcasts = [];
    int maxItemsToParse = 50; // Ограничиваем количество парсинга для слабых устройств

    for (var item in items.take(maxItemsToParse)) {
      try {
        final titleElement = item.findElements('title').firstOrNull;
        final enclosureElement = item.findElements('enclosure').firstOrNull;

        if (titleElement == null || enclosureElement == null) {
          continue;
        }

        final title = titleElement.innerText.trim();
        final audioUrl = enclosureElement.getAttribute('url') ?? '';
        
        if (audioUrl.isEmpty) {
          continue;
        }

        final descriptionElement = item.findElements('description').firstOrNull;
        final durationElement = item.findElements('itunes:duration').firstOrNull;
        final guidElement = item.findElements('guid').firstOrNull;
        final pubDateElement = item.findElements('pubDate').firstOrNull;

        // Упрощенный парсинг для скорости
        final description = descriptionElement?.innerText.trim() ?? '';
        final durationString = durationElement?.innerText.trim() ?? '0:00:00';
        final guid = guidElement?.innerText.trim() ?? '${podcasts.length}';
        
        // Быстрый парсинг длительности
        final duration = _parseDurationSimple(durationString);
        
        // Упрощенный парсинг даты
        DateTime publishedDate = DateTime.now();
        if (pubDateElement != null) {
          publishedDate = _parseDateSimple(pubDateElement.innerText.trim());
        }

        podcasts.add(PodcastEpisode(
          id: guid,
          title: title,
          audioUrl: audioUrl,
          imageUrl: null, // Не парсим картинки для ускорения
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
    debugPrint('Error parsing RSS: $e');
    return [];
  }
}

// Упрощенный парсинг длительности
Duration _parseDurationSimple(String durationString) {
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

// Упрощенный парсинг даты
DateTime _parseDateSimple(String dateString) {
  try {
    // Пробуем стандартный парсер
    return DateTime.parse(dateString);
  } catch (e) {
    // Пробуем упрощенный парсинг RSS формата
    try {
      final parts = dateString.split(' ');
      if (parts.length >= 3) {
        final day = int.tryParse(parts[1]) ?? 1;
        final month = _parseMonthSimple(parts[2]);
        final year = int.tryParse(parts[3]) ?? DateTime.now().year;
        return DateTime(year, month, day);
      }
    } catch (e2) {
      // Если не удалось, возвращаем текущую дату
    }
    return DateTime.now();
  }
}

int _parseMonthSimple(String month) {
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
  final int pageSize = 10;
  String errorMessage = '';
  ConnectivityResult _connectionStatus = ConnectivityResult.none;
  final Connectivity _connectivity = Connectivity();
  
  final ScrollController _scrollController = ScrollController();
  late StreamSubscription<ConnectivityResult> _connectivitySubscription;

  @override
  void initState() {
    super.initState();
    _initConnectivity();
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(_updateConnectionStatus);
    _loadPodcastsWithStrategy();
    _scrollController.addListener(_scrollListener);
  }

  @override
  void dispose() {
    _connectivitySubscription.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initConnectivity() async {
    try {
      final result = await _connectivity.checkConnectivity();
      setState(() {
        _connectionStatus = result;
      });
    } catch (e) {
      debugPrint('Could not check connectivity: $e');
    }
  }

  void _updateConnectionStatus(ConnectivityResult result) {
    setState(() {
      _connectionStatus = result;
    });
    
    // Автоматически перезагружаем при восстановлении соединения
    if (result != ConnectivityResult.none && podcasts.isEmpty) {
      _loadPodcastsWithStrategy();
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

  Future<void> _loadPodcastsWithStrategy() async {
    // Стратегия загрузки в зависимости от типа соединения
    switch (_connectionStatus) {
      case ConnectivityResult.wifi:
        await _loadPodcastsWithRetry(maxRetries: 2);
        break;
      case ConnectivityResult.mobile:
        await _loadPodcastsWithRetry(maxRetries: 1, timeout: const Duration(seconds: 10));
        break;
      case ConnectivityResult.none:
        await _loadFromCache();
        break;
      default:
        await _loadPodcastsWithRetry(maxRetries: 1);
    }
  }

  Future<void> _loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedData = prefs.getString(_rssCacheKey);
      final cacheTime = prefs.getString(_cacheTimestampKey);
      
      if (cachedData != null && cacheTime != null) {
        final cacheDateTime = DateTime.parse(cacheTime);
        final now = DateTime.now();
        
        if (now.difference(cacheDateTime) < cacheDuration) {
          // Используем кэшированные данные
          final List<PodcastEpisode> cachedPodcasts = await compute(
            _parseRssInBackground, 
            cachedData
          );
          
          cachedPodcasts.sort((a, b) => b.publishedDate.compareTo(a.publishedDate));
          final initialPodcasts = cachedPodcasts.take(pageSize).toList();
          
          if (mounted) {
            final podcastRepo = Provider.of<PodcastRepository>(context, listen: false);
            podcastRepo.setEpisodes(cachedPodcasts);

            setState(() {
              podcasts = initialPodcasts;
              isLoading = false;
              hasMore = cachedPodcasts.length > pageSize;
              errorMessage = 'Используются кэшированные данные. Проверьте подключение к интернету.';
            });
          }
          return;
        }
      }
      
      // Если кэша нет или он устарел
      setState(() {
        errorMessage = 'Нет подключения к интернету и кэшированных данных';
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        errorMessage = 'Ошибка загрузки кэша: $e';
        isLoading = false;
      });
    }
  }

  Future<void> _saveToCache(String rssData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_rssCacheKey, rssData);
      await prefs.setString(_cacheTimestampKey, DateTime.now().toIso8601String());
    } catch (e) {
      debugPrint('Error saving to cache: $e');
    }
  }

  Future<void> _loadPodcastsWithRetry({
    int maxRetries = 2,
    Duration timeout = const Duration(seconds: 15),
    Duration initialDelay = const Duration(seconds: 1),
  }) async {
    int attempt = 0;
    bool success = false;
    
    while (attempt <= maxRetries && !success) {
      if (attempt > 0) {
        // Экспоненциальная задержка перед повторной попыткой
        await Future.delayed(initialDelay * (1 << (attempt - 1)));
      }
      
      try {
        await _fetchPodcasts(timeout: timeout);
        success = true;
      } catch (e) {
        attempt++;
        debugPrint('Attempt $attempt failed: $e');
        
        if (attempt > maxRetries) {
          if (mounted) {
            setState(() {
              errorMessage = 'Не удалось загрузить подкасты после $maxRetries попыток';
              isLoading = false;
            });
          }
        }
      }
    }
  }

  Future<void> _fetchPodcasts({Duration? timeout}) async {
    try {
      setState(() {
        isLoading = true;
        errorMessage = '';
        currentPage = 1;
      });

      debugPrint('Fetching podcasts with ${timeout?.inSeconds}s timeout...');
      
      final rssUrl = await _getRssUrl();
      final request = http.Request('GET', Uri.parse(rssUrl));
      
      // Настраиваем таймауты
      final client = http.Client();
      final response = await client.send(request).timeout(
        timeout ?? const Duration(seconds: 20)
      );

      if (response.statusCode == 200) {
        // Читаем тело с ограничением по размеру
// ~500KB максимум
        
        // Читаем поток с декодированием
        final responseBytes = await response.stream.toBytes();
        final responseBody = utf8.decode(responseBytes);
        
        // Сохраняем в кэш
        await _saveToCache(responseBody);

        // Парсим с ограничением по времени
        final List<PodcastEpisode> fetchedPodcasts = await _parseWithTimeout(responseBody);
        
        if (fetchedPodcasts.isEmpty) {
          // Пробуем загрузить из кэша
          await _loadFromCache();
          return;
        }

        fetchedPodcasts.sort((a, b) => b.publishedDate.compareTo(a.publishedDate));
        
        final initialPodcasts = fetchedPodcasts.take(pageSize).toList();
        
        if (mounted) {
          final podcastRepo = Provider.of<PodcastRepository>(context, listen: false);
          podcastRepo.setEpisodes(fetchedPodcasts);

          setState(() {
            podcasts = initialPodcasts;
            isLoading = false;
            hasMore = fetchedPodcasts.length > pageSize;
            errorMessage = '';
          });
        }
      } else {
        // Пробуем загрузить из кэша при ошибке HTTP
        await _loadFromCache();
      }
    } catch (e) {
      debugPrint('Error fetching podcasts: $e');
      
      // При любой ошибке пробуем загрузить из кэша
      await _loadFromCache();
    }
  }

  Future<List<PodcastEpisode>> _parseWithTimeout(String responseBody) async {
    try {
      if (kIsWeb) {
        return _parseRssInBackground(responseBody);
      } else {
        return await compute(_parseRssInBackground, responseBody)
            .timeout(const Duration(seconds: 5));
      }
    } on TimeoutException {
      debugPrint('RSS parsing timeout');
      return [];
    } catch (e) {
      debugPrint('Parsing error: $e');
      return [];
    }
  }

  Future<void> _loadMorePodcasts() async {
    if (isLoadingMore || !hasMore) return;
    
    if (!mounted) return;
    
    setState(() {
      isLoadingMore = true;
    });

    try {
      // Искусственная задержка для плавности
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
      debugPrint('Error loading more podcasts: $e');
    } finally {
      if (mounted) {
        setState(() {
          isLoadingMore = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Инициализируем AudioPlayerService с репозиторием
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
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadPodcastsWithStrategy(),
            tooltip: 'Обновить',
          ),
          if (_connectionStatus == ConnectivityResult.none)
            IconButton(
              icon: const Icon(Icons.wifi_off),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Нет подключения к интернету'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              tooltip: 'Нет подключения',
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildConnectionIndicator() {
    IconData icon;
    Color color;
    
    switch (_connectionStatus) {
      case ConnectivityResult.wifi:
        icon = Icons.wifi;
        color = Colors.green;
        break;
      case ConnectivityResult.mobile:
        icon = Icons.network_cell;
        color = Colors.orange;
        break;
      case ConnectivityResult.none:
        icon = Icons.wifi_off;
        color = Colors.red;
        break;
      default:
        icon = Icons.network_check;
        color = Colors.grey;
    }
    
    return Icon(icon, size: 16, color: color);
  }

  Widget _buildBody() {
    if (isLoading) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            _getLoadingMessage(),
            style: const TextStyle(color: Colors.white54),
            textAlign: TextAlign.center,
          ),
        ],
      );
    }

    if (errorMessage.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _connectionStatus == ConnectivityResult.none 
                  ? Icons.wifi_off 
                  : Icons.error_outline,
                size: 64,
                color: Colors.white54,
              ),
              const SizedBox(height: 16),
              Text(
                errorMessage,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: () => _loadPodcastsWithStrategy(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                    ),
                    child: const Text('Повторить'),
                  ),
                  const SizedBox(width: 16),
                  if (_connectionStatus != ConnectivityResult.none && podcasts.isNotEmpty)
                    OutlinedButton(
                      onPressed: () {
                        setState(() {
                          errorMessage = '';
                        });
                      },
                      child: const Text('Продолжить офлайн'),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    if (podcasts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.podcasts, size: 64, color: Colors.white54),
            const SizedBox(height: 16),
            const Text(
              'Нет доступных подкастов',
              style: TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              _connectionStatus == ConnectivityResult.none
                  ? 'Подключитесь к интернету для загрузки'
                  : 'Проверьте подключение и попробуйте снова',
              style: const TextStyle(color: Colors.white54),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadPodcastsWithStrategy(),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(8),
        itemCount: podcasts.length + (hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == podcasts.length && hasMore) {
            return _buildLoadingIndicator();
          }
          
          return PodcastItem(
            key: ValueKey(podcasts[index].id),
            podcast: podcasts[index],
          );
        },
      ),
    );
  }

  String _getLoadingMessage() {
    switch (_connectionStatus) {
      case ConnectivityResult.wifi:
        return 'Загрузка через Wi-Fi...';
      case ConnectivityResult.mobile:
        return 'Загрузка через мобильную сеть...\n(может быть медленно)';
      case ConnectivityResult.none:
        return 'Загрузка из кэша...';
      default:
        return 'Загрузка...';
    }
  }

  Widget _buildLoadingIndicator() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Center(
        child: isLoadingMore
            ? Column(
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    _connectionStatus == ConnectivityResult.mobile
                        ? 'Загрузка может занять время...'
                        : 'Загрузка...',
                    style: const TextStyle(color: Colors.white54),
                  ),
                ],
              )
            : ElevatedButton(
                onPressed: _loadMorePodcasts,
                child: const Text('Загрузить еще'),
              ),
      ),
    );
  }

  Future<String> _getRssUrl() async {
    const originalUrl = AppStrings.podcastRssOriginalUrl;
    const proxies = AppStrings.corsProxies;
    
    // Для медленных соединений используем только первый прокси
    if (_connectionStatus == ConnectivityResult.mobile) {
      final proxy = proxies.first;
      return '$proxy${Uri.encodeFull(originalUrl)}';
    }
    
    // Для Wi-Fi пробуем все прокси
    for (final proxy in proxies) {
      try {
        final url = '$proxy${Uri.encodeFull(originalUrl)}';
        debugPrint('Trying RSS URL: $url');
        
        final response = await http.get(Uri.parse(url)).timeout(
          const Duration(seconds: 5)
        );
        if (response.statusCode == 200) {
          debugPrint('Success with proxy: $proxy');
          return url;
        }
      } catch (e) {
        debugPrint('Proxy $proxy failed: $e');
      }
    }
    
    return '${proxies.first}${Uri.encodeFull(originalUrl)}';
  }
}