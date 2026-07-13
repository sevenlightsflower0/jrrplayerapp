import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:jrrplayerapp/constants/app_colors.dart';
import 'package:jrrplayerapp/models/news.dart';

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
              // ✅ Правильный способ: обернуть в DefaultTextStyle
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

  void _openNewsDetail(BuildContext context) {
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
                style: const TextStyle(color: AppColors.customDarkGrey, fontSize: 12),
              ),
              const SizedBox(height: 8),
              // Тоже используем DefaultTextStyle для согласованности
              DefaultTextStyle(
                style: const TextStyle(color: AppColors.customBlack),
                child: Html(data: news.description),
              ),
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
  }
}