/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:gitjournal/markdown/gj_markdown_serializers.dart';

/// Safety gates deciding whether a note body may be opened in the rich
/// (super_editor based) markdown editor. Data safety comes first: anything
/// the rich editor can't round-trip byte-for-byte must stay in the plain
/// text editor.
class RichEditorSafety {
  RichEditorSafety._();

  /// Returns true if the body contains markdown the rich editor must not
  /// touch (would lose content or formatting), so the plain text editor
  /// must be used instead.
  static bool hasUnsafeMarkdown(String body) {
    // a) Fenced code blocks. The rich editor only models inline code, so a
    //    fence would be rewritten into something else.
    if (body.contains('```')) {
      return true;
    }

    // b) Tables: two or more consecutive lines starting with `|`.
    var consecutivePipeLines = 0;
    for (var line in body.split('\n')) {
      if (line.trimLeft().startsWith('|')) {
        consecutivePipeLines++;
        if (consecutivePipeLines >= 2) {
          return true;
        }
      } else {
        consecutivePipeLines = 0;
      }
    }

    // c) Raw HTML tags. Broader than the minimal `<[a-zA-Z]+>` shape: the
    //    rich editor strips unknown inline HTML, so any tag lookalike
    //    (including `<br/>`, `</b>`, `<img src="x">`) forces the fallback.
    if (_htmlTagPattern.hasMatch(body)) {
      return true;
    }

    return false;
  }

  static final RegExp _htmlTagPattern =
      RegExp(r'</?[a-zA-Z][a-zA-Z0-9]*(\s[^<>]*)?/?>');

  /// Normalizes a markdown string for the roundtrip comparison: per-line
  /// trailing whitespace (super_editor turns soft line breaks into markdown
  /// hard breaks by adding two trailing spaces) plus leading/trailing blank
  /// lines of the whole document.
  static String normalizeForCompare(String markdown) {
    var lines = markdown.split('\n').map((l) => l.trimRight()).toList();
    while (lines.isNotEmpty && lines.first.trim().isEmpty) {
      lines.removeAt(0);
    }
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return lines.join('\n');
  }

  /// Runs the deserialize -> serialize roundtrip and reports whether the
  /// output is equal to the input beyond [normalizeForCompare]. Notes where
  /// this returns false must not be opened in the rich editor.
  static bool isRoundtripStable(String body) {
    try {
      final doc = deserializeGitJournalMarkdown(body);
      final out = serializeGitJournalDocument(doc);
      return normalizeForCompare(out) == normalizeForCompare(body);
    } catch (e) {
      // If the roundtrip machinery throws, never risk the content.
      return false;
    }
  }
}
