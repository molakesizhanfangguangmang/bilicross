import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/season_selection.dart';
import '../i18n/app_localizations.dart';

/// 合集清单：合集 → 段 → 集 三级展示 + 勾选。
///
/// 勾选语义（设计定案第 2 节）：
/// - 合集行有勾：勾上 = 整个合集全下；
/// - 段行有勾：可全选、可多选、可一个不勾；勾段 = 批量把该段的集勾上；
/// - 段与集是**同一份勾选数据**：段内集全勾则段显示全勾，
///   全不勾显示空勾，部分勾显示半勾 —— 不是两套状态；
/// - 段全不勾时照样能手勾单个集。
/// 默认全不勾（背后没有合集的单集清单默认勾，那种情况不走这个组件）。
class SeasonManifestView extends StatefulWidget {
  const SeasonManifestView({
    super.key,
    required this.manifest,
    this.onSelectionChanged,
    this.preflightOf,
    this.isPreflighting,
  });

  final SeasonManifest manifest;

  /// 勾选集合变化时回调（传出当前勾中的合集内序号副本）。
  final ValueChanged<Set<int>>? onSelectionChanged;

  /// 取某一集的预检结果（不传就不显示预检状态）。
  final PreflightResult Function(int page)? preflightOf;

  /// 某一集是否正在预检中。
  final bool Function(int page)? isPreflighting;

  @override
  State<SeasonManifestView> createState() => _SeasonManifestViewState();
}

class _SeasonManifestViewState extends State<SeasonManifestView> {
  /// 勾选状态。语义与边界都在 [SeasonSelection] 里，这里只负责重建与回调。
  final SeasonSelection _selection = SeasonSelection();

  void _changed() => widget.onSelectionChanged?.call(_selection.pages);

  void _toggleEpisode(int page) => setState(() {
        _selection.toggleEpisode(page);
        _changed();
      });

  void _toggleSection(SeasonSection section) => setState(() {
        _selection.toggleSection(section);
        _changed();
      });

  void _toggleAll() => setState(() {
        _selection.toggleManifest(widget.manifest);
        _changed();
      });

  @override
  Widget build(BuildContext context) {
    final manifest = widget.manifest;
    // 只有一个段且没有标题时，段这一层不显示 —— 那是「合集没分段」的兜底形状，
    // 硬加一层「无标题段」只会让清单看起来莫名其妙地多缩进一次。
    final singleUnnamedSection =
        manifest.sections.length == 1 && manifest.sections.first.title.isEmpty;
    final allSelected = _selection.allOfManifest(manifest);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Header(
          manifest: manifest,
          checked: allSelected,
          onToggle: _toggleAll,
        ),
        const SizedBox(height: 8),
        if (singleUnnamedSection)
          for (final episode in manifest.sections.first.episodes)
            _EpisodeRow(
              episode: episode,
              depth: 0,
              checked: _selection.contains(episode.page),
              onToggle: () => _toggleEpisode(episode.page),
              preflight: widget.preflightOf?.call(episode.page),
              preflighting:
                  widget.isPreflighting?.call(episode.page) ?? false,
            )
        else
          for (final section in manifest.sections) ...<Widget>[
            _SectionRow(
              section: section,
              checked: _selection.allOf(section),
              partial: !_selection.allOf(section) && _selection.anyOf(section),
              onToggle: () => _toggleSection(section),
            ),
            for (final episode in section.episodes)
              _EpisodeRow(
                episode: episode,
                depth: 1,
                checked: _selection.contains(episode.page),
                onToggle: () => _toggleEpisode(episode.page),
                preflight: widget.preflightOf?.call(episode.page),
                preflighting:
                    widget.isPreflighting?.call(episode.page) ?? false,
              ),
            const SizedBox(height: 6),
          ],
        const SizedBox(height: 4),
        Text(
          _countHint(context, manifest),
          style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
        ),
      ],
    );
  }

  String _countHint(BuildContext context, SeasonManifest manifest) {
    final l10n = AppLocalizations.of(context);
    return l10n.tr('manifest.countHint', {
      'episodes': '${manifest.totalEpisodes}',
      'sections': '${manifest.sections.length}',
      'checked': '${_selection.count}',
    });
  }
}

/// 合集标题行：勾选框 + 标题 + 「共 N 集 · M 段」。
class _Header extends StatelessWidget {
  const _Header({
    required this.manifest,
    required this.checked,
    required this.onToggle,
  });

  final SeasonManifest manifest;
  final bool checked;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Checkbox(value: checked, onChanged: (_) => onToggle()),
        const SizedBox(width: 4),
        const Icon(Icons.video_library_outlined, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                manifest.title.isEmpty
                    ? l10n.tr('manifest.untitled')
                    : manifest.title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                l10n.tr('manifest.summary', {
                  'episodes': '${manifest.totalEpisodes}',
                  'sections': '${manifest.sections.length}',
                }),
                style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 段行：勾选框 + 段名 · N 集。
class _SectionRow extends StatelessWidget {
  const _SectionRow({
    required this.section,
    required this.checked,
    required this.partial,
    required this.onToggle,
  });

  final SeasonSection section;
  final bool checked;
  final bool partial;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 0, 4),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 34,
            child: Checkbox(
              value: checked ? true : (partial ? null : false),
              tristate: true,
              onChanged: (_) => onToggle(),
            ),
          ),
          const Icon(Icons.folder_outlined, size: 15, color: Color(0xff6d716f)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              section.title.isEmpty
                  ? l10n.tr('manifest.untitledSection')
                  : section.title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          Text(
            l10n.tr(
              'manifest.sectionEpisodes',
              {'count': '${section.episodes.length}'},
            ),
            style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
          ),
        ],
      ),
    );
  }
}

/// 集行：勾选框 + 序号 · 标题 · 时长。
class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.episode,
    required this.depth,
    required this.checked,
    required this.onToggle,
    this.preflight,
    this.preflighting = false,
  });

  final SeasonEpisode episode;
  final int depth;
  final bool checked;
  final VoidCallback onToggle;
  final PreflightResult? preflight;
  final bool preflighting;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: EdgeInsets.fromLTRB(depth == 0 ? 26 : 48, 0, 0, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 34,
              child: Checkbox(value: checked, onChanged: (_) => onToggle()),
            ),
            SizedBox(
              width: 30,
              child: Text(
                // 序号是合集内编号，补下别的段时不会重号，所以直接展示。
                '${episode.page}',
                style: const TextStyle(fontSize: 12, color: Color(0xff9aa3a0)),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        episode.title.isEmpty ? '—' : episode.title,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    if (preflighting) ...<Widget>[
                      const SizedBox(width: 6),
                      const SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      ),
                    ] else if (preflight != null &&
                        preflight!.status != PreflightStatus.ok) ...<Widget>[
                      const SizedBox(width: 6),
                      _StatusChip(result: preflight!),
                    ],
                  ],
                ),
              ),
            ),
            if (episode.durationSec > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 12),
                child: Text(
                  formatDuration(episode.durationSec),
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xff9aa3a0)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 预检未通过时的小标记：缺档 / 不可用 / 风控，用颜色区分严重度。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.result});

  final PreflightResult result;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (String key, Color color) = switch (result.status) {
      PreflightStatus.riskControl => (
          'manifest.preflight.riskControl',
          const Color(0xffc0392b),
        ),
      PreflightStatus.unavailable => (
          'manifest.preflight.unavailable',
          const Color(0xff6d716f),
        ),
      _ => ('manifest.preflight.missingQuality', const Color(0xffb06a3b)),
    };
    return Tooltip(
      message: result.message.isEmpty ? l10n.tr(key) : result.message,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          l10n.tr(key),
          style: TextStyle(fontSize: 11, color: color),
        ),
      ),
    );
  }
}
