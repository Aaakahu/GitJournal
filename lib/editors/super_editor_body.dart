/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:gitjournal/app/theme/expressive_motion.dart';
import 'package:gitjournal/l10n.dart';
import 'package:gitjournal/markdown/gj_markdown_serializers.dart';
import 'package:gitjournal/themes/glass_theme.dart';
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

  /// Called with the document-order index of the selected image node and the
  /// new display width, so the parent can precisely rewrite that markup's
  /// `|N` suffix (append when absent, remove on null - null means "full
  /// column width").
  final void Function(int imageIndex, double? widthOrNull)? onImageWidthSet;

  const SuperEditorBody({
    super.key,
    required this.textController,
    required this.imageDir,
    required this.autofocus,
    required this.onChanged,
    this.onImageWidthSet,
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

  // 长按选中图片的状态（苹果备忘录式交互）。见 _showImageMenu。
  final _ImageSelection _imageSelection = _ImageSelection();
  OverlayEntry? _imageMenuEntry;
  AnimationController? _imageMenuFade;
  bool _imageReloadPending = false;

  @override
  void initState() {
    super.initState();
    _imageSelection.onSelectRequest = _showImageMenu;
    _imageSelection.previewWidth.addListener(_onImageSelectionVisualChange);
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
      // The document is reloaded from the new controller below; a pending
      // image selection points at node ids that no longer exist.
      _hideImageMenu(reload: false);
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
    _imageMenuEntry?.remove();
    _imageMenuEntry = null;
    _imageMenuFade?.dispose();
    _imageMenuFade = null;
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
    // 图片选中期间（含滑块写回的瞬间），生命周期震荡等外部控制器写入不触发
    // 整篇重载——那会打散选中和菜单。先欠着，退出选中时统一比对补载。
    if (_imageSelection.selectedNodeId.value != null ||
        _imageMenuEntry != null) {
      _imageReloadPending = true;
      return;
    }
    // External change (image insertion, undo, search): reload everything.
    // v1: this resets the caret to the start of the document.
    _loadDocument(widget.textController.text);
  }

  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);

    return GjImageScope(
      imageDir: widget.imageDir,
      selection: _imageSelection,
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

  void _onImageWidthSet(String nodeId, double? widthOrNull) {
    final nodes = _document.toList(growable: false);
    var imageIndex = 0;
    for (final node in nodes) {
      if (node is! ImageNode) continue;
      if (node.id == nodeId) {
        widget.onImageWidthSet?.call(imageIndex, widthOrNull);
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

    final rect = layout.getRectForSelection(selection.base, selection.extent);
    if (rect == null) return null;

    final topLeft = layout.getGlobalOffsetFromDocumentOffset(rect.topLeft);
    final bottomRight =
        layout.getGlobalOffsetFromDocumentOffset(rect.bottomRight);
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

  /// Selection moved or content scrolled: reposition the visible toolbar /
  /// image menu.
  void _onSelectionVisualChange() {
    if (!mounted) return;
    if (_toolbarEntry != null) {
      _toolbarEntry!.markNeedsBuild();
    }
    if (_imageMenuEntry != null) {
      _imageMenuEntry!.markNeedsBuild();
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
      final isHeader = node.getMetadataValue('blockType') == header1Attribution;
      requests.add(ChangeParagraphBlockTypeRequest(
        nodeId: node.id,
        blockType: isHeader ? paragraphAttribution : header1Attribution,
      ));
    }
    if (requests.isNotEmpty) {
      _editor.execute(requests);
    }
  }

  // ---------------------------------------------------------------------------
  // 图片长按选中（苹果备忘录式）：长按图片 → 图片加账本黄描边 + 四角圆点手柄，
  // 并在图片正上方浮出玻璃菜单（查看大图 / 显示大小滑块 / 删除）。复用批次三
  // SelectionFormatToolbar 的 Overlay 定位骨架（跟随滚动、顶部放不下落到底部）。
  // ---------------------------------------------------------------------------

  /// Marks the overlay entry for rebuild so the menu follows the image on
  /// scroll. The component side pushes the change.
  void _onImageSelectionVisualChange() {
    if (!mounted) return;
    _imageMenuEntry?.markNeedsBuild();
  }

  void _showImageMenu() {
    final nodeId = _imageSelection.selectedNodeId.value;
    if (nodeId == null || !mounted) return;

    // 选中图片时收起键盘并清除文字选区：光标停止闪烁、输入法面板收起，
    // 注意力完整交给玻璃菜单（真机反馈：菜单呼出后键盘不收、光标仍闪）。
    FocusManager.instance.primaryFocus?.unfocus();
    _editor.execute(const [ClearSelectionRequest()]);
    final fade = _imageMenuFade;
    if (_imageMenuEntry != null && fade != null) {
      // Switching to another long-pressed image: just reposition.
      _imageMenuEntry!.markNeedsBuild();
      if (fade.status != AnimationStatus.forward &&
          fade.status != AnimationStatus.completed) {
        fade.forward();
      }
      return;
    }

    final controller = AnimationController(
      vsync: this,
      duration: ExpressiveMotion.duration(context, ExpressiveMotion.medium),
    );
    controller.value = controller.duration == Duration.zero ? 1 : 0;
    if (controller.value == 0) controller.forward();
    _imageMenuFade = controller;

    final entry = OverlayEntry(
      builder: (entryContext) {
        final globalRect = _imageSelection.rect();
        if (globalRect == null) return const SizedBox.shrink();

        final overlayBox =
            Overlay.of(entryContext).context.findRenderObject() as RenderBox?;
        if (overlayBox == null || !overlayBox.attached) {
          return const SizedBox.shrink();
        }
        Offset toOverlay(Offset o) => overlayBox.globalToLocal(o);
        final imageRect = Rect.fromLTRB(
          toOverlay(globalRect.topLeft).dx,
          toOverlay(globalRect.topLeft).dy,
          toOverlay(globalRect.bottomRight).dx,
          toOverlay(globalRect.bottomRight).dy,
        );

        const menuWidth = _imageMenuWidth;
        const menuHeight = _imageMenuHeight;
        final padding = MediaQuery.paddingOf(entryContext);
        final overlayWidth = overlayBox.size.width;
        // 图片正上方；顶部放不下则落到图片下方。水平方向跟随图片，出屏则收回。
        var top = imageRect.top - menuHeight - _toolbarEdgeMargin;
        if (top < padding.top + _toolbarEdgeMargin) {
          top = imageRect.bottom + _toolbarEdgeMargin;
        }
        var left = imageRect.center.dx - menuWidth / 2;
        left = left.clamp(
            _toolbarEdgeMargin,
            math.max(_toolbarEdgeMargin,
                overlayWidth - menuWidth - _toolbarEdgeMargin));
        final menuRect = Rect.fromLTWH(left, top, menuWidth, menuHeight);

        return Positioned.fill(
          child: _ImageMenuDismissListener(
            menuRect: menuRect,
            imageRect: imageRect,
            onDismiss: _hideImageMenu,
            child: Stack(
              children: [
                Positioned(
                  left: left,
                  top: top,
                  child: FadeTransition(
                    opacity: CurvedAnimation(
                      parent: controller,
                      curve: ExpressiveMotion.effects,
                    ),
                    child: _ImageSelectionMenu(
                      sliderMin: _imageSelection.columnWidth * 0.25,
                      sliderMax: _imageSelection.columnWidth,
                      sliderValue: (_imageSelection.previewWidth.value ??
                              _imageSelection.currentWidth)
                          .clamp(_imageSelection.columnWidth * 0.25,
                              _imageSelection.columnWidth),
                      onView: _viewSelectedImageFullScreen,
                      onDelete: _deleteSelectedImage,
                      onClose: () => _hideImageMenu(),
                      onSliderChanged: (value) =>
                          _imageSelection.previewWidth.value = value,
                      onSliderCommit: _commitImageWidth,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    _imageMenuEntry = entry;
    Overlay.of(context).insert(entry);
  }

  /// Closes the image selection. While a selection was active, controller
  /// changes were deferred ([_imageReloadPending]); if any piled up (lifecycle
  /// save storms, the slider write-back), catch up with one document reload.
  void _hideImageMenu({bool reload = true}) {
    final entry = _imageMenuEntry;
    final fade = _imageMenuFade;
    _imageMenuEntry = null;
    _imageMenuFade = null;
    _imageSelection.clear();
    entry?.remove();
    fade?.dispose();

    if (reload && mounted && _imageReloadPending) {
      _imageReloadPending = false;
      _loadDocument(widget.textController.text);
    }
  }

  /// Slider onChangeEnd: hand the new width to the parent for a precise
  /// markup rewrite of just this image. Dragging to the full column width
  /// removes the `|N` suffix entirely (full width is device-independent;
  /// hardcoding a desktop column width into the note isn't).
  void _commitImageWidth(double width) {
    final nodeId = _imageSelection.selectedNodeId.value;
    if (nodeId == null) return;

    // 预览宽度保留到退出选中：文档要等控制器写回 + 选中期保护解除后才会
    // 重载，先撤预览会让图片跳回旧宽度。
    _imageSelection.previewWidth.value = width;
    final full = width >= _imageSelection.columnWidth - 0.5;
    _onImageWidthSet(nodeId, full ? null : width);
    _imageReloadPending = true;
  }

  void _viewSelectedImageFullScreen() {
    final provider = _imageSelection.provider;
    if (provider == null) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => _FullScreenImageViewer(image: provider),
      ),
    );
  }

  /// Deletes the selected image node. The document serializer (debounced
  /// write-back) removes exactly that markup from the body; the image file
  /// itself stays on disk (the 90-day cleaner owns it).
  void _deleteSelectedImage() {
    final nodeId = _imageSelection.selectedNodeId.value;
    if (nodeId == null) return;
    _hideImageMenu(reload: false);
    _editor.execute([DeleteNodeRequest(nodeId: nodeId)]);
  }
}

const _imageMenuWidth = 240.0;
const _imageMenuHeight = 128.0;

/// Mutable state of the long-press image selection, shared with the
/// [GjImageComponent]s through [GjImageScope].
class _ImageSelection {
  final selectedNodeId = ValueNotifier<String?>(null);

  /// Live slider preview width for the selected image (logical px).
  final previewWidth = ValueNotifier<double?>(null);

  Rect? Function()? rectGetter;
  ImageProvider? provider;
  double columnWidth = 0;
  double currentWidth = 0;

  /// Set by [SuperEditorBodyState]; fires the menu/selection flow.
  VoidCallback? onSelectRequest;

  bool get isActive => selectedNodeId.value != null;

  Rect? rect() => rectGetter?.call();

  void requestSelect({
    required String nodeId,
    required Rect? Function() rectGetter,
    required double columnWidth,
    required double currentWidth,
    ImageProvider? provider,
  }) {
    this.rectGetter = rectGetter;
    this.columnWidth = columnWidth;
    this.currentWidth = currentWidth;
    this.provider = provider;
    if (selectedNodeId.value != nodeId) {
      previewWidth.value = null;
    }
    selectedNodeId.value = nodeId;
    onSelectRequest?.call();
  }

  void clear() {
    selectedNodeId.value = null;
    previewWidth.value = null;
    rectGetter = null;
    provider = null;
  }
}

/// Dismisses the image menu when the user taps outside the menu and the
/// selected image. Plain [Listener] + translucent behavior: drags still
/// reach the scroll view (scrolling keeps the menu), taps select text in
/// the editor below as usual.
class _ImageMenuDismissListener extends StatefulWidget {
  final Rect menuRect;
  final Rect imageRect;
  final VoidCallback onDismiss;
  final Widget child;

  const _ImageMenuDismissListener({
    required this.menuRect,
    required this.imageRect,
    required this.onDismiss,
    required this.child,
  });

  @override
  State<_ImageMenuDismissListener> createState() =>
      _ImageMenuDismissListenerState();
}

class _ImageMenuDismissListenerState extends State<_ImageMenuDismissListener> {
  Offset? _downPosition;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) => _downPosition = event.position,
      onPointerUp: (event) {
        final down = _downPosition;
        _downPosition = null;
        if (down == null) return;

        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.attached) return;
        // A drag (scroll) is not a tap: keep the menu.
        if ((box.globalToLocal(event.position) - box.globalToLocal(down))
                .distance >
            kTouchSlop) {
          return;
        }
        final pos = box.globalToLocal(event.position);
        if (widget.menuRect.contains(pos)) return;
        // A little slack around the image so wobbly taps on it don't deselect.
        if (widget.imageRect.inflate(8).contains(pos)) return;
        widget.onDismiss();
      },
      child: widget.child,
    );
  }
}

/// 玻璃菜单：查看大图 / 显示大小滑块 / 删除。材质取 GlassTokens.popover +
/// blurSigma（blur 只给浮层），描边与分隔线用 edge，强调与危险色来自令牌。
class _ImageSelectionMenu extends StatelessWidget {
  final double sliderMin;
  final double sliderMax;
  final double sliderValue;
  final VoidCallback onView;
  final VoidCallback onDelete;
  final VoidCallback onClose;
  final ValueChanged<double> onSliderChanged;
  final ValueChanged<double> onSliderCommit;

  const _ImageSelectionMenu({
    required this.sliderMin,
    required this.sliderMax,
    required this.sliderValue,
    required this.onView,
    required this.onDelete,
    required this.onClose,
    required this.onSliderChanged,
    required this.onSliderCommit,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<GlassTokens>();
    final loc = context.loc;
    final destructive =
        tokens?.destructive ?? Theme.of(context).colorScheme.error;

    return FocusScope(
      // 浮层绝不抢焦点（jotsy 教训）：抢了键盘就收。
      canRequestFocus: false,
      child: Material(
        // Overlay 条目不在 Scaffold 的 Material 之下（独立宿主时落在根
        // Overlay），InkWell/Slider 需要 Material 祖先；透明类型不画东西，
        // 玻璃质感由下面的 Container 负责。
        type: MaterialType.transparency,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(
              sigmaX: tokens?.blurSigma ?? 13,
              sigmaY: tokens?.blurSigma ?? 13,
            ),
            child: Container(
              width: _imageMenuWidth,
              decoration: BoxDecoration(
                color: tokens?.popover ??
                    Theme.of(context)
                        .colorScheme
                        .surface
                        .withValues(alpha: 0.97),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: tokens?.edge ?? Colors.black12),
                boxShadow: [
                  BoxShadow(
                    color: tokens?.shade ?? Colors.black26,
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 40,
                    child: Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: onView,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: Row(
                                children: [
                                  const Icon(Icons.zoom_out_map, size: 20),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      loc.imageViewLarge,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: loc.imageMenuClose,
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: onClose,
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: tokens?.edge ?? Colors.black12),
                  SizedBox(
                    height: 44,
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: Text(loc.imageMenuSize,
                              style: Theme.of(context).textTheme.bodyMedium),
                        ),
                        Expanded(
                          child: Slider(
                            value: sliderValue.clamp(sliderMin, sliderMax),
                            min: sliderMin,
                            max: sliderMax,
                            label:
                                '${((sliderValue / sliderMax) * 100).round()}%',
                            onChanged: onSliderChanged,
                            onChangeEnd: onSliderCommit,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: tokens?.edge ?? Colors.black12),
                  SizedBox(
                    height: 40,
                    child: InkWell(
                      onTap: onDelete,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline,
                                size: 20, color: destructive),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                loc.imageMenuDelete,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(color: destructive),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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
            color: (base.color ?? theme.colorScheme.onSurface)
                .withValues(alpha: 0.7),
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
  final _ImageSelection selection;

  const GjImageScope({
    super.key,
    required this.imageDir,
    required this.selection,
    required super.child,
  });

  static GjImageScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<GjImageScope>();
    assert(scope != null, 'GjImageScope not found in context');
    return scope!;
  }

  @override
  bool updateShouldNotify(GjImageScope oldWidget) =>
      imageDir != oldWidget.imageDir || selection != oldWidget.selection;
}

/// Renders [ImageNode]s inline in the editor flow: local images from the
/// note folder with the `|width` url suffix honored (as a *maximum* width:
/// smaller images render at their natural size). Very tall images (>3:1)
/// fold into a 2:3 box showing only their top, with a badge.
///
/// 苹果备忘录式交互：单击无操作（吞掉点击，选区不动），长按选中——描边 +
/// 四角手柄 + 玻璃菜单（查看大图 / 显示大小 / 删除），见
/// [SuperEditorBodyState] 的图片选中段。
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
  Widget? createComponent(SingleColumnDocumentComponentContext componentContext,
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
  _ImageSelection? _watchedSelection;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final selection = GjImageScope.of(context).selection;
    if (!identical(selection, _watchedSelection)) {
      _watchedSelection?.selectedNodeId
          .removeListener(_onSelectionStateChanged);
      _watchedSelection?.previewWidth.removeListener(_onSelectionStateChanged);
      _watchedSelection = selection;
      selection.selectedNodeId.addListener(_onSelectionStateChanged);
      selection.previewWidth.addListener(_onSelectionStateChanged);
    }
  }

  @override
  void dispose() {
    _watchedSelection?.selectedNodeId.removeListener(_onSelectionStateChanged);
    _watchedSelection?.previewWidth.removeListener(_onSelectionStateChanged);
    if (_imageListener != null) {
      _imageStream?.removeListener(_imageListener!);
    }
    super.dispose();
  }

  void _onSelectionStateChanged() {
    if (mounted) setState(() {});
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
    final scope = GjImageScope.of(context);
    final selection = scope.selection;

    final match = imageUrlWidthSuffixRegex.firstMatch(widget.imageUrl);
    var imagePath = widget.imageUrl;
    double? width;
    if (match != null) {
      imagePath = match.group(1)!;
      width = double.parse(match.group(2)!);
    }

    return LayoutBuilder(builder: (context, constraints) {
      final maxWidth = constraints.maxWidth;
      final isSelected = selection.selectedNodeId.value == widget.nodeId;
      // 滑块拖动的实时预览直接接管显示宽度；写回后的文档重载落到同一宽度，
      // 视觉无缝。
      final effectiveWidth =
          (isSelected ? selection.previewWidth.value : null) ?? width;
      // `|width` is a maximum width: smaller images keep their natural size,
      // larger ones scale down to fit. No suffix: the full column width.
      final displayMaxWidth = (effectiveWidth != null
              ? math.min(effectiveWidth, maxWidth)
              : maxWidth)
          .clamp(1.0, double.infinity);

      final provider = _resolveImageProvider(imagePath);
      _listenForImageSize(imagePath, provider);
      final isLongImage = _isLongImage;

      final content = isLongImage
          ? _buildFoldedImage(provider!, displayMaxWidth, theme)
          : _buildImage(provider, theme);

      // The inner recognizers sit deeper in the tree than the document
      // gesture system's, so they win the arena. (opaque: BoxComponent 链不
      // 参与命中测试，deferToChild 会让整个点击丢失。)
      return _ImageBoxComponent(
        key: widget.componentKey,
        caretLineHeight: _caretLineHeight(theme),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 单击无操作：吞掉点击让文档手势系统收不到，选区保持原位（旧版
          // 单击切 |240 会误触；开全屏交由长按菜单）。空 onTap 必须保留，
          // 置 null 会把点击漏给 super_editor，光标就会落到图片块边界。
          onTap: () {},
          onLongPress: () {
            final natural = _decodedImage;
            final current = effectiveWidth ?? natural?.width.toDouble();
            selection.requestSelect(
              nodeId: widget.nodeId,
              rectGetter: () {
                final box = context.findRenderObject() as RenderBox?;
                if (box == null || !box.attached) return null;
                return box.localToGlobal(Offset.zero) & box.size;
              },
              columnWidth: maxWidth,
              currentWidth:
                  current != null ? math.min(current, maxWidth) : maxWidth,
              provider: provider,
            );
          },
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: displayMaxWidth),
              child:
                  isSelected ? _buildSelectionOverlay(content, theme) : content,
            ),
          ),
        ),
      );
    });
  }

  /// 选中视觉：账本黄描边 + 四角小圆点手柄（Apple Notes 式）。
  Widget _buildSelectionOverlay(Widget content, ThemeData theme) {
    final tokens = theme.extension<GlassTokens>();
    final accent = tokens?.accent ?? theme.colorScheme.secondary;
    const dotSize = 8.0;

    Widget dot(Alignment alignment) => Align(
          alignment: alignment,
          child: Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              color: accent,
              shape: BoxShape.circle,
              border: Border.all(
                color: theme.colorScheme.surface,
                width: 1.5,
              ),
            ),
          ),
        );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: accent, width: 2),
          ),
          child: content,
        ),
        dot(Alignment.topLeft),
        dot(Alignment.topRight),
        dot(Alignment.bottomLeft),
        dot(Alignment.bottomRight),
      ],
    );
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
  /// a badge in the bottom right corner. Viewing the full image goes
  /// through the long-press menu (查看大图).
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
}

/// 正文的行高（标题 Medium 基样式，见 _buildStylesheet），用于图片块边界的
/// 光标高度。
double _caretLineHeight(ThemeData theme) {
  final base = theme.textTheme.titleMedium;
  return (base?.fontSize ?? 16) * (base?.height ?? 1.45);
}

/// BoxComponent equivalent for images whose caret edge hugs the leading
/// edge at text line height. Stock [BoxComponent] reports a full-height
/// edge (box_component.dart `getEdgeForPosition`), so a selection collapsed
/// on the image boundary renders the caret as a thin bar as tall as the
/// image - the cursor fix this fork ships.
class _ImageBoxComponent extends StatefulWidget {
  final double caretLineHeight;
  final Widget child;

  const _ImageBoxComponent({
    super.key,
    required this.caretLineHeight,
    required this.child,
  });

  @override
  State<_ImageBoxComponent> createState() => _ImageBoxComponentState();
}

class _ImageBoxComponentState extends State<_ImageBoxComponent>
    with DocumentComponent {
  @override
  UpstreamDownstreamNodePosition getBeginningPosition() {
    return const UpstreamDownstreamNodePosition.upstream();
  }

  @override
  UpstreamDownstreamNodePosition getBeginningPositionNearX(double x) {
    final width = (context.findRenderObject() as RenderBox).size.width;
    return x < width / 2
        ? const UpstreamDownstreamNodePosition.upstream()
        : const UpstreamDownstreamNodePosition.downstream();
  }

  @override
  UpstreamDownstreamNodePosition? movePositionLeft(NodePosition currentPosition,
      [MovementModifier? movementModifier]) {
    if (currentPosition == const UpstreamDownstreamNodePosition.upstream()) {
      return null;
    }
    return const UpstreamDownstreamNodePosition.upstream();
  }

  @override
  UpstreamDownstreamNodePosition? movePositionRight(
      NodePosition currentPosition,
      [MovementModifier? movementModifier]) {
    if (currentPosition == const UpstreamDownstreamNodePosition.downstream()) {
      return null;
    }
    return const UpstreamDownstreamNodePosition.downstream();
  }

  @override
  UpstreamDownstreamNodePosition? movePositionUp(
          NodePosition currentPosition) =>
      null;

  @override
  UpstreamDownstreamNodePosition? movePositionDown(
          NodePosition currentPosition) =>
      null;

  @override
  UpstreamDownstreamNodePosition getEndPosition() {
    return const UpstreamDownstreamNodePosition.downstream();
  }

  @override
  UpstreamDownstreamNodePosition getEndPositionNearX(double x) {
    final width = (context.findRenderObject() as RenderBox).size.width;
    return x < width / 2
        ? const UpstreamDownstreamNodePosition.upstream()
        : const UpstreamDownstreamNodePosition.downstream();
  }

  @override
  Offset getOffsetForPosition(NodePosition nodePosition) {
    if (nodePosition is! UpstreamDownstreamNodePosition) {
      throw Exception(
          'Expected nodePosition of type UpstreamDownstreamNodePosition but received: $nodePosition');
    }

    final myBox = context.findRenderObject() as RenderBox;
    return nodePosition.affinity == TextAffinity.upstream
        ? Offset(myBox.size.width / 4, myBox.size.height / 2)
        : Offset(3 * myBox.size.width / 4, myBox.size.height / 2);
  }

  @override
  UpstreamDownstreamNodePosition getPositionAtOffset(Offset localOffset) {
    final myBox = context.findRenderObject() as RenderBox;
    return localOffset.dx <= myBox.size.width / 2
        ? const UpstreamDownstreamNodePosition.upstream()
        : const UpstreamDownstreamNodePosition.downstream();
  }

  @override
  Rect getRectForPosition(NodePosition nodePosition) {
    if (nodePosition is! UpstreamDownstreamNodePosition) {
      throw Exception(
          'Expected nodePosition of type UpstreamDownstreamNodePosition but received: $nodePosition');
    }

    final myBox = context.findRenderObject() as RenderBox;
    return Rect.fromLTWH(0, 0, myBox.size.width, myBox.size.height);
  }

  @override
  Rect getEdgeForPosition(NodePosition nodePosition) {
    final boundingBox = getRectForPosition(nodePosition);
    // 光标修正：按正文行高绘制、锚在图片前缘（Stock BoxComponent 返回整图
    // 高的 edge，选区落在图片边界时光标被画成等高细竖条）。
    final height = math.min(widget.caretLineHeight, boundingBox.height);
    return Rect.fromLTWH(
      boundingBox.left,
      boundingBox.bottom - height,
      boundingBox.width,
      height,
    );
  }

  @override
  Rect getRectForSelection(
      NodePosition basePosition, NodePosition extentPosition) {
    if (basePosition is! UpstreamDownstreamNodePosition) {
      throw Exception(
          'Expected nodePosition of type UpstreamDownstreamNodePosition but received: $basePosition');
    }
    if (extentPosition is! UpstreamDownstreamNodePosition) {
      throw Exception(
          'Expected nodePosition of type UpstreamDownstreamNodePosition but received: $extentPosition');
    }

    final selection = UpstreamDownstreamNodeSelection(
        base: basePosition, extent: extentPosition);
    if (selection.isCollapsed) {
      return getRectForPosition(selection.extent);
    }

    final myBox = context.findRenderObject() as RenderBox;
    return Offset.zero & myBox.size;
  }

  @override
  UpstreamDownstreamNodeSelection getCollapsedSelectionAt(nodePosition) {
    if (nodePosition is! UpstreamDownstreamNodePosition) {
      throw Exception(
          'The given nodePosition ($nodePosition) is not compatible with _ImageBoxComponent');
    }
    return UpstreamDownstreamNodeSelection.collapsed(nodePosition);
  }

  @override
  UpstreamDownstreamNodeSelection getSelectionBetween(
      {required basePosition, required extentPosition}) {
    if (basePosition is! UpstreamDownstreamNodePosition) {
      throw Exception(
          'The given basePosition ($basePosition) is not compatible with _ImageBoxComponent');
    }
    if (extentPosition is! UpstreamDownstreamNodePosition) {
      throw Exception(
          'The given extentPosition ($extentPosition) is not compatible with _ImageBoxComponent');
    }

    return UpstreamDownstreamNodeSelection(
        base: basePosition, extent: extentPosition);
  }

  @override
  UpstreamDownstreamNodeSelection getSelectionInRange(
      Offset localBaseOffset, Offset localExtentOffset) {
    return getSelectionBetween(
      basePosition: getPositionAtOffset(localBaseOffset),
      extentPosition: getPositionAtOffset(localExtentOffset),
    );
  }

  @override
  UpstreamDownstreamNodeSelection getSelectionOfEverything() {
    return const UpstreamDownstreamNodeSelection.all();
  }

  @override
  bool isVisualSelectionSupported() => true;

  @override
  MouseCursor? getDesiredCursorAtOffset(Offset localOffset) => null;

  @override
  Widget build(BuildContext context) => widget.child;
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
