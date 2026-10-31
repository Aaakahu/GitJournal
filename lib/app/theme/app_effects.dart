/*
 * SPDX-FileCopyrightText: 2026 GitJournal fork contributors
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter/material.dart';

/// 浮动面板使用单层语义阴影，颜色取 `colorScheme.shadow` 而非硬编码黑色，
/// 浅色 12% / 暗色 24%（模式取自 jotsy）。替代 GlassTokens.shade 的双层投影。
class AppEffects {
  const AppEffects._();

  /// 浮层（对话框、底部弹层等 blur 表面）的单层语义阴影。
  static List<BoxShadow> softShadow(ColorScheme colors) => [
        BoxShadow(
          color: colors.shadow.withValues(
            alpha: colors.brightness == Brightness.dark ? 0.24 : 0.12,
          ),
          offset: const Offset(0, 6),
          blurRadius: 18,
          spreadRadius: 0,
        ),
      ];

  /// 静止态卡片（卡片墙、设置分组、GlassCard）的极淡投影。
  ///
  /// 仅亮色模式使用：暗色模式靠表面层级区分，叠加黑色投影只会发脏，
  /// 因此暗色返回 null（不给 shade）。
  static List<BoxShadow>? restingCardShadow(ColorScheme colors) =>
      colors.brightness == Brightness.light
          ? <BoxShadow>[
              BoxShadow(
                color: colors.shadow.withValues(alpha: 0.03),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ]
          : null;
}
