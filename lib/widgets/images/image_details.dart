/*
 * SPDX-FileCopyrightText: 2020-2021 Roland Fredenhagen <important@van-fredenhagen.de>
 * SPDX-FileCopyrightText: 2020-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:gitjournal/settings/markdown_renderer_config.dart';
import 'package:gitjournal/widgets/images/interactive_image_view.dart';
import 'package:gitjournal/widgets/images/markdown_image.dart';
import 'package:gitjournal/widgets/images/themable_image.dart';
import 'package:provider/provider.dart';

class ImageDetails extends StatefulWidget {
  final ThemableImage image;
  final String caption;
  const ImageDetails(this.image, this.caption);

  @override
  _ImageDetailsState createState() => _ImageDetailsState();
}

class _ImageDetailsState extends State<ImageDetails> {
  int _rotation = 0;
  bool _showUI = true;

  // 下拉关闭进度：内容缩放/背景淡出由 InteractiveImageView 直接映射，
  // 顶栏与图注用同一进度同步淡出。
  double _dismissProgress = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = context.watch<MarkdownRendererConfig>();
    final bg =
        theme.brightness == Brightness.dark ? Colors.black : Colors.white;
    final overlayColor = getOverlayBackgroundColor(settings, theme,
        light: Colors.white, dark: Colors.black);
    final barOpacity = (1 - _dismissProgress).clamp(0.0, 1.0);
    return Stack(
      children: [
        InteractiveImageView(
          backgroundColor: bg,
          maxScale: settings.maxImageZoom,
          onTap: () => setState(() => _showUI = !_showUI),
          onDismissed: () => Navigator.of(context).pop(),
          onDismissProgress: (progress) {
            if (mounted) {
              setState(() => _dismissProgress = progress);
            }
          },
          child: Hero(
            tag: widget.image,
            child: RotatedBox(
                quarterTurns: _rotation,
                child: ThemableImage.from(widget.image, bg: bg)),
          ),
        ),
        if (_showUI && barOpacity > 0)
          Positioned(
            top: MediaQuery.of(context).padding.top,
            left: 0,
            right: 0,
            height: 60,
            child: Opacity(
              opacity: barOpacity,
              child: Material(
                  color: overlayColor,
                  child: Padding(
                      padding:
                          const EdgeInsetsDirectional.fromSTEB(8, 0, 0, 0),
                      child: Row(
                        children: [
                          IconButton(
                              splashRadius: 20,
                              icon: const Icon(Icons.arrow_back),
                              onPressed: () => Navigator.pop(context)),
                          const Spacer(),
                          IconButton(
                              splashRadius: 20,
                              icon: const Icon(Icons.rotate_90_degrees_ccw),
                              onPressed: () => setState(() => _rotation--))
                        ],
                      ))),
            ),
          ),
        // TODO use a DraggableScrollableSheet, when they can be dynamically
        // height restricted https://github.com/flutter/flutter/issues/41599
        if (_showUI && widget.caption.isNotEmpty && barOpacity > 0)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Opacity(
              opacity: barOpacity,
              child: Hero(
                  tag: "caption",
                  child: Container(
                    color: overlayColor,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: SingleChildScrollView(
                          child: Text(
                        widget.caption,
                        style: theme.primaryTextTheme.bodyLarge,
                      )),
                    ),
                  )),
            ),
          ),
      ],
    );
  }
}
