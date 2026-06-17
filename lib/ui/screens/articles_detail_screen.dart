// lib/ui/screens/articles_detail_screen.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:jrrplayerapp/constants/app_colors.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

// Правильный современный импорт для открытия ссылок в браузере на вебе
import 'package:url_launcher/url_launcher.dart';

class ArticleDetailScreen extends StatefulWidget {
  final String articleUrl;
  final String title;

  const ArticleDetailScreen({
    super.key,
    required this.articleUrl,
    this.title = 'Статья',
  });

  @override
  State<ArticleDetailScreen> createState() => _ArticleDetailScreenState();
}

class _ArticleDetailScreenState extends State<ArticleDetailScreen> {
  late final WebViewController? _controller;
  bool _isLoading = true;
  double _loadingProgress = 0.0;

  @override
  void initState() {
    super.initState();

    if (!kIsWeb) {
      _initializeWebView();
    } else {
      // На вебе — сразу открываем в новой вкладке (через 100мс, чтобы экран успел отрисоваться)
      Future.delayed(const Duration(milliseconds: 100), () {
        _openInBrowser();
      });
    }
  }

  void _initializeWebView() {
    late final PlatformWebViewControllerCreationParams params;

    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final WebViewController controller =
        WebViewController.fromPlatformCreationParams(params);

      controller.setJavaScriptMode(JavaScriptMode.unrestricted);
  
    // Inject JavaScript to block microphone access on page load
    controller.addJavaScriptChannel(
      'disableMic',
      onMessageReceived: (JavaScriptMessage message) {
        // Just a placeholder – we use runJavaScript directly below
      },
    );
    
    // Better: use onWebViewCreated to run the script early
    // Actually, we can set a custom HTML to run before loading?
    // The easiest: after controller is created, run the script.
    // But we need to ensure it runs before the page loads.
    // We can use onPageStarted to inject it early.
    // Alternatively, we can set a custom user script.
    
    // For simplicity, we'll use runJavaScript after loading, but it might be too late.
    // Instead, we can use a custom WebKit configuration with a user script.
    
    // Since webview_flutter doesn't expose user scripts directly, we can use
    // the onPageStarted callback to inject the script on every navigation.
    // ---- RECOMMENDED APPROACH ----
    controller.setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (String url) {
          // Inject the script as soon as the page starts loading
          controller.runJavaScript('''
            (function() {
              // Override getUserMedia to reject immediately
              if (navigator.mediaDevices) {
                navigator.mediaDevices.getUserMedia = function(constraints) {
                  return Promise.reject(new Error("Microphone not available"));
                };
              }
              // Also block older APIs
              if (navigator.getUserMedia) {
                navigator.getUserMedia = null;
              }
              if (window.AudioContext) {
                // Optionally disable AudioContext if it might trigger mic
                // But that might break audio playback, so be careful.
                // We'll only block mic-related things.
              }
              console.log('Microphone access disabled by app');
            })();
          ''');
          setState(() => _isLoading = true);
        },
        onProgress: (progress) {
          setState(() {
            _loadingProgress = progress / 100;
          });
        },
        onPageFinished: (_) => setState(() => _isLoading = false),
        onWebResourceError: (_) => setState(() => _isLoading = false),
      ),
    );

    // Android-специфичные настройки (безопасно)
    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(true);
      (controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppColors.customBackgr)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            setState(() {
              _loadingProgress = progress / 100;
            });
          },
          onPageStarted: (_) => setState(() => _isLoading = true),
          onPageFinished: (_) => setState(() => _isLoading = false),
          onWebResourceError: (_) => setState(() => _isLoading = false),
        ),
      )
      ..loadRequest(Uri.parse(widget.articleUrl));

    _controller = controller;
  }

  Future<void> _openInBrowser() async {
    final uri = Uri.parse(widget.articleUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    // ==================== ВЕБ-ВЕРСИЯ ====================
    if (kIsWeb) {
      return Scaffold(
        backgroundColor: AppColors.customBackgr,
        appBar: AppBar(
          title: Text(widget.title),
          backgroundColor: AppColors.customGreen,
          foregroundColor: AppColors.customWhite,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.open_in_browser, size: 80, color: AppColors.customWhite),
              SizedBox(height: 24),
              Text(
                'Открываем статью в новой вкладке...',
                style: TextStyle(fontSize: 20, color: AppColors.customWhite),
              ),
              SizedBox(height: 16),
              CircularProgressIndicator(color: AppColors.customGreen),
            ],
          ),
        ),
      );
    }

    // ==================== МОБИЛЬНАЯ ВЕРСИЯ ====================
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: AppColors.customGreen,
        foregroundColor: AppColors.customWhite,
        actions: [
          if (_isLoading)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  value: _loadingProgress,
                  valueColor: const AlwaysStoppedAnimation<Color>(AppColors.customWhite),
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller!),
          if (_isLoading && _loadingProgress < 1.0)
            LinearProgressIndicator(
              value: _loadingProgress,
              backgroundColor: AppColors.customBackgr,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.green[400]!),
            ),
        ],
      ),
    );
  }
}