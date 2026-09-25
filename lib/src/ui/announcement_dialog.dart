import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/announcement.dart';
import '../core/announcement_center.dart';
import '../core/update_check.dart';
import '../i18n/app_localizations.dart';
import 'about_dialog.dart';
import 'palette.dart';
import 'widgets.dart';

/// 「滑到底」的判定容差：正文滚到距底部 8px 以内就算读完。
const double kAnnouncementBottomTolerance = 8;

/// `poll.requireVote` 的公告：提交连续失败到这个次数就放行关闭。
///
/// ⚠️ 不能只做「投了才给关」——网络一直不通时用户会被永久锁在弹窗里，只能杀进程。
const int kMaxVoteFailures = 2;

/// 弹一条公告。[review] 为真表示用户是从设置页主动点开查看的 ——
/// 那时不强制滑到底、不可关闭的公告也允许关（否则会被卡在设置页出不去）。
Future<void> showAnnouncementDialog(
  BuildContext context, {
  required AnnouncementCenter center,
  required Announcement announcement,
  bool review = false,
}) {
  return showDialog<void>(
    context: context,
    // 两种公告都不给「点外面关掉」这条路：可关闭的走底部按钮，
    // 不可关闭的只能点「立即更新」。
    barrierDismissible: false,
    builder: (_) => _AnnouncementDialog(
      center: center,
      announcement: announcement,
      review: review,
    ),
  );
}

class _AnnouncementDialog extends StatefulWidget {
  const _AnnouncementDialog({
    required this.center,
    required this.announcement,
    required this.review,
  });

  final AnnouncementCenter center;
  final Announcement announcement;
  final bool review;

  @override
  State<_AnnouncementDialog> createState() => _AnnouncementDialogState();
}

class _AnnouncementDialogState extends State<_AnnouncementDialog> {
  final ScrollController _scroll = ScrollController();

  /// 正文是不是长到需要滚动。要在首帧布局之后才算得出来。
  bool _needsScroll = false;
  bool _atBottom = true;
  bool _updating = false;
  int _voteFailures = 0;

  Announcement get _announcement => widget.announcement;

  /// `poll.requireVote` 并且还没投票：这时候不给关。
  ///
  /// ⚠️ 三种情况必须放行，否则是死锁：投票已结束（服务端不再收票）、本机已投过、
  /// 提交连续失败到 [kMaxVoteFailures]。
  bool get _voteGateOpen {
    final poll = _announcement.poll;
    if (poll == null || !poll.requireVote) return false;
    if (_voteFailures >= kMaxVoteFailures) return false;
    return poll.open && !widget.center.hasVoted(poll.id);
  }

  /// 能不能关：不可关闭的公告只有「立即更新」一条路；
  /// 可关闭的还得先把长的正文滑到底。
  bool get _canClose {
    if (widget.review) return true;
    if (_announcement.forced) return false;
    if (_voteGateOpen) return false;
    return !_needsScroll || _atBottom;
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // 短正文 vs 长正文只有布局完才知道；不量这一次的话，短公告也会被判成「要滑到底」。
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom = _scroll.position.extentAfter <= kAnnouncementBottomTolerance;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
  }

  void _measure() {
    if (!mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    final needs = position.maxScrollExtent > 1;
    final atBottom = position.extentAfter <= kAnnouncementBottomTolerance;
    if (needs != _needsScroll || atBottom != _atBottom) {
      setState(() {
        _needsScroll = needs;
        _atBottom = atBottom;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final poll = _announcement.poll;
    final pollOpen =
        poll != null && poll.open && !widget.center.hasVoted(poll.id);
    return PopScope(
      // 读完（或本来就能关）之前，系统返回键也不放行 —— 否则安卓上按一下
      // 就绕过了「必须看完」。
      canPop: _canClose,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(widget.center.dismiss(_announcement));
      },
      child: Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (_announcement.forced) ...<Widget>[
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Icon(Icons.priority_high, size: 18, color: kDanger),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        _announcement.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: Scrollbar(
                    controller: _scroll,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      child: Text(_announcement.body),
                    ),
                  ),
                ),
                if (!widget.review && _needsScroll && !_atBottom)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      l10n.tr('announcement.scrollToEnd'),
                      style: const TextStyle(fontSize: 12, color: kTextMuted),
                    ),
                  ),
                if (!widget.review && _voteGateOpen)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      l10n.tr('announcement.voteToClose'),
                      style: const TextStyle(fontSize: 12, color: kTextMuted),
                    ),
                  ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    if (pollOpen) ...<Widget>[
                      FilledButton(
                        onPressed: _updating
                            ? null
                            : () => unawaited(_openPoll()),
                        child: Text(
                          _announcement.actionLabel.isEmpty
                              ? l10n.tr('announcement.vote')
                              : _announcement.actionLabel,
                        ),
                      ),
                    ],
                    if (_announcement.closable) ...<Widget>[
                      if (pollOpen) const SizedBox(width: 8),
                      TextButton(
                        onPressed:
                            _canClose ? () => Navigator.of(context).pop() : null,
                        child: Text(l10n.tr('common.close')),
                      ),
                    ],
                    if (_announcement.forced) ...<Widget>[
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed:
                            _updating ? null : () => unawaited(_runUpdate()),
                        child: Text(
                          _updating
                              ? l10n.tr('announcement.checking')
                              : l10n.tr('announcement.updateNow'),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openPoll() async {
    final voted = await showPollDialog(
      context,
      center: widget.center,
      announcement: _announcement,
      onFailed: () {
        if (!mounted) return;
        setState(() => _voteFailures += 1);
      },
    );
    if (!mounted || !voted) return;
    // 投完就算处理完了。⚠️ 但不可关闭的公告不在这里放行 —— 否则「投一票」
    // 就能绕过强制更新。
    if (!_announcement.forced) Navigator.of(context).pop();
  }

  /// 「立即更新」：复用现有的更新检查流程（关于页的「检测更新」走的是同一套）。
  ///
  /// ⚠️ 内测构建会在这个方法体开头被注入一段分支（见
  /// `scripts/inject-internal-build.js`）：内测包不做更新检查，只提示一句再放行。
  Future<void> _runUpdate() async {
    setState(() => _updating = true);
    final result = await checkForUpdate();
    if (!mounted) return;
    setState(() => _updating = false);
    await handleUpdateResult(
      context,
      result,
      notifyWhenUpToDate: true,
      androidAbi: Platform.isAndroid ? 'arm64-v8a' : null,
    );
    if (!mounted) return;
    // ⚠️ 远端没有更新的版本时必须放行关闭：这条公告不可关闭，可本机已经没东西可装了，
    // 不放行就是把用户永久锁在弹窗里（只能杀进程）。
    if (result.outcome != UpdateOutcome.available) {
      await widget.center.dismiss(_announcement, force: true);
      if (mounted) Navigator.of(context).pop();
    }
  }
}

/// 投票层。返回是否投出去了。
Future<bool> showPollDialog(
  BuildContext context, {
  required AnnouncementCenter center,
  required Announcement announcement,
  VoidCallback? onFailed,
}) async {
  final poll = announcement.poll;
  if (poll == null) return false;
  final voted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PollDialog(
      center: center,
      announcement: announcement,
      onFailed: onFailed,
    ),
  );
  return voted ?? false;
}

class _PollDialog extends StatefulWidget {
  const _PollDialog({
    required this.center,
    required this.announcement,
    this.onFailed,
  });

  final AnnouncementCenter center;
  final Announcement announcement;

  /// 每次提交失败回调一次，供上层判断「是不是该放行关闭了」。
  final VoidCallback? onFailed;

  @override
  State<_PollDialog> createState() => _PollDialogState();
}

class _PollDialogState extends State<_PollDialog> {
  final Set<String> _selected = <String>{};
  bool _submitting = false;

  Future<void> _submit() async {
    if (_selected.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    final ok = await widget.center.vote(
      widget.announcement,
      _selected.toList(),
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok) {
      // 只回「已提交」：票数接口带管理密钥，客户端拿不到，界面也不假装有。
      Navigator.of(context).pop(true);
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).tr('announcement.voteFailed')),
          duration: const Duration(seconds: 2),
        ),
      );
    widget.onFailed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final poll = widget.announcement.poll!;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                poll.question.isEmpty
                    ? widget.announcement.title
                    : poll.question,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final option in poll.options)
                        if (poll.multi)
                          CheckboxListTile(
                            value: _selected.contains(option.id),
                            onChanged: (checked) => setState(() {
                              if (checked == true) {
                                _selected.add(option.id);
                              } else {
                                _selected.remove(option.id);
                              }
                            }),
                            title: Text(
                              option.label,
                              style: const TextStyle(fontSize: 13),
                            ),
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                          )
                        else
                          ChoiceTile(
                            selected: _selected.contains(option.id),
                            title: option.label,
                            onTap: () => setState(() {
                              _selected
                                ..clear()
                                ..add(option.id);
                            }),
                          ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: Text(l10n.tr('common.cancel')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: (_selected.isEmpty || _submitting)
                        ? null
                        : () => unawaited(_submit()),
                    child: Text(
                      _submitting
                          ? l10n.tr('announcement.submitting')
                          : l10n.tr('announcement.submit'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
