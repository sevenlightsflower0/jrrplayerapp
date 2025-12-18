import 'package:flutter/foundation.dart';
import 'package:jrrplayerapp/models/podcast.dart';

class PodcastRepository with ChangeNotifier {
  final List<PodcastEpisode> _episodes = [];
  final Map<String, Duration> _durations = {};
  
  List<PodcastEpisode> get episodes => _episodes.map((episode) {
    final duration = _durations[episode.id];
    return duration != null ? episode.copyWith(duration: duration) : episode;
  }).toList();
  
  void updateEpisodeDuration(String episodeId, Duration duration) {
    _durations[episodeId] = duration;
    notifyListeners();
  }

  // Метод для добавления эпизодов в репозиторий
  void setEpisodes(List<PodcastEpisode> episodes) {
    _episodes.clear();
    _episodes.addAll(episodes);
    notifyListeners();
  }

  // Метод для получения эпизода по ID
  PodcastEpisode? getEpisodeById(String id) {
    try {
      return _episodes.firstWhere((episode) => episode.id == id);
    } catch (e) {
      return null; // Возвращаем null если не найден
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

  // Метод для очистки репозитория
  void clear() {
    _episodes.clear();
    _durations.clear();
    notifyListeners();
  }

  // Метод для добавления одного эпизода
  void addEpisode(PodcastEpisode episode) {
    _episodes.add(episode);
    notifyListeners();
  }

  // Метод для удаления эпизода по ID
  void removeEpisode(String id) {
    _episodes.removeWhere((episode) => episode.id == id);
    _durations.remove(id);
    notifyListeners();
  }
}