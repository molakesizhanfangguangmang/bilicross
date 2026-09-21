/// 页面重建次数统计。
///
/// 用途单一：评估「按业务分区订阅」是否值得做——即页面有没有在被无关通知
/// 反复重建（白画）。只在 build 里自增一个 int，开销可忽略；不主动写日志，
/// 由高级设置里的入口按需取一次快照并归零。
class RebuildStats {
  RebuildStats._();

  static const String download = 'download';
  static const String tasks = 'tasks';
  static const String account = 'account';
  static const String settings = 'settings';

  static final Map<String, int> _counts = <String, int>{};

  static void tick(String page) => _counts[page] = (_counts[page] ?? 0) + 1;

  /// 取走当前计数并归零。返回的 map 只含出现过的页面。
  static Map<String, int> takeAndReset() {
    final snapshot = Map<String, int>.from(_counts);
    _counts.clear();
    return snapshot;
  }
}
