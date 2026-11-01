/*
 * SPDX-FileCopyrightText: 2019-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter/material.dart';
import 'package:gitjournal/core/folder/notes_folder.dart';
import 'package:gitjournal/core/image.dart' as core;
import 'package:gitjournal/core/image.dart';
import 'package:gitjournal/core/note.dart';
import 'package:gitjournal/core/notes/note.dart';
import 'package:gitjournal/editors/common.dart';
import 'package:gitjournal/editors/editing_session_registry.dart';
import 'package:gitjournal/editors/editor_scroll_view.dart';
import 'package:gitjournal/editors/heuristics.dart';
import 'package:gitjournal/editors/markdown_toolbar.dart';
import 'package:gitjournal/editors/note_body_editor.dart';
import 'package:gitjournal/editors/note_title_editor.dart';
import 'package:gitjournal/editors/super_editor_body.dart';
import 'package:gitjournal/editors/undo_redo.dart';
import 'package:gitjournal/editors/utils/disposable_change_notifier.dart';
import 'package:gitjournal/error_reporting.dart';
import 'package:gitjournal/folder_views/common.dart';
import 'package:gitjournal/l10n.dart';
import 'package:gitjournal/logger/logger.dart';
import 'package:gitjournal/markdown/markdown_renderer.dart';
import 'package:gitjournal/markdown/rich_editor_safety.dart';
import 'package:gitjournal/settings/app_config.dart';
import 'package:gitjournal/utils/markdown.dart';
import 'package:gitjournal/utils/utils.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'controllers/rich_text_controller.dart';

class MarkdownEditor extends StatefulWidget implements Editor {
  final Note note;
  final NotesFolder parentFolder;
  final bool noteModified;

  @override
  final EditorCommon common;

  final bool editMode;
  final String? highlightString;
  final ThemeData theme;

  const MarkdownEditor({
    super.key,
    required this.note,
    required this.parentFolder,
    required this.noteModified,
    required this.editMode,
    required this.highlightString,
    required this.theme,
    required this.common,
  });

  @override
  MarkdownEditorState createState() {
    return MarkdownEditorState();
  }
}

class MarkdownEditorState extends State<MarkdownEditor>
    with DisposableChangeNotifier
    implements EditorState {
  late Note _note;
  late TextEditingController _textController;
  late TextEditingController _titleTextController;
  late UndoRedoStack _undoRedoStack;

  late EditorHeuristics _heuristics;

  late bool _noteModified;

  late ScrollController _scrollController;

  final _bodyEditorKey = GlobalKey();
  final _richBodyEditorKey = GlobalKey<SuperEditorBodyState>();

  /// Whether this editor session uses the WYSIWYG (super_editor) body.
  /// Decided once when the note is opened - notes that can't round-trip
  /// safely fall back to the plain text editor.
  late final bool _useRichEditor;

  // Roundtrip check result cache, so it runs at most once per body content.
  String? _roundtripCheckedBody;
  bool _roundtripStable = false;

  /// Whether the body currently carries the `#情绪` tag - drives the mood
  /// button's icon. Kept as a field so the icon updates even when the text
  /// change itself doesn't trigger a rebuild.
  late bool _hasMoodTag;

  @override
  void initState() {
    super.initState();
    _note = widget.note;
    _noteModified = widget.noteModified;

    _textController = buildController(
      text: _note.body,
      highlightText: widget.highlightString,
      theme: widget.theme,
    );
    _titleTextController = buildController(
      text: _note.title ?? "",
      highlightText: widget.highlightString,
      theme: widget.theme,
    );
    _heuristics = EditorHeuristics(text: _note.body);

    _scrollController = ScrollController(keepScrollOffset: false);
    _undoRedoStack = UndoRedoStack();

    _textController.addListener(_textControllerChanged);

    _useRichEditor =
        AppConfig.instance.richMarkdownEditor && _isSafeForRichEditor(_note.body);

    _hasMoodTag = hasMoodTag(_note.body);
  }

  bool _isSafeForRichEditor(String body) {
    if (RichEditorSafety.hasUnsafeMarkdown(body)) {
      return false;
    }
    if (_roundtripCheckedBody != body) {
      _roundtripCheckedBody = body;
      _roundtripStable = RichEditorSafety.isRoundtripStable(body);
    }
    return _roundtripStable;
  }

  // Rebuild to refresh the live preview when the text changes
  void _textControllerChanged() {
    if (!mounted) return;
    if (AppConfig.instance.livePreview) {
      setState(() {});
    }
  }

  void _replaceTextController({String? highlightText, int currentPos = -1}) {
    _textController = buildController(
      text: _textController.text,
      highlightText: highlightText,
      theme: widget.theme,
      currentPos: currentPos,
    );
    _textController.addListener(_textControllerChanged);
  }

  @override
  void dispose() {
    _textController.dispose();
    _titleTextController.dispose();
    _scrollController.dispose();

    super.disposeListenables();
    super.dispose();
  }

  @override
  void didUpdateWidget(MarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.noteModified != widget.noteModified) {
      _noteModified = widget.noteModified;
    }
    if (oldWidget.note != widget.note) {
      _note = widget.note;
      // 编辑租约：路径仍被编辑会话持有时，同步重载送来的新 Note 不回写编辑器
      // 正文/标题（跳过重载，编辑会话的内容为准）；租约期间到达的 Note 只会
      // 是本会话自己保存/重命名的产物，内容与编辑器一致，跳过无损失。
      if (!EditingSessionRegistry.isBeingEdited(widget.note.filePath)) {
        _textController.text = _note.body;
        _titleTextController.text = _note.title ?? "";
        _hasMoodTag = hasMoodTag(_note.body);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    var appConfig = context.watch<AppConfig>();

    Widget bodyEditor;
    if (_useRichEditor) {
      bodyEditor = SuperEditorBody(
        key: _richBodyEditorKey,
        textController: _textController,
        imageDir: p.join(_note.repoPath, _note.parent.folderPath),
        autofocus: widget.editMode,
        onChanged: _richTextChanged,
        onImageWidthSet: _onRichImageWidthSet,
      );
    } else {
      bodyEditor = NoteBodyEditor(
        key: _bodyEditorKey,
        textController: _textController,
        autofocus: widget.editMode,
        onChanged: _noteTextChanged,
      );
    }

    Widget editor;
    if (_useRichEditor) {
      // super_editor's top-level render object is a SliverHybridStack
      // (RenderSliver family) - it must hang directly off a CustomScrollView.
      // A Column (RenderFlex) only accepts RenderBox children: in debug the
      // assert fires, in release the sliver is never laid out or painted and
      // the editor shows up as a dead grey block.
      //
      // The selection format toolbar (SuperEditorBody) mounts itself into the
      // nearest Overlay. Hosting that Overlay HERE, with the editor as its
      // base entry, keeps the toolbar inside this route's subtree so pushed
      // routes and dialogs cover it - the root overlay would float above
      // them. The rich branch's widget structure is static (content flows
      // through controllers), so the base entry never goes stale.
      editor = Overlay(
        initialEntries: [
          OverlayEntry(
            builder: (context) => Positioned.fill(
              child: CustomScrollView(
                controller: _scrollController,
                slivers: <Widget>[
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 0.0),
                    sliver: SliverToBoxAdapter(
                      child: NoteTitleEditor(
                        _titleTextController,
                        _noteTitleTextChanged,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 16.0),
                    sliver: bodyEditor,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    } else {
      editor = EditorScrollView(
        scrollController: _scrollController,
        child: Column(
          children: <Widget>[
            NoteTitleEditor(
              _titleTextController,
              _noteTitleTextChanged,
            ),
            bodyEditor,
          ],
        ),
      );
    }

    // In the rich editor the body already shows the rendered result, so the
    // split screen preview makes no sense there.
    if (!_useRichEditor && appConfig.livePreview) {
      // The preview renders the same text the editor is editing
      var previewNote = _note.copyWith(body: _textController.text);
      editor = Column(
        children: <Widget>[
          Expanded(child: editor),
          const Divider(height: 1.0),
          Expanded(
            child: EditorScrollView(
              child: MarkdownRenderer(
                note: previewNote,
                onNoteTapped: (note) =>
                    openNoteEditor(context, note, _note.parent),
                onImageWidthChange: _onImageMarkupToggled,
              ),
            ),
          ),
        ],
      );
    }

    Widget? markdownToolbar;
    if (!_useRichEditor && appConfig.experimentalMarkdownToolbar) {
      markdownToolbar = MarkdownToolBar(
        textController: _textController,
      );
    }

    final extraActions = <Widget>[
      IconButton(
        tooltip: context.loc.editorMoodTooltip,
        icon: Icon(
          _hasMoodTag ? Icons.mood : Icons.mood_outlined,
          color: _hasMoodTag ? Theme.of(context).colorScheme.secondary : null,
        ),
        onPressed: _showMoodPicker,
      ),
    ];
    if (!_useRichEditor) {
      extraActions.add(IconButton(
        tooltip: context.loc.editorLivePreview,
        icon: Icon(
          Icons.vertical_split,
          color: appConfig.livePreview
              ? Theme.of(context).colorScheme.secondary
              : null,
        ),
        onPressed: () {
          appConfig.livePreview = !appConfig.livePreview;
          appConfig.save();
        },
      ));
    }

    return EditorScaffold(
      startingNote: widget.note,
      editor: widget,
      editorState: this,
      noteModified: _noteModified,
      editMode: widget.editMode,
      parentFolder: _note.parent,
      body: editor,
      onUndoSelected: _undo,
      onRedoSelected: _redo,
      undoAllowed: _undoRedoStack.undoPossible,
      redoAllowed: _undoRedoStack.redoPossible,
      extraActions: extraActions,
      extraBottomWidget: markdownToolbar,
      findAllowed: true,
    );
  }

  @override
  Note getNote() {
    // Push any debounced rich editor serialization into the text controller
    // before reading it, so a save right after typing can't lose content.
    if (_useRichEditor) {
      _richBodyEditorKey.currentState?.flushPendingWrite();
    }
    return _note.copyWith(
      body: _textController.text.trim(),
      title: _titleTextController.text.trim(),
      type: NoteType.Unknown,
    );
  }

  /// Text updates from the rich editor arrive after the debounced
  /// serialization. The editor heuristics (bullet auto-continuation etc.)
  /// operate on raw text and don't apply to the document model, so only the
  /// modified flag and the undo stack run here.
  ///
  /// Known v1 limitations in this mode: undo granularity follows the
  /// serialization debounce interval, and search highlighting is not
  /// rendered (find still works on the plain text).
  void _richTextChanged() {
    _checkMoodTagChanged();
    if (_noteModified && !widget.editMode) return;

    var newState = !(widget.editMode && _textController.text.trim().isEmpty);
    if (newState != _noteModified) {
      setState(() {
        _noteModified = newState;
      });
    }

    var redraw = _undoRedoStack
        .textChanged(TextEditorState.fromValue(_textController.value));
    if (redraw) {
      setState(() {});
    }

    notifyListeners();
  }

  /// Sets (or clears) the `|N` width suffix of the imageIndex-th image
  /// markup in the body. The document-order index of the image node matches
  /// the order of the image markups in the text because the rich editor is
  /// only active for bodies that round-trip exactly.
  void _onRichImageWidthSet(int imageIndex, double? widthOrNull) {
    // Sync any debounced document serialization first, so the markup indexes
    // match the document the user sees.
    _richBodyEditorKey.currentState?.flushPendingWrite();
    var matches = imageMarkupRegex.allMatches(_textController.text).toList();
    if (imageIndex >= matches.length) return;
    var match = matches[imageIndex];
    _onImageWidthSet(match.start, match.end, widthOrNull);
  }

  void _noteTextChanged() {
    try {
      _applyHeuristics();
    } catch (e, stackTrace) {
      Log.e("EditorHeuristics: $e");
      logExceptionWarning(e, stackTrace);
    }
    _checkMoodTagChanged();
    if (_noteModified && !widget.editMode) return;

    var newState = !(widget.editMode && _textController.text.trim().isEmpty);
    if (newState != _noteModified) {
      setState(() {
        _noteModified = newState;
      });
    }

    notifyListeners();
  }

  /// Keeps the mood button's icon in sync with the body text even when no
  /// other rebuild is scheduled (live preview off, modified flag unchanged).
  void _checkMoodTagChanged() {
    var hasMood = hasMoodTag(_textController.text);
    if (hasMood != _hasMoodTag) {
      setState(() {
        _hasMoodTag = hasMood;
      });
    }
  }

  /// The mood picker (v1): any selection toggles the `#情绪` tag - the
  /// pipeline only tracks the tag's presence, never which mood was picked.
  void _showMoodPicker() {
    // 收起键盘：避免弹层下半被 viewInsets 顶出可视区。
    FocusManager.instance.primaryFocus?.unfocus();
    const moods = ['😊', '😐', '😟', '😫', '😡', '🤩'];
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        var theme = Theme.of(sheetContext);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  sheetContext.loc.editorMoodPickerTitle,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (var mood in moods)
                      IconButton(
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          _toggleMoodTag();
                        },
                        tooltip: mood,
                        icon: Text(mood, style: const TextStyle(fontSize: 28)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Toggles the standalone `#情绪` line at the top of the body. Not tracked
  /// by the undo stack - tagging a mood isn't undoable.
  void _toggleMoodTag() {
    // 与图片宽度切换同源的问题：rich 模式下文档有 300ms 序列化去抖，
    // 不先冲刷会用旧文本重建文档，丢最近输入并把光标弹回文首。
    _richBodyEditorKey.currentState?.flushPendingWrite();
    var newText = toggleMoodTag(_textController.text);
    setState(() {
      _textController.value = TextEditingValue(
        text: newText,
        selection: const TextSelection.collapsed(offset: 0),
      );
      _hasMoodTag = hasMoodTag(newText);
      _noteModified = true;
    });
    notifyListeners();
  }

  void _noteTitleTextChanged() {
    if (_noteModified && !widget.editMode) return;

    var newState =
        !(widget.editMode && _titleTextController.text.trim().isEmpty);
    if (newState != _noteModified) {
      setState(() {
        _noteModified = newState;
      });
    }

    notifyListeners();
  }

  void _applyHeuristics() {
    var editState = TextEditorState.fromValue(_textController.value);
    var es = _heuristics.textChanged(editState);
    if (es != null) {
      _textController.value = es.toValue();
    }

    var redraw = _undoRedoStack.textChanged(editState);
    if (redraw) {
      setState(() {});
    }
  }

  @override
  Future<void> addImage(String filePath) async {
    try {
      var image = await core.Image.copyIntoFs(_note.parent, filePath);

      if (_useRichEditor) {
        // The rich editor owns the caret: insert at the document layer.
        // Writing into the hidden text controller would insert at the stale
        // selection left over from the last serialization and race the
        // "external change" document reload - images needed several tries.
        var relativeImagePath =
            p.relative(image.filePath, from: _note.parent.folderPath);
        if (!relativeImagePath.startsWith('.')) {
          relativeImagePath = './$relativeImagePath';
        }
        _richBodyEditorKey.currentState?.insertImageNode(relativeImagePath);
        setState(() {
          _noteModified = true;
        });
        return;
      }

      var ts = insertImage(
        TextEditorState.fromValue(_textController.value),
        image,
        _note.fileFormat,
      );

      setState(() {
        _textController.value = ts.toValue();
        _noteModified = true;
      });
    } catch (ex) {
      showErrorSnackbar(context, ex);
    }
  }

  @override
  bool get noteModified => _noteModified;

  // Rewrites exactly the image markup between [start] and [end]: a markup
  // with a `|width` suffix loses it (full width), a plain one gains `|240`
  // (thumbnail). Not tracked by the undo stack - toggling an image size
  // isn't undoable.
  void _onImageMarkupToggled(int start, int end) {
    var text = _textController.text;
    if (start < 0 || end > text.length || start >= end) return;

    var markup = text.substring(start, end);
    var match = imageMarkupRegex.firstMatch(markup);
    if (match == null) return;
    var newMarkup = match.group(3) != null
        ? '![${match.group(1)}](${match.group(2)})'
        : '![${match.group(1)}](${match.group(2)}|$gjImageThumbnailWidth)';

    int adjustOffset(int offset) {
      if (offset <= start) return offset;
      if (offset >= end) return offset + newMarkup.length - markup.length;
      return start;
    }

    var selection = _textController.selection;
    setState(() {
      _textController.value = TextEditingValue(
        text: text.replaceRange(start, end, newMarkup),
        selection: TextSelection(
          baseOffset: adjustOffset(selection.baseOffset),
          extentOffset: adjustOffset(selection.extentOffset),
        ),
      );
      _noteModified = true;
    });
  }

  /// Rewrites exactly the image markup between [start] and [end]: sets the
  /// `|N` width suffix to [widthOrNull] (appended when the markup has none),
  /// or removes the suffix on null (full column width). Not tracked by the
  /// undo stack - resizing an image isn't undoable.
  void _onImageWidthSet(int start, int end, double? widthOrNull) {
    var text = _textController.text;
    if (start < 0 || end > text.length || start >= end) return;

    var markup = text.substring(start, end);
    var match = imageMarkupRegex.firstMatch(markup);
    if (match == null) return;
    var newMarkup = widthOrNull == null
        ? '![${match.group(1)}](${match.group(2)})'
        : '![${match.group(1)}](${match.group(2)}|${widthOrNull.round()})';

    int adjustOffset(int offset) {
      if (offset <= start) return offset;
      if (offset >= end) return offset + newMarkup.length - markup.length;
      return start;
    }

    var selection = _textController.selection;
    setState(() {
      _textController.value = TextEditingValue(
        text: text.replaceRange(start, end, newMarkup),
        selection: TextSelection(
          baseOffset: adjustOffset(selection.baseOffset),
          extentOffset: adjustOffset(selection.extentOffset),
        ),
      );
      _noteModified = true;
    });
  }

  Future<void> _undo() async {
    var es = _undoRedoStack.undo();
    setState(() {
      _textController.value = es.toValue();
    });
  }

  Future<void> _redo() async {
    var es = _undoRedoStack.redo();
    setState(() {
      _textController.value = es.toValue();
    });
  }

  @override
  SearchInfo search(String? text) {
    setState(() {
      // In the rich editor the body controller is kept untouched: replacing
      // it would reload the whole document. Search highlighting is a known
      // v1 limitation there.
      if (!_useRichEditor) {
        _replaceTextController(highlightText: text);
      }
      _titleTextController = buildController(
        text: _titleTextController.text,
        highlightText: text,
        theme: widget.theme,
      );
    });

    return SearchInfo.compute(body: _textController.text, text: text);
  }

  @override
  void scrollToResult(String text, int num) {
    if (_useRichEditor) {
      // v1 limitation: there's no mapping between markdown text offsets and
      // super_editor document positions, so scrolling to a search result is
      // disabled in the rich editor.
      return;
    }

    setState(() {
      _replaceTextController(highlightText: text, currentPos: num);
    });

    scrollToSearchResult(
      scrollController: _scrollController,
      textController: _textController,
      textEditorKey: _bodyEditorKey,
      textStyle: NoteBodyEditor.textStyle(context),
      searchText: text,
      resultNum: num,
    );
  }
}
