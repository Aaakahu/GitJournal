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
      _textController.text = _note.body;
      _titleTextController.text = _note.title ?? "";
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
        onImageResized: _onRichImageResized,
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
      editor = CustomScrollView(
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
                onImageResized: _onImageResized,
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
      extraButton: _useRichEditor
          ? null
          : IconButton(
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
            ),
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

  /// Rewrites the `|width` suffix of the imageIndex-th image markup in the
  /// body. The document-order index of the image node matches the order of
  /// the image markups in the text because the rich editor is only active
  /// for bodies that round-trip exactly.
  void _onRichImageResized(int imageIndex, double width) {
    var matches = imageMarkupRegex.allMatches(_textController.text).toList();
    if (imageIndex >= matches.length) return;
    var match = matches[imageIndex];
    _onImageResized(match.start, match.end, width);
  }

  void _noteTextChanged() {
    try {
      _applyHeuristics();
    } catch (e, stackTrace) {
      Log.e("EditorHeuristics: $e");
      logExceptionWarning(e, stackTrace);
    }
    if (_noteModified && !widget.editMode) return;

    var newState = !(widget.editMode && _textController.text.trim().isEmpty);
    if (newState != _noteModified) {
      setState(() {
        _noteModified = newState;
      });
    }

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

  // Writes the new image width back into the body by replacing exactly the
  // markup of the resized image. Not tracked by the undo stack - resizing
  // an image isn't undoable.
  void _onImageResized(int start, int end, double width) {
    var text = _textController.text;
    if (start < 0 || end > text.length || start >= end) return;

    var markup = text.substring(start, end);
    var newMarkup = imageMarkupWithWidth(markup, width.round());
    if (newMarkup == null) return;

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
