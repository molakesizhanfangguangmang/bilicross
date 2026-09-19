import 'package:flutter/material.dart';

/// Release 说明的极简 Markdown 渲染。
///
/// 说明由本项目自己按固定格式撰写（`## 标题`、`- 列表`、`**粗体**`），
/// 不需要通用 Markdown 解析器，因此不引第三方依赖：
/// 只认这几种写法，其余内容原样显示，不会出现丢掉正文的情况。
class ReleaseNotesView extends StatelessWidget {
  const ReleaseNotesView({super.key, required this.notes});

  final String notes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocks = parseReleaseNotes(notes);
    if (blocks.isEmpty) {
      return Text(
        '',
        style: theme.textTheme.bodyMedium,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (var i = 0; i < blocks.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 8),
          _buildBlock(context, blocks[i]),
        ],
      ],
    );
  }

  Widget _buildBlock(BuildContext context, NotesBlock block) {
    final theme = Theme.of(context);
    switch (block.kind) {
      case NotesBlockKind.heading:
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            block.text,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      case NotesBlockKind.bullet:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 8),
              child: Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Expanded(child: _richText(context, block.text)),
          ],
        );
      case NotesBlockKind.paragraph:
        return _richText(context, block.text);
    }
  }

  /// 段落与列表项支持 `**粗体**`，其余按普通文本。
  Widget _richText(BuildContext context, String text) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium;
    final spans = <TextSpan>[];
    final pattern = RegExp(r'\*\*(.+?)\*\*');
    var index = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > index) {
        spans.add(TextSpan(text: text.substring(index, match.start)));
      }
      spans.add(
        TextSpan(
          text: match.group(1),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      );
      index = match.end;
    }
    if (index < text.length) {
      spans.add(TextSpan(text: text.substring(index)));
    }
    return Text.rich(TextSpan(style: base, children: spans));
  }
}

enum NotesBlockKind { heading, bullet, paragraph }

class NotesBlock {
  const NotesBlock(this.kind, this.text);

  final NotesBlockKind kind;
  final String text;
}

/// 把说明文本切成若干块。空行只用于分隔，不产出块。
List<NotesBlock> parseReleaseNotes(String raw) {
  final blocks = <NotesBlock>[];
  for (final line in raw.split('\n')) {
    final text = line.trimRight();
    if (text.trim().isEmpty) continue;
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('## ')) {
      blocks.add(NotesBlock(NotesBlockKind.heading, trimmed.substring(3).trim()));
      continue;
    }
    if (trimmed.startsWith('# ')) {
      blocks.add(NotesBlock(NotesBlockKind.heading, trimmed.substring(2).trim()));
      continue;
    }
    if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
      blocks.add(NotesBlock(NotesBlockKind.bullet, trimmed.substring(2).trim()));
      continue;
    }
    blocks.add(NotesBlock(NotesBlockKind.paragraph, trimmed));
  }
  return blocks;
}
