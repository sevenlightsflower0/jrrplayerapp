// Замени весь файл

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart' as dom;

import 'package:jrrplayerapp/models/news.dart';
import 'package:jrrplayerapp/widgets/news_item.dart';
import 'package:jrrplayerapp/constants/strings.dart';

class NewsFeedScreen extends StatefulWidget {
  const NewsFeedScreen({super.key});

  @override
  State<NewsFeedScreen> createState() => _NewsFeedScreenState();
}

class _NewsFeedScreenState extends State<NewsFeedScreen> {
  List<News> _news = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String _error = '';
  bool _hasInternetError = false;
  int _currentPage = 1;
  bool _hasMorePages = true;
  final ScrollController _scrollController = ScrollController();
  final Set<String> _loadedNewsUrls = {};

  @override
  void initState() {
    super.initState();
    _loadNews();
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
      _loadMoreNews();
    }
  }

  Future<void> _loadNews() async {
    setState(() {
      _isLoading = true;
      _error = '';
      _currentPage = 1;
      _hasMorePages = true;
      _news.clear();
      _loadedNewsUrls.clear();
    });

    try {
      final url = AppStrings.proxyUrl(AppStrings.newsFeedUrl); // ← главное изменение
      final response = await AppStrings.getWithProxy(url);

      if (response.statusCode == 200) {
        _parseHtml(response.body, isFirstLoad: true);
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      setState(() {
        _error = 'Не удалось загрузить новости: $e';
        _hasInternetError = true;
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMoreNews() async {
    if (_isLoadingMore || !_hasMorePages) return;
    setState(() => _isLoadingMore = true);

    try {
      final nextPage = _currentPage + 1;
      final url = AppStrings.proxyUrl('${AppStrings.newsFeedUrl}$nextPage/');
      final response = await AppStrings.getWithProxy(url);

      if (response.statusCode == 200 && response.body.contains('tgme_widget_message')) {
        _parseHtml(response.body, isFirstLoad: false);
      } else {
        setState(() => _hasMorePages = false);
      }
    } catch (e) {
      setState(() => _hasMorePages = false);
    } finally {
      setState(() => _isLoadingMore = false);
    }
  }

  void _parseHtml(String htmlContent, {required bool isFirstLoad}) {
    try {
      final document = parser.parse(htmlContent);
      List<News> loadedNews = [];

      // Парсим Telegram сообщения
      final messageWraps = document.querySelectorAll('.tgme_widget_message_wrap');
      
      if (kDebugMode) {
        debugPrint('🔍 Найдено Telegram сообщений: ${messageWraps.length}');
      }

      int newNewsCount = 0;

      for (final element in messageWraps) {
        try {
          final news = _parseTelegramMessage(element);
          if (news != null && !_loadedNewsUrls.contains(news.url)) {
            loadedNews.add(news);
            _loadedNewsUrls.add(news.url);
            newNewsCount++;
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('❌ Ошибка парсинга Telegram сообщения: $e');
          }
        }
      }

      // 🔄 ИЗМЕНЕНИЕ 1: Сортируем загруженные новости по дате в обратном порядке (от новых к старым)
      loadedNews.sort((a, b) {
        try {
          final dateA = _parseDateTimeFromString(a.date);
          final dateB = _parseDateTimeFromString(b.date);
          return dateB.compareTo(dateA); // Обратный порядок
        } catch (e) {
          return 0;
        }
      });

      // Проверяем есть ли еще страницы
      final nextPage = document.querySelector('.next.page-numbers, a.next');
      final hasMore = nextPage != null;

      setState(() {
        if (isFirstLoad) {
          _news = loadedNews;
          _currentPage = 1;
        } else {
          if (newNewsCount > 0) {
            // 🔄 ИЗМЕНЕНИЕ 2: Объединяем и пересортировываем все новости
            final allNews = [..._news, ...loadedNews];
            allNews.sort((a, b) {
              try {
                final dateA = _parseDateTimeFromString(a.date);
                final dateB = _parseDateTimeFromString(b.date);
                return dateB.compareTo(dateA); // Обратный порядок
              } catch (e) {
                return 0;
              }
            });
            _news = allNews;
            _currentPage++;
          } else {
            _hasMorePages = false;
          }
        }
        _hasMorePages = hasMore;
        _isLoading = false;
        _isLoadingMore = false;
      });
      
      if (kDebugMode) {
        debugPrint('✅ Загружено $newNewsCount новых новостей');
        debugPrint('📄 Всего новостей: ${_news.length}');
        debugPrint('➡️ Есть еще страницы: $_hasMorePages');
        debugPrint('🔢 Текущая страница: $_currentPage');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ Ошибка парсинга HTML: $e');
      }
      setState(() {
        _error = 'Ошибка обработки данных: $e';
        _isLoading = false;
        _isLoadingMore = false;
      });
    }
  }

  // 🔄 ИЗМЕНЕНИЕ 3: Функция для парсинга даты из строки
  DateTime _parseDateTimeFromString(String dateString) {
    try {
      // Пробуем разные форматы дат
      final formats = [
        'dd.MM.yyyy HH:mm',
        'yyyy-MM-ddTHH:mm:ssZ',
        'yyyy-MM-dd HH:mm:ss',
      ];
      
      for (final format in formats) {
        try {
          if (format == 'dd.MM.yyyy HH:mm') {
            final parts = dateString.split(' ');
            final dateParts = parts[0].split('.');
            final timeParts = parts[1].split(':');
            return DateTime(
              int.parse(dateParts[2]),
              int.parse(dateParts[1]),
              int.parse(dateParts[0]),
              int.parse(timeParts[0]),
              int.parse(timeParts[1]),
            );
          } else {
            final dateTime = DateTime.parse(dateString);
            return dateTime;
          }
        } catch (e) {
          continue;
        }
      }
      
      // Если ни один формат не подошел, возвращаем текущую дату
      return DateTime.now();
    } catch (e) {
      return DateTime.now();
    }
  }

  News? _parseTelegramMessage(dom.Element element) {
    try {
      // Извлекаем ID сообщения
      final messageElement = element.querySelector('.tgme_widget_message');
      final dataPost = messageElement?.attributes['data-post'];
      final messageId = dataPost?.split('/').last ?? '';

      // Заголовок
      final titleElement = element.querySelector('.tgme_widget_message_text b');
      final title = titleElement?.text.trim();

      if (title == null || title.isEmpty) {
        return null;
      }

      // URL сообщения
      final urlElement = element.querySelector('.tgme_widget_message_date');
      var url = urlElement?.attributes['href'];
      if (url == null || url.isEmpty) {
        url = 'https://t.me/jrr_news/$messageId';
      }

      // Дата и время
      final timeElement = element.querySelector('time');
      var dateTime = timeElement?.attributes['datetime'];
      if (dateTime == null || dateTime.isEmpty) {
        dateTime = _getCurrentDate();
      } else {
        // Преобразуем ISO дату в читаемый формат
        dateTime = _formatDateTime(dateTime);
      }

      // Изображение
      String? imageUrl;
      final photoWrap = element.querySelector('.tgme_widget_message_photo_wrap');
      if (photoWrap != null) {
        final style = photoWrap.attributes['style'];
        if (style != null) {
          final match = RegExp(r"background-image:url\('(.*?)'\)").firstMatch(style);
          imageUrl = match?.group(1);
        }
      }

      // Текст сообщения (описание)
      final textElement = element.querySelector('.tgme_widget_message_text');
      String description = '';
      
      if (textElement != null) {
        // Удаляем заголовок из текста для получения чистого описания
        final clonedElement = textElement.clone(true);
        clonedElement.querySelector('b')?.remove();
        description = _cleanText(clonedElement.text.trim());
      }

      // Если описание пустое, используем заголовок
      if (description.isEmpty) {
        description = title;
      }

      // Источник (из последнего <i> элемента)
      final sourceElement = element.querySelector('.tgme_widget_message_text i:last-child');
      final source = sourceElement?.text.trim() ?? 'JRR News';

      return News(
        id: messageId.isNotEmpty ? messageId : url,
        title: _cleanText(title),
        date: _cleanText(dateTime),
        imageUrl: imageUrl ?? '',
        description: _cleanText('$description\n\n📡 $source'),
        url: url,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ Ошибка парсинга Telegram сообщения: $e');
      }
      return null;
    }
  }

  String _formatDateTime(String isoDateTime) {
    try {
      final dateTime = DateTime.parse(isoDateTime);
      return '${dateTime.day.toString().padLeft(2, '0')}.${dateTime.month.toString().padLeft(2, '0')}.${dateTime.year} ${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return isoDateTime;
    }
  }

  String _cleanText(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _getCurrentDate() {
    final now = DateTime.now();
    return '${now.day.toString().padLeft(2, '0')}.${now.month.toString().padLeft(2, '0')}.${now.year}';
  }

  Widget _buildErrorWidget() {
    return SingleChildScrollView(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _hasInternetError ? Icons.wifi_off : Icons.error_outline,
                size: 64,
                color: Colors.grey[400],
              ),
              const SizedBox(height: 16),
              Text(
                _error,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _loadNews,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green[400],
                  foregroundColor: Colors.white,
                ),
                child: const Text('Попробовать снова'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyWidget() {
    return const SingleChildScrollView(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.article_outlined,
              size: 64,
              color: Colors.grey,
            ),
            SizedBox(height: 16),
            Text(
              'Статьи не найдены',
              style: TextStyle(color: Colors.grey, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadMoreIndicator() {
    if (!_hasMorePages) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(
          child: Text(
            'Все статьи загружены',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    
    return _isLoadingMore
        ? const Padding(
            padding: EdgeInsets.all(16.0),
            child: Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
              ),
            ),
          )
        : const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: RefreshIndicator(
        onRefresh: _loadNews,
        color: Colors.green[400],
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                ),
              )
            : _error.isNotEmpty
                ? _buildErrorWidget()
                : _news.isEmpty
                    ? _buildEmptyWidget()
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _news.length + 1,
                        itemBuilder: (ctx, index) {
                          if (index == _news.length) {
                            return _buildLoadMoreIndicator();
                          }
                          return NewsItem(
                            news: _news[index],
                          );
                        },
                      ),
      ),
    );
  }
}
