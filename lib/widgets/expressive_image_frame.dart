/*
 * SPDX-FileCopyrightText: 2026 GitJournal fork contributors
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter/widgets.dart';

import '../app/theme/expressive_motion.dart';

/// `Image.frameBuilder` 的统一实现：首次解码出画面时淡入（180ms），
/// 缓存命中时直接显示（模式取自 jotsy 的 expressive_image_frame.dart）。
///
/// 卡片墙封面、编辑器嵌图原先解码完成的那一帧会“啪”地冒出来，滚动到
/// 新卡片时尤其明显。规则收敛在一处，所有图片入口共用，避免时长/曲线漂移。
///
/// - [wasSynchronouslyLoaded] 为 true（ImageCache 命中）时不套任何动画层，
///   滚回已经显示过的卡片不会再闪一次；
/// - 时长经 [ExpressiveMotion.duration] 解析，系统开启“减少动态效果”时直接显示；
/// - 淡入结束后不透明度恒为 1，[AnimatedOpacity] 不再产生离屏合成层。
Widget expressiveImageFrameBuilder(
  BuildContext context,
  Widget child,
  int? frame,
  bool wasSynchronouslyLoaded,
) {
  if (wasSynchronouslyLoaded) {
    return child;
  }
  return AnimatedOpacity(
    opacity: frame == null ? 0 : 1,
    duration: ExpressiveMotion.duration(context, ExpressiveMotion.fast),
    curve: ExpressiveMotion.effects,
    child: child,
  );
}
