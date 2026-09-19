import 'models.dart';

/// 合集清单的勾选状态。
///
/// **段与集共用这一份数据**：段的状态（全勾 / 半勾 / 空）由「该段内被勾中的集」
/// 推导出来，不另存一份，避免两套状态对不上。
///
/// 抽成独立类是为了能脱离 widget 测这些语义 —— 之前这部分逻辑埋在
/// State 里，只能靠手点，回归时容易漏。
///
/// 所有操作都是**同步**的：调用方负责在改完后重建界面。这里没有异步回写，
/// 所以不存在「旧结果覆盖新状态」的竞态。
class SeasonSelection {
  SeasonSelection();

  final Set<int> _pages = <int>{};

  /// 勾中的合集内序号（副本，外部改不动内部状态）。
  Set<int> get pages => Set<int>.unmodifiable(_pages);

  int get count => _pages.length;

  bool get isEmpty => _pages.isEmpty;

  bool contains(int page) => _pages.contains(page);

  /// 该段的集是否全被勾中。
  bool allOf(SeasonSection section) =>
      section.episodes.isNotEmpty &&
      section.episodes.every((episode) => _pages.contains(episode.page));

  /// 该段是否有任意一集被勾中（用于判断半勾态）。
  bool anyOf(SeasonSection section) =>
      section.episodes.any((episode) => _pages.contains(episode.page));

  /// 整份清单是否全被勾中。
  bool allOfManifest(SeasonManifest manifest) =>
      manifest.totalEpisodes > 0 && _pages.length == manifest.totalEpisodes;

  /// 单集：勾上 / 取消。
  void toggleEpisode(int page) {
    if (!_pages.remove(page)) _pages.add(page);
  }

  /// 段：全勾则整段取消，否则整段勾上。
  void toggleSection(SeasonSection section) {
    if (allOf(section)) {
      for (final episode in section.episodes) {
        _pages.remove(episode.page);
      }
    } else {
      for (final episode in section.episodes) {
        _pages.add(episode.page);
      }
    }
  }

  /// 合集：全勾则清空，否则全部勾上。
  void toggleManifest(SeasonManifest manifest) {
    if (allOfManifest(manifest)) {
      _pages.clear();
    } else {
      for (final episode in manifest.allEpisodes) {
        _pages.add(episode.page);
      }
    }
  }

  /// 清空。
  void clear() => _pages.clear();
}
