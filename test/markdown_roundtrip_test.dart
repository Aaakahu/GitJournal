/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:gitjournal/markdown/gj_markdown_serializers.dart';
import 'package:gitjournal/markdown/rich_editor_safety.dart';

void main() {
  group('markdown roundtrip (deserialize -> serialize)', () {
    // Bodies that must survive the super_editor roundtrip byte-for-byte.
    // These are the shapes the rich editor is allowed to touch.
    final stableCases = <String>[
      // Plain paragraph
      'Hello world',
      // Paragraph with a soft line break (serializer adds two trailing
      // spaces -> covered by the normalization below)
      'Hello\nworld',
      // Image with our |width url suffix, both with and without
      '![Image](./a.jpg|600)',
      '![Image](./sub/dir/b.png)',
      // Bold / italic / strikethrough / inline code / links
      '**bold** and *italic*',
      '~~struck~~ text',
      '`inline code` and [a link](https://example.com)',
      // Unordered list
      '- item one\n- item two\n- item three',
      // Nested unordered list
      '- parent\n  - child\n  - child2',
      // Ordered list with real numbering
      '1. first\n2. second\n3. third',
      // Task list with checked state
      '- [ ] open task\n- [x] done task',
      // Headers
      '# h1\n\n## h2\n\n### h3',
      // Blockquote
      '> quoted text',
      // Multi paragraph with blank line
      'p1\n\np2',
      // Combined body, the common note shape
      '# Shopping\n\nSome **bold** text\n\n- apples\n- pears\n- [ ] buy milk\n\n![Image](./a.jpg|600)\n\ndone.',
    ];

    for (var body in stableCases) {
      test('preserves content: ${body.replaceAll('\n', '\\n')}', () {
        final doc = deserializeGitJournalMarkdown(body);
        final out = serializeGitJournalDocument(doc);

        expect(
          RichEditorSafety.normalizeForCompare(out),
          equals(RichEditorSafety.normalizeForCompare(body)),
          reason: 'roundtrip changed the body',
        );

        // The roundtrip must be idempotent: a second pass may not change the
        // text again, otherwise every editor open would rewrite the note.
        final doc2 = deserializeGitJournalMarkdown(out);
        final out2 = serializeGitJournalDocument(doc2);
        expect(out2, equals(out));
      });
    }

    test('image url |600 suffix is preserved verbatim', () {
      final doc = deserializeGitJournalMarkdown('![Image](./a.jpg|600)');
      final out = serializeGitJournalDocument(doc);
      expect(out, contains('./a.jpg|600'));
    });

    test('task list checked state is preserved', () {
      final doc =
          deserializeGitJournalMarkdown('- [ ] open\n- [x] done');
      final out = serializeGitJournalDocument(doc);
      expect(out, contains('- [ ] open'));
      expect(out, contains('- [x] done'));
    });
  });

  group('rich editor safety check (must fall back to plain editor)', () {
    test('code fences are unsafe', () {
      expect(RichEditorSafety.hasUnsafeMarkdown('```dart\nmain();\n```'),
          isTrue);
      expect(RichEditorSafety.hasUnsafeMarkdown('text with ``` inside'),
          isTrue);
    });

    test('tables are unsafe', () {
      expect(
        RichEditorSafety.hasUnsafeMarkdown('| a | b |\n| --- | --- |\n| 1 | 2 |'),
        isTrue,
      );
      // A single pipe line alone is not a table
      expect(RichEditorSafety.hasUnsafeMarkdown('| just a pipe line'),
          isFalse);
    });

    test('raw html tags are unsafe', () {
      expect(RichEditorSafety.hasUnsafeMarkdown('hello <b>bold</b>'), isTrue);
      expect(RichEditorSafety.hasUnsafeMarkdown('line break <br/>'), isTrue);
      expect(RichEditorSafety.hasUnsafeMarkdown('closing </div> tag'),
          isTrue);
      expect(RichEditorSafety.hasUnsafeMarkdown('<img src="x.png">'), isTrue);
      // Math comparisons are not tags
      expect(RichEditorSafety.hasUnsafeMarkdown('5 < 10 and 10 > 3'),
          isFalse);
    });

    test('roundtrip-unstable bodies are detected', () {
      // Autolinks get rewritten to [label](url) form
      expect(
        RichEditorSafety.isRoundtripStable('see <https://example.com>'),
        isFalse,
      );
      // Ordered lists not starting at 1. get renumbered
      expect(
        RichEditorSafety.isRoundtripStable('3. three\n4. four'),
        isFalse,
      );
      // Underscore emphasis is rewritten to asterisk emphasis
      expect(RichEditorSafety.isRoundtripStable('_emphasis_'), isFalse);
      // Loose lists (blank line between items) come back as tight lists
      expect(
        RichEditorSafety.isRoundtripStable('- a\n\n- b'),
        isFalse,
      );
    });

    test('plain safe bodies pass the roundtrip', () {
      expect(RichEditorSafety.isRoundtripStable('Hello world'), isTrue);
      expect(
        RichEditorSafety.isRoundtripStable('Some text\n\n![Image](./x.jpg|300)'),
        isTrue,
      );
      // Note: an image directly following a task/list line is parsed as part
      // of the list item and gets dropped by the inline parser - such bodies
      // fail the roundtrip check and automatically fall back to the plain
      // text editor.
    });
  });
}
