import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../i18n/app_localizations.dart';
import 'expand_page_route.dart';
import 'season_manifest_view.dart';

/// 合集选择页。
///
/// 从下载页的「这个视频属于合集」入口进来 —— **进来就意味着要下合集**，
/// 所以清单默认全不勾，用户自己挑要哪些（设计定案第 2 节）。
/// 单集下载不走这里，在下载页直接选流即可。
///
/// 顶部固定：合集标题 + 勾选统计 + 预检进度 + 加入按钮；
/// 下面是清单本体（懒加载 + 分级展开）。
class SeasonSelectPage extends StatefulWidget {
  const SeasonSelectPage({
    required this.state,
    required this.manifest,
    super.key,
  });

  final AppState state;
  final SeasonManifest manifest;

  @override
  State<SeasonSelectPage> createState() => _SeasonSelectPageState();
}

class _SeasonSelectPageState extends State<SeasonSelectPage> {
  final Set<int> _selected = <int>{};

  /// 单集覆盖的档位（合集内序号 -> 档位号）。**只有这里列出的集例外**，
  /// 其余集仍按预检给出的实际最高档走。
  final Map<int, int> _qualityOverrides = <int, int>{};

  /// 缺档汇总的「跳到第一处」目标。滚完会置回 null，
  /// 这样再点同一处仍然能触发（值从 null 变成目标页）。
  int? _focusPage;

  @override
  void initState() {
    super.initState();
    // 进页面时清一次预检，避免把上一个合集的残留结果带进来。
    widget.state.resetPreflight();
  }

  /// 勾中的集里缺档的那些（有流可下，但不是你选的那一档）。
  Set<int> _missingQualityPages() => <int>{
        for (final page in _selected)
          if (widget.state.preflightOf(page).qualityFellBack) page,
      };

  void _jumpToMissing(Set<int> flagged) {
    if (flagged.isEmpty) return;
    final first = flagged.reduce((a, b) => a < b ? a : b);
    setState(() => _focusPage = first);
    // 滚完（300ms）把目标清掉，让下次点同一处还能触发。
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _focusPage = null);
    });
  }

  /// 给某一集单独换个档。可选档位来自预检缓存，不再发请求。
  Future<void> _overrideQuality(int page) async {
    final state = widget.state;
    final preflight = state.preflightOf(page);
    final options = preflight.videoOptions;
    if (options.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    final current = _qualityOverrides[page];
    final picked = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(l10n.tr('manifest.overrideQualityTitle')),
        children: <Widget>[
          for (final stream in options)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(stream.id),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${stream.label} · ${stream.detail}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  if (stream.id == current)
                    const Icon(Icons.radio_button_checked, size: 16),
                ],
              ),
            ),
          const Divider(height: 1),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(0),
            child: Text(l10n.tr('manifest.overrideQualityClear')),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      // 0 是「不覆盖」的哨兵值：清掉这一集的例外，回到实际最高档。
      if (picked <= 0) {
        _qualityOverrides.remove(page);
      } else {
        _qualityOverrides[page] = picked;
      }
    });
  }

  void _onSelectionChanged(Set<int> pages) {
    setState(() {
      // _selected 是 final 集合：整集赋值不行，只能原地改内容。
      _selected
        ..clear()
        ..addAll(pages);
    });
    unawaited(
      widget.state.preflightEpisodes(
        manifest: widget.manifest,
        pages: pages,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final state = widget.state;
        final total = _selected.length;
        final ready = state.preflightReadyCount(_selected);
        final allReady = total > 0 && ready == total;
        // 缺档汇总：只算勾中的集。预检没跑完的集不在这里 —— 它们还没结论。
        final flagged = _missingQualityPages();

        return Scaffold(
          appBar: AppBar(title: Text(l10n.tr('manifest.title'))),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: Column(
                children: <Widget>[
                  // 顶部固定区：合集信息 + 统计 + 加入按钮，滚动不动。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          widget.manifest.title.isEmpty
                              ? l10n.tr('manifest.untitled')
                              : widget.manifest.title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.tr('manifest.summary', {
                            'episodes': '${widget.manifest.totalEpisodes}',
                            'sections': '${widget.manifest.sections.length}',
                          }),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xff6d716f),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                total == 0
                                    ? l10n.tr('manifest.nothingSelected')
                                    : allReady
                                        ? l10n.tr('manifest.selectedReady', {
                                            'count': '$total',
                                          })
                                        : l10n.tr('manifest.preflighting', {
                                            'ready': '$ready',
                                            'total': '$total',
                                          }),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xff6d716f),
                                ),
                              ),
                            ),
                            FilledButton.icon(
                              onPressed: !allReady
                                  ? null
                                  : () => _enqueue(context, state),
                              icon: const Icon(Icons.playlist_add),
                              label: Text(
                                l10n.tr('manifest.enqueueSelected', {
                                  'count': '$total',
                                }),
                              ),
                            ),
                          ],
                        ),
                        // 缺档汇总：预检跑完后给一次，点一下滚到第一处并高亮。
                        if (flagged.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
                            decoration: BoxDecoration(
                              color: const Color(0x14b06a3b),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              children: <Widget>[
                                const Icon(
                                  Icons.info_outline,
                                  size: 15,
                                  color: Color(0xffb06a3b),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    l10n.tr('manifest.missingQualitySummary', {
                                      'count': '${flagged.length}',
                                    }),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xffb06a3b),
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => _jumpToMissing(flagged),
                                  style: TextButton.styleFrom(
                                    minimumSize: Size.zero,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    textStyle: const TextStyle(fontSize: 12),
                                  ),
                                  child: Text(l10n.tr('manifest.jumpToFirst')),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  // 清单本体。
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      child: SeasonManifestView(
                        manifest: widget.manifest,
                        preflightOf: state.preflightOf,
                        isPreflighting: state.isPreflighting,
                        onSelectionChanged: _onSelectionChanged,
                        flaggedPages: flagged,
                        focusPage: _focusPage,
                        qualityOverrideOf: (page) => _qualityOverrides[page],
                        onOverrideQuality: _overrideQuality,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _enqueue(BuildContext context, AppState state) {
    final outcome = state.enqueueEpisodes(
      manifest: widget.manifest,
      selectedPages: _selected,
      engine: 'dart',
      qualityOverrides: _qualityOverrides,
    );
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l10n.tr('manifest.batchResult', {
            'enqueued': '${outcome.enqueued}',
            'skipped': '${outcome.skipped}',
            'renamed': '${outcome.renamed}',
          }),
        ),
      ),
    );
  }
}

/// 从下载页进入合集选择页（用与「高级设置」相同的展开转场）。
void openSeasonSelectPage(
  BuildContext context,
  AppState state,
  SeasonManifest manifest, {
  Rect? sourceRect,
}) {
  Navigator.of(context).push(
    ExpandPageRoute<void>(
      sourceRect: sourceRect,
      duration: Duration(milliseconds: state.settings.animDurationMs),
      curveName: state.settings.animCurve,
      style: state.settings.animStyle,
      builder: (context) => SeasonSelectPage(state: state, manifest: manifest),
    ),
  );
}
