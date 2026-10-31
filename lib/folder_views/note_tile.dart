/*
 * SPDX-FileCopyrightText: 2019-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:gitjournal/app/theme/app_effects.dart';
import 'package:gitjournal/core/note.dart';
import 'package:gitjournal/core/notes/note.dart';
import 'package:gitjournal/core/views/first_image_view.dart';
import 'package:gitjournal/utils/markdown.dart';
import 'package:gitjournal/widgets/highlighted_text.dart';
import 'package:intl/intl.dart';

class NoteTile extends StatelessWidget {
  final Note note;
  final NoteSelectedFunction noteTapped;
  final NoteSelectedFunction noteLongPressed;
  final bool selected;
  final String searchTerm;
  final String searchTermLowerCase;

  NoteTile({
    required this.note,
    required this.noteTapped,
    required this.noteLongPressed,
    required this.selected,
    required this.searchTerm,
  }) : searchTermLowerCase = searchTerm.toLowerCase();

  @override
  Widget build(BuildContext context) {
    var body = _displayText();

    var theme = Theme.of(context);
    var textTheme = theme.textTheme;
    var borderColor = theme.highlightColor.withAlpha(100);
    if (theme.brightness == Brightness.dark) {
      borderColor = theme.highlightColor.withAlpha(30);
    }

    if (selected) {
      borderColor = theme.colorScheme.secondary;
    }

    assert(note.oid.isNotEmpty);

    var tileContent = Container(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        border: Border.all(color: borderColor, width: selected ? 2.0 : 1.0),
        // 静止卡片极淡投影：仅亮色，暗色靠表面分层（AppEffects.restingCardShadow）。
        boxShadow: AppEffects.restingCardShadow(theme.colorScheme) ??
            const <BoxShadow>[],
      ),
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Image area: intrinsic aspect ratio, capped so portrait photos
          // don't swallow the whole card.
          NoteFirstImageThumbnail(
            note: note,
            maxHeight: 260.0,
            cacheWidth: 800,
          ),
          if (note.title != null)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: HighlightedText(
                text: note.title!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleLarge!
                    .copyWith(fontSize: textTheme.titleLarge!.fontSize! * 0.8),
                highlightText: searchTerm,
                highlightTextLowerCase: searchTermLowerCase,
              ),
            ),
          if (note.title == null && note.type == NoteType.Journal)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: HighlightedText(
                text: '${note.created.day} ${DateFormat('MMMM, yyyy').format(note.created)}\n${DateFormat('EEEE HH:mm').format(note.created)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleLarge!
                    .copyWith(fontSize: textTheme.titleLarge!.fontSize! * 0.8),
                highlightText: searchTerm,
                highlightTextLowerCase: searchTermLowerCase,
              ),
            ),
          if (body.isNotEmpty) ...[
            const SizedBox(height: 8.0),
            _buildBody(context, body),
          ],
          const SizedBox(height: 8.0),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Text(
              DateFormat('MM-dd HH:mm').format(note.modified),
              style: textTheme.bodySmall!.copyWith(color: theme.hintColor),
            ),
          ),
        ],
      ),
    );

    const borderRadius = BorderRadius.all(Radius.circular(8));
    return Material(
      borderRadius: borderRadius,
      type: MaterialType.card,
      child: InkWell(
        borderRadius: borderRadius,
        onTap: () => noteTapped(note),
        onLongPress: () => noteLongPressed(note),
        child: Hero(
          tag: note.filePath,
          child: tileContent,
          flightShuttleBuilder: (BuildContext flightContext,
                  Animation<double> animation,
                  HeroFlightDirection flightDirection,
                  BuildContext fromHeroContext,
                  BuildContext toHeroContext) =>
              Material(child: toHeroContext.widget),
        ),
      ),
    );
  }

  static const _maxLines = 12;

  // The tiles are rebuilt on every frame of the scrolling grid - cache the
  // computed display text per (note version, search term).
  static final _displayTextCache = <String, String>{};

  String _displayText() {
    var cacheKey = '${note.oid}:$searchTerm';
    var cached = _displayTextCache[cacheKey];
    if (cached != null) return cached;

    var foundSearchTerm = searchTerm.isEmpty ? true : false;
    var buffer = <String>[];
    var i = 0;

    for (var rawLine in LineSplitter.split(note.body)) {
      // Image markups and header hashes are markup fragments that carry no
      // meaning in a card summary - drop them, along with lines that only
      // held an image so they don't eat summary lines.
      var line = rawLine.replaceAll(imageMarkupRegex, '');
      line = line.replaceAll(RegExp(' {2,}'), ' ');
      line = replaceMarkdownChars(line);
      if (line.trimLeft().startsWith('#')) {
        line = line.replaceAll('#', '');
      }
      line = line.trim();
      if (line.isEmpty) {
        continue;
      }
      buffer.add(line);

      if (line.toLowerCase().contains(searchTermLowerCase)) {
        foundSearchTerm = true;
      }

      i += 1;
      if (i == _maxLines && foundSearchTerm) {
        break;
      }
    }

    if (buffer.length > _maxLines) {
      buffer = buffer.sublist(buffer.length - _maxLines);
    }

    var displayText = buffer.join("\n").trimRight();

    if (displayText.isEmpty &&
        imageMarkupRegex.hasMatch(note.body)) {
      displayText = '[图片]';
    }

    if (_displayTextCache.length > 1024) {
      _displayTextCache.clear();
    }
    _displayTextCache[cacheKey] = displayText;

    return displayText;
  }

  Widget _buildBody(BuildContext context, String text) {
    var textTheme = Theme.of(context).textTheme;

    return HighlightedText(
      text: text,
      highlightText: searchTerm,
      highlightTextLowerCase: searchTermLowerCase,
      style: textTheme.titleMedium!
          .copyWith(fontSize: textTheme.titleMedium!.fontSize! * 0.9),
      overflow: TextOverflow.ellipsis,
      maxLines: 3,
    );
  }
}
