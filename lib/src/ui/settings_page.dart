import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/log_store.dart';
import '../core/models.dart';
import 'log_page.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.state, super.key});

  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _dir =
      TextEditingController(text: widget.state.settings.downloadDir);
  late final TextEditingController _ffmpeg =
      TextEditingController(text: widget.state.settings.ffmpegPath);
  late final TextEditingController _proxy =
      TextEditingController(text: widget.state.settings.proxy);
  late final TextEditingController _userAgent =
      TextEditingController(text: widget.state.settings.userAgent);
  late final TextEditingController _appKey =
      TextEditingController(text: widget.state.settings.appKey);
  late final TextEditingController _appSec =
      TextEditingController(text: widget.state.settings.appSec);

  @override
  void dispose() {
    _dir.dispose();
    _ffmpeg.dispose();
    _proxy.dispose();
    _userAgent.dispose();
    _appKey.dispose();
    _appSec.dispose();
    super.dispose();
  }

  /// 下拉项固定一组预设，但存盘里可能是旧值或手工改过的值。
  /// 当前值不在预设里就补进列表，否则 DropdownButton 取不到匹配项会断言失败。
  List<int> _choices(List<int> presets, int current, {bool byQuality = false}) {
    if (presets.contains(current)) return presets;
    final merged = <int>[...presets, current];
    if (byQuality) {
      merged.sort((left, right) => qualityRank(left).compareTo(qualityRank(right)));
    }
    return merged;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final windows = Theme.of(context).platform == TargetPlatform.windows;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final settings = state.settings;
        return PageFrame(
          title: '设置',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionCard(
                title: '下载',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _dir,
                      decoration: InputDecoration(
                        labelText: '下载目录',
                        prefixIcon: const Icon(Icons.folder_outlined),
                        suffixIcon: IconButton(
                          tooltip: '选择目录',
                          onPressed: _pickDirectory,
                          icon: const Icon(Icons.folder_open),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: settings.preferredQuality,
                      decoration: const InputDecoration(
                        labelText: '默认画质',
                        prefixIcon: Icon(Icons.high_quality_outlined),
                      ),
                      items: [
                        for (final entry in _choices(
                          const [129, 127, 126, 125, 120, 116, 112, 80, 74, 64, 32, 16],
                          settings.preferredQuality,
                          byQuality: true,
                        ))
                          DropdownMenuItem(
                            value: entry,
                            child: Text('${qualityLabel(entry)}（$entry）'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        settings.preferredQuality = value;
                        setState(() {});
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: settings.preferredAudio,
                      decoration: const InputDecoration(
                        labelText: '默认音质',
                        prefixIcon: Icon(Icons.graphic_eq),
                      ),
                      items: [
                        for (final entry in _choices(
                          const [30280, 30232, 30216, 30251, 30250],
                          settings.preferredAudio,
                        ))
                          DropdownMenuItem(
                            value: entry,
                            child: Text('${audioLabel(entry)}（$entry）'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        settings.preferredAudio = value;
                        setState(() {});
                      },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const SizedBox(width: 96, child: Text('并发任务')),
                        Expanded(
                          child: Slider(
                            value: settings.maxParallelTasks.toDouble().clamp(1, 4),
                            min: 1,
                            max: 4,
                            divisions: 3,
                            label: '${settings.maxParallelTasks}',
                            onChanged: (value) {
                              settings.maxParallelTasks = value.round();
                              setState(() {});
                            },
                          ),
                        ),
                        Text('${settings.maxParallelTasks}'),
                      ],
                    ),
                    Row(
                      children: [
                        const SizedBox(width: 96, child: Text('单文件连接')),
                        Expanded(
                          child: Slider(
                            value: settings.partsPerFile.toDouble().clamp(1, 8),
                            min: 1,
                            max: 8,
                            divisions: 7,
                            label: '${settings.partsPerFile}',
                            onChanged: (value) {
                              settings.partsPerFile = value.round();
                              setState(() {});
                            },
                          ),
                        ),
                        Text('${settings.partsPerFile}'),
                      ],
                    ),
                    const Text(
                      '同一个文件切成几段并行下载，1 表示单连接。服务端不支持分段或文件较小时会自动退回单连接。',
                      style: TextStyle(fontSize: 12, color: Color(0xff6d716f)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings.preferAppApi,
                      onChanged: (value) {
                        settings.preferAppApi = value;
                        setState(() {});
                      },
                      title: const Text('优先使用 APP 通道解析'),
                      subtitle: const Text('需要有 APP Token；失败会自动回退网页通道'),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings.useAppGrpc,
                      onChanged: (value) {
                        settings.useAppGrpc = value;
                        setState(() {});
                      },
                      title: const Text('补取 HDR Vivid 档位（gRPC）'),
                      subtitle: const Text(
                        '解析成功后再请求一次 gRPC PlayView，补上 129 档（HDR Vivid），'
                        '需要 APP Token；失败只记日志，不影响原有结果',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: '混流',
                trailing: StateChip(
                  text: state.ffmpegPath == null ? '内置合并' : 'ffmpeg 就绪',
                  tone: 1,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _ffmpeg,
                      decoration: const InputDecoration(
                        labelText: 'ffmpeg 可执行文件路径',
                        hintText: '留空则在系统 PATH 中查找',
                        prefixIcon: Icon(Icons.movie_filter_outlined),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        onPressed: () async {
                          widget.state.settings.ffmpegPath = _ffmpeg.text.trim();
                          await widget.state.refreshFfmpeg();
                        },
                        child: const Text('检测 ffmpeg'),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings.preferFfmpegMux,
                      onChanged: (value) {
                        settings.preferFfmpegMux = value;
                        setState(() {});
                      },
                      title: const Text('优先使用 ffmpeg 合并'),
                      subtitle: const Text('关闭则始终用内置分片合并；无论开关，另一条路都会兜底'),
                    ),
                    const Text(
                      '合并只做流复制，不转码。没有 ffmpeg 时用内置合并：按 moof/mdat 把两条流'
                      '交替写成 MP4，采样数据原样搬运。两条路都失败才会保留分片并写进任务消息，'
                      '之后可以在任务页单独重试合并。',
                      style: TextStyle(fontSize: 12, color: Color(0xff6d716f)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: '网络与高级',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _proxy,
                      decoration: const InputDecoration(
                        labelText: '代理',
                        hintText: 'http://host:port，留空为直连',
                        prefixIcon: Icon(Icons.lan_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _userAgent,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'User-Agent',
                        hintText: '留空使用内置短串 Mozilla/5.0',
                        helperText: '桌面长串在移动端下载地址上会被 CDN 拒；不确定就留空',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _appKey,
                      decoration: const InputDecoration(labelText: 'AppKey'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _appSec,
                      decoration: const InputDecoration(labelText: 'AppSec'),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'AppKey/AppSec 会随客户端分发，无法真正保密；只用于申请 APP 授权码。',
                      style: TextStyle(fontSize: 12, color: Color(0xff6d716f)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: '解析引擎',
                trailing: const StateChip(text: 'Dart 内置'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('当前所有任务由 Dart 内置引擎执行。'),
                    const SizedBox(height: 6),
                    Text(
                      windows
                          ? 'BBDownNext 兼容引擎（随包附带、本地 serve 模式）尚未接入，接入后可按任务切换。'
                          : '该平台只提供 Dart 内置引擎。',
                      style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: '诊断',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('运行日志'),
                  subtitle: Text(
                    LogStore.instance.filePath == null
                        ? '解析走了哪条通道、为什么回退、下载与合并的细节'
                        : '记录文件：${LogStore.instance.filePath}',
                    style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (context) => const LogPage()),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存设置'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickDirectory() async {
    final path = await FilePicker.getDirectoryPath();
    if (path == null || path.isEmpty) return;
    _dir.text = path;
    setState(() {});
  }

  Future<void> _save() async {
    final settings = widget.state.settings;
    settings.downloadDir = _dir.text.trim();
    settings.ffmpegPath = _ffmpeg.text.trim();
    settings.proxy = _proxy.text.trim();
    settings.userAgent = _userAgent.text.trim();
    settings.appKey = _appKey.text.trim();
    settings.appSec = _appSec.text.trim();
    await widget.state.saveSettings();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设置已保存')),
    );
  }
}
