/*
 * SPDX-FileCopyrightText: 2020-2021 Roland Fredenhagen <important@van-fredenhagen.de>
 * SPDX-FileCopyrightText: 2020-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:gitjournal/l10n.dart';
import 'package:gitjournal/logger/logger.dart';
import 'package:gitjournal/settings/markdown_renderer_config.dart';
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

  // FIXME: Avoid using dynamic!
  final Future<dynamic> data;

  /// When set, a drag handle is rendered at the bottom right corner which
  /// lets the user change the image width. Called with the final width
  /// (in logical pixels) once the drag ends.
  final void Function(double width)? onResizeEnd;

  const MarkdownImage._(this.data, this.width, this.height, String? altText,
      String? tooltip, {this.onResizeEnd})
      : altText = altText ?? "",
        tooltip = tooltip ?? "";

  factory MarkdownImage(Uri uri, String imageDirectory,
      {double? width,
      double? height,
      String? altText,
      String? titel,
      void Function(double width)? onResizeEnd}) {
    final file = ((uri.isScheme("http") || uri.isScheme("https"))
        ? DefaultCacheManager().getSingleFile(uri.toString())
        : Future.sync(() =>
            File.fromUri(Uri.parse(p.join(imageDirectory, uri.toString())))));

    final data = file.then(
        (value) => value.path.endsWith(".svg") ? value.readAsString() : file);

    return MarkdownImage._(data, width, height, altText, titel,
        onResizeEnd: onResizeEnd);
  }

  @override
  State<MarkdownImage> createState() => _MarkdownImageState();
}

class _MarkdownImageState extends State<MarkdownImage> {
  // The width while the resize handle is being dragged, null otherwise
  double? _dragWidth;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<MarkdownRendererConfig>();
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final width = _dragWidth ?? widget.width;

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
                if (snapshot.data is String) {
                  im = ThemableImage.svg(
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
                } else {
                  im = ThemableImage.image(
                    snapshot.data as File,
                    width: width,
                    height: widget.height,
                    doTheme: (settings.themeRasterGraphics ||
                            override == ThemeOverride.Do) &&
                        override != ThemeOverride.No &&
                        dark,
                    bg: theme.canvasColor,
                  );
                }

                Widget image = GestureDetector(
                  child: im,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ImageDetails(
                          im as ThemableImage,
                          captionText(context, widget.altText, widget.tooltip),
                        ),
                      ),
                    );
                  },
                );

                if (widget.onResizeEnd != null) {
                  image = Stack(
                    alignment: AlignmentDirectional.bottomEnd,
                    children: [
                      image,
                      _buildResizeHandle(
                        settings: settings,
                        theme: theme,
                        maxWidth: constraints.maxWidth,
                      ),
                    ],
                  );
                }

                return image;
              }

              return SizedBox(
                  width: width,
                  height: widget.height,
                  child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator())));
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

  Widget _buildResizeHandle({
    required MarkdownRendererConfig settings,
    required ThemeData theme,
    required double maxWidth,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) {
        setState(() {
          var startWidth = _dragWidth ?? widget.width ?? maxWidth;
          _dragWidth = (startWidth + details.delta.dx).clamp(40.0, maxWidth);
        });
      },
      onHorizontalDragEnd: (details) {
        final newWidth = _dragWidth;
        setState(() => _dragWidth = null);
        if (newWidth != null) {
          widget.onResizeEnd!(newWidth);
        }
      },
      child: Container(
        width: 32.0,
        height: 32.0,
        margin: const EdgeInsets.all(4.0),
        decoration: BoxDecoration(
          color: getOverlayBackgroundColor(settings, theme),
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.settings_ethernet,
          size: 18.0,
          color: theme.iconTheme.color,
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
