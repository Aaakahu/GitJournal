/*
 * SPDX-FileCopyrightText: 2026 GitJournal fork contributors
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter/material.dart';

import '../../themes/glass_theme.dart';
import 'app_radii.dart';

/// 页面底/卡片色/边框的统一函数（模式取自 jotsy 的 expressive_surfaces.dart，
/// 入参适配 Glass 令牌体系：只依赖 [GlassTokens] 与亮度，浅暗两套不分叉）。
abstract final class ExpressiveSurfaces {
  /// 页面画布底色：Glass 的 base（浅色由 GlassBackground 叠加氛围光）。
  static Color pageBackground(GlassTokens tokens) => tokens.base;

  /// 卡片表面底色：
  /// - 亮色模式纯白化，消除半透明白叠暖白底带来的发灰；
  /// - 暗色模式卡片色叠在 base 上，形成表面分层。
  static Color cardColor(Brightness brightness, GlassTokens tokens) =>
      brightness == Brightness.light
          ? Colors.white
          : Color.alphaBlend(tokens.card, tokens.base);

  /// 卡片边框颜色：Glass 的 hairline edge 本身就是低透明（浅 .13 / 暗 .11）。
  static Color cardBorderColor(GlassTokens tokens) => tokens.edge;

  /// 卡片统一微边框：0.8px，明暗主题下都显轻盈。
  static BorderSide cardBorderSide(GlassTokens tokens) =>
      BorderSide(color: cardBorderColor(tokens), width: 0.8);

  /// 卡片统一样式（圆角 [AppRadii.card] + 微边框）。
  static OutlinedBorder cardShape(GlassTokens tokens) => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.card),
        side: cardBorderSide(tokens),
      );
}
