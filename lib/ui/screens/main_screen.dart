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

  // Социальные кнопки (отдельный виджет)
  Widget _buildSocialButtons(double buttonSize) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildSocialButton('assets/icon/icon_vkontakte.svg', AppStrings.vkontakteUrl, buttonSize),
        _buildSocialButton('assets/icon/icon_telegram.svg', AppStrings.telegramUrl, buttonSize),
        _buildSocialButton('assets/icon/icon_wwweblink.svg', AppStrings.wwweblinkUrl, buttonSize),
      ],
    );
  }

  // Верхняя часть (радио + плеер) - 55% высоты
  Widget _buildTopPart({required double availableWidth, required double availableHeight}) {
    return SizedBox(
      height: availableHeight * 0.55, // 55% от высоты
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          // Круглая кнопка переключения на радио с анимацией волн
          RadioButtonWithWaves(screenWidth: availableWidth),
          // Проигрыватель
          const AudioPlayerWidget(),
          const SizedBox(height: 8),
        ],
      ),
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
              padding: EdgeInsets.zero,
              tabAlignment: TabAlignment.fill,
              labelPadding: const EdgeInsets.symmetric(horizontal: 2.0),
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
  void initState() {
    super.initState();
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
    
    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
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
                  padding: EdgeInsets.zero,
                  tabAlignment: TabAlignment.fill,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 2.0),
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
            ? LayoutBuilder(
                builder: (context, constraints) {
                  final double availableWidth = constraints.maxWidth;
                  final double buttonSize = availableWidth * 0.08;
                  
                  return Stack(
                    children: [
                      Column(
                        children: [
                          // Социальные кнопки отдельно сверху
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: _buildSocialButtons(buttonSize),
                          ),
                          // Верхняя часть с радио и плеером
                          _buildTopPart(
                            availableWidth: availableWidth,
                            availableHeight: constraints.maxHeight,
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
                },
              )
            : OrientationBuilder(
                builder: (context, orientation) {
                  if (orientation == Orientation.landscape) {
                    // Горизонтальная ориентация: левая часть 40%, правая 60% ширины, обе на всю высоту
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final double availableWidth = constraints.maxWidth;
                        final double availableHeight = constraints.maxHeight;
                        final double leftWidth = availableWidth * 0.4;   // 40% ширины
                        final double rightWidth = availableWidth * 0.6;  // 60% ширины
                        final double buttonSize = rightWidth * 0.10;
                        
                        return Row(
                          children: [
                            // Левая часть (40% ширины) - на всю высоту
                            SizedBox(
                              width: leftWidth,
                              height: availableHeight,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  // Верхняя часть с радио и плеером (55% высоты)
                                  _buildTopPart(
                                    availableWidth: leftWidth,
                                    availableHeight: availableHeight,
                                  ),
                                ],
                              ),
                            ),
                            // Правая часть (60% ширины) - на всю высоту
                            SizedBox(
                              width: rightWidth,
                              height: availableHeight,
                              child: Column(
                                children: [
                                  // Социальные кнопки сверху правой части
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 16),
                                    child: _buildSocialButtons(buttonSize),
                                  ),
                                  // TabBar и контент - занимает всё оставшееся пространство
                                  Expanded(
                                    child: _buildBottomPart(),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  } else {
                    // Вертикальная ориентация
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final double availableWidth = constraints.maxWidth;
                        final double availableHeight = constraints.maxHeight;
                        final double buttonSize = availableWidth * 0.10;
                        
                        return Column(
                          children: [
                            // Социальные кнопки отдельно сверху
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: _buildSocialButtons(buttonSize),
                            ),
                            // Верхняя часть (радио + плеер) - 55% высоты
                            _buildTopPart(
                              availableWidth: availableWidth,
                              availableHeight: availableHeight,
                            ),
                            // Нижняя часть (табы) - остальное пространство
                            Expanded(
                              child: _buildBottomPart(),
                            ),
                          ],
                        );
                      },
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
