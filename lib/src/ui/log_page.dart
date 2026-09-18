import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/log_store.dart';
import '../i18n/app_localizations.dart';

/// 运行日志页。看解析走了哪条通道、为什么回退、下载与合并的细节。
///
/// 内容全部来自 [LogStore]，入库前已经掩码，这里不做二次处理。
class LogPage extends StatelessWidget {
  const LogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = LogStore.instance;
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tr('logs.title')),
        actions: [
          IconButton(
            tooltip: l10n.tr('logs.copyAll'),
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () async {
              final text = store.dump;
              if (text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.tr('logs.empty'))),
                );
                return;
              }
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    l10n.tr('logs.copied', {'count': '${store.entries.length}'}),
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: l10n.tr('logs.clear'),
            icon: const Icon(Icons.delete_outline),
            onPressed: store.clear,
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: store.revision,
        builder: (context, revision, child) {
          final entries = store.entries;
          return Column(
            children: [
              SwitchListTile(
                value: store.verbose,
                secondary: const Icon(Icons.bug_report_outlined),
                title: Text(l10n.tr('logs.verbose')),
                subtitle: Text(
                  store.filePath == null
                      ? l10n.tr('logs.verboseNoFile')
                      : l10n.tr('logs.verboseWithFile', {'path': '${store.filePath}'}),
                  style: const TextStyle(fontSize: 12),
                ),
                onChanged: (value) {
                  store.verbose = value;
                  store.add(
                    l10n.tr('logs.section'),
                    value ? l10n.tr('logs.verboseOn') : l10n.tr('logs.verboseOff'),
                  );
                },
              ),
              const Divider(height: 1),
              Expanded(
                child: entries.isEmpty
                    ? Center(child: Text(l10n.tr('logs.empty')))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        itemCount: entries.length,
                        itemBuilder: (context, index) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: SelectableText(
                            entries[index].line,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
