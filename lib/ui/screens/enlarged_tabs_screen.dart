import 'package:flutter/material.dart';
import 'package:jrrplayerapp/constants/strings.dart';
import 'package:jrrplayerapp/ui/screens/articles_feed_screen.dart';
import 'package:jrrplayerapp/ui/screens/news_feed_screen.dart';
import 'package:jrrplayerapp/ui/screens/podcast_list_screen.dart';

class EnlargedTabsScreen extends StatefulWidget {
  const EnlargedTabsScreen({super.key});

  @override
  State<EnlargedTabsScreen> createState() => _EnlargedTabsScreenState();
}

class _EnlargedTabsScreenState extends State<EnlargedTabsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.appName),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: AppStrings.articlesTab),
            Tab(text: AppStrings.newsTab),
            Tab(text: AppStrings.podcastsTab),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          ArticlesFeedScreen(),
          NewsFeedScreen(),
          PodcastListScreen(),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }
}