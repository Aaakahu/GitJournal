/*
 * SPDX-FileCopyrightText: 2019-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'dart:convert';
import 'dart:core';

/// Matches image markups with local paths: `![alt](path)` or
/// `![alt](path|width)` where `|width` is our display-width extension
/// (in logical pixels).
final RegExp imageMarkupRegex =
    RegExp(r'!\[([^\]]*)\]\(([^()\s|]+)(?:\|(\d+))?\)');

/// The width in logical pixels a plain image markup gets when it is toggled
/// to thumbnail size (`|240` suffix). Matches what desktop Obsidian shows
/// for `![[name|240]]` after inbox-sync.
const int gjImageThumbnailWidth = 240;

/// Splits the rendered image URL into its path and the `|width` suffix.
/// The `|` survives the markdown parser percent-encoded as `%7C`.
final RegExp imageUrlWidthSuffixRegex =
    RegExp(r'^(.*?)(?:%7C|\|)(\d+)$', caseSensitive: false);

/// The path of the first local image markup in the markdown [body],
/// or null if there is none.
String? firstLocalImagePath(String body) {
  for (var match in imageMarkupRegex.allMatches(body)) {
    var path = match.group(2)!;
    if (!path.contains('://')) {
      return path;
    }
  }
  return null;
}

String stripMarkdownFormatting(String markdown) {
  var output = StringBuffer();

  var lines = LineSplitter.split(markdown);
  for (var line in lines) {
    line = line.trim();
    if (line.startsWith('#')) {
      line = line.replaceAll('#', '');
    }
    if (line.isEmpty) {
      continue;
    }
    line = replaceMarkdownChars(line);

    output.write(line.trim());
    output.write(' ');
  }

  return output.toString().trimRight();
}

/// Summary text for list tiles: like [stripMarkdownFormatting], but image
/// markups are dropped entirely - in a card they only leave clutter. When
/// nothing textual remains and the note does contain images, a "[图片]"
/// placeholder keeps the tile from looking empty.
String noteSummaryText(String markdown) {
  var hasImage = imageMarkupRegex.hasMatch(markdown);
  var text = stripMarkdownFormatting(markdown.replaceAll(imageMarkupRegex, ''));
  // Drop the double spaces left behind where an image sat mid-line.
  text = text.replaceAll(RegExp(' {2,}'), ' ');
  if (text.isEmpty && hasImage) {
    return '[图片]';
  }
  return text;
}

String replaceMarkdownChars(String line) {
  line = line.replaceFirst('- [ ]', '☐');
  line = line.replaceFirst('- [x]', '☑');
  line = line.replaceFirst('- [X]', '☑');

  line = replaceListChar(line, '* ');
  line = replaceListChar(line, '- ');
  line = replaceListChar(line, '+ ');

  return line;
}

String replaceListChar(String line, String char) {
  const String bullet = '• ';

  var starPos = line.indexOf(char);
  if (starPos == 0) {
    line = line.replaceFirst(char, bullet);
  } else if (starPos != -1) {
    var beforeStar = line.substring(0, starPos);
    if (beforeStar.trim().isEmpty) {
      line = line.replaceFirst(char, bullet, starPos);
    }
  }

  return line;
}
