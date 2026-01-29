import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:jrrplayerapp/models/podcast.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PodcastRepository with ChangeNotifier {
  final List<PodcastEpisode> _episodes = [];
  final Map<String, Duration> _durations = {};
  final Map<String, PodcastEpisode> _episodeCache = {};
  static const String _episodesCacheKey = 'episodes_cache';
  
  List<PodcastEpisode> get episodes => _episodes.map((episode) {
    final duration = _durations[episode.id];
    return duration != null ? episode.copyWith(duration: duration) : episode;
  }).toList();
  
  void updateEpisodeDuration(String episodeId, Duration duration) {
    _durations[episodeId] = duration;
    _episodeCache.remove(episodeId); // Инвалидируем кэш
    notifyListeners();
  }

  // Метод для добавления эпизодов в репозиторий
  Future<void> setEpisodes(List<PodcastEpisode> episodes) async {
    _episodes.clear();
    _episodes.addAll(episodes);
    
    // Кэшируем только первые 20 эпизодов для экономии памяти
    _episodeCache.clear();
    for (int i = 0; i < episodes.length && i < 20; i++) {
      _episodeCache[episodes[i].id] = episodes[i];
    }
    
    // Сохраняем в постоянное хранилище
    await _saveToStorage();
    
    notifyListeners();
  }

  Future<void> _saveToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final episodesJson = _episodes.map((e) => e.toJson()).toList();
      final jsonString = jsonEncode(episodesJson);
      await prefs.setString(_episodesCacheKey, jsonString);
    } catch (e) {
      debugPrint('Error saving episodes to storage: $e');
    }
  }

  Future<void> loadFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_episodesCacheKey);
      if (jsonString != null) {
        final List episodesJson = jsonDecode(jsonString);
        _episodes.clear();
        for (var json in episodesJson) {
          _episodes.add(PodcastEpisode.fromJson(json));
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error loading episodes from storage: $e');
    }
  }

  // Метод для получения эпизода по ID с кэшированием
  PodcastEpisode? getEpisodeById(String id) {
    // Сначала проверяем быстрый кэш
    if (_episodeCache.containsKey(id)) {
      return _episodeCache[id];
    }
    
    // Если нет в кэше, ищем в основном списке
    try {
      final episode = _episodes.firstWhere((episode) => episode.id == id);
      // Добавляем в кэш (с ограничением размера)
      if (_episodeCache.length >= 20) {
        _episodeCache.remove(_episodeCache.keys.first);
      }
      _episodeCache[id] = episode;
      return episode;
    } catch (e) {
      return null;
    }
  }
  
  // Метод для получения всех эпизодов
  List<PodcastEpisode> getAllEpisodes() {
    return List.from(_episodes);
  }
  
  // Метод для получения эпизодов, отсортированных по дате (новые первыми)
  List<PodcastEpisode> getSortedEpisodes() {
    final episodes = getAllEpisodes();
    episodes.sort((a, b) => b.publishedDate.compareTo(a.publishedDate));
    return episodes;
  }
  
  Future<PodcastEpisode?> getNextEpisode(PodcastEpisode currentEpisode) async {
    try {
      // Получаем отсортированные эпизоды
      final episodes = getSortedEpisodes();
      
      // Находим текущий эпизод
      final currentIndex = episodes.indexWhere((ep) => ep.id == currentEpisode.id);
      
      // Проверяем, есть ли следующий эпизод
      if (currentIndex != -1 && currentIndex + 1 < episodes.length) {
        return episodes[currentIndex + 1];
      }
      
      return null;
    } catch (e) {
      debugPrint('Error getting next episode: $e');
      return null;
    }
  }

  Future<PodcastEpisode?> getPreviousEpisode(PodcastEpisode currentEpisode) async {
    try {
      // Получаем отсортированные эпизоды
      final episodes = getSortedEpisodes();
      
      // Находим текущий эпизод
      final currentIndex = episodes.indexWhere((ep) => ep.id == currentEpisode.id);
      
      // Проверяем, есть ли предыдущий эпизод
      if (currentIndex != -1 && currentIndex > 0) {
        return episodes[currentIndex - 1];
      }
      
      return null;
    } catch (e) {
      debugPrint('Error getting previous episode: $e');
      return null;
    }
  }

  // Метод для добавления одного эпизода
  void addEpisode(PodcastEpisode episode) {
    _episodes.add(episode);
    notifyListeners();
  }

  // В класс PodcastRepository добавьте следующие поля и методы:

  final Map<String, Duration> _positions = {}; // Добавьте это поле

  // Метод для проверки, есть ли сохраненная позиция для эпизода
  bool hasEpisodePosition(String episodeId) {
    return _positions.containsKey(episodeId) && _positions[episodeId]! > Duration.zero;
  }

  // Метод для получения позиции эпизода (возвращает 0 только если нет сохраненной позиции)
  Duration getEpisodePosition(String episodeId) {
    return _positions[episodeId] ?? Duration.zero;
  }

  // Метод для обновления позиции эпизода
  void updateEpisodePosition(String episodeId, Duration position) {
    // Сохраняем позицию только если она больше 1 секунды
    // чтобы не сохранять случайные короткие позиции
    if (position.inSeconds > 1) {
      _positions[episodeId] = position;
      _savePositionsToStorage();
      notifyListeners();
    }
  }

  // Метод для сохранения позиций в хранилище
  Future<void> _savePositionsToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final positionsMap = _positions.map((key, value) => 
        MapEntry(key, value.inSeconds.toString()));
      await prefs.setString('podcast_positions', jsonEncode(positionsMap));
    } catch (e) {
      debugPrint('Error saving positions to storage: $e');
    }
  }

  // Метод для загрузки позиций из хранилища
  Future<void> loadPositionsFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final positionsJson = prefs.getString('podcast_positions');
      if (positionsJson != null) {
        final Map<String, dynamic> positionsMap = jsonDecode(positionsJson);
        positionsMap.forEach((key, value) {
          if (value is String) {
            _positions[key] = Duration(seconds: int.tryParse(value) ?? 0);
          }
        });
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error loading positions from storage: $e');
    }
  }

  // В методе clear() добавьте очистку позиций
  void clear() {
    _episodes.clear();
    _durations.clear();
    _positions.clear(); // Добавьте эту строку
    _episodeCache.clear();
    notifyListeners();
  }

  // В методе removeEpisode добавьте удаление позиции
  void removeEpisode(String id) {
    _episodes.removeWhere((episode) => episode.id == id);
    _durations.remove(id);
    _positions.remove(id); // Добавьте эту строку
    _episodeCache.remove(id);
    notifyListeners();
  }
  }