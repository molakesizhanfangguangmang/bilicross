import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../i18n/app_localizations.dart';
import '../core/announcement.dart';
import '../core/background_config.dart';
import '../core/models.dart';
import '../app_state.dart';
import './palette.dart';

/// 「非卡片面」的兜底底色 —— `EmptyState` 占位框、任务页分组头这类
/// **不是卡片**的面。
///
/// ⚠️ 卡片浓度（`cardTheme.color`）只作用于真卡片；这些面在默认态必须保持原样
/// （占位框零填充、分组头用 `kSurfaceTint`），所以默认是 `null`＝「沿用各处原本的
/// 默认外观」。只在「开了背景或卡片 < 100%」时才由 main.dart 塞进一个非空值。
/// ⚠️ 这是**唯一来源**，别再在别处硬编码这些面的底色。
class PanelFill extends ThemeExtension<PanelFill> {
  const PanelFill(
    this.color, {
    this.hasBackground = false,
    this.uiOpacity = kUiMaxOpacity,
  });

  final Color? color;
  final bool hasBackground;
  final double uiOpacity;

  @override
  PanelFill copyWith({
    Color? color,
    bool? hasBackground,
    double? uiOpacity,
  }) =>
      PanelFill(
        color ?? this.color,
        hasBackground: hasBackground ?? this.hasBackground,
        uiOpacity: uiOpacity ?? this.uiOpacity,
      );

  @override
  PanelFill lerp(covariant PanelFill? other, double t) {
    if (other == null) return this;
    return PanelFill(
      Color.lerp(color, other.color, t),
      hasBackground: other.hasBackground,
      uiOpacity: other.uiOpacity,
    );
  }
}

/// 取「非卡片面」的兜底底色；`null` ＝ 保持该处原本的默认外观。
Color? panelColor(BuildContext context) =>
    Theme.of(context).extension<PanelFill>()?.color;

/// 卡片玻璃的全局作用域。
///
/// ⚠️ 卡片是**列表里会滚动**的元素，直接贴 `BackdropFilter` 在滚动期间会变透明
/// （框架对移动中的 backdrop 层复用缓存，2026-10-03 已实验证伪）。所以玻璃一律
/// 采样 [backgroundKey] 指向的**不滚动的背景层**：采样域固定，卡片只是在这块
/// 固定的纹理上滑动开窗，滚动期间不会失效。
///
class CardGlassScope extends StatelessWidget {
  const CardGlassScope({
    required this.mode,
    required this.hasBackground,
    required this.backgroundKey,
    required this.child,
    super.key,
  });

  /// 取值见 `kCardGlassModes`：`off` / `glass`。
  final String mode;

  /// 没有背景图时玻璃背后是纯色，磨出来只是一层灰雾，直接不启用。
  final bool hasBackground;

  /// 背景层的采样 key（由 `main.dart` 建在背景图上）；空＝没法采样。
  final GlobalKey? backgroundKey;

  /// 当前卡片该用的玻璃参数；null ＝ 走普通卡片。
  final Widget child;

  static _CardGlassData? _maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_CardGlassData>();

  @override
  Widget build(BuildContext context) {
    return _CardGlassData(
      mode: mode,
      hasBackground: hasBackground,
      backgroundKey: backgroundKey,
      child: child,
    );
  }
}

class _CardGlassData extends InheritedWidget {
  const _CardGlassData({
    required this.mode,
    required this.hasBackground,
    required this.backgroundKey,
    required super.child,
  });

  final String mode;
  final bool hasBackground;
  final GlobalKey? backgroundKey;

  /// 能不能上玻璃：开着、有背景图、且采样 key 有效。
  bool get active => mode != 'off' && hasBackground && backgroundKey != null;

  @override
  bool updateShouldNotify(_CardGlassData old) =>
      mode != old.mode ||
      hasBackground != old.hasBackground ||
      backgroundKey != old.backgroundKey;
}

/// 卡片 / 面板玻璃的统一参数。
///
/// ⚠️ 目标是「玻璃」而不是「磨砂」：模糊只留一点，主要靠**折射 + 边缘高光**
/// 出材质感。之前把 blur 拉到 12、thickness 拉到 32 是反的 —— 那是往磨砂走，
/// 观感就是「够模糊但不像玻璃」（2026-10-13 用户反馈）。改这里同时影响卡片与面板。
const LiquidGlassSettings kCardGlassSettings = LiquidGlassSettings(
  // 底色压淡（玻璃本体不该是一层白雾），靠折射与高光出质感。
  glassColor: Color(0x1FFFFFFF),
  blur: 4,
  // 厚度 = 折射位移幅度；调大才有「透镜」感。
  thickness: 46,
  // 折射率偏高，让边缘把背景拉出可辨的形变。
  refractiveIndex: 1.42,
  // 边缘高光与菲涅尔是「玻璃」最直观的特征。
  lightIntensity: 1.0,
  fresnelStrength: 1.6,
  specularSharpness: GlassSpecularSharpness.medium,
  ambientStrength: 0.05,
  saturation: 1.35,
  chromaticAberration: 0.03,
  // 边缘吸收给一点，形成玻璃厚边的暗角。
  edgeAbsorption: 0.12,
);

/// 「底栏效果 · 半透」的本体参数（浅色主题）。
///
/// ⚠️ 配方逐项抄自酷安底栏的真实实现（Kyant0/AndroidLiquidGlass 的
/// `LiquidBottomTabs`），不是凭观感猜的：
///
/// ```kotlin
/// effects = { vibrancy(); blur(8dp.toPx()); lens(24dp.toPx(), 24dp.toPx()) }
/// onDrawSurface = { drawRect(containerColor) }   // 浅色 #FAFAFA @40%
/// highlight = { Highlight.Default.copy(alpha = progress) }  // 静止 alpha=0
/// ```
///
/// 四条硬结论（2026-10-14 逐行核对 + 读 shader 后重写）：
///
/// 1. 「半透色」来自那层 **40% 的 #FAFAFA 实底**，不是来自玻璃本身。
///    之前把 glassColor 压到 6~8% 白，所以「太透明又不明显」。
/// 2. 静止态**没有任何高光**（酷安的 highlight alpha 在静止时就是 0），
///    立体感只在按下时随 `pressProgress` 浮现。所以这里的
///    `lightIntensity` / `fresnelStrength` / `ambientRim` / `rimShade`
///    全部归零 —— premium shader 里定向高光写死 `×3.0` 且被
///    `thicknessScale` 放大，压参数没用，只能整条关掉。
/// 3. 本体折射恒定，不随按压变化（酷安那层随按压生长的是**另一个**
///    隐藏图层，不对应本库的 `settingsOnPress`）。
/// 4. ⚠️ **必须用 [GlassLensModel.paraxial]，不能用默认的 spherical。**
///    酷安的 `lens()` 是 `circleMap` 位移：**向外法线取反＝向内、二次曲线、
///    上限就是 refractionAmount**。而默认的球面模型是精确斯涅尔折射：
///    位移 = `baseRefract.xy × (height + thickness×8) / |z|`，边缘处会飙到
///    几十逻辑像素，再被 `maxReach`（半个短边）**截断成一条平台** ——
///    于是整条边缘带都在采样同一片很远处的内容，糊成一片，就是用户说的
///    「浑浊」（2026-10-14 实测反馈：删高光后仍有）。
///    paraxial 的 `-normalXY·|normalXY|·baseHeight·(n-1)` 与 circleMap 同构：
///    同样向内、同样有界、同样是「边缘最强、到内边界归零」。
///
///    **参数换算是死的**（不要凭感觉调）：
///    - 折射带宽度（逻辑像素）= `thickness / 3`
///      （渲染时 `uThickness = thickness × dpr/3`，而 uThickness 就是 SDF
///      法线从边缘衰减到零的距离）
///    - 边缘最大位移（逻辑像素）= `8 × (refractiveIndex - 1) × thickness / 3`
///    酷安是 `lens(24dp, 24dp)`＝带子 24dp、边缘位移 24dp，所以：
///    `thickness = 72`、`refractiveIndex = 1.125` → 两者**同时**等于 24。
///    （2.4.1.9 给的 36 / 1.2 只有 12px 带子，形变全挤在窄带里，所以厚重）
///
/// 指示块不受这里影响（它走 `indicatorSettings`，按压时照旧上浮）。
const LiquidGlassSettings kNavGammaSettingsLight = LiquidGlassSettings(
  // 酷安 `containerColor`（浅色）= #FAFAFA @ 40%；这里给 35% ——
  // 用户要更「轻盈、透光强一点」，压掉一点实底（2026-10-14 反馈）。
  glassColor: Color(0x59FAFAFA),
  // blur(8dp) —— 与酷安逐字相同。
  blur: 8,
  // ⚠️ 见类注释第 4 条：72 / 1.125 是「带子 24dp + 位移 24dp」的解，别乱动。
  thickness: 72,
  refractiveIndex: 1.125,
  // ⚠️ 球面模型会糊一大片，必须用 paraxial（酷安 circleMap 的同构实现）。
  lensModel: GlassLensModel.paraxial,
  // vibrancy() —— 酷安是 1.5 的色矩阵，库内用 saturation 表达。
  saturation: 1.5,
  // 定向高光全关（见上面第 2 条）。
  lightIntensity: 0.0,
  fresnelStrength: 0.0,
  ambientRim: 0.0,
  ambientStrength: 0.0,
  rimShade: 0.0,
  // 酷安那条「不是一整圈」的白色细边：shader 里 rimLight 只画
  // 光轴两端的两个弧（lit³ + 0.85·opp³，各带 exp 衰减），
  // 与酷安 Highlight 的 |cos| 调制同构，且不吃 ×3 的定向放大。
  // ⚠️ 酷安静止时 highlight.alpha = 0（细边只在按下浮现）；这里只留
  // 一半当作常驻的「一点点边缘白」，再多就回到上一版的立体感（2026-10-14 反馈）。
  rimLight: 0.5,
  // 静止态没有阴影（酷安 shadow alpha = progress）。
  shadowElevation: 0.0,
  // 色散只在指示块上开，本体不开。
  chromaticAberration: 0.0,
  edgeAbsorption: 0.0,
);

/// [kNavGammaSettingsLight] 的深色版：酷安深色 `containerColor` = #121212 @ 40%。
const LiquidGlassSettings kNavGammaSettingsDark = LiquidGlassSettings(
  glassColor: Color(0x59121212),
  blur: 8,
  thickness: 72,
  refractiveIndex: 1.125,
  lensModel: GlassLensModel.paraxial,
  saturation: 1.5,
  lightIntensity: 0.0,
  fresnelStrength: 0.0,
  ambientRim: 0.0,
  ambientStrength: 0.0,
  rimShade: 0.0,
  rimLight: 1.0,
  shadowElevation: 0.0,
  chromaticAberration: 0.0,
  edgeAbsorption: 0.0,
);

/// 取当前主题下的「半透」档本体参数。
LiquidGlassSettings navGammaSettingsFor(Brightness brightness) =>
    brightness == Brightness.dark
        ? kNavGammaSettingsDark
        : kNavGammaSettingsLight;

/// 带磨砂能力的普通卡片壳（无标题栏），供「高级设置」「关于」这类入口和
/// [CollapsibleSection] 使用。
///
/// 未开磨砂时等价于普通 [Card]（继承 `cardTheme` 的 elevation 0 + 描边）；
/// 开了磨砂时给半透明底 + 白边 + 阴影 + 背景模糊，与 [SectionCard] 同规格。
class FrostCard extends StatelessWidget {
  const FrostCard({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _CardShell(clip: true, child: child);
  }
}

/// 卡片壳：默认是普通 [Card]；`CardGlassScope` 生效时换成液态玻璃。
///
/// ⚠️ 玻璃层外面仍然套一层 `Card`（透明底 + 细边）—— 里面的 `ListTile` /
/// `SwitchListTile` 需要 `Material` 祖先才能出水波纹，直接换成玻璃容器会出
/// 运行时断言。
class _CardShell extends StatelessWidget {
  const _CardShell({required this.child, this.clip = false});

  final Widget child;
  final bool clip;

  @override
  Widget build(BuildContext context) {
    final glass = CardGlassScope._maybeOf(context);
    final active = glass != null && glass.active;
    if (!active) {
      return Card(
        clipBehavior: clip ? Clip.antiAlias : Clip.none,
        child: child,
      );
    }
    // ⚠️ 用 `LightweightLiquidGlass` 而非 `GlassContainer`：只有前者能显式
    // 指定 `backgroundKey`，把采样域钉在**不滚动**的背景层上（2026-10-03 实验结论）。
    final inner = Card(
      elevation: 0,
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: kBorder),
      ),
      child: child,
    );
    return LightweightLiquidGlass(
      backgroundKey: glass.backgroundKey,
      shape: const LiquidRoundedRectangle(borderRadius: 8),
      settings: kCardGlassSettings,
      child: inner,
    );
  }
}

/// 给「非卡片面」（下载页地址行、任务页顶部固定条）套一层兜底底色，圆角与卡片一致。
///
/// ⚠️ `panelColor` 为 `null`（默认态）时**只留内边距、不加底色** —— 几何与旧版逐像素
/// 一致，零回归。要在别处给非卡片面上底，一律走这里，别再各写各的。
/// ⚠️ `radius` 默认 8（浮在页面里的面板）；贴着 AppBar 的通栏（任务页顶部固定条）
/// 传 0 —— 上边贴边还带圆角会像被裁掉的卡片。
class PanelBox extends StatelessWidget {
  const PanelBox({
    required this.child,
    this.padding,
    this.radius = 8,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final glass = CardGlassScope._maybeOf(context);

    // ⚠️ 玻璃优先：必须先判玻璃、再管底色。反过来的话，开了背景之后
    // `panelColor` 非空，会直接掉进下面那条普通 `Container` 分支，
    // 「非卡片面」永远上不了玻璃（2026-10-13 用户反馈下载/任务页不生效）。
    if (glass != null && glass.active) {
      return LightweightLiquidGlass(
        backgroundKey: glass.backgroundKey,
        shape: LiquidRoundedRectangle(borderRadius: radius),
        settings: kCardGlassSettings,
        child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
      );
    }

    final color = panelColor(context);
    // 默认态（无底色）保持 decoration 为 null，几何与旧版逐像素一致。
    if (color == null) {
      return Container(padding: padding, child: child);
    }
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: child,
    );
  }
}

/// 手机端的宽度断点：窄于这个宽度按手机布局处理。
///
/// ⚠️ 有些改动**只在手机端生效**（用户 2026-09-20 明确要求）—— 桌面窗口宽，
/// 标题大一号、按钮铺开都不占地方，没必要跟着一起缩。
const double kCompactWidth = 600;

bool isCompactLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width < kCompactWidth;

/// 页面标题样式。手机端降一号：默认的 24px 在手机上太占地方。
TextStyle pageTitleStyle(BuildContext context) {
  final base =
      Theme.of(context).textTheme.headlineSmall ?? const TextStyle(fontSize: 24);
  if (!isCompactLayout(context)) return base;
  return base.copyWith(fontSize: 20);
}

/// 手机端的紧凑按钮样式：矮一点、字小一点，一行能多放几个。
ButtonStyle compactActionStyle() => OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: const TextStyle(fontSize: 12),
    );

/// 页面外壳：内容居中、宽度封顶 980，自带滚动。
///
/// ⚠️ **不再渲染页面标题** —— 标题统一由顶部 AppBar 显示（见 main.dart）。
/// 以前这里是「AppBar 显示应用名 + 内容区再显示一次页名」，手机上等于
/// 两条标题栏叠着，白占一整行的高度。
class PageFrame extends StatelessWidget {
  const PageFrame({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: child,
        ),
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.title,
    required this.child,
    this.trailing,
    super.key,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title, style: Theme.of(context).textTheme.titleMedium),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
    return _CardShell(child: content);
  }
}

/// 可折叠的设置分组：组头一行（标题 + 当前值摘要 + 展开箭头），点一下开合。
///
/// ⚠️ 展开状态由调用方持有 —— 不要写进设置对象，否则点一下展开就会被
/// 当成「有未保存的改动」。
class CollapsibleSection extends StatelessWidget {
  const CollapsibleSection({
    required this.title,
    required this.summary,
    required this.expanded,
    required this.onToggle,
    required this.child,
    super.key,
  });

  final String title;

  /// 收起时也看得见的当前值，排在标题右侧。
  final String summary;

  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FrostCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 12, color: kTextMuted),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: kTextSubtle,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: child,
            ),
        ],
      ),
    );
  }
}

class InfoLine extends StatelessWidget {
  const InfoLine({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: const TextStyle(color: kTextMuted)),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;

  /// [glass] 为真时不要画不透明底色 —— 那会把外面那层玻璃整个盖住，
  /// 看起来就跟没开一样（2026-10-13 修：任务页「暂无任务」/ 下载页
  /// 「等待解析」就是被这层底色挡住的）。
  Widget _buildContent(BuildContext context, {bool glass = false}) {
    return Container(
      constraints: const BoxConstraints(minHeight: 240),
      decoration: BoxDecoration(
        color: glass ? null : panelColor(context),
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 42, color: kTextSubtle),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 空状态也是「看起来像卡片」的面（下载页「等待解析」、任务页「暂无任务」），
    // 跟着开关一起上玻璃，否则那两页像是没生效。
    final glass = CardGlassScope._maybeOf(context);
    if (glass != null && glass.active) {
      return LightweightLiquidGlass(
        backgroundKey: glass.backgroundKey,
        shape: const LiquidRoundedRectangle(borderRadius: 8),
        settings: kCardGlassSettings,
        child: _buildContent(context, glass: true),
      );
    }
    return _buildContent(context);
  }
}

/// 单选行。不使用 Radio/RadioListTile：其 groupValue/onChanged 在新版 Flutter 已废弃，
/// 而 CI 的 analyze 会把弃用提示当作问题。
/// 公告里的一张图。
///
/// ⚠️ 公告是**单向下发**的内容，图挂了一张不该在弹窗里留个红叉或撑出一片空白 ——
/// 加载失败就整块收起。加载完成（或失败）时回调一次 [onSettled]，公告弹窗靠它
/// 重算「正文到底要不要滑到底」（图片晚于正文到位，会改变可滚高度）。
class AnnouncementImage extends StatefulWidget {
  const AnnouncementImage({
    required this.path,
    this.maxHeight = 220,
    this.radius = 8,
    this.onSettled,
    super.key,
  });

  final String path;
  final double maxHeight;
  final double radius;
  final VoidCallback? onSettled;

  @override
  State<AnnouncementImage> createState() => _AnnouncementImageState();
}

class _AnnouncementImageState extends State<AnnouncementImage> {
  bool _settled = false;

  void _settle() {
    if (_settled) return;
    _settled = true;
    final callback = widget.onSettled;
    if (callback != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => callback());
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = announcementMediaUrl(widget.path);
    if (url.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: Image.network(
          url,
          width: double.infinity,
          fit: BoxFit.contain,
          loadingBuilder: (context, child, progress) {
            if (progress == null) {
              _settle();
              return child;
            }
            return const SizedBox(
              height: 120,
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          },
          errorBuilder: (context, error, stackTrace) {
            _settle();
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }
}

class ChoiceTile extends StatelessWidget {
  const ChoiceTile({
    required this.selected,
    required this.title,
    required this.onTap,
    this.image = '',
    super.key,
  });

  final bool selected;
  final String title;

  /// 选项配图（相对路径，空串＝纯文字）。放在文字上方。
  final String image;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (image.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 28, bottom: 8),
                child: AnnouncementImage(path: image, maxHeight: 160),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected ? Theme.of(context).colorScheme.primary : kTextFaint,
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: const TextStyle(fontSize: 13))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class StateChip extends StatelessWidget {
  const StateChip({required this.text, this.tone = 0, super.key});

  /// 0 中性，1 正常，2 警示，3 失败。
  final String text;
  final int tone;

  @override
  Widget build(BuildContext context) {
    final (background, border) = switch (tone) {
      1 => (kBrandTint, kBrandSoft),
      2 => (kWarningSurface, kWarningBorder),
      3 => (kDangerSurface, kDangerBorder),
      _ => (kSurfaceNeutral, kBorderStrong),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(text, style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}

class TaskCard extends StatelessWidget {
  const TaskCard({required this.state, required this.task, super.key});

  final AppState state;
  final DownloadTask task;

  /// 分片都还在时允许单独重跑合并。判断走 [AppState.canRetryMerge]（缓存过的），
  /// 这里在 build 路径上，不能同步 stat。
  bool get _canMerge => state.canRetryMerge(task);

  int get _tone => switch (task.stage) {
        TaskStage.done => 1,
        TaskStage.failed => 3,
        TaskStage.stopped => 3,
        TaskStage.pending => 2,
        TaskStage.paused => 2,
        _ => 0,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final running = task.stage == TaskStage.downloading || task.stage == TaskStage.muxing;
    return SectionCard(
      title: task.title,
      trailing: StateChip(text: task.stage.label(l10n), tone: _tone),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (running || task.progress > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(
                minHeight: 3,
                value: task.stage == TaskStage.muxing ? null : task.progress,
              ),
            ),
          InfoLine(
            label: l10n.tr('tasks.progress'),
            value: '${formatBytes(task.receivedBytes)}'
                '${task.totalBytes > 0 ? ' / ${formatBytes(task.totalBytes)}' : ''}',
          ),
          InfoLine(
            label: l10n.tr('tasks.channel'),
            value: task.channel.isEmpty ? l10n.tr('tasks.notRecorded') : task.channel,
          ),
          InfoLine(
            label: l10n.tr('download.part'),
            value: task.page > 1
                ? l10n.tr('tasks.pagePart', {'page': '${task.page}', 'cid': '${task.cid}'})
                : l10n.tr('tasks.cidOnly', {'cid': '${task.cid}'}),
          ),
          if (task.message.isNotEmpty)
            InfoLine(label: l10n.tr('tasks.status'), value: task.message),
          InfoLine(label: l10n.tr('tasks.output'), value: task.outputPath),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              // 下载中可以暂停（分片留着，继续时按断点接）；合并中没有暂停点，只有强制结束。
              if (task.stage == TaskStage.downloading)
                OutlinedButton(
                  onPressed: () => state.pauseTask(task.id),
                  child: Text(l10n.tr('tasks.pause')),
                ),
              if (running)
                OutlinedButton(
                  onPressed: () => _stop(context, state, task),
                  child: Text(l10n.tr('tasks.forceStop')),
                ),
              if (task.stage == TaskStage.paused)
                OutlinedButton(
                  onPressed: () => state.resumeTask(task.id),
                  child: Text(l10n.tr('tasks.resume')),
                ),
              // 等待中的任务：「开始」只下这一条，不动等待栏里其他待下的。
              // 其余状态仍是「重试」—— 同一按钮位按状态换名，不让两个按钮做同一件事。
              if (task.stage == TaskStage.pending)
                FilledButton.icon(
                  onPressed:
                      state.queueRunning ? null : () => state.startTask(task.id),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(l10n.tr('tasks.start')),
                )
              else
                OutlinedButton(
                  onPressed: running ? null : () => state.retryTask(task.id),
                  child: Text(l10n.tr('tasks.retry')),
                ),
              // running 时短路：分片还在写，判断既无意义又正撞上通知最密的时段。
              if (!running && !task.merged && _canMerge)
                OutlinedButton(
                  onPressed: running ? null : () => state.retryMerge(task.id),
                  child: Text(l10n.tr('tasks.retryMux')),
                ),
              if (task.stage == TaskStage.failed ||
                  task.stage == TaskStage.stopped ||
                  task.stage == TaskStage.paused ||
                  (task.stage == TaskStage.done && !task.merged && !task.singleTrack))
                OutlinedButton(
                  onPressed: running ? null : () => _cleanup(context, state, task),
                  child: Text(l10n.tr('tasks.cleanup')),
                ),
              OutlinedButton(
                onPressed: running ? null : () => state.removeTask(task.id),
                child: Text(l10n.tr('common.remove')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 强制结束会连分片一起删掉，删了就续不回来，所以先确认一次。
  Future<void> _stop(
    BuildContext context,
    AppState state,
    DownloadTask task,
  ) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.tr('tasks.forceStop')),
        content: Text(
          '${l10n.tr('tasks.forceStopConfirm', {'title': task.title})}'
          '${l10n.tr('tasks.forceStopWarning')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.tr('common.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.tr('tasks.forceStop')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    state.stopTask(task.id);
  }

  /// 删掉这个任务留下的成品与分片，并把任务从列表里去掉。
  Future<void> _cleanup(
    BuildContext context,
    AppState state,
    DownloadTask task,
  ) async {
    final l10n = AppLocalizations.of(context);
    final removed = await state.cleanupTask(task.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          removed > 0
              ? l10n.tr('tasks.cleanedFiles', {'count': '$removed'})
              : l10n.tr('tasks.nothingToClean'),
        ),
      ),
    );
  }
}
