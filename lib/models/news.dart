// lib/models/news.dart
class News {
  final String date;
  final String imageUrl;
  final String description;
  final String title;
  final String id;
  final String url;

  const News({
    required this.date,
    required this.imageUrl,
    required this.description,
    required this.title,
    required this.id,
    required this.url,
  });
}