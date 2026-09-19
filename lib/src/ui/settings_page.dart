import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../i18n/app_localizations.dart';
import 'advanced_page.dart';
import 'backup_card.dart';
import 'expand_page_route.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.state, super.key});

  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 高级设置入口卡片的 key：展开动画要以它的屏幕位置为起点。
  final GlobalKey _advancedKey = GlobalKey();

  /// 长按「高级设置」解锁动画调节。
  ///
  /// 解锁是**单向**的：这里只置位、不提供关回去的入口。
  Future<void> _saveSettings(VoidCallback change) async {
    change();
    await widget.state.saveSettings();
  }

  Future<void> _unlockAnimTuning(AppSettings settings) async {
    if (settings.animTuningUnlocked) return;
    settings.animTuningUnlocked = true;
    await widget.state.saveSettings();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).tr('settings.animUnlocked')),
      ),
    );
  }

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
    final l10n = AppLocalizations.of(context);
    final windows = Theme.of(context).platform == TargetPlatform.windows;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final settings = state.settings;
        return PageFrame(
          title: l10n.tr('settings.title'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionCard(
                title: l10n.tr('settings.download'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _dir,
                      decoration: InputDecoration(
                        labelText: l10n.tr('settings.downloadDir'),
                        prefixIcon: const Icon(Icons.folder_outlined),
                        suffixIcon: IconButton(
                          tooltip: l10n.tr('settings.chooseDir'),
                          onPressed: _pickDirectory,
                          icon: const Icon(Icons.folder_open),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: settings.preferredQuality,
                      decoration: InputDecoration(
                        labelText: l10n.tr('settings.quality'),
                        prefixIcon: const Icon(Icons.high_quality_outlined),
                      ),
                      items: [
                        for (final entry in _choices(
                          const [129, 127, 126, 125, 120, 116, 112, 80, 74, 64, 32, 16],
                          settings.preferredQuality,
                          byQuality: true,
                        ))
                          DropdownMenuItem(
                            value: entry,
                            child: Text('${qualityLabel(entry, l10n)}（$entry）'),
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
                      decoration: InputDecoration(
                        labelText: l10n.tr('settings.audio'),
                        prefixIcon: const Icon(Icons.graphic_eq),
                      ),
                      items: [
                        for (final entry in _choices(
                          const [30280, 30232, 30216, 30251, 30250],
                          settings.preferredAudio,
                        ))
                          DropdownMenuItem(
                            value: entry,
                            child: Text('${audioLabel(entry, l10n)}（$entry）'),
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
                        SizedBox(width: 96, child: Text(l10n.tr('settings.parallelTasks'))),
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
                        SizedBox(width: 96, child: Text(l10n.tr('settings.partsPerFile'))),
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
                    Text(
                      l10n.tr('settings.partsHint'),
                      style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings.preferAppApi,
                      onChanged: (value) {
                        settings.preferAppApi = value;
                        setState(() {});
                      },
                      title: Text(l10n.tr('settings.preferApp')),
                      subtitle: Text(l10n.tr('settings.preferAppHint')),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings.useAppGrpc,
                      onChanged: (value) {
                        settings.useAppGrpc = value;
                        setState(() {});
                      },
                      title: Text(l10n.tr('settings.grpcHdr')),
                      subtitle: Text(l10n.tr('settings.grpcHint')),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: l10n.tr('settings.mux'),
                trailing: StateChip(
                  text: state.ffmpegPath == null
                      ? l10n.tr('settings.builtinMux')
                      : l10n.tr('settings.ffmpegReady'),
                  tone: 1,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _ffmpeg,
                      decoration: InputDecoration(
                        labelText: l10n.tr('settings.ffmpegPath'),
                        hintText: l10n.tr('settings.ffmpegPathHint'),
                        prefixIcon: const Icon(Icons.movie_filter_outlined),
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
                        child: Text(l10n.tr('settings.detectFfmpeg')),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings.preferFfmpegMux,
                      onChanged: (value) {
                        settings.preferFfmpegMux = value;
                        setState(() {});
                      },
                      title: Text(l10n.tr('settings.preferFfmpeg')),
                      subtitle: Text(l10n.tr('settings.preferFfmpegHint')),
                    ),
                    Text(
                      l10n.tr('settings.muxExplain'),
                      style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: l10n.tr('settings.network'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _proxy,
                      decoration: InputDecoration(
                        labelText: l10n.tr('settings.proxy'),
                        hintText: 'http://host:port',
                        prefixIcon: const Icon(Icons.lan_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _userAgent,
                      maxLines: 2,
                      decoration: InputDecoration(
                        labelText: 'User-Agent',
                        hintText: l10n.tr('settings.uaHint'),
                        helperText: l10n.tr('settings.uaHelper'),
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
                    Text(
                      l10n.tr('settings.appKeyHint'),
                      style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: l10n.tr('settings.engine'),
                trailing: StateChip(text: l10n.tr('settings.engineDart')),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(l10n.tr('settings.engineDartDesc')),
                    const SizedBox(height: 6),
                    Text(
                      windows
                          ? l10n.tr('settings.engineFuture')
                          : l10n.tr('settings.engineOnlyDart'),
                      style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(l10n.tr('settings.save')),
                ),
              ),
              const SizedBox(height: 24),
              // 备份与恢复只给 Windows 的安装版与便携版用：两边数据目录不同，
              // 靠备份互相迁移；安卓侧不显示这个入口，界面保持原样。
              if (windows) ...[
                BackupCard(state: state),
                const SizedBox(height: 12),
                // 关闭行为：默认最小化到托盘，任务继续跑；选「退出」才真退。
                SectionCard(
                  title: l10n.tr('settings.closeBehavior'),
                  child: DropdownButtonFormField<bool>(
                    initialValue: settings.closeToTray,
                    decoration: InputDecoration(
                      labelText: l10n.tr('settings.closeBehavior'),
                      prefixIcon: const Icon(Icons.exit_to_app_outlined),
                    ),
                    items: [
                      DropdownMenuItem<bool>(
                        value: true,
                        child: Text(l10n.tr('settings.closeToTray')),
                      ),
                      DropdownMenuItem<bool>(
                        value: false,
                        child: Text(l10n.tr('settings.closeToExit')),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      settings.closeToTray = value;
                      setState(() {});
                    },
                  ),
                ),
                const SizedBox(height: 24),
              ],
              // 高级设置收进独立页面：启动画面、详细日志、关于都是低频项，
              // 放在主页会把常用设置挤下去。语言留在主页，新用户要能一眼找到。
              Card(
                key: _advancedKey,
                child: ListTile(
                  leading: const Icon(Icons.tune),
                  title: Text(l10n.tr('settings.advanced')),
                  subtitle: Text(
                    l10n.tr('settings.advancedHint'),
                    style: const TextStyle(fontSize: 12, color: Color(0xff6d716f)),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  // 长按解锁动画调节。解锁后不再提供关回去的入口。
                  onLongPress: state.settings.animTuningUnlocked
                      ? null
                      : () => _unlockAnimTuning(state.settings),
                  onTap: () {
                    // 从这个卡片的位置展开到整页：先把矩形算出来再推路由。
                    Navigator.of(context).push(
                      ExpandPageRoute<void>(
                        sourceRect: globalRectOf(_advancedKey.currentContext!),
                        duration: Duration(
                          milliseconds: state.settings.animDurationMs,
                        ),
                        // 曲线与展开形式跟随设置，两端一致。
                        curveName: state.settings.animCurve,
                        style: state.settings.animStyle,
                        builder: (context) =>
                            AdvancedSettingsPage(state: state),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              // 预检的并发策略：默认严格串行加间隔，稳；要快可开并行。
              SectionCard(
                title: l10n.tr('settings.parallelPreflight'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      l10n.tr('settings.parallelPreflightHint'),
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xff6d716f)),
                    ),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: settings.parallelPreflight,
                      title: Text(l10n.tr('settings.parallelPreflight')),
                      onChanged: (value) => _saveSettings(
                        () => widget.state.settings.parallelPreflight = value,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // 同名文件处理：批量下载几乎必然撞名，这里定撞名时的行为。
              // 即选即落盘，不等「保存设置」。
              SectionCard(
                title: l10n.tr('settings.duplicate'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(l10n.tr('settings.duplicateHint'),
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xff6d716f))),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: <Widget>[
                        for (final mode in kDuplicateModes)
                          ChoiceChip(
                            label: Text(
                              l10n.tr('settings.duplicate.$mode'),
                            ),
                            selected: settings.duplicateMode == mode,
                            onSelected: (_) => _saveSettings(
                              () => widget.state.settings.duplicateMode = mode,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // 语言切换是即选即生效：改完直接落盘并重建界面，不等「保存设置」。
              SectionCard(
                title: l10n.tr('settings.language'),
                child: DropdownButtonFormField<String>(
                  initialValue: settings.localeCode,
                  decoration: InputDecoration(
                    labelText: l10n.tr('settings.language'),
                    prefixIcon: const Icon(Icons.translate),
                  ),
                  items: [
                    for (final code in kLocaleCodes)
                      DropdownMenuItem(
                        value: code,
                        child: Text(_localeName(l10n, code)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    state.setLocale(value);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 「跟随系统」跟当前界面走；语言名本身永远用各自的母语显示，
  /// 这是各平台语言选择器的通行做法，方便用户认出自己的语言。
  String _localeName(AppLocalizations l10n, String code) => switch (code) {
        kLocaleSystem => l10n.tr('settings.languageSystem'),
        kLocaleZhCN => l10n.tr('settings.languageZh'),
        kLocaleEnUS => l10n.tr('settings.languageEn'),
        _ => code,
      };

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
      SnackBar(content: Text(AppLocalizations.of(context).tr('settings.saved'))),
    );
  }
}
