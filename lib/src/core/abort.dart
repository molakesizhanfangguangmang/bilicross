/// 中断下载的两种意图：暂停要留分片，强制结束不留。
enum AbortReason { pause, stop }

/// 用户主动中断，用来和网络错误区分开。
///
/// 只有它会让任务落到「暂停」或「已结束」，普通异常一律算失败，分片留下待续传。
class TaskAborted implements Exception {
  const TaskAborted(this.reason);

  final AbortReason reason;

  bool get isPause => reason == AbortReason.pause;

  @override
  String toString() => isPause ? '已暂停' : '已强制结束';
}

/// 一次任务运行的取消句柄。
///
/// 只靠「收到数据块时查一次标志」是不够的：连接彻底不动时永远等不到那一刻，
/// 进度会停在最后一个字节上，界面上的暂停键按下去也没有反应——这正是
/// 「卡在 90%~99% 时暂停不了」的成因。所以句柄同时握着当前那条连接，
/// 取消时先把连接掐掉，让卡在 `await` 里的读取立刻以错误收场，
/// 再由各层把错误归类成 [TaskAborted]。
class AbortControl {
  AbortReason? _reason;
  void Function()? _abortConnection;

  AbortReason? get reason => _reason;
  bool get aborted => _reason != null;

  void pause() => _abort(AbortReason.pause);

  void stop() => _abort(AbortReason.stop);

  void _abort(AbortReason reason) {
    if (_reason != null) return;
    _reason = reason;
    _abortConnection?.call();
  }

  /// 由正在跑的那一段（下载会话、ffmpeg 进程）登记「怎么掐自己」。
  /// 登记时若已经被取消，立刻掐一次。
  void bind(void Function() abortConnection) {
    _abortConnection = abortConnection;
    if (aborted) abortConnection();
  }

  void unbind() => _abortConnection = null;

  /// 每个可能长时间等待的地方都先问一句。
  void throwIfAborted() {
    final reason = _reason;
    if (reason != null) throw TaskAborted(reason);
  }
}
