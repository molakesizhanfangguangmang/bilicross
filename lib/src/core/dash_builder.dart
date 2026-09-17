import 'models.dart';

/// 把 playurl 返回的 dash 结构转成可选流列表。
class DashBuilder {
  const DashBuilder._();

  static int _codecRank(String codecs) {
    final lower = codecs.toLowerCase();
    // 同清晰度优先 AVC：三端软解与硬件解都最稳，HEVC/AV1 只作为可选。
    if (lower.startsWith('avc')) return 0;
    if (lower.startsWith('hev') || lower.startsWith('hvc')) return 1;
    if (lower.startsWith('av01')) return 2;
    return 3;
  }

  static String _pickUrl(Map<String, dynamic> item) {
    final base = (item['base_url'] ?? item['baseUrl']) as String? ?? '';
    if (base.isNotEmpty) return base;
    final backups = _backups(item);
    return backups.isEmpty ? '' : backups.first;
  }

  static List<String> _backups(Map<String, dynamic> item) {
    final raw = item['backup_url'] ?? item['backupUrl'];
    if (raw is! List) return const [];
    return raw.whereType<String>().where((value) => value.isNotEmpty).toList();
  }

  static List<MediaStream> videoStreams(Map<String, dynamic> data) {
    final dash = data['dash'];
    if (dash is! Map) return const [];
    final raw = dash['video'];
    if (raw is! List) return const [];
    final streams = <MediaStream>[];
    for (final item in raw.whereType<Map>()) {
      final map = item.cast<String, dynamic>();
      final url = _pickUrl(map);
      if (url.isEmpty) continue;
      final id = (map['id'] as num?)?.toInt() ?? 0;
      streams.add(MediaStream(
        id: id,
        label: qualityLabel(id),
        codecs: map['codecs'] as String? ?? '',
        bandwidth: (map['bandwidth'] as num?)?.toInt() ?? 0,
        url: url,
        backupUrls: _backups(map),
        width: (map['width'] as num?)?.toInt() ?? 0,
        height: (map['height'] as num?)?.toInt() ?? 0,
      ));
    }
    streams.sort((left, right) {
      final byQuality = right.id.compareTo(left.id);
      if (byQuality != 0) return byQuality;
      return _codecRank(left.codecs).compareTo(_codecRank(right.codecs));
    });
    return streams;
  }

  static List<MediaStream> audioStreams(Map<String, dynamic> data) {
    final dash = data['dash'];
    if (dash is! Map) return const [];
    final collected = <Map<String, dynamic>>[];
    // dash.audio 与 dash.dolby.audio 是数组，dash.flac.audio 是单个对象。
    void absorb(Object? raw) {
      if (raw is List) {
        for (final item in raw.whereType<Map>()) {
          collected.add(item.cast<String, dynamic>());
        }
      } else if (raw is Map) {
        collected.add(raw.cast<String, dynamic>());
      }
    }

    absorb(dash['audio']);
    final flac = dash['flac'];
    if (flac is Map) absorb(flac['audio']);
    final dolby = dash['dolby'];
    if (dolby is Map) absorb(dolby['audio']);

    final streams = <MediaStream>[];
    final seen = <int>{};
    for (final map in collected) {
      final url = _pickUrl(map);
      if (url.isEmpty) continue;
      final id = (map['id'] as num?)?.toInt() ?? 0;
      if (!seen.add(id)) continue;
      streams.add(MediaStream(
        id: id,
        label: audioLabel(id),
        codecs: map['codecs'] as String? ?? '',
        bandwidth: (map['bandwidth'] as num?)?.toInt() ?? 0,
        url: url,
        backupUrls: _backups(map),
      ));
    }
    streams.sort((left, right) => left.id.compareTo(right.id));
    return streams;
  }

  static int durationOf(Map<String, dynamic> data) {
    final dash = data['dash'];
    if (dash is Map) {
      final duration = (dash['duration'] as num?)?.toInt() ?? 0;
      if (duration > 0) return duration;
    }
    return ((data['timelength'] as num?)?.toInt() ?? 0) ~/ 1000;
  }
}
