// lib/ui/screens/articles_feed_screen.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart' as dom;

import 'package:jrrplayerapp/models/article.dart';
import 'package:jrrplayerapp/widgets/article_item.dart';
import 'package:jrrplayerapp/constants/strings.dart';

class ArticlesFeedScreen extends StatefulWidget {
  const ArticlesFeedScreen({super.key});

  @override
  State<ArticlesFeedScreen> createState() => _ArticlesFeedScreenState();
}

class _ArticlesFeedScreenState extends State<ArticlesFeedScreen> {
  List<Article> _articles = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String _error = '';
  int _currentPage = 1;
  bool _hasMorePages = true;
  final ScrollController _scrollController = ScrollController();
  final Set<String> _loadedUrls = {};

  @override
  void initState() {
    super.initState();
    _loadArticles();
    _scrollController.addListener(_scrollListener);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollListener() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 300) {
      if (!_isLoadingMore && _hasMorePages) {
        _loadMoreArticles();
      }
    }
  }

  Future<void> _loadArticles() async {
    setState(() {
      _isLoading = true;
      _error = '';
      _currentPage = 1;
      _articles.clear();
      _loadedUrls.clear();
    });

    try {
      final url = kIsWeb
          ? AppStrings.proxyUrl('${AppStrings.articlesFeedUrl}/')
          : '${AppStrings.articlesFeedUrl}/';

      final response = await AppStrings.getWithProxy(url);

      if (response.statusCode == 200) {
        _parseHtml(response.body, isFirstLoad: true);
      } else {
        throw Exception('Ошибка сервера: ${response.statusCode}');
      }
    } catch (e) {
      setState(() {
        _error = 'Нет подключения к интернету';
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMoreArticles() async {
    if (_isLoadingMore || !_hasMorePages) return;
    setState(() => _isLoadingMore = true);

    try {
      final nextPage = _currentPage + 1;
      final url = kIsWeb
          ? AppStrings.proxyUrl('${AppStrings.articlesFeedUrl}/page/$nextPage/')
          : '${AppStrings.articlesFeedUrl}/page/$nextPage/';

      final response = await AppStrings.getWithProxy(url);

      if (response.statusCode == 200 && response.body.contains('qt-part-archive-item')) {
        _parseHtml(response.body, isFirstLoad: false);
      } else {
        _hasMorePages = false;
      }
    } catch (e) {
      _hasMorePages = false;
    } finally {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    }
  }

  void _parseHtml(String html, {required bool isFirstLoad}) {
    final document = parser.parse(html);
    final items = document.querySelectorAll('.qt-part-archive-item');
    final List<Article> newArticles = [];

    for (final el in items) {
      final article = _parseArticle(el);
      if (article != null && !_loadedUrls.contains(article.url)) {
        newArticles.add(article);
        _loadedUrls.add(article.url);
      }
    }

    final hasNext = document.querySelector('.next.page-numbers') != null;

    setState(() {
      if (isFirstLoad) {
        _articles = newArticles;
      } else {
        _articles.addAll(newArticles);
      }
      _currentPage = isFirstLoad ? 1 : _currentPage + 1;
      _hasMorePages = hasNext && newArticles.isNotEmpty;
      _isLoading = false;
      _isLoadingMore = false;
    });
  }

  Article? _parseArticle(dom.Element element) {
    try {
      final link = element.querySelector('h3.qt-title a');
      final title = link?.text.trim();
      final url = link?.attributes['href'];
  
      if (title == null || url == null || title.isEmpty || url.isEmpty) {
        return null;
      }
  
      final dateEl = element.querySelector('.qt-date');
      final date = dateEl?.text.trim() ?? _getCurrentDate();
  
      // === САМЫЙ НАДЁЖНЫЙ СПОСОБ ПОЛУЧИТЬ КАРТИНКУ В 2025 ГОДУ ===
      String? imageUrl;
  
      // 1. Сначала ищем <img> с data-lazy-src (это основной способ на jrock.pro сейчас)
      final img = element.querySelector('img[data-lazy-src]');
      imageUrl = img?.attributes['data-lazy-src'];
  
      // 2. Если нет — пробуем обычный src
      if (imageUrl == null || imageUrl.isEmpty) {
        imageUrl = img?.attributes['src'];
      }
  
      // 3. Если и этого нет — ищем фон .qt-header-bg
      if (imageUrl == null || imageUrl.isEmpty) {
        final bg = element.querySelector('.qt-header-bg');
        imageUrl = bg?.attributes['data-bgimage'];
      }
  
      // === ДЕЛАЕМ URL РАБОЧИМ ЛЮБОЙ ЦЕНОЙ ===
      if (imageUrl != null && imageUrl.isNotEmpty) {
        imageUrl = imageUrl.trim();
  
        // Убираем кавычки
        if ((imageUrl.startsWith('"') && imageUrl.endsWith('"')) ||
            (imageUrl.startsWith("'") && imageUrl.endsWith("'"))) {
          imageUrl = imageUrl.substring(1, imageUrl.length - 1);
        }
  
        // Делаем абсолютным
        if (imageUrl.startsWith('//')) {
          imageUrl = 'https:$imageUrl';
        } else if (imageUrl.startsWith('/')) {
          imageUrl = 'https://jrock.pro$imageUrl';
        } else if (!imageUrl.startsWith('http')) {
          imageUrl = 'https://jrock.pro/$imageUrl';
        }
  
        // Дополнительно: иногда на jrock.pro в data-lazy-src лежит относительный путь без слеша
        // Пример: wp-content/uploads/... → добавляем слеш
        if (imageUrl.contains('wp-content') && !imageUrl.startsWith('http')) {
          imageUrl = 'https://jrock.pro/$imageUrl';
        }
      }
  
      // Если всё равно пусто — ставим заглушку
      final finalImageUrl = imageUrl?.isNotEmpty == true
          ? imageUrl!
          : 'https://jrock.pro/wp-content/uploads/2023/01/jrock-logo.png'; // логотип как fallback
  
      return Article(
        id: url,
        title: title.replaceAll(RegExp(r'\s+'), ' ').trim(),
        date: date,
        imageUrl: finalImageUrl,
        description: title,
        url: url,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Ошибка парсинга статьи: $e');
      return null;
    }
  }

  String _getCurrentDate() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.wifi_off, size: 80, color: Colors.grey),
          const SizedBox(height: 20),
          Text(
            _error.isEmpty ? 'Нет интернета' : _error,
            style: const TextStyle(color: Colors.white70, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _loadArticles,
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green[600]),
            child: const Text('Обновить', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildLoader() {
    return const Center(child: CircularProgressIndicator(color: Colors.green));
  }

  Widget _buildLoadMore() {
    if (!_hasMorePages) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: Text('Больше нет', style: TextStyle(color: Colors.grey))),
      );
    }
    return _isLoadingMore
        ? const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator(color: Colors.green)),
          )
        : const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: RefreshIndicator(
        onRefresh: _loadArticles,
        color: Colors.green[400],
        child: _isLoading
            ? _buildLoader()
            : _error.isNotEmpty
                ? _buildError()
                : _articles.isEmpty
                    ? const Center(child: Text('Пусто', style: TextStyle(color: Colors.grey)))
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _articles.length + 1,
                        itemBuilder: (context, index) {
                          if (index == _articles.length) return _buildLoadMore();
                          return ArticleItem(article: _articles[index]);
                        },
                      ),
      ),
    );
  }
}