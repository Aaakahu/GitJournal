/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:gitjournal/app/theme/expressive_motion.dart';

/// 全屏图片查看的手势包，升级原 PhotoView 全屏页：
///
///  - 双击缩放：以点按位置为不动点，[Matrix4Tween] 补间到 2.5x；再次双击复原；
///  - 捏合/平移：手指一落就立即停掉进行中的补间（手指优先级最高）；
///  - 下拉关闭：内容随手指下移并按距离线性缩到 0.82、背景同步淡出（直接映射，
///    不补间）；越过视口高度 15% 或快速甩动（velocity > 800 px/s）即关闭，
///    否则用 [ExpressiveMotion.spatial] 弹簧回位。
///
/// 手势状态是一个纯 translate+scale 的 [Matrix4]；所有补间都在 Matrix4 域内
/// 进行，手势开始时从补间终点接管，补间结束时写回状态，保证不跳变。
class InteractiveImageView extends StatefulWidget {
  final Widget child;
  final Color backgroundColor;
  final double maxScale;
  final VoidCallback? onTap;
  final VoidCallback? onDismissed;

  /// 下拉关闭进度（0..1），用于父层同步淡出顶栏/图注等 UI。
  final ValueChanged<double>? onDismissProgress;

  const InteractiveImageView({
    super.key,
    required this.child,
    required this.backgroundColor,
    this.maxScale = 8.0,
    this.onTap,
    this.onDismissed,
    this.onDismissProgress,
  });

  @override
  State<InteractiveImageView> createState() => _InteractiveImageViewState();
}

class _InteractiveImageViewState extends State<InteractiveImageView>
    with TickerProviderStateMixin {
  static const _doubleTapScale = 2.5;
  static const _dismissThreshold = 0.15; // 视口高度的 15%
  static const _dismissVelocity = 800.0; // px/s
  static const _minShrink = 0.82; // 下拉到底时内容的最小缩放

  Size _viewportSize = Size.zero;

  // 手势状态：p' = _scale * p + _offset。
  double _scale = 1.0;
  Offset _offset = Offset.zero;

  // 下拉关闭的累积距离（>0 即处于下拉关闭手势中）。
  double _dragDistance = 0;

  // Matrix4 补间（双击缩放/回位/边界回弹）。
  AnimationController? _anim;
  Matrix4Tween? _matrixTween;
  Curve _animCurve = ExpressiveMotion.effects;

  // 回位补间开始时的下拉进度：背景透明度按同一曲线恢复到 0。
  double? _backTweenFromProgress;

  // 手势模式。
  _GestureMode _mode = _GestureMode.idle;
  double _baseScale = 1.0;
  Offset _baseOffset = Offset.zero;
  Offset _referenceFocal = Offset.zero;

  Offset _doubleTapFocal = Offset.zero;

  @override
  void dispose() {
    _anim?.dispose();
    super.dispose();
  }

  double get _dismissProgress => _dragDistance <= 0
      ? 0
      : (_dragDistance / (_viewportSize.height * _dismissThreshold))
          .clamp(0.0, 1.0);

  /// 当前应呈现的下拉进度：拖拽中按距离直接映射；回位补间中按曲线恢复。
  double get _currentDismissProgress {
    if (_dragDistance > 0) return _dismissProgress;
    final from = _backTweenFromProgress;
    final anim = _anim;
    if (from != null && anim != null && anim.isAnimating) {
      return (from * (1 - _animCurve.transform(anim.value)))
          .clamp(0.0, 1.0);
    }
    return 0;
  }

  Matrix4 _composeMatrix() {
    if (_dragDistance > 0) {
      final t = _dismissProgress;
      final s = 1.0 - (1.0 - _minShrink) * t;
      final c = Offset(_viewportSize.width / 2, _viewportSize.height / 2);
      // p' = s*(p - c) + c + (0, _dragDistance)。
      return Matrix4.identity()
        ..translateByDouble(
          c.dx * (1 - s),
          c.dy * (1 - s) + _dragDistance,
          0,
          1,
        )
        ..scaleByDouble(s, s, s, 1);
    }
    return Matrix4.identity()
      ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
      ..scaleByDouble(_scale, _scale, _scale, 1);
  }

  Matrix4 get _effectiveMatrix {
    final anim = _anim;
    if (anim != null && anim.isAnimating && _matrixTween != null) {
      return _matrixTween!
          .evaluate(CurvedAnimation(parent: anim, curve: _animCurve));
    }
    return _composeMatrix();
  }

  /// 把纯 translate+scale 矩阵写回手势状态字段。
  void _applyMatrix(Matrix4 m) {
    final translation = m.getTranslation();
    setState(() {
      _scale = m.getMaxScaleOnAxis();
      _offset = Offset(translation.x, translation.y);
      _dragDistance = 0;
      _backTweenFromProgress = null;
    });
    widget.onDismissProgress?.call(_dismissProgress);
  }

  /// 把下拉关闭的累积距离换算成等价的 (scale, offset) 并清掉拖拽状态：
  /// 两种 compose 完全等价（都是纯 translate+scale），视觉无缝。
  /// 之后的手势/补间都在普通缩放平移状态上进行。
  void _freezeDragIntoOffset() {
    if (_dragDistance <= 0) return;
    final t = _dismissProgress;
    final s = 1.0 - (1.0 - _minShrink) * t;
    final c = Offset(_viewportSize.width / 2, _viewportSize.height / 2);
    setState(() {
      _scale = s;
      _offset = Offset(c.dx * (1 - s), c.dy * (1 - s) + _dragDistance);
      _dragDistance = 0;
    });
  }

  void _animateTo(Matrix4 target, {Curve curve = ExpressiveMotion.effects}) {
    var controller = _anim;
    if (controller == null) {
      controller = AnimationController(
        vsync: this,
        duration: ExpressiveMotion.medium,
      )..addListener(() {
          if (!mounted) return;
          setState(() {});
          widget.onDismissProgress?.call(_currentDismissProgress);
        });
      // 补间自然结束时把终点矩阵写回状态，否则收尾的瞬间会跳回旧状态。
      controller.addStatusListener((status) {
        if (status != AnimationStatus.completed) return;
        final tween = _matrixTween;
        if (tween != null) _applyMatrix(tween.end!);
      });
      _anim = controller;
    }

    _animCurve = curve;
    _matrixTween = Matrix4Tween(begin: _composeMatrix(), end: target);
    controller
      ..duration = ExpressiveMotion.duration(context, ExpressiveMotion.medium)
      ..forward(from: 0);
  }

  /// 手指落下：立即停掉进行中的补间（手指最高优先级），并从补间终点接管，
  /// 避免内容跳变。
  void _captureTweenEnd() {
    final anim = _anim;
    if (anim == null || !anim.isAnimating) return;
    anim.stop();
    _applyMatrix(_matrixTween!.end!);
  }

  void _onDoubleTap() {
    _captureTweenEnd();
    if (_scale > 1.01) {
      // 复原：从当前（已放大的）矩阵补间回单位阵。
      _animateTo(Matrix4.identity());
    } else {
      // 以点按位置为不动点放大到 2.5x：p' = 2.5*(p - f) + f。
      final f = _doubleTapFocal;
      _animateTo(
        Matrix4.identity()
          ..translateByDouble(f.dx, f.dy, 0, 1)
          ..scaleByDouble(_doubleTapScale, _doubleTapScale, _doubleTapScale, 1)
          ..translateByDouble(-f.dx, -f.dy, 0, 1),
      );
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _captureTweenEnd();
    // 把进行中的下拉状态换算成普通缩放平移，手势统一处理。
    _freezeDragIntoOffset();
    setState(() {
      _mode = details.pointerCount > 1
          ? _GestureMode.zoom
          : _scale > 1.01
              ? _GestureMode.pan
              : _GestureMode.pending;
      _baseScale = _scale;
      _baseOffset = _offset;
      _referenceFocal = details.localFocalPoint;
    });
    widget.onDismissProgress?.call(_currentDismissProgress);
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    switch (_mode) {
      case _GestureMode.zoom:
      case _GestureMode.pan:
        // 允许从下拉冻结态（scale < 1）继续捏合，不允许缩得比初始更小。
        final minScale = math.min(_baseScale, 1.0);
        final s1 = (_baseScale * details.scale).clamp(minScale, widget.maxScale);
        setState(() {
          _scale = s1;
          // 保持焦点下的内容点跟随手指：t1 = f - (s1/s0)*(f0 - t0)。
          _offset = details.localFocalPoint -
              (_referenceFocal - _baseOffset) * (s1 / _baseScale);
        });
        break;
      case _GestureMode.pending:
        final delta = details.focalPointDelta;
        if (delta.dy > kTouchSlop && delta.dy.abs() > delta.dx.abs()) {
          setState(() => _mode = _GestureMode.dismiss);
        } else if (delta.dx.abs() > kTouchSlop || details.pointerCount > 1) {
          setState(() => _mode = _GestureMode.zoom);
        }
        break;
      case _GestureMode.dismiss:
        // 直接映射：距离 -> 下移量与缩放，不补间。
        setState(() {
          _dragDistance =
              math.max(0, _dragDistance + details.focalPointDelta.dy);
        });
        widget.onDismissProgress?.call(_dismissProgress);
        break;
      case _GestureMode.idle:
        break;
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    switch (_mode) {
      case _GestureMode.dismiss:
        final velocity = details.velocity.pixelsPerSecond.dy;
        final threshold = _viewportSize.height * _dismissThreshold;
        if (_dragDistance > threshold || velocity > _dismissVelocity) {
          widget.onDismissed?.call();
          return;
        }
        // spatial 弹簧回位：先把拖拽状态冻结成等价缩放平移（视觉无缝），
        // 内容按曲线弹回原位，背景透明度按同一曲线恢复。
        final fromProgress = _dismissProgress;
        _freezeDragIntoOffset();
        setState(() => _backTweenFromProgress = fromProgress);
        _animateTo(Matrix4.identity(), curve: ExpressiveMotion.spatial);
        break;
      case _GestureMode.zoom:
      case _GestureMode.pan:
        if (_scale <= 1.001) {
          _animateTo(Matrix4.identity());
        } else {
          // 把平移限制在内容边界内，防止图片被甩出屏幕。
          final maxX = math.max(0.0,
              (_viewportSize.width * _scale - _viewportSize.width) / 2);
          final maxY = math.max(
              0.0, (_viewportSize.height * _scale - _viewportSize.height) / 2);
          final clamped = Offset(
            _offset.dx.clamp(-maxX, maxX),
            _offset.dy.clamp(-maxY, maxY),
          );
          if (clamped != _offset) {
            _animateTo(Matrix4.identity()
              ..translateByDouble(clamped.dx, clamped.dy, 0, 1)
              ..scaleByDouble(_scale, _scale, _scale, 1));
          }
        }
        break;
      case _GestureMode.pending:
      case _GestureMode.idle:
        break;
    }
    if (mounted) {
      setState(() => _mode = _GestureMode.idle);
    }
    widget.onDismissProgress?.call(_currentDismissProgress);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      _viewportSize = constraints.biggest;

      final progress = _currentDismissProgress;
      return Stack(
        children: [
          // 背景随下拉距离同步淡出（直接映射，不补间）。
          Positioned.fill(
            child: ColoredBox(
              color: widget.backgroundColor
                  .withValues(alpha: widget.backgroundColor.a * (1 - progress)),
            ),
          ),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              onDoubleTapDown: (details) =>
                  _doubleTapFocal = details.localPosition,
              onDoubleTap: _onDoubleTap,
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              onScaleEnd: _onScaleEnd,
              child: Transform(
                transform: _effectiveMatrix,
                child: widget.child,
              ),
            ),
          ),
        ],
      );
    });
  }
}

enum _GestureMode { idle, pending, zoom, pan, dismiss }
