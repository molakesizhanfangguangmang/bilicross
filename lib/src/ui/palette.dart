/// 语义色板。
///
/// ⚠️ 为什么要这一层：以前全仓有 **23 个写死的颜色**散在 15 个文件里
/// （`Color(0xff6d716f)` 这种，光次要文字就出现 36 次）。那样一来
/// **主题色只能改一半** —— `ColorScheme` 换了，这些写死的灰不会跟着变，
/// 界面看着像没做完。
///
/// 所以分两类：
/// - **品牌色**：走 `ColorScheme`（由 seed 生成），换主题时跟着变。
/// - **语义色**：就是下面这些。文字层级、面、线、状态色 —— 它们**不该**
///   跟着主题走。用户要是选个红色主题，缺档标记就跟主题撞色了，
///   一眼分不清哪个是警告。
///
/// 命名按「用途」而不是「长相」：叫 `kTextMuted` 不叫 `kGrey600`，
/// 这样以后调整具体色值时不用改调用点。

library;

import 'package:flutter/material.dart';

import '../core/models.dart';

// ---------- 文字层级 ----------

/// 主要文字（正文、标题）。
const Color kTextPrimary = Color(0xff101212);

/// 次要文字（比正文弱一档，仍清晰可读）。
const Color kTextSecondary = Color(0xff4d5250);

/// 说明文字（卡片副标题、提示语）。用得最多。
const Color kTextMuted = Color(0xff6d716f);

/// 再弱一档的说明文字。
const Color kTextSubtle = Color(0xff65716c);

/// 最弱：序号、时长这类辅助信息。
const Color kTextFaint = Color(0xff9aa3a0);

// ---------- 面 ----------

/// 页面底色。
const Color kSurfacePage = Color(0xfff6f7f5);

/// 次级卡片底（比页面底略深）。
const Color kSurfaceCardAlt = Color(0xfff0f2f0);

/// 极浅的填充（输入框内衬等）。
const Color kSurfaceSubtle = Color(0xfff2f4f2);

/// 中性浅底。
const Color kSurfaceNeutral = Color(0xffeeefee);

/// 带一点品牌倾向的浅底。
const Color kSurfaceTint = Color(0xffeef2f0);

// ---------- 线 ----------

/// 常规分隔线与边框。
const Color kBorder = Color(0xffd9dedb);

/// 需要更明显的边框（聚焦、强调）。
const Color kBorderStrong = Color(0xffc9cecc);

// ---------- 品牌（固定值，另有一套跟随主题的） ----------

/// 品牌色浅调。
const Color kBrandSoft = Color(0xff8fb3a4);

/// 品牌色极浅底。
const Color kBrandTint = Color(0xffe6eee9);

// ---------- 状态色（固定，不跟主题走） ----------

/// 警告/缺档：文字与标记。
const Color kWarning = Color(0xffb06a3b);

/// 警告行的底色（很淡的一层）。
const Color kWarningRowTint = Color(0x14b06a3b);

/// 警告浅底（chip 背景）。
const Color kWarningSurface = Color(0xfff4efe2);

/// 警告边框。
const Color kWarningBorder = Color(0xffcbb78a);

/// 提示语文字（比警告轻，比如「地址已失效」这类说明）。
const Color kNoticeText = Color(0xff8a5b4a);

/// 错误/风控：文字与标记。
const Color kDanger = Color(0xffc0392b);

/// 错误浅底。
const Color kDangerSurface = Color(0xfff3e6e4);

/// 错误边框。
const Color kDangerBorder = Color(0xffc9a19c);

// ---------- 主题色 ----------

/// 按 id 取品牌 seed。认不出来（旧配置、手改过的值）就回落到默认。
///
/// 预设表在 `core/models.dart` 的 [kThemeSeeds] —— 那边存的是色值数字，
/// 免得 core 层依赖 Flutter 的界面类型。
Color themeSeedOf(String id) =>
    Color(kThemeSeeds[id] ?? kThemeSeeds[kThemeDefault]!);
