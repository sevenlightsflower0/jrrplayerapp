import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/svg.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:jrrplayerapp/constants/app_colors.dart';
import 'package:jrrplayerapp/ui/screens/podcast_list_screen.dart';
import 'package:jrrplayerapp/widgets/audio_player_widget.dart';
import 'package:jrrplayerapp/constants/strings.dart';
import 'package:jrrplayerapp/ui/screens/articles_feed_screen.dart';
import 'package:jrrplayerapp/ui/screens/news_feed_screen.dart';
import 'package:jrrplayerapp/widgets/radio_button_with_waves.dart'; 
import 'package:jrrplayerapp/ui/screens/enlarged_tabs_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isInitialized = false;

  // Функция для открытия URL
  Future<void> _launchURL(String url) async {
    final Uri uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      throw 'Could not launch $url';
    }
  }

  // Функция для построения социальных кнопок
  Widget _buildSocialButton(String asset, String url, double buttonSize) {
    return SizedBox(
      width: buttonSize,
      height: buttonSize,
      child: ElevatedButton(
        onPressed: () => _launchURL(url),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.customBackgr,
          foregroundColor: AppColors.customWhite,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(2),
          ),
          padding: EdgeInsets.zero,
        ),
        child: SvgPicture.asset(
          asset,
          width: buttonSize,
          height: buttonSize,
          colorFilter: const ColorFilter.mode(AppColors.customWhite, BlendMode.srcIn),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    // Откладываем тяжелую инициализацию
    _initializeAsync();
    
    _tabController = TabController(length: 3, vsync: this);

    // Настройка системной навигационной панели
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ));
  }

  Future<void> _initializeAsync() async {
    // Даем время на отрисовку начального UI
    await Future.delayed(const Duration(milliseconds: 300));
    
    // Инициализируем дополнительные сервисы здесь если нужно
    
    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final buttonSize = screenWidth * 0.10;
    final totalButtonsWidth = buttonSize * 5;

    final bool showAppBar = kIsWeb || defaultTargetPlatform == TargetPlatform.windows;

    if (!_isInitialized) {
      return const Scaffold(
        backgroundColor: AppColors.customBackgr,
        body: Center(
          child: CircularProgressIndicator(
            color: AppColors.customWhite,
          ),
        ),
      );
    }
    
    return Scaffold(
      backgroundColor: AppColors.customBackgr,
      appBar: showAppBar
          ? AppBar(
              title: const Text(AppStrings.appName),
              backgroundColor: AppColors.customWhite,
              foregroundColor: AppColors.customBackgr,
              bottom: TabBar(
                controller: _tabController,
                tabs: const [
                  Tab(text: AppStrings.articlesTab),
                  Tab(text: AppStrings.newsTab),
                  Tab(text: AppStrings.podcastsTab),
                ],
              ),
            )
          : null,
      body: SafeArea(
        top: true,
        bottom: false,
        child: Column(
          children: [
            // Три квадратные кнопки с SVG иконками
            Container(
              width: totalButtonsWidth,
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildSocialButton('assets/icons/icon_vkontakte.svg', AppStrings.vkontakteUrl, buttonSize),
                  _buildSocialButton('assets/icons/icon_telegram.svg', AppStrings.telegramUrl, buttonSize),
                  _buildSocialButton('assets/icons/icon_wwweblink.svg', AppStrings.wwweblinkUrl, buttonSize),
                ],
              ),
            ),

            // Круглая кнопка переключения на радио с анимацией волн
            RadioButtonWithWaves(screenWidth: screenWidth),
            
            // Проигрыватель
            const Expanded(
              flex: 1,
              child: Center(
                child: AudioPlayerWidget(),
              ),
            ),

            // Кнопка для увеличения табов
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const EnlargedTabsScreen()),
                );
              },
              child: const Text(AppStrings.enlargeTabsButton),
            ),

            // Нижняя половина экрана с табами (только если не показываем AppBar)
            if (!showAppBar) Expanded(
              flex: 2, // Увеличиваем flex, чтобы табы занимали больше места
              child: Column(
                children: [
                  // Таб-бар
                  TabBar(
                    controller: _tabController,
                    tabs: const [
                      Tab(text: AppStrings.articlesTab),
                      Tab(text: AppStrings.newsTab),
                      Tab(text: AppStrings.podcastsTab),
                    ],
                  ),
                  // Контент табов - занимает всё оставшееся пространство
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: const [
                        ArticlesFeedScreen(),
                        NewsFeedScreen(),
                        PodcastListScreen(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            
            // Контент табов для случая с AppBar
            if (showAppBar) Expanded(
              flex: 2,
              child: TabBarView(
                controller: _tabController,
                children: const [
                  ArticlesFeedScreen(),
                  Center(child: Text(AppStrings.newsComingSoon)),
                  PodcastListScreen(),
                ],
              ),
            ),
          ],
        ),
      ),
      // Убрана bottomNavigationBar для мобильных устройств
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }
}