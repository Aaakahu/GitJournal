/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:gitjournal/markdown/gj_markdown_serializers.dart';
import 'package:gitjournal/utils/markdown.dart';

void main() {
  group('hasMoodTag', () {
    test('detects a standalone tag line', () {
      expect(hasMoodTag('#情绪'), isTrue);
      expect(hasMoodTag('#情绪 \n'), isTrue);
      expect(hasMoodTag('#情绪\n\nHello'), isTrue);
      expect(hasMoodTag('Hello\n\n#情绪'), isTrue);
    });

    test('ignores non-standalone occurrences', () {
      expect(hasMoodTag(''), isFalse);
      expect(hasMoodTag('Hello'), isFalse);
      expect(hasMoodTag('my #情绪 tag'), isFalse);
      expect(hasMoodTag('#情绪matic'), isFalse);
      expect(hasMoodTag('##情绪'), isFalse);
    });
  });

  group('toggleMoodTag', () {
    test('adds the tag line on top of an empty body', () {
      expect(toggleMoodTag(''), '#情绪\n');
    });

    test('adds the tag line plus a blank line on top of a body', () {
      expect(toggleMoodTag('Hello'), '#情绪\n\nHello');
    });

    test('removes the tag line and the blank line', () {
      expect(toggleMoodTag('#情绪\n\nHello'), 'Hello');
      expect(toggleMoodTag('#情绪\nHello'), 'Hello');
      expect(toggleMoodTag('#情绪\n'), '');
      expect(toggleMoodTag('#情绪'), '');
    });

    test('is symmetric', () {
      for (var body in ['Hello', '', 'Hello\n\nWorld', 'Hello\n#其他']) {
        expect(toggleMoodTag(toggleMoodTag(body)), body);
      }
    });
  });

  // The mood tag must survive the rich editor's markdown roundtrip:
  // deserialize -> serialize happens on every document reload, and if the
  // '#情绪' line got mangled the pipeline would lose the tag.
  test('tag line survives the rich editor roundtrip', () {
    var body = '#情绪\n\nHello World\n\nSecond paragraph.';
    expect(hasMoodTag(body), isTrue);

    var doc = deserializeGitJournalMarkdown(body);
    var serialized = serializeGitJournalDocument(doc);

    expect(hasMoodTag(serialized), isTrue,
        reason: 'serialized body was: $serialized');
  });
}
