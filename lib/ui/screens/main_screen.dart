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

  // Функция для определения типа устройства (маленький экран)
  bool _isSmallScreen(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    // iPhone SE имеет высоту 667 логических пикселей (без учета safe areas)
    return screenHeight <= 700;
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final isSmallScreen = _isSmallScreen(context);
    
    // Адаптивные размеры для маленьких экранов
    final buttonSize = isSmallScreen ? screenWidth * 0.08 : screenWidth * 0.10;
    final socialButtonsMargin = isSmallScreen ? 2.0 : 4.0;
    final radioButtonSize = isSmallScreen ? screenWidth * 0.4 : screenWidth * 0.5;

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
              margin: EdgeInsets.symmetric(vertical: socialButtonsMargin),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildSocialButton('assets/icons/icon_vkontakte.svg', AppStrings.vkontakteUrl, buttonSize),
                  SizedBox(width: isSmallScreen ? 12 : 16),
                  _buildSocialButton('assets/icons/icon_telegram.svg', AppStrings.telegramUrl, buttonSize),
                  SizedBox(width: isSmallScreen ? 12 : 16),
                  _buildSocialButton('assets/icons/icon_wwweblink.svg', AppStrings.wwweblinkUrl, buttonSize),
                ],
              ),
            ),

            // Круглая кнопка переключения на радио с анимацией волн
            RadioButtonWithWaves(
              screenWidth: screenWidth,
              size: radioButtonSize,
            ),
            
            // Проигрыватель - для маленьких экранов уменьшаем высоту
            Container(
              height: isSmallScreen ? 80 : 100,
              margin: EdgeInsets.symmetric(vertical: isSmallScreen ? 4 : 8),
              child: const Center(
                child: AudioPlayerWidget(),
              ),
            ),

            // Кнопка для увеличения табов (скрываем на очень маленьких экранах)
            if (!isSmallScreen || screenHeight > 600)
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const EnlargedTabsScreen()),
                    );
                  },
                  child: const Text(AppStrings.enlargeTabsButton),
                ),
              ),

            // Нижняя половина экрана с табами (только если не показываем AppBar)
            if (!showAppBar) Expanded(
              child: Column(
                children: [
                  // Таб-бар с уменьшенной высотой на маленьких экранах
                  SizedBox(
                    height: isSmallScreen ? 40 : 48,
                    child: TabBar(
                      controller: _tabController,
                      tabs: const [
                        Tab(text: AppStrings.articlesTab),
                        Tab(text: AppStrings.newsTab),
                        Tab(text: AppStrings.podcastsTab),
                      ],
                    ),
                  ),
                  // Контент табов
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
      
      bottomNavigationBar: Container(
        height: kBottomNavigationBarHeight,
        color: Colors.transparent,
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }
}