import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:jrrplayerapp/repositories/podcast_repository.dart';
import 'package:jrrplayerapp/services/audio_player_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart' as xml;
import 'package:jrrplayerapp/models/podcast.dart';
import 'package:jrrplayerapp/widgets/podcast_item.dart';
import 'package:flutter/foundation.dart';
import 'package:jrrplayerapp/constants/strings.dart';

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

        podcasts.add(PodcastEpisode(
          id: guid,
          title: title,
          audioUrl: audioUrl,
          imageUrl: _getImageUrl(item),
          channelImageUrl: null,
          description: description,
          duration: duration,
          currentPosition: Duration.zero,
        ));
        
        debugPrint('Added podcast: $title');
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
  String errorMessage = '';

  @override
  void initState() {
    super.initState();
    _fetchPodcasts();
  }

  Future<void> _fetchPodcasts() async {
    try {
      setState(() {
        isLoading = true;
        errorMessage = '';
      });

      debugPrint('Fetching podcasts from RSS feed...');
      
      // VERWENDE DIE KONSTANTEN AUS APPSTRINGS
      final rssUrl = await _getRssUrl();
      
      final response = await http.get(Uri.parse(rssUrl));

      debugPrint('Response status: ${response.statusCode}');
      debugPrint('Response body length: ${response.body.length}');

      if (response.statusCode == 200) {
        final List<PodcastEpisode> fetchedPodcasts = await compute(
          _parseRssInBackground, 
          response.body
        );

        debugPrint('Parsed ${fetchedPodcasts.length} podcasts');

        // Восстанавливаем позиции из SharedPreferences
        final List<PodcastEpisode> podcastsWithPositions = [];
        final prefs = await SharedPreferences.getInstance();
        
        for (var podcast in fetchedPodcasts) {
          final positionMs = prefs.getInt('position_${podcast.id}') ?? 0;
          podcastsWithPositions.add(podcast.copyWith(
            currentPosition: Duration(milliseconds: positionMs),
          ));
        }

        // ОБНОВЛЯЕМ РЕПОЗИТОРИЙ С ИСПОЛЬЗОВАНИЕМ Context
        if (mounted) {
          final podcastRepo = Provider.of<PodcastRepository>(context, listen: false);
          podcastRepo.setEpisodes(podcastsWithPositions);
        }

        setState(() {
          podcasts = podcastsWithPositions;
          isLoading = false;
        });
      } else {
        setState(() {
          errorMessage = 'Ошибка загрузки: ${response.statusCode}';
          isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching podcasts: $e');
      setState(() {
        errorMessage = 'Ошибка загрузки подкастов: $e';
        isLoading = false;
      });
    }
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
    
    // Fallback: Verwende den ersten Proxy
    return '${proxies.first}${Uri.encodeFull(originalUrl)}';
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
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: podcasts.length,
        // Добавляем ключи для лучшей производительности
        itemBuilder: (context, index) {
          return PodcastItem(
            key: ValueKey(podcasts[index].id),
            podcast: podcasts[index],
          );
        },
      ),
    );
  }
}