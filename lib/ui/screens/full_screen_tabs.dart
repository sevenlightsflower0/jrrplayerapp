import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jrrplayerapp/constants/app_colors.dart';
import 'package:jrrplayerapp/constants/strings.dart';
import 'package:jrrplayerapp/ui/screens/articles_feed_screen.dart';
import 'package:jrrplayerapp/ui/screens/news_feed_screen.dart';
import 'package:jrrplayerapp/ui/screens/podcast_list_screen.dart';

class FullScreenTabs extends StatefulWidget {
  final TabController tabController;
  
  const FullScreenTabs({super.key, required this.tabController});

  @override
  State<FullScreenTabs> createState() => _FullScreenTabsState();
}

class _FullScreenTabsState extends State<FullScreenTabs> with SingleTickerProviderStateMixin {
  late TabController _fullScreenTabController;

  @override
  void initState() {
    super.initState();
    // Создаем новый контроллер для полноэкранного режима с сохранением позиции
    _fullScreenTabController = TabController(
      length: 3, 
      vsync: this,
      initialIndex: widget.tabController.index,
    );
    
    // Настройка системной навигационной панели для полноэкранного режима
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _fullScreenTabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.customBackgr,
      appBar: AppBar(
        backgroundColor: AppColors.customWhite,
        foregroundColor: AppColors.customBackgr,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
        title: const Text(AppStrings.appName),
        bottom: TabBar(
          controller: _fullScreenTabController,
          tabs: const [
            Tab(text: AppStrings.articlesTab),
            Tab(text: AppStrings.newsTab),
            Tab(text: AppStrings.podcastsTab),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _fullScreenTabController,
          children: const [
            ArticlesFeedScreen(),
            NewsFeedScreen(),
            PodcastListScreen(),
          ],
        ),
      ),
    );
  }
}