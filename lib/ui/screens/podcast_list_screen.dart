import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:jrrplayerapp/constants/app_colors.dart';
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

// ----------------------------------------------------------------------
// Парсеры (без изменений)
// ----------------------------------------------------------------------

List<PodcastEpisode> _parseRssQuickly(String responseBody, {int limit = 20}) {
  try {
    final document = xml.XmlDocument.parse(responseBody);
    var items = document.findAllElements('item').toList();
    if (items.isEmpty) {
      final channel = document.findAllElements('channel').firstOrNull;
      items = channel?.findElements('item').toList() ?? [];
    }
    if (items.isEmpty) return [];

    String? channelImageUrl;
    final channel = document.findAllElements('channel').firstOrNull;
    if (channel != null) {
      final itunesImage = channel.findElements('itunes:image').firstOrNull;
      if (itunesImage != null) {
        channelImageUrl = itunesImage.getAttribute('href')?.trim();
      }
    }

    List<PodcastEpisode> podcasts = [];
    int parsedCount = 0;

    for (var item in items) {
      if (parsedCount >= limit) break;
      try {
        final title = item.findElements('title').firstOrNull?.innerText.trim() ?? 'Без названия';
        final audioUrl = item.findElements('enclosure').firstOrNull?.getAttribute('url') ?? '';
        if (audioUrl.isEmpty) continue;
        final guid = item.findElements('guid').firstOrNull?.innerText.trim() ?? '${parsedCount}_${DateTime.now().millisecondsSinceEpoch}';
        String? episodeImageUrl;
        final itunesImage = item.findElements('itunes:image').firstOrNull;
        if (itunesImage != null) {
          episodeImageUrl = itunesImage.getAttribute('href')?.trim();
        }
        podcasts.add(PodcastEpisode(
          id: guid,
          title: title,
          audioUrl: audioUrl,
          imageUrl: episodeImageUrl,
          channelImageUrl: channelImageUrl,
          description: '',
          duration: Duration.zero,
          publishedDate: DateTime.now(),
          channelId: 'jrr_podcast_channel',
          channelTitle: 'Подкасты',
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

List<PodcastEpisode> _parseRssFull(String responseBody) {
  try {
    final document = xml.XmlDocument.parse(responseBody);
    var items = document.findAllElements('item').toList();
    if (items.isEmpty) {
      final channel = document.findAllElements('channel').firstOrNull;
      items = channel?.findElements('item').toList() ?? [];
    }

    String? channelImageUrl;
    final channel = document.findAllElements('channel').firstOrNull;
    if (channel != null) {
      final channelImage = channel.findElements('image').firstOrNull;
      if (channelImage != null) {
        final channelUrlElement = channelImage.findElements('url').firstOrNull;
        if (channelUrlElement != null) {
          channelImageUrl = channelUrlElement.innerText.trim();
        }
      }
      if (channelImageUrl == null) {
        final itunesImage = channel.findElements('itunes:image').firstOrNull;
        if (itunesImage != null) {
          channelImageUrl = itunesImage.getAttribute('href')?.trim();
        }
      }
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

        String? episodeImageUrl;
        final itunesImage = item.findElements('itunes:image').firstOrNull;
        if (itunesImage != null) {
          episodeImageUrl = itunesImage.getAttribute('href')?.trim();
        }
        if (episodeImageUrl == null) {
          final mediaThumbnail = item.findElements('media:thumbnail').firstOrNull;
          if (mediaThumbnail != null) {
            episodeImageUrl = mediaThumbnail.getAttribute('url')?.trim();
          }
        }
        if (episodeImageUrl == null) {
          final mediaContents = item.findElements('media:content');
          for (var content in mediaContents) {
            final type = content.getAttribute('type');
            final url = content.getAttribute('url');
            if (type?.startsWith('image/') == true && url != null) {
              episodeImageUrl = url.trim();
              break;
            }
          }
        }
        if (episodeImageUrl == null) {
          final enclosures = item.findElements('enclosure');
          for (var enclosure in enclosures) {
            final type = enclosure.getAttribute('type');
            final url = enclosure.getAttribute('url');
            if (type?.startsWith('image/') == true && url != null) {
              episodeImageUrl = url.trim();
              break;
            }
          }
        }

        final description = descriptionElement?.innerText.trim() ?? '';
        final durationString = durationElement?.innerText.trim() ?? '0:00:00';
        final guid = guidElement?.innerText.trim() ?? '${podcasts.length}_${DateTime.now().millisecondsSinceEpoch}';
        final duration = _parseDuration(durationString);
        DateTime publishedDate = DateTime.now();
        if (pubDateElement != null) {
          publishedDate = _parseDate(pubDateElement.innerText.trim());
        }

        podcasts.add(PodcastEpisode(
          id: guid,
          title: title,
          audioUrl: audioUrl,
          imageUrl: episodeImageUrl,
          channelImageUrl: channelImageUrl,
          description: description,
          duration: duration,
          publishedDate: publishedDate,
          channelId: 'jrr_podcast_channel',
          channelTitle: 'Подкасты',
        ));
      } catch (e) {
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
  // Игнорируем ошибки парсинга, используем текущую дату
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

// ----------------------------------------------------------------------
// Экран
// ----------------------------------------------------------------------

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

  final List<String> _failedProxies = [];
  final Map<String, Duration> _proxyResponseTimes = {};

  bool _isDownloading = false;
  String _downloadStatus = '';
  ConnectionType _connectionType = ConnectionType.offline;

  final ScrollController _scrollController = ScrollController();
  final Connectivity _connectivity = Connectivity();

  // FIX: правильный тип для подписки (список)
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;

  Timer? _statusUpdateTimer;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    await _initConnectivity();

    // FIX: убрано приведение, тип уже правильный
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(_handleConnectivityResult);

    _scrollController.addListener(_scrollListener);
    _testProxiesInBackground();
    await _loadPodcasts();
  }

  Future<void> _initConnectivity() async {
    try {
      final result = await _connectivity.checkConnectivity();
      _handleConnectivityResult(result);
    } catch (e) {
      debugPrint('Connectivity check error: $e');
    }
  }

  void _handleConnectivityResult(dynamic result) {
    List<ConnectivityResult> results;
    if (result is List<ConnectivityResult>) {
      results = result;
    } else if (result is ConnectivityResult) {
      results = [result];
    } else {
      results = [];
    }
    for (var r in results) {
      _updateConnectionType(r);
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
    debugPrint('🔌 Connection type: $_connectionType');
  }

  // ----------------------------------------------------------------------
  // Прокси и сеть
  // ----------------------------------------------------------------------

  Future<void> _testProxiesInBackground() async {
    const proxies = AppStrings.corsProxies;
    for (final proxy in proxies) {
      if (_failedProxies.contains(proxy)) continue;
      try {
        final startTime = DateTime.now();
        final testUrl = '$proxy${Uri.encodeFull('https://httpbin.org/get')}';
        final response = await http.get(Uri.parse(testUrl)).timeout(
          const Duration(seconds: 5),
        );
        if (response.statusCode == 200) {
          final duration = DateTime.now().difference(startTime);
          _proxyResponseTimes[proxy] = duration;
          _failedProxies.remove(proxy);
          debugPrint('✅ Proxy test passed: $proxy (${duration.inMilliseconds}ms)');
        } else {
          _failedProxies.add(proxy);
          debugPrint('❌ Proxy test failed (HTTP ${response.statusCode}): $proxy');
        }
      } catch (e) {
        _failedProxies.add(proxy);
        debugPrint('❌ Proxy test error: $e');
      }
    }
  }

  Future<String?> _getBestProxyUrl() async {
    const originalUrl = AppStrings.podcastRssOriginalUrl;
    const proxies = AppStrings.corsProxies;

    // Если есть рабочие прокси – выбираем самый быстрый
    if (_proxyResponseTimes.isNotEmpty) {
      final workingProxies = _proxyResponseTimes.entries
          .where((entry) => !_failedProxies.contains(entry.key))
          .toList();
      if (workingProxies.isNotEmpty) {
        workingProxies.sort((a, b) => a.value.compareTo(b.value));
        final fastest = workingProxies.first.key;
        debugPrint('🎵 Using fastest proxy: $fastest');
        return '$fastest${Uri.encodeFull(originalUrl)}';
      }
    }

    // Ищем первый рабочий прокси (с повторной проверкой)
    for (final proxy in proxies) {
      if (!_failedProxies.contains(proxy)) {
        final testUrl = '$proxy${Uri.encodeFull('https://httpbin.org/get')}';
        try {
          debugPrint('🎵 Testing proxy on the fly: $proxy');
          final response = await http.get(Uri.parse(testUrl)).timeout(
            const Duration(seconds: 5),
          );
          if (response.statusCode == 200) {
            _failedProxies.remove(proxy);
            debugPrint('🎵 Proxy test successful: $proxy');
            return '$proxy${Uri.encodeFull(originalUrl)}';
          } else {
            _failedProxies.add(proxy);
          }
        } catch (e) {
          _failedProxies.add(proxy);
        }
      }
    }

    // Если все прокси провалились – пробуем прямой запрос (без прокси) только на Wi-Fi
    if (_connectionType == ConnectionType.wifi) {
      debugPrint('🎵 All proxies failed, trying direct URL (no proxy)');
      return originalUrl;
    }

    // В мобильной сети – возвращаем null, чтобы переключиться на кэш или ошибку
    debugPrint('🎵 All proxies failed and not on Wi-Fi – no URL available');
    return null;
  }

  // ----------------------------------------------------------------------
  // Основная логика загрузки
  // ----------------------------------------------------------------------

  Future<void> _loadPodcasts() async {
    if (_isDownloading) return;
    if (_connectionType == ConnectionType.offline) {
      _updateStatus('Нет подключения к интернету');
      await _loadFromCache();
      return;
    }

    _isDownloading = true;
    _startStatusUpdates();

    try {
      // Пытаемся загрузить 3 раза с разными стратегиями
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          _updateStatus('Попытка загрузки $attempt из 3...');
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
          if (podcasts.isNotEmpty || !isLoading) {
            break;
          }
          if (attempt < 3) {
            await Future.delayed(Duration(seconds: attempt * 2));
          }
        } catch (e) {
          debugPrint('Load attempt $attempt failed: $e');
          if (attempt == 3) rethrow;
        }
      }
    } catch (e) {
      debugPrint('Load podcasts error: $e');
      if (mounted) {
        setState(() {
          errorMessage = _connectionType == ConnectionType.offline
              ? 'Нет подключения к интернету'
              : 'Ошибка загрузки: ${e.toString()}';
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
    // Сначала показываем кэш (если есть)
    if (podcasts.isEmpty) {
      await _loadFromCache(showOnlyIfValid: true);
    }
    // Пробуем получить свежие данные (прямой запрос или через прокси)
    try {
      await _fetchFullPodcasts();
    } catch (e) {
      debugPrint('Wi-Fi fetch failed: $e');
      if (podcasts.isEmpty) {
        await _loadFromCache(); // если кэша ещё нет – покажем ошибку
      }
    }
  }

  Future<void> _loadWithMobile() async {
    _updateStatus('Оптимизированная загрузка...');
    if (podcasts.isEmpty) {
      await _loadFromCache(showOnlyIfValid: true);
    }
    try {
      await _loadQuickPodcasts();
    } catch (e) {
      debugPrint('Quick load failed: $e');
    }
    if (podcasts.isEmpty) {
      try {
        await _fetchFullPodcasts();
      } catch (e) {
        debugPrint('Full load also failed: $e');
        await _loadFromCache();
      }
    }
  }

  // ----------------------------------------------------------------------
  // Быстрая загрузка (первые 10 эпизодов)
  // ----------------------------------------------------------------------

  Future<void> _loadQuickPodcasts() async {
    try {
      _updateStatus('Загрузка быстрого доступа...');
      final proxyUrl = await _getBestProxyUrl();
      if (proxyUrl == null) {
        debugPrint('⚠️ No proxy URL available for quick load');
        throw Exception('Нет доступного прокси');
      }

      debugPrint('📡 Quick load URL: $proxyUrl');
      final client = http.Client();
      final response = await client.send(
        http.Request('GET', Uri.parse(proxyUrl))
          ..headers['Accept-Encoding'] = 'gzip'
          ..headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
      ).timeout(const Duration(seconds: 20));

      debugPrint('📡 Quick load response status: ${response.statusCode}');
      if (response.statusCode == 200) {
        final bytes = await _readStreamBytes(response.stream, limit: 50000);
        final responseBody = utf8.decode(bytes);
        debugPrint('📄 Quick load body length: ${responseBody.length} bytes');

        List<PodcastEpisode> quickPodcasts;
        if (kIsWeb) {
          quickPodcasts = _parseRssQuickly(responseBody, limit: 10);
        } else {
          quickPodcasts = await compute(
            (body) => _parseRssQuickly(body, limit: 10),
            responseBody,
          );
        }
        debugPrint('📦 Quick parse found ${quickPodcasts.length} episodes');

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
        } else {
          throw Exception('Быстрый парсинг не дал результатов');
        }
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
      client.close();
    } catch (e) {
      debugPrint('Quick load error: $e');
      rethrow;
    }
  }

  // ----------------------------------------------------------------------
  // Полная загрузка
  // ----------------------------------------------------------------------

  Future<void> _fetchFullPodcasts() async {
    try {
      _updateStatus('Загрузка подкастов...');
      final proxyUrl = await _getBestProxyUrl();
      if (proxyUrl == null) {
        debugPrint('⚠️ No proxy URL available for full load');
        throw Exception('Нет доступного прокси');
      }

      debugPrint('📡 Full load URL: $proxyUrl');
      final client = http.Client();
      final timeoutDuration = _connectionType == ConnectionType.mobile
          ? const Duration(seconds: 40)
          : const Duration(seconds: 60);

      final response = await client.send(
        http.Request('GET', Uri.parse(proxyUrl))
          ..headers['Accept-Encoding'] = 'gzip'
          ..headers['Connection'] = 'keep-alive'
          ..headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
      ).timeout(timeoutDuration, onTimeout: () {
        throw TimeoutException('Сервер не отвечает', timeoutDuration);
      });

      debugPrint('📡 Full load response status: ${response.statusCode}');
      if (response.statusCode == 200) {
        final bytes = await _readStreamBytes(response.stream);
        final responseBody = utf8.decode(bytes);
        debugPrint('📄 Full load body length: ${responseBody.length} bytes');

        await _saveToCache(responseBody);

        List<PodcastEpisode> fullPodcasts;
        if (kIsWeb) {
          fullPodcasts = _parseRssFull(responseBody);
        } else {
          fullPodcasts = await compute(_parseRssFull, responseBody)
              .timeout(const Duration(seconds: 10), onTimeout: () => []);
        }
        debugPrint('📦 Full parse found ${fullPodcasts.length} episodes');

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
        } else {
          // Парсинг вернул пустой список – пробуем кэш
          debugPrint('⚠️ Full parse returned empty, trying cache');
          await _loadFromCache();
        }
      } else {
        debugPrint('⚠️ HTTP error, trying cache');
        await _loadFromCache();
      }
      client.close();
    } catch (e) {
      debugPrint('Full fetch error: $e');
      await _loadFromCache();
    }
  }

  // ----------------------------------------------------------------------
  // Кэш
  // ----------------------------------------------------------------------

  Future<void> _loadFromCache({bool showOnlyIfValid = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedData = prefs.getString(_rssCacheKey);
      final cacheTime = prefs.getString(_cacheTimestampKey);

      if (cachedData != null && cacheTime != null) {
        final cacheDateTime = DateTime.parse(cacheTime);
        final now = DateTime.now();
        final maxCacheAge = showOnlyIfValid ? cacheDuration : const Duration(days: 1);

        if (!showOnlyIfValid || now.difference(cacheDateTime) < maxCacheAge) {
          _updateStatus('Загрузка из кэша...');
          debugPrint('📂 Loading cache from $cacheDateTime');

          List<PodcastEpisode> cachedPodcasts;
          if (kIsWeb) {
            cachedPodcasts = _parseRssFull(cachedData);
          } else {
            cachedPodcasts = await compute(_parseRssFull, cachedData)
                .timeout(const Duration(seconds: 3), onTimeout: () => []);
          }
          debugPrint('📦 Cache parse found ${cachedPodcasts.length} episodes');

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
        } else {
          debugPrint('⏰ Cache is too old (${now.difference(cacheDateTime).inHours} hours)');
        }
      } else {
        debugPrint('📂 No cache found');
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
      debugPrint('💾 Cache saved');
    } catch (e) {
      debugPrint('Cache save error: $e');
    }
  }

  // ----------------------------------------------------------------------
  // Вспомогательные методы
  // ----------------------------------------------------------------------

  Future<List<int>> _readStreamBytes(Stream<List<int>> stream, {int? limit}) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
      if (limit != null && bytes.length >= limit) break;
    }
    return bytes;
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

  // ----------------------------------------------------------------------
  // Пагинация
  // ----------------------------------------------------------------------

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
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final podcastRepo = Provider.of<PodcastRepository>(context, listen: false);
      final allEpisodes = podcastRepo.getSortedEpisodes();
      final startIndex = podcasts.length;
      final endIndex = startIndex + pageSize;
      if (startIndex < allEpisodes.length) {
        final morePodcasts = allEpisodes.sublist(
          startIndex,
          endIndex < allEpisodes.length ? endIndex : allEpisodes.length,
        );
        if (mounted) {
          setState(() {
            podcasts.addAll(morePodcasts);
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

  // ----------------------------------------------------------------------
  // Build
  // ----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final audioService = Provider.of<AudioPlayerService>(context, listen: false);
      final podcastRepo = Provider.of<PodcastRepository>(context, listen: false);
      audioService.setPodcastRepository(podcastRepo);
    });

    return Scaffold(
      backgroundColor: AppColors.customBlack,
      body: _buildBody(),
    );
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
                style: const TextStyle(color: AppColors.customWhite, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              if (_connectionType == ConnectionType.mobile)
                const Text(
                  'Используется оптимизированный режим для медленного соединения',
                  style: TextStyle(color: AppColors.customGrey, fontSize: 12),
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
              color: AppColors.customWhite,
            ),
            const SizedBox(height: 16),
            Text(
              errorMessage,
              style: const TextStyle(color: AppColors.customWhite, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: _loadPodcasts,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.customGreen,
                    foregroundColor: AppColors.customWhite,
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
          const Icon(Icons.podcasts, size: 64, color: AppColors.customGrey),
          const SizedBox(height: 16),
          const Text(
            'Нет доступных подкастов',
            style: TextStyle(color: AppColors.customWhite, fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text(
            _connectionType == ConnectionType.offline
                ? 'Подключитесь к интернету для загрузки'
                : 'Проверьте соединение и попробуйте снова',
            style: const TextStyle(color: AppColors.customGrey),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _loadPodcasts,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.customGreen,
              foregroundColor: AppColors.customWhite,
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
                    style: const TextStyle(color: AppColors.customGrey),
                  ),
                ],
              )
            : ElevatedButton(
                onPressed: _loadMorePodcasts,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.customGreen,
                  foregroundColor: AppColors.customWhite,
                ),
                child: const Text('Загрузить еще'),
              ),
      ),
    );
  }
}
