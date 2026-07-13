import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:jrrplayerapp/constants/app_colors.dart';
import 'package:jrrplayerapp/models/news.dart';
import 'package:jrrplayerapp/ui/screens/news_detail_screen.dart'; // ← добавьте импорт

class NewsItem extends StatelessWidget {
  final News news;

  const NewsItem({super.key, required this.news});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.customTransp,
      child: InkWell(
        onTap: () => _openNewsDetail(context),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                news.date,
                style: const TextStyle(color: AppColors.customGreen, fontSize: 12),
              ),
              if (news.imageUrl.isNotEmpty) ...[
                const SizedBox(height: 8),
                Image.network(
                  news.imageUrl,
                  height: 200,
                  width: double.infinity,
                  fit: BoxFit.contain,
                  alignment: Alignment.center,
                ),
              ],
              const SizedBox(height: 8),
              DefaultTextStyle(
                style: const TextStyle(
                  color: AppColors.customWhite,
                  fontSize: 14,
                ),
                child: Html(data: news.description),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Новый метод – открывает полноэкранный экран вместо диалога
  void _openNewsDetail(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => NewsDetailScreen(news: news),
      ),
    );
  }
}