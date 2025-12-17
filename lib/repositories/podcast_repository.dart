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
}