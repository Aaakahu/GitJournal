/*
 * SPDX-FileCopyrightText: 2020-2021 Roland Fredenhagen <important@van-fredenhagen.de>
 * SPDX-FileCopyrightText: 2020-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: Apache-2.0
 */

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:gitjournal/l10n.dart';
import 'package:gitjournal/logger/logger.dart';
import 'package:gitjournal/settings/markdown_renderer_config.dart';
import 'package:gitjournal/widgets/delayed_loading_gate.dart';
import 'package:gitjournal/widgets/images/image_caption.dart';
import 'package:gitjournal/widgets/images/image_details.dart';
import 'package:gitjournal/widgets/images/themable_image.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:universal_io/io.dart';

class MarkdownImage extends StatefulWidget {
  final double? width;
  final double? height;
  final String altText;
  final String tooltip;

  /// Horizontal alignment of the image inside the column (from the markup's
  /// `c`/`r` suffix letter, or the global default).
  final AlignmentDirectional alignment;

  // FIXME: Avoid using dynamic!
  final Future<dynamic> data;

  /// When set, tapping the image toggles its width (thumbnail <-> full).
  /// When null, tapping opens the image details page.
  final VoidCallback? onToggleWidth;

  const MarkdownImage._(this.data, this.width, this.height, String? altText,
      String? tooltip,
      {this.onToggleWidth, this.alignment = AlignmentDirectional.centerStart})
      : altText = altText ?? "",
        tooltip = tooltip ?? "";

  factory MarkdownImage(Uri uri, String imageDirectory,
      {double? width,
      double? height,
      String? altText,
      String? titel,
      AlignmentDirectional alignment = AlignmentDirectional.centerStart,
      void Function()? onToggleWidth}) {
    final file = ((uri.isScheme("http") || uri.isScheme("https"))
        ? DefaultCacheManager().getSingleFile(uri.toString())
        : Future.sync(() =>
            File.fromUri(Uri.parse(p.join(imageDirectory, uri.toString())))));

    final data = file.then(
        (value) => value.path.endsWith(".svg") ? value.readAsString() : file);

    return MarkdownImage._(data, width, height, altText, titel,
        onToggleWidth: onToggleWidth, alignment: alignment);
  }

  @override
  State<MarkdownImage> createState() => _MarkdownImageState();
}

class _MarkdownImageState extends State<MarkdownImage> {
  // Intrinsic size of the decoded raster image, for the long-image fold
  // decision. Filled synchronously when the image is cached, otherwise
  // through the image stream.
  ui.Image? _decodedImage;
  String? _decodedPath;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;

  void _listenForImageSize(File file) {
    if (_decodedPath == file.path) return;
    if (_imageListener != null) {
      _imageStream?.removeListener(_imageListener!);
      _imageStream = null;
      _imageListener = null;
    }

    final stream = FileImage(file).resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener((info, synchronousCall) {
      if (!mounted || _decodedPath == file.path) return;
      void apply() {
        _decodedImage = info.image;
        _decodedPath = file.path;
      }

      if (synchronousCall) {
        // Inside build: just update the fields, this build still uses them.
        apply();
      } else {
        setState(apply);
      }
    });
    stream.addListener(listener);
    _imageStream = stream;
    _imageListener = listener;
  }

  @override
  void dispose() {
    if (_imageListener != null) {
      _imageStream?.removeListener(_imageListener!);
    }
    super.dispose();
  }

  /// 折叠判定：高/宽 > 3，或按当前显示宽度渲染后的高度超过视口可用高度
  /// 约 1.5 倍（满屏大图遮死编辑区，真机反馈）。视口取 MediaQuery 屏幕
  /// 尺寸减系统上下边距；普通竖拍照片（高/宽 1.3~2）不会折叠。
  bool _isFoldWorthy(double displayMaxWidth) {
    final image = _decodedImage;
    if (image == null) return false;
    if (image.height > image.width * 3) return true;

    final media = MediaQuery.of(context);
    final viewportHeight = media.size.height - media.padding.vertical;
    final renderedHeight = displayMaxWidth * image.height / image.width;
    return renderedHeight > viewportHeight * 1.5;
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<MarkdownRendererConfig>();
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final width = widget.width;

    // Test for override tags in AltText/Tooltip
    ThemeOverride override = ThemeOverride.None;
    if (settings.themeOverrideTagLocation == SettingsImageTextType.Alt ||
        settings.themeOverrideTagLocation == SettingsImageTextType.AltTool) {
      if (hasTag(widget.altText, settings.doThemeTags)) {
        override = ThemeOverride.Do;
      } else if (hasTag(widget.altText, settings.doNotThemeTags)) {
        override = ThemeOverride.No;
      }
    }
    if (settings.themeOverrideTagLocation == SettingsImageTextType.Tooltip ||
        settings.themeOverrideTagLocation == SettingsImageTextType.AltTool) {
      if (hasTag(widget.tooltip, settings.doThemeTags)) {
        override = ThemeOverride.Do;
      } else if (hasTag(widget.tooltip, settings.doNotThemeTags)) {
        override = ThemeOverride.No;
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final small =
            constraints.maxWidth < MediaQuery.of(context).size.width - 40;
        // `|width` is a maximum width: smaller images keep their natural
        // size, larger ones scale down to fit. No suffix: the column width.
        final displayMaxWidth =
            (width != null ? math.min(width, constraints.maxWidth) : constraints.maxWidth)
                .clamp(1.0, double.infinity);
        final image = FutureBuilder(
            future: widget.data,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                String errorMessage = snapshot.error.toString();
                Log.e(errorMessage);
                if (snapshot.error is HttpExceptionWithStatus) {
                  final httpError = snapshot.error as HttpExceptionWithStatus;
                  errorMessage = context.loc.widgetsImageRendererHttpError(
                      httpError.statusCode.toString(),
                      httpError.uri.toString());
                }
                return SizedBox(
                  width: width,
                  height: widget.height,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.error,
                              color: theme.colorScheme.error,
                              size: 36,
                            ),
                            Text(
                              errorMessage,
                              style: theme.textTheme.bodyLarge!
                                  .copyWith(color: theme.colorScheme.error),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            )
                          ]),
                    ),
                  ),
                );
              }

              if (snapshot.hasData) {
                Widget im;
                ThemableImage themable;
                var isLongImage = false;
                if (snapshot.data is String) {
                  themable = ThemableImage.svg(
                    snapshot.data as String,
                    width: width ?? MediaQuery.of(context).size.width,
                    height: widget.height,
                    themingMethod: override == ThemeOverride.No ||
                            settings.themeVectorGraphics ==
                                    SettingsThemeVectorGraphics.Off &&
                                override != ThemeOverride.Do
                        ? ThemingMethod.none
                        : dark
                            ? settings.themeVectorGraphics ==
                                    SettingsThemeVectorGraphics.Filter
                                ? ThemingMethod.filter
                                : ThemingMethod.invertBrightness
                            : settings.matchCanvasColor
                                ? ThemingMethod.wToBg
                                : ThemingMethod.none,
                    themingCondition: settings.themeSvgWithBackground ||
                            override == ThemeOverride.Do
                        ? ThemingCondition.none
                        : ThemingCondition.noBackground,
                    colorCondition: settings.vectorGraphicsAdjustColors ==
                            SettingsVectorGraphicsAdjustColors.All
                        ? ColorCondition.all
                        : settings.vectorGraphicsAdjustColors ==
                                SettingsVectorGraphicsAdjustColors.BnW
                            ? ColorCondition.bw
                            : ColorCondition.gray,
                    bg: settings.matchCanvasColor
                        ? theme.canvasColor
                        : Colors.black,
                  );
                  im = Align(
                    alignment: widget.alignment,
                    child: themable,
                  );
                } else {
                  final file = snapshot.data as File;
                  _listenForImageSize(file);
                  isLongImage = _isFoldWorthy(displayMaxWidth);
                  themable = ThemableImage.image(
                    file,
                    height: widget.height,
                    doTheme: (settings.themeRasterGraphics ||
                            override == ThemeOverride.Do) &&
                        override != ThemeOverride.No &&
                        dark,
                    bg: theme.canvasColor,
                  );

                  if (isLongImage) {
                    im = _buildFoldedImage(file, displayMaxWidth, theme);
                  } else {
                    im = Align(
                      alignment: widget.alignment,
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(maxWidth: displayMaxWidth),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: widget.alignment,
                          child: themable,
                        ),
                      ),
                    );
                  }
                }

                return GestureDetector(
                  behavior: widget.onToggleWidth != null && !isLongImage
                      ? HitTestBehavior.opaque
                      : HitTestBehavior.deferToChild,
                  onTap: isLongImage
                      // Folded images always open the full screen viewer.
                      ? () => _openDetails(context, themable)
                      : widget.onToggleWidth ??
                          () => _openDetails(context, themable),
                  child: im,
                );
              }

              // 图片源解析通常毫秒级（本地文件）：300ms 内完成就不闪指示器。
              return DelayedLoadingGate(
                loading: true,
                builder: (context, showLoading) => SizedBox(
                  width: width,
                  height: widget.height,
                  child: showLoading
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child:
                              Center(child: CircularProgressIndicator()))
                      : null,
                ),
              );
            });

        if (shouldCaption(context, widget.altText, widget.tooltip)) {
          if (small || !settings.overlayCaption) {
            return Column(
                children: [image, ImageCaption(widget.altText, widget.tooltip, false)]);
          } else {
            return Stack(
                alignment: AlignmentDirectional.bottomEnd,
                children: [
                  image,
                  ImageCaption(widget.altText, widget.tooltip, true)
                ]);
          }
        }
        return image;
      },
    );
  }

  /// A 2:3 box (width:height) showing only the top of the long image, with
  /// a badge in the bottom right corner. Tapping opens the full screen
  /// viewer. The `|width` toggle keeps acting on the display constraint.
  Widget _buildFoldedImage(
      File file, double displayMaxWidth, ThemeData theme) {
    return Stack(
      children: [
        SizedBox(
          width: displayMaxWidth,
          height: displayMaxWidth * 1.5,
          child: ClipRect(
            child: Image.file(
              file,
              fit: BoxFit.fitWidth,
              alignment: Alignment.topCenter,
            ),
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              context.loc.widgetsLongImageBadge,
              style: theme.textTheme.labelSmall,
            ),
          ),
        ),
      ],
    );
  }

  void _openDetails(BuildContext context, ThemableImage themable) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ImageDetails(
          themable,
          captionText(context, widget.altText, widget.tooltip),
        ),
      ),
    );
  }
}

Color getOverlayBackgroundColor(
    MarkdownRendererConfig settings, ThemeData theme,
    {Color? light, Color? dark}) {
  return theme.brightness == Brightness.dark
      ? settings.transparentCaption
          ? Colors.black.withAlpha(100)
          : dark ?? theme.canvasColor
      : settings.transparentCaption
          ? Colors.white.withAlpha(100)
          : light ?? theme.canvasColor;
}

enum ThemeOverride { None, Do, No }
