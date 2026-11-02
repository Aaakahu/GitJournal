/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:gitjournal/markdown/gj_markdown_serializers.dart';
import 'package:gitjournal/markdown/rich_editor_safety.dart';
import 'package:gitjournal/utils/markdown.dart';
import 'package:super_editor/super_editor.dart';

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
      // Image with the alignment letter suffix (center / right)
      '![Image](./a.jpg|600c)',
      '![Image](./a.jpg|600r)',
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

    test('image url |600c alignment suffix is preserved verbatim', () {
      final doc = deserializeGitJournalMarkdown('![Image](./a.jpg|600c)');
      final out = serializeGitJournalDocument(doc);
      expect(out, contains('./a.jpg|600c'));
      expect(RichEditorSafety.isRoundtripStable('![Image](./a.jpg|600c)'),
          isTrue);
    });

    test('trailing empty paragraph (blank-tap caret home) serializes to a '
        'clean blank line', () {
      final doc = deserializeGitJournalMarkdown('Hello\n\n![x](./a.jpg)');
      // The node SuperEditorBodyState.claimBlankTap inserts below a trailing
      // image to give the caret a text position to live in.
      doc.insertNodeAt(
        doc.nodeCount,
        ParagraphNode(id: 'caret-home', text: AttributedText()),
      );

      final out = serializeGitJournalDocument(doc);

      // The empty paragraph is a plain trailing blank line - no stray
      // characters, no dangling markup.
      expect(out, 'Hello\n\n![x](./a.jpg)\n\n');

      // Reparsing drops the blank line (no stray node comes back) and a
      // second pass converges to the canonical body, byte-stable.
      final doc2 = deserializeGitJournalMarkdown(out);
      expect(
        doc2.toList().map((n) => n.runtimeType).toList(),
        [ParagraphNode, ImageNode],
      );
      final out2 = serializeGitJournalDocument(doc2);
      expect(out2, 'Hello\n\n![x](./a.jpg)');
      expect(
        serializeGitJournalDocument(deserializeGitJournalMarkdown(out2)),
        out2,
      );
    });

    test('task list checked state is preserved', () {
      final doc =
          deserializeGitJournalMarkdown('- [ ] open\n- [x] done');
      final out = serializeGitJournalDocument(doc);
      expect(out, contains('- [ ] open'));
      expect(out, contains('- [x] done'));
    });

    test('selection-toolbar toggles (B/I/S/H) serialize to stable markdown',
        () {
      // The exact edit requests the selection format toolbar issues, applied
      // to a plain paragraph: the resulting markers must roundtrip.
      final doc = deserializeGitJournalMarkdown('Hello world');
      final composer = MutableDocumentComposer();
      final editor = createDefaultDocumentEditor(
        document: doc,
        composer: composer,
        isHistoryEnabled: false,
      );
      final node = doc.getNodeAt(0) as ParagraphNode;
      final range = DocumentRange(
        start: DocumentPosition(
          nodeId: node.id,
          nodePosition: const TextNodePosition(offset: 0),
        ),
        end: DocumentPosition(
          nodeId: node.id,
          nodePosition: TextNodePosition(offset: node.text.length),
        ),
      );

      editor.execute([
        ToggleTextAttributionsRequest(
          documentRange: range,
          attributions: {boldAttribution},
        ),
        ToggleTextAttributionsRequest(
          documentRange: range,
          attributions: {italicsAttribution},
        ),
        ToggleTextAttributionsRequest(
          documentRange: range,
          attributions: {strikethroughAttribution},
        ),
        ChangeParagraphBlockTypeRequest(
          nodeId: node.id,
          blockType: header1Attribution,
        ),
      ]);

      final out = serializeGitJournalDocument(editor.document);
      expect(out, contains('# '));
      expect(out, contains('**'));
      expect(out, contains('*'));
      expect(out, contains('~~'));

      // The serialized form must survive a full roundtrip unchanged.
      final doc2 = deserializeGitJournalMarkdown(out);
      final out2 = serializeGitJournalDocument(doc2);
      expect(out2, equals(out));
    });
  });

  group('image align suffix (|Nc / |Nr / |c)', () {
    test('|600 without a letter parses unchanged (existing |N data)', () {
      final m = imageMarkupRegex.firstMatch('![x](./a.jpg|600)')!;
      expect(m.group(2), './a.jpg');
      expect(m.group(3), '600');
      expect(alignFromMarkupMatch(m), isNull);
    });

    test('|600c / |600r / |c parse width + alignment letter', () {
      final mc = imageMarkupRegex.firstMatch('![x](./a.jpg|600c)')!;
      expect(mc.group(2), './a.jpg');
      expect(mc.group(3), '600');
      expect(alignFromMarkupMatch(mc), GjImageAlign.center);

      final mr = imageMarkupRegex.firstMatch('![x](./a.jpg|600r)')!;
      expect(mr.group(3), '600');
      expect(alignFromMarkupMatch(mr), GjImageAlign.right);

      final mo = imageMarkupRegex.firstMatch('![x](./a.jpg|c)')!;
      expect(mo.group(3), isNull);
      expect(alignFromMarkupMatch(mo), GjImageAlign.center);
    });

    test('rendered url suffix splits path/width/letter (%7C form)', () {
      final m = imageUrlWidthSuffixRegex.firstMatch('./a.jpg%7C600c')!;
      expect(m.group(1), './a.jpg');
      expect(m.group(2), '600');
      expect(imageUrlAlign('./a.jpg%7C600c'), GjImageAlign.center);
      expect(imageUrlAlign('./a.jpg%7C600'), isNull);
      expect(imageUrlAlign('./a.jpg%7Cr'), GjImageAlign.right);
    });

    test('gjImageMarkup rebuilds the suffix exactly', () {
      expect(gjImageMarkup('x', './a.jpg', 240, GjImageAlign.left),
          '![x](./a.jpg|240)');
      expect(gjImageMarkup('x', './a.jpg', 600, GjImageAlign.center),
          '![x](./a.jpg|600c)');
      expect(gjImageMarkup('x', './a.jpg', null, GjImageAlign.right),
          '![x](./a.jpg|r)');
      expect(gjImageMarkup('x', './a.jpg', null, GjImageAlign.left),
          '![x](./a.jpg)');
    });

    test('letter-only |c roundtrips byte-stable', () {
      final doc = deserializeGitJournalMarkdown('![Image](./a.jpg|c)');
      final out = serializeGitJournalDocument(doc);
      expect(
        RichEditorSafety.normalizeForCompare(out),
        equals(RichEditorSafety.normalizeForCompare('![Image](./a.jpg|c)')),
        reason: 'roundtrip changed the body',
      );
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
