/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:gitjournal/app/theme/expressive_motion.dart';
import 'package:gitjournal/l10n.dart';
import 'package:gitjournal/markdown/gj_markdown_serializers.dart';
import 'package:gitjournal/utils/markdown.dart';
import 'package:gitjournal/widgets/expressive_image_frame.dart';
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

class SuperEditorBodyState extends State<SuperEditorBody>
    with TickerProviderStateMixin {
  late MutableDocument _document;
  late MutableDocumentComposer _composer;
  late Editor _editor;

  /// Locates the laid-out document for selection-rect queries (format toolbar
  /// positioning).
  final GlobalKey _documentLayoutKey = GlobalKey();

  Timer? _debounceTimer;

  // Set while we push serialized markdown into the text controller so the
  // controller listener knows not to reload the document.
  bool _writingToController = false;

  // 选区格式工具栏（浮条）状态。见 _showSelectionToolbar。
  OverlayEntry? _toolbarEntry;
  AnimationController? _toolbarFade;
  ScrollableState? _trackedScrollable;

  @override
  void initState() {
    super.initState();
    _loadDocument(widget.textController.text, initial: true);
    widget.textController.addListener(_onControllerChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // The outer CustomScrollView owns scrolling; while the toolbar is up it
    // must follow the content, so track the scroll position.
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable != _trackedScrollable) {
      _trackedScrollable?.position.removeListener(_onSelectionVisualChange);
      _trackedScrollable = scrollable;
      _trackedScrollable?.position.addListener(_onSelectionVisualChange);
    }
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
    _trackedScrollable?.position.removeListener(_onSelectionVisualChange);
    _toolbarEntry?.remove();
    _toolbarEntry = null;
    _toolbarFade?.dispose();
    _toolbarFade = null;
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
      composer.selectionNotifier.addListener(_onSelectionChanged);
    } else {
      // Order matters here. The old SuperEditor widget is only removed from
      // the tree by this frame's rebuild, and until then its
      // EditorSelectionAndFocusPolicy keeps listening to focus changes and
      // pushing them into its composer. Disposing the old composer
      // synchronously therefore crashes with "Bad state: Cannot add new
      // events after calling close" as soon as a focus change arrives (seen
      // on phones where the app oscillates inactive <-> resumed every
      // second).
      //
      // 1) Drop the primary focus first, while the old editor can still
      //    process the resulting change. Only when the focus is actually
      //    inside this editor - don't steal it from the title field on
      //    unrelated external reloads.
      final primaryFocus = FocusManager.instance.primaryFocus;
      final focusContext = primaryFocus?.context;
      if (focusContext != null &&
          focusContext.findAncestorStateOfType<SuperEditorBodyState>() ==
              this) {
        primaryFocus!.unfocus();
      }
      setState(() {
        _document = document;
        _composer = composer;
        _editor = editor;
      });
      composer.selectionNotifier.addListener(_onSelectionChanged);
      // The reload resets the selection; the toolbar follows what the new
      // composer reports (hidden - it starts collapsed).
      _onSelectionChanged();
      // 2) Dispose only after the frame ended: the framework has unmounted
      //    the old SuperEditor widget by then, so no further events can
      //    reach the old composer.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldEditor!.dispose();
        oldComposer!.dispose();
      });
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
        documentLayoutKey: _documentLayoutKey,
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

  // ---------------------------------------------------------------------------
  // 选区格式工具栏：选中正文文字时在选区上方浮出小型格式条（加粗/斜体/删除线/
  // 标题）。浮条走 Overlay 定位在选区上方并跟随选区与滚动；绝不走 BottomSheet
  // 或新路由（会抢焦点收键盘）。键盘收起或选区清空即隐藏。
  // ---------------------------------------------------------------------------

  /// Whether the current selection is expanded over document text.
  bool get _hasExpandedSelection {
    final selection = _composer.selection;
    return selection != null && !selection.isCollapsed;
  }

  /// Global bounding box of the current selection, or null when it can't be
  /// determined (nothing laid out, image-only selection, ...).
  Rect? _selectionGlobalRect() {
    final selection = _composer.selection;
    if (selection == null || selection.isCollapsed) return null;

    final layout = _documentLayoutKey.currentState as DocumentLayout?;
    if (layout == null) return null;

    final rect =
        layout.getRectForSelection(selection.base, selection.extent);
    if (rect == null) return null;

    final topLeft = layout.getGlobalOffsetFromDocumentOffset(rect.topLeft);
    final bottomRight = layout.getGlobalOffsetFromDocumentOffset(rect.bottomRight);
    return Rect.fromLTRB(
      topLeft.dx,
      topLeft.dy,
      bottomRight.dx,
      bottomRight.dy,
    );
  }

  void _onSelectionChanged() {
    if (!mounted) return;
    if (_hasExpandedSelection) {
      _showSelectionToolbar();
    } else {
      _hideSelectionToolbar();
    }
  }

  /// Selection moved or content scrolled: reposition the visible toolbar.
  void _onSelectionVisualChange() {
    if (!mounted) return;
    if (_toolbarEntry != null) {
      _toolbarEntry!.markNeedsBuild();
    }
  }

  void _showSelectionToolbar() {
    final fade = _toolbarFade;
    if (_toolbarEntry != null && fade != null) {
      // Already showing: just reposition.
      _toolbarEntry!.markNeedsBuild();
      if (fade.status != AnimationStatus.forward &&
          fade.status != AnimationStatus.completed) {
        fade.forward();
      }
      return;
    }

    // 出现/消失走批次二 motion token 的 medium 档淡入（浮条非玻璃，普通
    // Opacity 即可）；减少动态效果时 duration 为 0，直接到位。
    final controller = AnimationController(
      vsync: this,
      duration: ExpressiveMotion.duration(context, ExpressiveMotion.medium),
    );
    controller.value = controller.duration == Duration.zero ? 1 : 0;
    if (controller.value == 0) controller.forward();
    _toolbarFade = controller;

    final entry = OverlayEntry(
      builder: (entryContext) {
        final globalRect = _selectionGlobalRect();
        if (globalRect == null) return const SizedBox.shrink();

        // The entry lives in the Overlay's Stack: convert the global selection
        // rect into that coordinate space.
        final overlayBox =
            Overlay.of(entryContext).context.findRenderObject() as RenderBox?;
        if (overlayBox == null || !overlayBox.attached) {
          return const SizedBox.shrink();
        }
        final rect = Rect.fromLTRB(
          overlayBox.globalToLocal(globalRect.topLeft).dx,
          overlayBox.globalToLocal(globalRect.topLeft).dy,
          overlayBox.globalToLocal(globalRect.bottomRight).dx,
          overlayBox.globalToLocal(globalRect.bottomRight).dy,
        );

        final padding = MediaQuery.paddingOf(entryContext);
        // Above the selection, or below it when there's no room at the top.
        var top = rect.top - _toolbarBarHeight - _toolbarEdgeMargin;
        if (top < padding.top + _toolbarEdgeMargin) {
          top = rect.bottom + _toolbarEdgeMargin;
        }

        return Positioned(
          top: top,
          left: 0,
          right: 0,
          child: Align(
            alignment: Alignment.topCenter,
            child: FadeTransition(
              opacity: CurvedAnimation(
                parent: controller,
                curve: ExpressiveMotion.effects,
              ),
              child: _KeyboardDismissWatcher(
                onKeyboardDismissed: _hideSelectionToolbar,
                child: SelectionFormatToolbar(
                  onBold: () => _toggleInlineAttribution(boldAttribution),
                  onItalic: () => _toggleInlineAttribution(italicsAttribution),
                  onStrikethrough: () =>
                      _toggleInlineAttribution(strikethroughAttribution),
                  onHeading: _toggleHeading,
                ),
              ),
            ),
          ),
        );
      },
    );

    _toolbarEntry = entry;
    Overlay.of(context).insert(entry);
  }

  void _hideSelectionToolbar() {
    final fade = _toolbarFade;
    final entry = _toolbarEntry;
    if (entry == null || fade == null) return;
    _toolbarEntry = null;
    _toolbarFade = null;

    void teardown() {
      fade.dispose();
      entry.remove();
    }

    if (!mounted || fade.duration == Duration.zero) {
      teardown();
      return;
    }
    // If the State is disposed mid-reverse, the controller's ticker is
    // disposed with it and the TickerFuture never completes - no callback
    // runs on a disposed controller.
    fade.reverse().whenComplete(teardown);
  }

  void _toggleInlineAttribution(Attribution attribution) {
    final selection = _composer.selection;
    if (selection == null || selection.isCollapsed) return;

    // ToggleTextAttributionsRequest covers multi-node selections on its own.
    _editor.execute([
      ToggleTextAttributionsRequest(
        documentRange: selection,
        attributions: {attribution},
      ),
    ]);
  }

  /// Toggles the `#` heading line style on every paragraph covered by the
  /// selection: a header reverts to a plain paragraph, anything else becomes
  /// a header.
  void _toggleHeading() {
    final selection = _composer.selection;
    if (selection == null) return;

    final requests = <EditRequest>[];
    for (final node
        in _editor.document.getNodesInside(selection.base, selection.extent)) {
      if (node is! ParagraphNode) continue;
      final isHeader =
          node.getMetadataValue('blockType') == header1Attribution;
      requests.add(ChangeParagraphBlockTypeRequest(
        nodeId: node.id,
        blockType: isHeader ? paragraphAttribution : header1Attribution,
      ));
    }
    if (requests.isNotEmpty) {
      _editor.execute(requests);
    }
  }
}

const _toolbarBarHeight = 44.0;
const _toolbarEdgeMargin = 8.0;

/// Hides the toolbar the moment the keyboard goes down (viewInsets bottom
/// transitions from > 0 to 0). The selection clearing hides it too, via the
/// composer listener in [SuperEditorBodyState].
class _KeyboardDismissWatcher extends StatefulWidget {
  final VoidCallback onKeyboardDismissed;
  final Widget child;

  const _KeyboardDismissWatcher({
    required this.onKeyboardDismissed,
    required this.child,
  });

  @override
  State<_KeyboardDismissWatcher> createState() =>
      _KeyboardDismissWatcherState();
}

class _KeyboardDismissWatcherState extends State<_KeyboardDismissWatcher> {
  double? _lastKeyboardBottom;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final last = _lastKeyboardBottom;
    _lastKeyboardBottom = bottom;
    if (last != null && last > 0 && bottom == 0) {
      widget.onKeyboardDismissed();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 小型选区格式条：B / I / S / 标题 四个按钮，作用于 markdown inline 标记
/// （**bold**、*italic*、~~strike~~）与 `#` 标题行 —— 全部经 super_editor 的
/// style API，序列化由 GjParagraphSerializer/GjAttributedTextEncoder 保证
/// markdown 往返稳定。
///
/// ponytail: 按钮不带选中态高亮（需逐节点查询 attribution），需要时再加。
class SelectionFormatToolbar extends StatelessWidget {
  final VoidCallback onBold;
  final VoidCallback onItalic;
  final VoidCallback onStrikethrough;
  final VoidCallback onHeading;

  const SelectionFormatToolbar({
    super.key,
    required this.onBold,
    required this.onItalic,
    required this.onStrikethrough,
    required this.onHeading,
  });

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      // 浮条绝不抢焦点：抢了焦点键盘就收，选区也随之清空（jotsy 教训）。
      canRequestFocus: false,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(10),
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SizedBox(
            height: _toolbarBarHeight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: context.loc.selectionToolbarBold,
                  icon: const Icon(Icons.format_bold),
                  onPressed: onBold,
                ),
                IconButton(
                  tooltip: context.loc.selectionToolbarItalic,
                  icon: const Icon(Icons.format_italic),
                  onPressed: onItalic,
                ),
                IconButton(
                  tooltip: context.loc.selectionToolbarStrikethrough,
                  icon: const Icon(Icons.strikethrough_s),
                  onPressed: onStrikethrough,
                ),
                IconButton(
                  tooltip: context.loc.selectionToolbarHeading,
                  icon: const Icon(Icons.title),
                  onPressed: onHeading,
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
/// note folder with the `|width` url suffix honored (as a *maximum* width:
/// smaller images render at their natural size). Very tall images (>3:1)
/// fold into a 2:3 box showing only their top, with a badge; tapping the
/// folded image opens a full screen viewer. Unfolded, tapping toggles
/// between full width and thumbnail width (the write-back happens through
/// [GjImageScope.onImageWidthChange]).
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
  // Intrinsic size of the decoded image, for the long-image fold decision.
  // Filled synchronously when the image is cached, otherwise through the
  // image stream.
  ui.Image? _decodedImage;
  String? _decodedPath;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;

  void _listenForImageSize(String imagePath, ImageProvider? provider) {
    if (_decodedPath == imagePath) return;
    if (_imageListener != null) {
      _imageStream?.removeListener(_imageListener!);
      _imageStream = null;
      _imageListener = null;
    }
    if (provider == null) return;

    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener((info, synchronousCall) {
      if (!mounted || _decodedPath == imagePath) return;
      void apply() {
        _decodedImage = info.image;
        _decodedPath = imagePath;
      }

      if (synchronousCall) {
        // Inside build: just update the fields, this build still uses them.
        apply();
      } else {
        setState(apply);
      }
    });
    stream.addListener(listener);
    _imageStream = stream;
    _imageListener = listener;
  }

  @override
  void dispose() {
    if (_imageListener != null) {
      _imageStream?.removeListener(_imageListener!);
    }
    super.dispose();
  }

  bool get _isLongImage {
    final image = _decodedImage;
    return image != null && image.height > image.width * 3;
  }

  ImageProvider? _resolveImageProvider(String imagePath) {
    if (imagePath.startsWith('http://') || imagePath.startsWith('https://')) {
      return NetworkImage(imagePath);
    }
    var filePath = imagePath;
    if (!p.isAbsolute(filePath)) {
      filePath = p.join(GjImageScope.of(context).imageDir, filePath);
    }
    final file = File(filePath);
    if (file.existsSync()) {
      return FileImage(file);
    }
    return null;
  }

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
      // `|width` is a maximum width: smaller images keep their natural size,
      // larger ones scale down to fit. No suffix: the full column width.
      final displayMaxWidth =
          (width != null ? math.min(width, maxWidth) : maxWidth)
              .clamp(1.0, double.infinity);

      final provider = _resolveImageProvider(imagePath);
      _listenForImageSize(imagePath, provider);
      final isLongImage = _isLongImage;

      // The inner tap recognizer sits deeper in the tree than the document
      // gesture system's, so it wins the arena. (opaque: BoxComponent 链不参与
      // 命中测试，deferToChild 会让整个点击丢失。)
      return BoxComponent(
        key: widget.componentKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: isLongImage
              ? () => _openFullScreen(context, provider)
              : () {
                  // 上限语义：自然宽 ≤ 缩略图宽的图片，|240 切换没有视觉
                  // 变化——跳过并提示，避免"点了没反应"的死按钮感。
                  final natural = _decodedImage;
                  if (natural != null && natural.width <= 240) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(context.loc.imageToggleSkippedSmall),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                    return;
                  }
                  GjImageScope.of(context).onImageWidthChange(widget.nodeId);
                },
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: displayMaxWidth),
              child: isLongImage
                  ? _buildFoldedImage(provider!, displayMaxWidth, theme)
                  : _buildImage(provider, theme),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildImage(ImageProvider? provider, ThemeData theme) {
    if (provider == null) {
      return Container(
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
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      frameBuilder: expressiveImageFrameBuilder,
      errorBuilder: (context, error, stackTrace) => Container(
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

  /// A 2:3 box (width:height) showing only the top of the long image, with
  /// a badge in the bottom right corner. Tapping opens the full screen
  /// viewer. The `|width` toggle keeps acting on the display constraint.
  Widget _buildFoldedImage(
      ImageProvider provider, double displayMaxWidth, ThemeData theme) {
    return Stack(
      children: [
        SizedBox(
          width: displayMaxWidth,
          height: displayMaxWidth * 1.5,
          child: ClipRect(
            child: Image(
              image: provider,
              fit: BoxFit.fitWidth,
              alignment: Alignment.topCenter,
            ),
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: _LongImageBadge(theme: theme),
        ),
      ],
    );
  }

  void _openFullScreen(BuildContext context, ImageProvider? provider) {
    if (provider == null) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => _FullScreenImageViewer(image: provider),
      ),
    );
  }
}

class _LongImageBadge extends StatelessWidget {
  final ThemeData theme;

  const _LongImageBadge({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        context.loc.widgetsLongImageBadge,
        style: theme.textTheme.labelSmall,
      ),
    );
  }
}

/// Full screen viewer for folded (long) images in the rich editor: pinch to
/// zoom, drag to pan.
class _FullScreenImageViewer extends StatelessWidget {
  final ImageProvider image;

  const _FullScreenImageViewer({required this.image});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 8.0,
          child: Image(image: image),
        ),
      ),
    );
  }
}
