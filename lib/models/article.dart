// models/article.dart
class Article {
  final String id;
  final String title;
  final String date;
  final String imageUrl;
  final String description;
  final String url;

  const Article({
    required this.id,
    required this.title,
    required this.date,
    required this.imageUrl,
    required this.description,
    required this.url,
  });
}