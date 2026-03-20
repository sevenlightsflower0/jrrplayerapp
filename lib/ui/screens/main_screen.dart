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
    // Ограничиваем размер, чтобы на узких экранах кнопки не становились невидимыми
    final double clampedSize = buttonSize.clamp(30.0, 60.0);
    return SizedBox(
      width: clampedSize,
      height: clampedSize,
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
          width: clampedSize,
          height: clampedSize,
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
      systemNavigationBarColor: AppColors.customTransp,
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

  // Верхняя часть (социальные кнопки + радио + плеер)
  Widget _buildTopPart() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double availableWidth = constraints.maxWidth;
        final double buttonSize = availableWidth * 0.10;

		return SingleChildScrollView(
		  child: Column(
			mainAxisAlignment: MainAxisAlignment.start,
			children: [
			  // Социальные кнопки с равномерным распределением
			  Padding(
				padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
				child: Row(
				  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
				  children: [
					_buildSocialButton('assets/icon/icon_vkontakte.svg', AppStrings.vkontakteUrl, buttonSize),
					_buildSocialButton('assets/icon/icon_telegram.svg', AppStrings.telegramUrl, buttonSize),
					_buildSocialButton('assets/icon/icon_wwweblink.svg', AppStrings.wwweblinkUrl, buttonSize),
				  ],
				),
			  ),

			  // Круглая кнопка переключения на радио с анимацией волн
				  RadioButtonWithWaves(screenWidth: availableWidth),

			  // Проигрыватель (теперь без Expanded)																		
			  const AudioPlayerWidget(),
			  const SizedBox(height: 8),
			],
		  ),
		);
      },
    );
  }

  // Нижняя половина экрана (табы + TabBarView + кнопка "Увеличить табы" поверх)
  Widget _buildBottomPart() {
    return Stack(
      children: [
        Column(
          children: [
            TabBar(
              controller: _tabController,
              padding: EdgeInsets.zero,                    // ← убирает левый отступ всего бара
              tabAlignment: TabAlignment.fill,             // ← заставляет табы равномерно заполнять ширину
              labelPadding: const EdgeInsets.symmetric(horizontal: 2.0), // можно чуть увеличить для красоты  
              labelColor: AppColors.customWhite,
              unselectedLabelColor: AppColors.customGrey,
              indicatorColor: AppColors.customGreen,
              tabs: const [
                Tab(text: AppStrings.articlesTab),
                Tab(text: AppStrings.newsTab),
                Tab(text: AppStrings.podcastsTab),
              ],
            ),
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
        Positioned(
          bottom: 16,
          right: 16,
          child: ElevatedButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const EnlargedTabsScreen()),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.customTransp,
              elevation: 0,
              foregroundColor: AppColors.customWhite,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: const Text(AppStrings.enlargeTabsButton),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool showAppBar = kIsWeb || defaultTargetPlatform == TargetPlatform.windows;

    if (!_isInitialized) {
      return const Scaffold(
        backgroundColor: AppColors.customBackgr,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.customWhite),
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
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(kTextTabBarHeight),
							  
                child: TabBar(
                  controller: _tabController,
                  padding: EdgeInsets.zero,                    // ← убирает левый отступ всего бара
                  tabAlignment: TabAlignment.fill,             // ← заставляет табы равномерно заполнять ширину
                  labelPadding: const EdgeInsets.symmetric(horizontal: 2.0), // можно чуть увеличить для красоты 
                  tabs: const [
                    Tab(text: AppStrings.articlesTab),
                    Tab(text: AppStrings.newsTab),
                    Tab(text: AppStrings.podcastsTab),
                  ],
                ),
              ),
				
            )
          : null,
      body: SafeArea(
        top: true,
        bottom: false,
        child: showAppBar
            // Для десктопа: верхняя часть + TabBarView + кнопка "Увеличить табы" поверх 
            ? Stack(
                children: [
                  Column(
                    children: [
                      _buildTopPart(),
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
                  Positioned(
                    bottom: 16,
                    right: 16,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => const EnlargedTabsScreen()),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.customTransp,
                        elevation: 0,
                        foregroundColor: AppColors.customWhite,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      child: const Text(AppStrings.enlargeTabsButton),
                    ),
                  ),
                ],
              )
            : OrientationBuilder(
                builder: (context, orientation) {
                  if (orientation == Orientation.landscape) {
                    return Row(
                      children: [
                        Expanded(flex: 1, child: _buildTopPart()),
                        Expanded(flex: 1, child: _buildBottomPart()),
                      ],
                    );
                  } else {
                    return Column(
                      children: [
                        Expanded(flex: 1, child: _buildTopPart()),
                        Expanded(flex: 1, child: _buildBottomPart()),
                      ],
                    );
                  }
                },
              ),
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }
}