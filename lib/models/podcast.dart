class PodcastEpisode {
  final String id;
  final String title;
  final String audioUrl;
  final String? imageUrl;
  final String? channelImageUrl;
  final String? description;
  final Duration duration;
  Duration currentPosition;
  
  PodcastEpisode({
    required this.id,
    required this.title,
    required this.audioUrl,
    this.imageUrl,
    this.channelImageUrl,
    this.description,
    required this.duration,
    this.currentPosition = Duration.zero,
  });

  // Конвертация в Map для сохранения
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'audioUrl': audioUrl,
      'imageUrl': imageUrl,
      'channelImageUrl': channelImageUrl,
      'description': description,
      'duration': duration.inMilliseconds,
      'currentPosition': currentPosition.inMilliseconds,
    };
  }

  // Создание из Map
  factory PodcastEpisode.fromMap(Map<String, dynamic> map) {
    return PodcastEpisode(
      id: map['id'],
      title: map['title'],
      audioUrl: map['audioUrl'],
      imageUrl: map['imageUrl'],
      channelImageUrl: map['channelImageUrl'],
      description: map['description'],
      duration: Duration(milliseconds: map['duration'] ?? 0),
      currentPosition: Duration(milliseconds: map['currentPosition'] ?? 0),
    );
  }

  // Копирование с обновленными значениями
  PodcastEpisode copyWith({
    Duration? currentPosition,
    Duration? duration,
  }) {
    return PodcastEpisode(
      id: id,
      title: title,
      audioUrl: audioUrl,
      imageUrl: imageUrl,
      channelImageUrl: channelImageUrl,
      description: description,
      duration: duration ?? this.duration,
      currentPosition: currentPosition ?? this.currentPosition,
    );
  }
}