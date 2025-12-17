import 'package:flutter/material.dart';
import 'package:jrrplayerapp/models/news.dart';

class NewsItem extends StatelessWidget {
  final News news;

  const NewsItem({super.key, required this.news});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openNewsDetail(context),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                news.date,
                style: TextStyle(color: Colors.green[400], fontSize: 12),
              ),
              if (news.imageUrl.isNotEmpty) ...[
                const SizedBox(height: 8),
                Image.network(
                  news.imageUrl,
                  height: 200,
                  width: double.infinity,
                  fit: BoxFit.contain,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                news.description,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Implemented navigation method
  void _openNewsDetail(BuildContext context) {
    // You can use Navigator to push a new route
    // For now, we'll show a simple dialog as placeholder
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(news.title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (news.imageUrl.isNotEmpty)
                Image.network(
                  news.imageUrl,
                  height: 150,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              const SizedBox(height: 16),
              Text(
                news.date,
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(news.description),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    
    // For actual navigation to a detail page, you would use:
    // Navigator.of(context).push(
    //   MaterialPageRoute(
    //     builder: (context) => NewsDetailPage(news: news),
    //   ),
    // );
  }
}