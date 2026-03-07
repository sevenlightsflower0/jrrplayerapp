import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class AppStrings {
  // App
  static const String appName = 'Радио J-Rock';
  
  // Tabs
  static const String articlesTab = 'Актуальное';
  static const String newsTab = 'Новости';
  static const String podcastsTab = 'Hora Bissexta';
  static const String enlargeTabsButton = 'Увеличить табы';
  
  // Placeholders
  static const String articlesComingSoon = 'Articles Screen - Coming Soon';
  static const String newsComingSoon = 'News Screen - Coming Soon';
  
  // URLs
  static const String livestreamUrl = 'https://nradio.net/jrock';
  static const String vkontakteUrl = 'https://vk.com/jrockradio';
  static const String telegramUrl = 'https://t.me/jrockradio';
  static const String wwweblinkUrl = 'https://jrock.pro';
  static const String articlesFeedUrl = 'https://jrock.pro/lenta';
  static const String newsFeedUrl = 'https://t.me/s/jrr_news';
  // Podcast RSS Feed mit Proxy-Optionen
  static const String podcastRssOriginalUrl = 'https://cloud.mave.digital/61074';
  static const List<String> corsProxies = [
    'https://api.allorigins.win/raw?url=',
    'https://corsproxy.io/?',
    'https://api.codetabs.com/v1/proxy?quest=',
    'https://cors-anywhere.herokuapp.com/'
  ];
  // Deezer API mit mehreren Proxy-Optionen
  static List<String> getDeezerApiUrls(String query) {
    final originalUrl = 'https://api.deezer.com/search?q=$query&limit=1';
    return AppStrings.corsProxies.map((proxy) => 
      '$proxy${Uri.encodeFull(originalUrl)}'
    ).toList();
  }
  // ==================== CORS PROXY ДЛЯ ВЕБА ====================
  static String proxyUrl(String url) {
    if (kIsWeb) {
      // Самый надёжный прокси на декабрь 2025
      return 'https://api.allorigins.win/raw?url=${Uri.encodeFull(url)}';
    }
    return url;
  }

  // Более умная версия с fallback (если вдруг основной упадёт)
  static Future<http.Response> getWithProxy(String url) async {
    if (!kIsWeb) {
      return await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    }

    const proxies = [
      'https://api.allorigins.win/raw?url=',
      'https://corsproxy.io/?',
      'https://thingproxy.freeboard.io/fetch/',
      'https://cors.bridged.cc/',
    ];

    for (final proxyBase in proxies) {
      try {
        final full = '$proxyBase${Uri.encodeFull(url)}';
        final resp = await http
            .get(Uri.parse(full))
            .timeout(const Duration(seconds: 18));

        // allorigins иногда возвращает 200 с пустым телом или ошибкой в JSON
        if (resp.statusCode == 200 && resp.body.length > 500) {
          return resp;
        }
      } catch (_) {
        continue;
      }
    }
    throw Exception('Все CORS-прокси временно недоступны');
  }
}