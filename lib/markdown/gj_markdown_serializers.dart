/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:super_editor/super_editor.dart';
import 'package:super_editor_markdown/super_editor_markdown.dart';

/// Markdown serializers that keep GitJournal's markdown flavor byte-stable
/// across super_editor deserialize -> serialize roundtrips. Differences from
/// super_editor_markdown's defaults:
///  - unordered list items keep their `- ` bullet (super_editor emits `* `)
///  - ordered list items keep their real 1..n numbers (super_editor emits `1.`)
///  - strikethrough is serialized as `~~text~~` (super_editor emits `~text~`)
///
/// Everything else (images with our `|width` url suffix, headers, blockquotes,
/// task lists) roundtrips fine with the stock serializers and
/// [MarkdownSyntax.normal], so those are left untouched.

/// Deserializes markdown into a super_editor document using the plain
/// markdown syntax (no super_editor extensions like `=WxH` image sizes).
MutableDocument deserializeGitJournalMarkdown(String markdown) {
  return deserializeMarkdownToDocument(markdown, syntax: MarkdownSyntax.normal);
}

/// Serializes a super_editor document back to GitJournal flavored markdown.
String serializeGitJournalDocument(Document doc) {
  return serializeDocumentToMarkdown(
    doc,
    syntax: MarkdownSyntax.normal,
    // Fresh instances every call: GjListItemSerializer keeps numbering state
    // that is only valid within a single serialization pass.
    customNodeSerializers: [
      const GjImageSerializer(),
      const GjHorizontalRuleSerializer(),
      const GjParagraphSerializer(),
      GjListItemSerializer(),
      const GjTaskSerializer(),
    ],
  );
}

/// Serializes [ImageNode]s like super_editor's stock serializer, but restores
/// the `|width` display width suffix: the markdown parser percent-encodes the
/// pipe of `![Image](./a.jpg|600)` into `%7C` inside the node's url, and the
/// note text must keep the original `|` form.
class GjImageSerializer
    extends NodeTypedDocumentNodeMarkdownSerializer<ImageNode> {
  const GjImageSerializer();

  @override
  String doSerialization(
    Document document,
    ImageNode node, {
    NodeSelection? selection,
  }) {
    if (selection != null) {
      if (selection is! UpstreamDownstreamNodeSelection) {
        return '';
      }
      if (selection.isCollapsed) {
        return '';
      }
    }
    final buffer =
        StringBuffer('![${node.altText}](${node.imageUrl.replaceAll('%7C', '|')})');
    // A blank line must follow the image so that the next node starts its
    // own block (the framework only writes a single newline between nodes).
    final nodeIndex = document.getNodeIndexById(node.id);
    if (nodeIndex != document.nodeCount - 1) {
      buffer.writeln('');
    }
    return buffer.toString();
  }
}

/// Serializes [HorizontalRuleNode]s as `---` with the surrounding blank
/// lines the stock serializer drops.
class GjHorizontalRuleSerializer
    extends NodeTypedDocumentNodeMarkdownSerializer<HorizontalRuleNode> {
  const GjHorizontalRuleSerializer();

  @override
  String doSerialization(
    Document document,
    HorizontalRuleNode node, {
    NodeSelection? selection,
  }) {
    if (selection != null) {
      if (selection is! UpstreamDownstreamNodeSelection) {
        return '';
      }
      if (selection.isCollapsed) {
        return '';
      }
    }
    final buffer = StringBuffer('---');
    final nodeIndex = document.getNodeIndexById(node.id);
    if (nodeIndex != document.nodeCount - 1) {
      buffer.writeln('');
    }
    return buffer.toString();
  }
}

/// Serializes [AttributedText] to markdown inline syntax, keeping `~~` for
/// strikethrough. Ported from super_editor_markdown's
/// AttributedTextMarkdownSerializer.
class GjAttributedTextEncoder extends AttributionVisitor {
  late String _fullText;
  late StringBuffer _buffer;
  late int _bufferCursor;

  String serialize(AttributedText attributedText) {
    _fullText = attributedText.toPlainText();
    _buffer = StringBuffer();
    _bufferCursor = 0;
    if (_fullText.isNotEmpty) {
      attributedText.visitAttributions(this);
    }
    return _buffer.toString();
  }

  @override
  void visitAttributions(
    AttributedText fullText,
    int index,
    Set<Attribution> startingAttributions,
    Set<Attribution> endingAttributions,
  ) {
    _writeTextToBuffer(fullText.toPlainText().substring(_bufferCursor, index));

    if (startingAttributions.isNotEmpty) {
      final markdownStyles =
          _encodeStyles(startingAttributions, AttributionVisitEvent.start);
      final linkMarker =
          _encodeLinkMarker(startingAttributions, AttributionVisitEvent.start);

      _buffer
        ..write(linkMarker)
        ..write(markdownStyles);
    }

    _writeTextToBuffer(_fullText[index]);
    _bufferCursor = index + 1;

    if (endingAttributions.isNotEmpty) {
      final markdownStyles =
          _encodeStyles(endingAttributions, AttributionVisitEvent.end);
      final linkMarker =
          _encodeLinkMarker(endingAttributions, AttributionVisitEvent.end);

      _buffer
        ..write(markdownStyles)
        ..write(linkMarker);
    }
  }

  @override
  void onVisitEnd() {
    if (_bufferCursor <= _fullText.length - 1) {
      _writeTextToBuffer(_fullText.substring(_bufferCursor));
    }
  }

  /// Separates multiple lines in a single paragraph with two spaces before
  /// each line break (markdown hard line break), matching upstream behavior.
  void _writeTextToBuffer(String text) {
    final lines = text.split('\n');
    for (int i = 0; i < lines.length; i++) {
      if (i > 0) {
        _buffer
          ..write('  ')
          ..write('\n');
      }
      _buffer.write(lines[i]);
    }
  }

  static String _encodeStyles(
      Set<Attribution> attributions, AttributionVisitEvent event) {
    const startOrder = [
      codeAttribution,
      boldAttribution,
      italicsAttribution,
      strikethroughAttribution,
      underlineAttribution,
    ];

    final buffer = StringBuffer();
    final encodingOrder =
        event == AttributionVisitEvent.start ? startOrder : startOrder.reversed;

    for (final attribution in encodingOrder) {
      if (attributions.contains(attribution)) {
        buffer.write(_encodeMarker(attribution));
      }
    }
    return buffer.toString();
  }

  static String _encodeMarker(Attribution attribution) {
    if (attribution == codeAttribution) {
      return '`';
    } else if (attribution == boldAttribution) {
      return '**';
    } else if (attribution == italicsAttribution) {
      return '*';
    } else if (attribution == strikethroughAttribution) {
      // GitJournal renders `~~text~~`; keep the double tilde stable.
      return '~~';
    } else if (attribution == underlineAttribution) {
      return '¬';
    }
    return '';
  }

  static String _encodeLinkMarker(
      Set<Attribution> attributions, AttributionVisitEvent event) {
    final links = attributions.whereType<LinkAttribution>();
    if (links.isNotEmpty) {
      final link = links.first;
      if (event == AttributionVisitEvent.start) {
        return '[';
      }
      return '](${link.plainTextUri})';
    }
    return '';
  }
}

String _textToMarkdown(AttributedText text, TextNodeSelection? selection) {
  if (selection == null) {
    return GjAttributedTextEncoder().serialize(text);
  }
  return GjAttributedTextEncoder()
      .serialize(text.copyText(selection.start, selection.end));
}

/// Serializes [ParagraphNode]s (plain paragraphs, headers, blockquotes and
/// inline code blocks). Replaces super_editor's ParagraphNodeSerializer +
/// HeaderNodeSerializer so that the inline styles go through
/// [GjAttributedTextEncoder].
class GjParagraphSerializer
    extends NodeTypedDocumentNodeMarkdownSerializer<ParagraphNode> {
  const GjParagraphSerializer();

  @override
  String doSerialization(
    Document document,
    ParagraphNode node, {
    NodeSelection? selection,
  }) {
    if (selection != null && selection is! TextNodeSelection) {
      return '';
    }
    final textSelection = selection as TextNodeSelection?;
    if (textSelection != null && textSelection.isCollapsed) {
      return '';
    }

    final buffer = StringBuffer();
    final inlineMarkdown =
        _textToMarkdown(node.text, textSelection);

    final Attribution? blockType = node.getMetadataValue('blockType');
    if (blockType == header1Attribution) {
      buffer.write('# $inlineMarkdown');
    } else if (blockType == header2Attribution) {
      buffer.write('## $inlineMarkdown');
    } else if (blockType == header3Attribution) {
      buffer.write('### $inlineMarkdown');
    } else if (blockType == header4Attribution) {
      buffer.write('#### $inlineMarkdown');
    } else if (blockType == header5Attribution) {
      buffer.write('##### $inlineMarkdown');
    } else if (blockType == header6Attribution) {
      buffer.write('###### $inlineMarkdown');
    } else if (blockType == blockquoteAttribution) {
      buffer.write('> $inlineMarkdown');
    } else if (blockType == codeAttribution) {
      buffer
        ..writeln('```')
        ..writeln(inlineMarkdown)
        ..write('```');
    } else {
      buffer.write(inlineMarkdown);
    }

    final nodeIndex = document.getNodeIndexById(node.id);
    if (nodeIndex != document.nodeCount - 1) {
      buffer.writeln();
    }

    return buffer.toString();
  }
}

/// Serializes [ListItemNode]s keeping `- ` for unordered items and the real
/// ordinal for ordered items. The ordinal is computed per serialization pass
/// by counting consecutive ordered items - lists not starting at `1.` will
/// produce a different serialization and fall back to the plain text editor
/// via the roundtrip check.
class GjListItemSerializer
    extends NodeTypedDocumentNodeMarkdownSerializer<ListItemNode> {
  GjListItemSerializer();

  // Valid within a single serialization pass only (see
  // [serializeGitJournalDocument] which creates fresh instances).
  String? _lastOrderedNodeId;
  int _lastOrdinal = 0;

  @override
  String doSerialization(
    Document document,
    ListItemNode node, {
    NodeSelection? selection,
  }) {
    if (selection != null && selection is! TextNodeSelection) {
      return '';
    }
    final textSelection = selection as TextNodeSelection?;
    if (textSelection != null && textSelection.isCollapsed) {
      return '';
    }

    final inlineMarkdown = _textToMarkdown(node.text, textSelection);

    final indent = '  ' * node.indent;
    String symbol;
    if (node.type == ListItemType.unordered) {
      symbol = '-';
      _lastOrderedNodeId = null;
      _lastOrdinal = 0;
    } else {
      final prev = document.getNodeIndexById(node.id) > 0
          ? document.getNodeAt(document.getNodeIndexById(node.id) - 1)
          : null;
      if (prev != null && prev.id == _lastOrderedNodeId) {
        _lastOrdinal += 1;
      } else {
        _lastOrdinal = 1;
      }
      _lastOrderedNodeId = node.id;
      symbol = '$_lastOrdinal.';
    }

    final buffer = StringBuffer('$indent$symbol $inlineMarkdown');

    final nodeIndex = document.getNodeIndexById(node.id);
    final nodeBelow = nodeIndex < document.nodeCount - 1
        ? document.getNodeAt(nodeIndex + 1)
        : null;
    // Task items are serialized without a separating blank line so that a
    // mixed list stays tight: `- item\n- [ ] task`.
    if (nodeBelow != null &&
        nodeBelow is! TaskNode &&
        (nodeBelow is! ListItemNode || nodeBelow.type != node.type)) {
      buffer.writeln('');
    }

    return buffer.toString();
  }
}

/// Serializes [TaskNode]s as `- [x]` / `- [ ]`, same as upstream, but with
/// the GitJournal inline encoder.
class GjTaskSerializer
    extends NodeTypedDocumentNodeMarkdownSerializer<TaskNode> {
  const GjTaskSerializer();

  @override
  String doSerialization(
    Document document,
    TaskNode node, {
    NodeSelection? selection,
  }) {
    if (selection != null && selection is! TextNodeSelection) {
      return '';
    }
    final textSelection = selection as TextNodeSelection?;
    if (textSelection != null && textSelection.isCollapsed) {
      return '';
    }

    final inlineMarkdown = _textToMarkdown(node.text, textSelection);
    final buffer =
        StringBuffer('- [${node.isComplete ? 'x' : ' '}] $inlineMarkdown');

    // Tasks never add a trailing blank line in the stock serializer, which
    // merges the following block into the task list. Keep the blank line
    // that separated the task list from the next block.
    final nodeIndex = document.getNodeIndexById(node.id);
    final nodeBelow = nodeIndex < document.nodeCount - 1
        ? document.getNodeAt(nodeIndex + 1)
        : null;
    if (nodeBelow != null && nodeBelow is! TaskNode) {
      buffer.writeln('');
    }

    return buffer.toString();
  }
}
