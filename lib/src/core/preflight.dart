import 'dart:async';

import 'models.dart';

/// 预检调度：管批次号、并发策略、结果缓存。
///
/// 与网络解耦（解析函数由外部注入），所以**批次语义能脱离真实请求测** ——
/// 「连续勾选时旧批次结果不能回写新清单」这种事只靠手点很难验，必须能单测。
///
/// 批次规则：
/// - 每次 [run] 递增批次号，旧批次的返回一律丢弃（先发后到也不怕）；
/// - 不再选中的集，结果与在跑的都会被清掉（取消勾选即停止关心）；
/// - 已有结果的集不重复请求（勾选来回切不浪费请求）。
class PreflightRunner {
  PreflightRunner({
    required this.resolve,
    required this.onChanged,
  });

  /// 解析一集。抛异常由调用方在 [resolve] 内转成 [PreflightResult]。
  final Future<PreflightResult> Function(SeasonEpisode episode) resolve;

  /// 状态有变化时回调（界面据此重建）。
  final void Function() onChanged;

  final Map<int, PreflightResult> results = <int, PreflightResult>{};

  final Set<int> _inFlight = <int>{};

  int _generation = 0;

  bool get busy => _inFlight.isNotEmpty;

  bool isInFlight(int page) => _inFlight.contains(page);

  PreflightResult of(int page) =>
      results[page] ?? const PreflightResult.unknown();

  /// 勾中且已通过预检的集数。
  int readyCount(Set<int> pages) =>
      pages.where((page) => of(page).downloadable).length;

  /// 清空并作废当前批次（换清单时调用，避免旧合集的结果串到新合集）。
  void reset() {
    _generation += 1;
    results.clear();
    _inFlight.clear();
    onChanged();
  }

  /// 中途停手：作废在跑的批次，但**保留已有结果**。
  ///
  /// 与 [reset] 的区别是结果不清空 —— 撞到风控后用户还能看到已经查出来的
  /// 缺档，也能照样勾着下。要不要继续由用户点，不自动重跑。
  void halt() {
    _generation += 1;
    _inFlight.clear();
    onChanged();
  }

  /// 对 [pages] 里的集做预检。
  ///
  /// [parallel] 为真时 2 路并发，否则严格串行且每集之间留间隔。
  Future<void> run({
    required List<SeasonEpisode> episodes,
    required Set<int> pages,
    required bool parallel,
  }) async {
    final generation = ++_generation;

    // 取消勾选的集：结果清掉。
    results.removeWhere((page, _) => !pages.contains(page));
    // 上一批「在跑」的全部作废 —— 它们的返回会被 generation 挡掉。
    // 若不清掉，同一集在新批次里会被误判成「已经在跑」而永远拿不到结果
    // （取消再勾上就会踩到）。
    _inFlight.clear();

    final targets = <SeasonEpisode>[];
    for (final episode in episodes) {
      if (!pages.contains(episode.page)) continue;
      if (results.containsKey(episode.page)) continue;
      if (_inFlight.contains(episode.page)) continue;
      targets.add(episode);
    }
    if (targets.isEmpty) {
      onChanged();
      return;
    }

    for (final episode in targets) {
      _inFlight.add(episode.page);
    }
    onChanged();

    final queue = List<SeasonEpisode>.of(targets);

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        if (generation != _generation) return;
        final episode = queue.removeAt(0);
        final result = await resolve(episode);
        // 批次已作废：结果丢掉，绝不回写。
        if (generation != _generation) return;
        _inFlight.remove(episode.page);
        results[episode.page] = result;
        onChanged();
        if (!parallel && queue.isNotEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
        }
      }
    }

    await Future.wait(
      List<Future<void>>.generate(parallel ? 2 : 1, (_) => worker()),
    );
    if (generation != _generation) return;
    _inFlight.clear();
    onChanged();
  }
}
