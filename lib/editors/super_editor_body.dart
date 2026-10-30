/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gitjournal/markdown/gj_markdown_serializers.dart';
import 'package:gitjournal/utils/markdown.dart';
import 'package:path/path.dart' as p;
import 'package:super_editor/super_editor.dart';
import 'package:universal_io/io.dart';

/// WYSIWYG markdown body editor built on super_editor.
///
/// The plain-text [TextEditingController] stays the single source of truth:
///  - on start the body markdown is deserialized into a document;
///  - document edits are serialized back (debounced) into the controller;
///  - controller changes that were not caused by us (image insertion from the
///    attachment bar, undo, search replace) reload the whole document.
///
/// Known v1 limitations (by design, documented in the editor integration):
///  - reloading on external changes resets the caret to the document start;
///  - undo granularity follows the serialization debounce interval;
///  - search highlighting is not rendered (find still works, it operates on
///    the plain markdown text).
class SuperEditorBody extends StatefulWidget {
  final TextEditingController textController;

  /// Absolute path of the folder containing the note, used to resolve
  /// relative image paths.
  final String imageDir;
  final bool autofocus;
  final VoidCallback onChanged;

  /// Called with the document-order index of the tapped image node. The
  /// parent toggles the `|240` thumbnail suffix in the markdown text.
  final void Function(int imageIndex)? onImageWidthChange;

  const SuperEditorBody({
    super.key,
    required this.textController,
    required this.imageDir,
    required this.autofocus,
    required this.onChanged,
    this.onImageWidthChange,
  });

  @override
  State<SuperEditorBody> createState() => SuperEditorBodyState();
}

class SuperEditorBodyState extends State<SuperEditorBody> {
  late MutableDocument _document;
  late MutableDocumentComposer _composer;
  late Editor _editor;

  Timer? _debounceTimer;

  // Set while we push serialized markdown into the text controller so the
  // controller listener knows not to reload the document.
  bool _writingToController = false;

  @override
  void initState() {
    super.initState();
    _loadDocument(widget.textController.text, initial: true);
    widget.textController.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(SuperEditorBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.textController != widget.textController) {
      oldWidget.textController.removeListener(_onControllerChanged);
      widget.textController.addListener(_onControllerChanged);
      _loadDocument(widget.textController.text);
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    widget.textController.removeListener(_onControllerChanged);
    _editor.dispose();
    _composer.dispose();
    super.dispose();
  }

  void _loadDocument(String markdown, {bool initial = false}) {
    _debounceTimer?.cancel();
    _debounceTimer = null;

    final oldEditor = initial ? null : _editor;
    final oldComposer = initial ? null : _composer;
    final document = deserializeGitJournalMarkdown(markdown);
    final composer = MutableDocumentComposer();
    final editor = createDefaultDocumentEditor(
      document: document,
      composer: composer,
      // Undo/redo stays in the parent's text level UndoRedoStack.
      isHistoryEnabled: false,
    );
    editor.addListener(FunctionalEditListener(_onEditorChanged));

    if (initial) {
      _document = document;
      _composer = composer;
      _editor = editor;
    } else {
      setState(() {
        _document = document;
        _composer = composer;
        _editor = editor;
      });
      oldEditor!.dispose();
      oldComposer!.dispose();
    }
  }

  /// Serializes the document back into the text controller if a debounced
  /// write is pending. Called by the parent before it reads the note for
  /// saving, so the last keystrokes can't be lost.
  void flushPendingWrite() {
    if (_debounceTimer?.isActive != true) return;
    _writeBack(deferParentCallback: true);
  }

  /// Inserts an image node for [relativeImagePath] at the current caret and
  /// moves the caret after it. This is the rich editor's image insertion
  /// path: it edits the document directly instead of going through the text
  /// controller, whose selection is a stale serialization artifact and whose
  /// "external change" reload raced the 300ms write-back (images needed
  /// several attempts to stick).
  void insertImageNode(String relativeImagePath) {
    final imageNode = ImageNode(
      id: Editor.createNodeId(),
      imageUrl: relativeImagePath,
      altText: 'Image',
    );

    final selection = _composer.selection;
    final anchorId = selection?.extent.nodeId;
    final anchor = anchorId != null
        ? _document.getNodeById(anchorId)
        : _document.nodeCount > 0
            ? _document.getNodeAt(_document.nodeCount - 1)
            : null;

    if (selection != null &&
        anchor != null &&
        selection.base.nodeId == selection.extent.nodeId &&
        anchor is ParagraphNode) {
      // Stock caret insertion: splits the paragraph when needed, moves the
      // caret onto a fresh paragraph below the image.
      _editor.execute([InsertNodeAtCaretRequest(node: imageNode)]);
      return;
    }

    // Fallback: the caret API is a no-op without a selection anchored inside
    // a single paragraph (nothing focused yet, an image selected, ...).
    // Insert after the anchor node (or at the end) and park the caret on a
    // fresh paragraph below the image so further inserts keep working.
    final requests = <EditRequest>[];
    DocumentSelection caretTarget;
    if (anchor == null) {
      final below = _emptyParagraph();
      requests
        ..add(InsertNodeAtIndexRequest(nodeIndex: 0, newNode: imageNode))
        ..add(InsertNodeAtIndexRequest(nodeIndex: 1, newNode: below));
      caretTarget = DocumentSelection.collapsed(
        position: DocumentPosition(
          nodeId: below.id,
          nodePosition: below.endPosition,
        ),
      );
    } else {
      final below = _emptyParagraph();
      requests
        ..add(InsertNodeAfterNodeRequest(
          existingNodeId: anchor.id,
          newNode: imageNode,
        ))
        ..add(InsertNodeAfterNodeRequest(
          existingNodeId: imageNode.id,
          newNode: below,
        ));
      caretTarget = DocumentSelection.collapsed(
        position: DocumentPosition(
          nodeId: below.id,
          nodePosition: below.endPosition,
        ),
      );
    }
    requests.add(ChangeSelectionRequest(
      caretTarget,
      SelectionChangeType.insertContent,
      SelectionReason.userInteraction,
    ));
    _editor.execute(requests);
  }

  ParagraphNode _emptyParagraph() =>
      ParagraphNode(id: Editor.createNodeId(), text: AttributedText());

  void _onEditorChanged(List<EditEvent> changeLog) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), _writeBack);
  }

  void _writeBack({bool deferParentCallback = false}) {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (!mounted) return;

    final markdown = serializeGitJournalDocument(_editor.document);
    if (markdown != widget.textController.text) {
      _writingToController = true;
      widget.textController.value = TextEditingValue(
        text: markdown,
        selection: TextSelection.collapsed(offset: markdown.length),
        composing: TextRange.empty,
      );
      _writingToController = false;
      if (deferParentCallback) {
        // getNote() runs during parent builds; defer the callback so the
        // parent's setState happens outside the build phase.
        scheduleMicrotask(() {
          if (mounted) widget.onChanged();
        });
      } else {
        widget.onChanged();
      }
    }
  }

  void _onControllerChanged() {
    if (_writingToController) return;
    // External change (image insertion, undo, search): reload everything.
    // v1: this resets the caret to the start of the document.
    _loadDocument(widget.textController.text);
  }

  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);

    return GjImageScope(
      imageDir: widget.imageDir,
      onImageWidthChange: _onImageWidthChange,
      child: SuperEditor(
        editor: _editor,
        autofocus: widget.autofocus,
        // The outer CustomScrollView owns scrolling.
        shrinkWrap: true,
        stylesheet: _buildStylesheet(theme),
        componentBuilders: [
          const GjImageComponentBuilder(),
          ...defaultComponentBuilders,
          TaskComponentBuilder(_editor),
        ],
      ),
    );
  }

  void _onImageWidthChange(String nodeId) {
    final nodes = _document.toList(growable: false);
    var imageIndex = 0;
    for (final node in nodes) {
      if (node is! ImageNode) continue;
      if (node.id == nodeId) {
        widget.onImageWidthChange?.call(imageIndex);
        return;
      }
      imageIndex++;
    }
  }
}

/// Text styles matching the app theme. The paragraph style mirrors
/// [NoteBodyEditor]'s titleMedium style so the rich body doesn't look out of
/// place next to the title field.
Stylesheet _buildStylesheet(ThemeData theme) {
  TextStyle base = theme.textTheme.titleMedium ?? const TextStyle(fontSize: 16);
  base = base.copyWith(height: 1.45);

  TextStyle header(double factor, double spacing) => base.copyWith(
        fontSize: (base.fontSize ?? 16) * factor,
        fontWeight: FontWeight.bold,
        height: 1.3,
      );

  return Stylesheet(
    rules: [
      StyleRule(
        BlockSelector.all,
        (doc, docNode) => {
          Styles.textStyle: TextStyle(
            color: base.color ?? theme.colorScheme.onSurface,
            fontSize: base.fontSize,
            fontFamily: base.fontFamily,
            height: base.height,
          ),
          Styles.maxWidth: double.infinity,
        },
      ),
      StyleRule(
        const BlockSelector("header1"),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 16),
          Styles.textStyle: header(1.9, 16),
        },
      ),
      StyleRule(
        const BlockSelector("header2"),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 16),
          Styles.textStyle: header(1.5, 12),
        },
      ),
      StyleRule(
        const BlockSelector("header3"),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 16),
          Styles.textStyle: header(1.3, 8),
        },
      ),
      StyleRule(
        const BlockSelector("header4"),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 16),
          Styles.textStyle: header(1.15, 8),
        },
      ),
      StyleRule(
        const BlockSelector("header5"),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 16),
          Styles.textStyle: header(1.05, 8),
        },
      ),
      StyleRule(
        const BlockSelector("header6"),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 16),
          Styles.textStyle: header(1.0, 8),
        },
      ),
      StyleRule(
        const BlockSelector("paragraph"),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 8),
        },
      ),
      StyleRule(
        const BlockSelector("listItem"),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 8),
        },
      ),
      StyleRule(
        const BlockSelector("task"),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 8),
        },
      ),
      StyleRule(
        const BlockSelector("blockquote"),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(top: 8),
          Styles.textStyle: TextStyle(
            color: (base.color ?? theme.colorScheme.onSurface).withValues(alpha: 0.7),
            fontStyle: FontStyle.italic,
            fontSize: base.fontSize,
            height: base.height,
          ),
        },
      ),
      StyleRule(
        BlockSelector.all.last(),
        (doc, docNode) => {
          Styles.padding: const CascadingPadding.only(bottom: 24),
        },
      ),
    ],
    inlineTextStyler: defaultInlineTextStyler,
    inlineWidgetBuilders: defaultInlineWidgetBuilderChain,
  );
}

/// Provides the image resolution context to [GjImageComponent]s deep inside
/// the super_editor component tree.
class GjImageScope extends InheritedWidget {
  final String imageDir;
  final void Function(String nodeId) onImageWidthChange;

  const GjImageScope({
    super.key,
    required this.imageDir,
    required this.onImageWidthChange,
    required super.child,
  });

  static GjImageScope of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<GjImageScope>();
    assert(scope != null, 'GjImageScope not found in context');
    return scope!;
  }

  @override
  bool updateShouldNotify(GjImageScope oldWidget) =>
      imageDir != oldWidget.imageDir;
}

/// Renders [ImageNode]s inline in the editor flow: local images from the
/// note folder with the `|width` url suffix honored. Tapping the image
/// toggles between full width and thumbnail width (the write-back happens
/// through [GjImageScope.onImageWidthChange]).
class GjImageComponentBuilder implements ComponentBuilder {
  const GjImageComponentBuilder();

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
      Document document, DocumentNode node) {
    if (node is! ImageNode) return null;

    return ImageComponentViewModel(
      nodeId: node.id,
      createdAt: node.metadata[NodeMetadata.createdAt],
      imageUrl: node.imageUrl,
      expectedSize: node.expectedBitmapSize,
      selectionColor: const Color(0x00000000),
    );
  }

  @override
  Widget? createComponent(
      SingleColumnDocumentComponentContext componentContext,
      SingleColumnLayoutComponentViewModel componentViewModel) {
    if (componentViewModel is! ImageComponentViewModel) return null;

    return GjImageComponent(
      componentKey: componentContext.componentKey,
      nodeId: componentViewModel.nodeId,
      imageUrl: componentViewModel.imageUrl,
    );
  }
}

class GjImageComponent extends StatefulWidget {
  final GlobalKey componentKey;
  final String nodeId;
  final String imageUrl;

  const GjImageComponent({
    super.key,
    required this.componentKey,
    required this.nodeId,
    required this.imageUrl,
  });

  @override
  State<GjImageComponent> createState() => _GjImageComponentState();
}

class _GjImageComponentState extends State<GjImageComponent> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final match = imageUrlWidthSuffixRegex.firstMatch(widget.imageUrl);
    var imagePath = widget.imageUrl;
    double? width;
    if (match != null) {
      imagePath = match.group(1)!;
      width = double.parse(match.group(2)!);
    }

    return LayoutBuilder(builder: (context, constraints) {
      final maxWidth = constraints.maxWidth;
      // No `|width` suffix: full width. With suffix: the requested width.
      final effectiveWidth = (width ?? maxWidth).clamp(40.0, maxWidth);

      // The inner tap recognizer sits deeper in the tree than the document
      // gesture system's, so it wins the arena: tap toggles thumbnail/full.
      return BoxComponent(
        key: widget.componentKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () =>
              GjImageScope.of(context).onImageWidthChange(widget.nodeId),
          child: Center(
            child: SizedBox(
              width: effectiveWidth,
              child: _buildImage(imagePath, effectiveWidth, theme),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildImage(String imagePath, double width, ThemeData theme) {
    final isNetwork =
        imagePath.startsWith('http://') || imagePath.startsWith('https://');

    ImageProvider? provider;
    if (isNetwork) {
      provider = NetworkImage(imagePath);
    } else {
      var filePath = imagePath;
      if (!p.isAbsolute(filePath)) {
        filePath = p.join(GjImageScope.of(context).imageDir, filePath);
      }
      final file = File(filePath);
      if (file.existsSync()) {
        provider = FileImage(file);
      }
    }

    if (provider == null) {
      return Container(
        width: width,
        padding: const EdgeInsets.all(16),
        color: theme.highlightColor.withValues(alpha: 0.3),
        child: Icon(
          Icons.broken_image,
          size: 36,
          color: theme.colorScheme.error,
        ),
      );
    }

    return Image(
      image: provider,
      width: width,
      fit: BoxFit.cover,
      alignment: Alignment.centerLeft,
      errorBuilder: (context, error, stackTrace) => Container(
        width: width,
        padding: const EdgeInsets.all(16),
        color: theme.highlightColor.withValues(alpha: 0.3),
        child: Icon(
          Icons.broken_image,
          size: 36,
          color: theme.colorScheme.error,
        ),
      ),
    );
  }
}
