/*
 * SPDX-FileCopyrightText: 2026 GitJournal fork contributors
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/// Expressive 容器圆角；Glass 主题的卡片/弹层/输入全部引用这四值，
/// 不再散落手写数字（模式取自 jotsy，数值适配 Glass 令牌体系）。
class AppRadii {
  const AppRadii._();

  /// 卡片/面板表面（GlassPanel、GlassCard、cardTheme）。
  static const double card = 24;

  /// 导航类表面（抽屉、底部导航）。
  static const double nav = 28;

  /// 弹层（dialogTheme、bottomSheet）。
  static const double dialog = 28;

  /// 控件级（输入框、正文嵌图）。
  static const double input = 16;
}
