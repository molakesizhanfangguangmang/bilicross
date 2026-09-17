import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/log_store.dart';

/// 运行日志页。看解析走了哪条通道、为什么回退、下载与合并的细节。
///
/// 内容全部来自 [LogStore]，入库前已经掩码，这里不做二次处理。
class LogPage extends StatelessWidget {
  const LogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = LogStore.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: [
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () async {
              final text = store.dump;
              if (text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('暂无日志')),
                );
                return;
              }
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已复制 ${store.entries.length} 条')),
              );
            },
          ),
          IconButton(
            tooltip: '清空',
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
                title: const Text('详细日志'),
                subtitle: Text(
                  store.filePath == null
                      ? '打开后记录请求地址与响应码；这台设备写不了日志文件，只留在内存'
                      : '打开后记录请求地址与响应码，并追加到 ${store.filePath}',
                  style: const TextStyle(fontSize: 12),
                ),
                onChanged: (value) {
                  store.verbose = value;
                  store.add(
                    '日志',
                    value ? '已打开详细日志（凭据一律掩码）' : '已关闭详细日志',
                  );
                },
              ),
              const Divider(height: 1),
              Expanded(
                child: entries.isEmpty
                    ? const Center(child: Text('暂无日志'))
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
