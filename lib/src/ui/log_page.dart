import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_state.dart';
import '../core/diagnostic.dart';
import '../core/log_store.dart';
import '../i18n/app_localizations.dart';
import 'widgets.dart';

/// 运行日志页。看解析走了哪条通道、为什么回退、下载与合并的细节。
///
/// 内容全部来自 [LogStore]，入库前已经掩码，这里不做二次处理。
class LogPage extends StatefulWidget {
  const LogPage({required this.state, super.key});

  final AppState state;

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  bool _exporting = false;

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// 同名目标定名：同一天导出多次时加 `-2`、`-3`，不覆盖前一份。
  File _uniqueTarget(String dir, String fileName) {
    final base = fileName.replaceAll(RegExp(r'\.zip$'), '');
    var candidate = File('$dir${Platform.pathSeparator}$fileName');
    var n = 1;
    while (candidate.existsSync()) {
      n += 1;
      candidate = File('$dir${Platform.pathSeparator}$base-$n.zip');
    }
    return candidate;
  }

  Future<void> _export() async {
    if (_exporting) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _exporting = true);
    try {
      final info = await PackageInfo.fromPlatform();
      final state = widget.state;
      final store = LogStore.instance;

      final environment = <String, dynamic>{
        'app_version': info.version,
        'package_name': info.packageName,
        'platform': Platform.operatingSystem,
        'locale': state.settings.localeCode,
        'download_dir': state.settings.downloadDir,
        'proxy_configured': state.settings.proxy.trim().isNotEmpty,
        'parts_per_file': state.settings.partsPerFile,
        'max_parallel_tasks': state.settings.maxParallelTasks,
        'ffmpeg_path': state.settings.ffmpegPath,
      };
      final tasks = state.tasks.map((task) => task.toJson()).toList();
      final filePath = store.filePath;
      String? fileText;
      if (filePath != null) {
        final file = File(filePath);
        if (file.existsSync()) {
          fileText = file.readAsStringSync();
        }
      }
      final bytes = buildDiagnosticZip(
        environment: environment,
        tasks: tasks,
        logText: store.dump,
        logFileText: fileText,
      );
      final fileName = suggestDiagnosticFileName(DateTime.now());

      if (Platform.isAndroid) {
        final dir = state.settings.downloadDir.trim();
        if (dir.isEmpty) {
          _toast(l10n.tr('logs.noDownloadDir'));
          return;
        }
        final target = _uniqueTarget(dir, fileName);
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes, flush: true);
        _toast(l10n.tr('logs.exportDone', {'path': target.path}));
        return;
      }

      final target = await FilePicker.saveFile(
        bytes: bytes,
        dialogTitle: l10n.tr('logs.exportDiagnostic'),
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const <String>['zip'],
      );
      if (target == null) return;
      _toast(l10n.tr('logs.exportDone', {'path': target.toFilePath()}));
    } catch (error) {
      _toast(l10n.tr('logs.exportFailed', {'error': '$error'}));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = LogStore.instance;
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tr('logs.title')),
        actions: [
          IconButton(
            tooltip: l10n.tr('logs.exportDiagnostic'),
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.archive_outlined),
            onPressed: _exporting ? null : _export,
          ),
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
              PanelBox(
                radius: 0,
                child: SwitchListTile(
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
              ),
              const Divider(height: 1),
              Expanded(
                child: PanelBox(
                  radius: 8,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: entries.isEmpty
                      ? Center(child: Text(l10n.tr('logs.empty')))
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 2),
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
              ),
            ],
          );
        },
      ),
    );
  }
}
