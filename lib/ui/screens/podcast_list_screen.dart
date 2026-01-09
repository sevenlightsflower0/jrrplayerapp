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

const int initialPageSize = 10;
const int loadMorePageSize = 10;

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
    
    // Логируем для отладки
    debugPrint('Found ${items.length} items in RSS feed');

    List<PodcastEpisode> podcasts = [];

    for (var item in items) {
      try {
        final titleElement = item.findElements('title').firstOrNull;
        final enclosureElement = item.findElements('enclosure').firstOrNull;
        final descriptionElement = item.findElements('description').firstOrNull;
        final durationElement = item.findElements('itunes:duration').firstOrNull;
        final guidElement = item.findElements('guid').firstOrNull;
        final pubDateElement = item.findElements('pubDate').firstOrNull;

        if (titleElement == null || enclosureElement == null) {
          debugPrint('Skipping item - missing title or enclosure');
          continue;
        }

        final title = titleElement.innerText.trim();
        final audioUrl = enclosureElement.getAttribute('url') ?? '';
        
        if (audioUrl.isEmpty) {
          debugPrint('Skipping item - empty audio URL');
          continue;
        }

        final description = descriptionElement?.innerText.trim() ?? '';
        final durationString = durationElement?.innerText.trim() ?? '0:00:00';
        final guid = guidElement?.innerText.trim() ?? '${podcasts.length}';
        
        final duration = _parseDuration(durationString);
        
        // Парсим дату публикации
        DateTime publishedDate = DateTime.now();
        if (pubDateElement != null) {
          try {
            publishedDate = DateTime.parse(pubDateElement.innerText.trim());
          } catch (e) {
            try {
              // Пробуем другие форматы даты
              final dateString = pubDateElement.innerText.trim();
              if (dateString.contains(',')) {
                // Формат: "Wed, 15 Nov 2023 12:00:00 GMT"
                publishedDate = _parseRssDate(dateString);
              }
            } catch (e2) {
              debugPrint('Failed to parse date: $e2');
            }
          }
        }

        podcasts.add(PodcastEpisode(
          id: guid,
          title: title,
          audioUrl: audioUrl,
          imageUrl: _getImageUrl(item),
          channelImageUrl: null,
          description: description,
          duration: duration,
          publishedDate: publishedDate,
          channelId: 'jrr_podcast_channel', // ID канала по умолчанию
          channelTitle: 'J-Rock Radio Podcasts',
        ));
        
        debugPrint('Added podcast: $title (${publishedDate.toIso8601String()})');
      } catch (e) {
        debugPrint('Error parsing item: $e');
        continue;
      }
    }

    return podcasts;
  } catch (e) {
    debugPrint('Error parsing RSS: $e');
    return [];
  }
}

DateTime _parseRssDate(String dateString) {
  try {
    // Простая попытка разобрать RSS дату
    final parts = dateString.split(' ');
    if (parts.length >= 5) {
      final day = int.tryParse(parts[1]) ?? 1;
      final month = _parseMonth(parts[2]);
      final year = int.tryParse(parts[3]) ?? DateTime.now().year;
      
      final timeParts = parts[4].split(':');
      final hour = timeParts.isNotEmpty ? int.tryParse(timeParts[0]) ?? 0 : 0;
      final minute = timeParts.length > 1 ? int.tryParse(timeParts[1]) ?? 0 : 0;
      final second = timeParts.length > 2 ? int.tryParse(timeParts[2]) ?? 0 : 0;
      
      return DateTime(year, month, day, hour, minute, second);
    }
  } catch (e) {
    debugPrint('Failed to parse RSS date: $e');
  }
  return DateTime.now();
}

int _parseMonth(String month) {
  const months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12
  };
  return months[month] ?? 1;
}

Duration _parseDuration(String durationString) {
  try {
    // Обрабатываем случай когда длительность в секундах (число)
    if (durationString.contains(':') == false) {
      final seconds = int.tryParse(durationString) ?? 0;
      return Duration(seconds: seconds);
    }

    final parts = durationString.split(':');
    
    // Формат MM:SS
    if (parts.length == 2) {
      final minutes = int.parse(parts[0]);
      final seconds = int.parse(parts[1]);
      return Duration(minutes: minutes, seconds: seconds);
    }
    // Формат HH:MM:SS
    else if (parts.length == 3) {
      final hours = int.parse(parts[0]);
      final minutes = int.parse(parts[1]);
      final seconds = int.parse(parts[2]);
      return Duration(hours: hours, minutes: minutes, seconds: seconds);
    }
    // Формат HH:MM:SS.SSS (с миллисекундами)
    else if (parts.length == 4) {
      final hours = int.parse(parts[0]);
      final minutes = int.parse(parts[1]);
      final seconds = int.parse(parts[2]);
      return Duration(hours: hours, minutes: minutes, seconds: seconds);
    }
    
    return Duration.zero;
  } catch (e) {
    debugPrint('Error parsing duration "$durationString": $e');
    return Duration.zero;
  }
}

String? _getImageUrl(xml.XmlElement item) {
  try {
    final itunesImage = item.findElements('itunes:image').firstOrNull;
    if (itunesImage != null) {
      return itunesImage.getAttribute('href');
    }
    
    final mediaThumbnail = item.findElements('media:thumbnail').firstOrNull;
    if (mediaThumbnail != null) {
      return mediaThumbnail.getAttribute('url');
    }
    
    final content = item.findElements('media:content').firstOrNull;
    if (content != null) {
      return content.getAttribute('url');
    }
  } catch (e) {
    return null;
  }
  return null;
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
  
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchPodcasts();
    _scrollController.addListener(_scrollListener);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollListener() {
    if (_scrollController.position.pixels >= 
        _scrollController.position.maxScrollExtent - 200) {
      if (!isLoadingMore && hasMore && !isLoading) {
        _loadMorePodcasts();
      }
    }
  }

  Future<void> _fetchPodcasts() async {
    try {
      setState(() {
        isLoading = true;
        errorMessage = '';
        currentPage = 1;
        podcasts.clear();
      });

      debugPrint('Fetching podcasts page $currentPage...');
      
      final rssUrl = await _getRssUrl();
      final response = await http.get(Uri.parse(rssUrl));

      if (response.statusCode == 200) {
        final List<PodcastEpisode> fetchedPodcasts = await compute(
          _parseRssInBackground, 
          response.body
        );

        fetchedPodcasts.sort((a, b) => b.publishedDate.compareTo(a.publishedDate));
        
        final initialPodcasts = fetchedPodcasts.take(pageSize).toList();
        
        if (mounted) {
          final podcastRepo = Provider.of<PodcastRepository>(context, listen: false);
          podcastRepo.setEpisodes(fetchedPodcasts);

          setState(() {
            podcasts = initialPodcasts;
            isLoading = false;
            hasMore = fetchedPodcasts.length > pageSize;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            errorMessage = 'Ошибка загрузки: ${response.statusCode}';
            isLoading = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Error fetching podcasts: $e');
      if (mounted) {
        setState(() {
          errorMessage = 'Ошибка загрузки подкастов: $e';
          isLoading = false;
        });
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
        title: const Text('Подкасты'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchPodcasts,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (errorMessage.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              errorMessage,
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _fetchPodcasts,
              child: const Text('Повторить'),
            ),
          ],
        ),
      );
    }

    if (podcasts.isEmpty) {
      return const Center(
        child: Text(
          'Нет доступных подкастов',
          style: TextStyle(color: Colors.white),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchPodcasts,
      child: NotificationListener<ScrollNotification>(
        onNotification: (scrollNotification) {
          if (scrollNotification is ScrollEndNotification) {
            final metrics = scrollNotification.metrics;
            if (metrics.pixels >= metrics.maxScrollExtent - 100) {
              if (!isLoadingMore && hasMore) {
                _loadMorePodcasts();
              }
            }
          }
          return false;
        },
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
      ),
    );
  }

  Widget _buildLoadingIndicator() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Center(
        child: isLoadingMore
            ? const CircularProgressIndicator()
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
    
    for (final proxy in proxies) {
      try {
        final url = '$proxy${Uri.encodeFull(originalUrl)}';
        debugPrint('Trying RSS URL: $url');
        
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200) {
          debugPrint('Success with proxy: $proxy');
          return url;
        } else {
          debugPrint('Proxy $proxy returned status: ${response.statusCode}');
        }
      } catch (e) {
        debugPrint('Proxy $proxy failed: $e');
      }
    }
    
    return '${proxies.first}${Uri.encodeFull(originalUrl)}';
  }
}