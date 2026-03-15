import 'package:flutter/material.dart';
import 'package:jrrplayerapp/constants/app_colors.dart';
import 'package:provider/provider.dart';
import 'services/audio_player_service.dart';
import 'repositories/podcast_repository.dart';
import 'ui/screens/main_screen.dart';
import 'ui/screens/podcast_list_screen.dart';
import 'package:just_audio_background/just_audio_background.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.yourname.jrrplayerapp.channel.audio',
    androidNotificationChannelName: 'J-Rock Radio Playback',
    androidNotificationOngoing: true,
    androidShowNotificationBadge: true,
    androidNotificationIcon: 'mipmap/ic_launcher', // можно заменить на свой
    notificationColor: AppColors.customStyle,
    artDownscaleWidth: 512,
    artDownscaleHeight: 512,
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AudioPlayerService>(
          create: (context) => AudioPlayerService()..initialize(),
        ),
        ChangeNotifierProvider<PodcastRepository>(
          create: (context) => PodcastRepository(),
        ),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'J-Rock Radio Player',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.customStyle),
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const MainScreen(),
      debugShowCheckedModeBanner: false,
      routes: {
        '/podcasts': (context) => const PodcastListScreen(),
      },
    );
  }
}