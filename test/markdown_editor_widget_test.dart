/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:dart_git/blob_ctime_builder.dart';
import 'package:dart_git/file_mtime_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitjournal/core/file/file_storage.dart';
import 'package:gitjournal/core/folder/notes_folder_config.dart';
import 'package:gitjournal/core/folder/notes_folder_fs.dart';
import 'package:gitjournal/core/note.dart';
import 'package:gitjournal/core/notes/note.dart';
import 'package:gitjournal/editors/common.dart';
import 'package:gitjournal/editors/markdown_editor.dart';
import 'package:gitjournal/editors/note_body_editor.dart';
import 'package:gitjournal/editors/super_editor_body.dart';
import 'package:gitjournal/l10n.dart';
import 'package:gitjournal/settings/app_config.dart';
import 'package:gitjournal/settings/settings.dart';
import 'package:gitjournal/themes.dart';
import 'package:super_editor/super_editor.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

void main() {
  late NotesFolderFS folder;
  late SharedPreferences pref;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    pref = await SharedPreferences.getInstance();

    var config = NotesFolderConfig('', pref);
    // Synthetic rooted repo path: the core asserts require paths starting
    // with the platform separator (a POSIX-ism), and this test never touches
    // the filesystem, so nothing is ever created there.
    var repoPath = '${p.separator}gj_markdown_editor_widget_test';
    var fileStorage = FileStorage(
      repoPath: repoPath,
      blobCTimeBuilder: BlobCTimeBuilder(),
      fileMTimeBuilder: FileMTimeBuilder(),
    );
    folder = NotesFolderFS.root(config, fileStorage);

    // Reset the AppConfig singleton - it leaks across tests.
    var appConfig = AppConfig();
    appConfig.richMarkdownEditor = true;
    appConfig.livePreview = false;
    appConfig.experimentalMarkdownToolbar = false;
  });

  Note buildNote(String body, {String? title}) {
    var note = Note.newNote(folder,
        fileName: 'note.md', fileFormat: NoteFileFormat.Markdown);
    return note.copyWith(body: body, title: title);
  }

  Future<List<FlutterErrorDetails>> pumpEditor(
    WidgetTester tester,
    Note note,
  ) async {
    // Regression gate for the "grey dead editor block": every layout
    // exception the widget tree hits is captured here and must stay empty.
    var errors = <FlutterErrorDetails>[];
    var originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details);
      debugPrint(details.toString());
    };

    try {
      var appConfig = AppConfig();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppConfig>.value(value: appConfig),
            ChangeNotifierProvider<Settings>.value(value: Settings('', pref)),
            ListenableProvider<NotesFolderFS>.value(value: folder),
          ],
          child: MaterialApp(
            theme: Themes.fromName(GLASS_LIGHT_THEME_NAME),
            localizationsDelegates: gitJournalLocalizationDelegates,
            supportedLocales: gitJournalSupportedLocales,
            home: Scaffold(
              body: MarkdownEditor(
                note: note,
                parentFolder: folder,
                noteModified: false,
                editMode: false,
                highlightString: null,
                theme: Themes.fromName(GLASS_LIGHT_THEME_NAME),
                common: _NoopEditorCommon(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = originalOnError;
    }

    return errors;
  }

  testWidgets('Rich editor mounts as a sliver and stays layout-clean',
      (tester) async {
    var note = buildNote("Hello World\n\nSecond paragraph.", title: "My Note");

    var errors = await pumpEditor(tester, note);

    expect(errors, isEmpty);
    expect(find.byType(SuperEditor), findsOneWidget);
    expect(find.byType(NoteBodyEditor), findsNothing);

    // The editor text is rendered inside super_editor's own text widgets.
    expect(
      find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().contains("Hello World"),
      ),
      findsWidgets,
    );
  });

  testWidgets('Unsafe markdown falls back to the plain text editor',
      (tester) async {
    var note = buildNote("| a | b |\n|---|---|\n| 1 | 2 |", title: "Table");

    var errors = await pumpEditor(tester, note);

    expect(errors, isEmpty);
    expect(find.byType(NoteBodyEditor), findsOneWidget);
    expect(find.byType(SuperEditor), findsNothing);
    expect(find.textContaining('| a | b |'), findsOneWidget);
  });

  testWidgets('insertImageNode thrice inserts three images (regression: '
      'insertion needed several attempts)', (tester) async {
    var controller = TextEditingController(text: "Hello World");
    var bodyKey = GlobalKey<SuperEditorBodyState>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // super_editor's sliver tree must hang directly off a
          // CustomScrollView (it is itself a sliver).
          body: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SuperEditorBody(
                  key: bodyKey,
                  textController: controller,
                  imageDir: '/gj_test_images',
                  autofocus: false,
                  onChanged: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final state = bodyKey.currentState!;
    state.insertImageNode('./a.jpg');
    await tester.pump();
    state.insertImageNode('./b.jpg');
    await tester.pump();
    state.insertImageNode('./c.jpg');
    state.flushPendingWrite();
    await tester.pump();

    final editor = tester.widget<SuperEditor>(find.byType(SuperEditor));
    final images =
        editor.editor.document.toList().whereType<ImageNode>().toList();
    expect(images.map((n) => n.imageUrl),
        ['./a.jpg', './b.jpg', './c.jpg']);

    // The serialized write-back contains all three markups.
    expect(controller.text.contains('![Image](./a.jpg)'), isTrue);
    expect(controller.text.contains('![Image](./b.jpg)'), isTrue);
    expect(controller.text.contains('![Image](./c.jpg)'), isTrue);
  });

  testWidgets('Tapping an image does nothing to the body or the selection',
      (tester) async {
    var note = buildNote("Hello\n\n![x](./a.jpg)\n\nBye", title: "Img");

    var errors = await pumpEditor(tester, note);
    expect(errors, isEmpty);
    expect(find.byType(GjImageComponent), findsOneWidget);

    final editorState =
        tester.state<MarkdownEditorState>(find.byType(MarkdownEditor));

    await tester.tap(find.byType(GjImageComponent));
    await tester.pump(const Duration(milliseconds: 400));

    // 单击无操作：正文与选中菜单都不动。
    expect(editorState.getNote().body, "Hello\n\n![x](./a.jpg)\n\nBye");
    expect(find.byIcon(Icons.zoom_out_map), findsNothing);
  });

  testWidgets('Long-pressing an image opens the glass menu; the size slider '
      'writes the |N suffix back', (tester) async {
    var note = buildNote("Hello\n\n![x](./a.jpg|240)\n\nBye", title: "Img");

    var errors = await pumpEditor(tester, note);
    expect(errors, isEmpty);
    expect(find.byType(GjImageComponent), findsOneWidget);

    final editorState =
        tester.state<MarkdownEditorState>(find.byType(MarkdownEditor));

    // 长按选中：玻璃菜单浮出。
    await tester.longPress(find.byType(GjImageComponent));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.zoom_out_map), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    // 滑块拖到最左（列宽 25%）：onChangeEnd 精确写回该处 markup。
    final slider = tester.widget<Slider>(find.byType(Slider));
    await tester.drag(find.byType(Slider), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(
      editorState.getNote().body,
      "Hello\n\n![x](./a.jpg|${slider.min.round()})\n\nBye",
    );

    // 拖到最右（列宽 100%）：等价无上限，移除 |N 后缀。
    await tester.drag(find.byType(Slider), const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(editorState.getNote().body, "Hello\n\n![x](./a.jpg)\n\nBye");

    // 点菜单/图片以外区域：退出选中，菜单收起。
    await tester.tapAt(const Offset(10, 400));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.zoom_out_map), findsNothing);
    expect(editorState.getNote().body, "Hello\n\n![x](./a.jpg)\n\nBye");
  });

  testWidgets('Long-pressing the menu delete removes the image markup',
      (tester) async {
    var note = buildNote("Hello\n\n![x](./a.jpg)\n\nBye", title: "Img");

    var errors = await pumpEditor(tester, note);
    expect(errors, isEmpty);

    final editorState =
        tester.state<MarkdownEditorState>(find.byType(MarkdownEditor));

    await tester.longPress(find.byType(GjImageComponent));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    // 只删文档引用与 markup；markup 从正文精确消失。
    expect(editorState.getNote().body, "Hello\n\nBye");
    expect(find.byType(GjImageComponent), findsNothing);
  });

  testWidgets('Image menu align buttons rewrite the alignment suffix '
      '(width kept, letter-only on a plain markup)', (tester) async {
    var note = buildNote("Hello\n\n![x](./a.jpg|240)\n\nBye", title: "Img");

    var errors = await pumpEditor(tester, note);
    expect(errors, isEmpty);

    final editorState =
        tester.state<MarkdownEditorState>(find.byType(MarkdownEditor));

    await tester.longPress(find.byType(GjImageComponent));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.format_align_center), findsOneWidget);

    // 居中：|240 -> |240c，宽度保留，只动对齐字母。
    await tester.tap(find.byIcon(Icons.format_align_center));
    await tester.pumpAndSettle();
    expect(editorState.getNote().body, "Hello\n\n![x](./a.jpg|240c)\n\nBye");

    // 右对齐：|240c -> |240r。
    await tester.tap(find.byIcon(Icons.format_align_right));
    await tester.pumpAndSettle();
    expect(editorState.getNote().body, "Hello\n\n![x](./a.jpg|240r)\n\nBye");

    // 左对齐 = 无字母：|240r -> |240。
    await tester.tap(find.byIcon(Icons.format_align_left));
    await tester.pumpAndSettle();
    expect(editorState.getNote().body, "Hello\n\n![x](./a.jpg|240)\n\nBye");

    // 菜单外点击退出选中（欠着的文档重载落地），markup 稳定。
    await tester.tapAt(const Offset(10, 400));
    await tester.pumpAndSettle();
    expect(editorState.getNote().body, "Hello\n\n![x](./a.jpg|240)\n\nBye");
  });

  testWidgets('Aligning a plain markup writes the letter-only suffix',
      (tester) async {
    var note = buildNote("Hello\n\n![x](./a.jpg)\n\nBye", title: "Img");

    var errors = await pumpEditor(tester, note);
    expect(errors, isEmpty);

    final editorState =
        tester.state<MarkdownEditorState>(find.byType(MarkdownEditor));

    await tester.longPress(find.byType(GjImageComponent));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.format_align_center));
    await tester.pumpAndSettle();
    expect(editorState.getNote().body, "Hello\n\n![x](./a.jpg|c)\n\nBye");
  });

  testWidgets('Caret edge on an image boundary is text line-height tall',
      (tester) async {
    var note = buildNote("Hello\n\n![x](./a.jpg)\n\nBye", title: "Img");

    var errors = await pumpEditor(tester, note);
    expect(errors, isEmpty);

    final editor = tester.widget<SuperEditor>(find.byType(SuperEditor));
    final layout = editor.documentLayoutKey!.currentState! as DocumentLayout;
    final imageId =
        editor.editor.document.toList().whereType<ImageNode>().first.id;

    // 光标修正：选区落在图片块边界时，光标矩形按正文行高绘制、锚在图片
    // 前缘（Stock BoxComponent 返回整图高的 edge，渲染成等高细竖条）。
    final upstreamEdge = layout.getEdgeForPosition(DocumentPosition(
      nodeId: imageId,
      nodePosition: const UpstreamDownstreamNodePosition.upstream(),
    ));
    expect(upstreamEdge, isNotNull);
    expect(upstreamEdge!.height, closeTo(16 * 1.45, 0.5));

    final downstreamEdge = layout.getEdgeForPosition(DocumentPosition(
      nodeId: imageId,
      nodePosition: const UpstreamDownstreamNodePosition.downstream(),
    ));
    expect(downstreamEdge, isNotNull);
    expect(downstreamEdge!.height, closeTo(16 * 1.45, 0.5));
  });

  testWidgets('Tapping the blank space below a short note drops the caret '
      'at the document end (image edge)', (tester) async {
    var note = buildNote("Hello\n\n![x](./a.jpg)", title: "Img");

    var errors = await pumpEditor(tester, note);
    expect(errors, isEmpty);

    final superEditor = tester.widget<SuperEditor>(find.byType(SuperEditor));
    final editor = superEditor.editor;
    final imageId =
        editor.document.toList().whereType<ImageNode>().first.id;

    // The test surface is much taller than this note's content: everything
    // below the trailing image is dead space for super_editor's native
    // gesture layer. The fallback must park the caret on the image's
    // trailing edge. (Tap point computed from the content edge; the screen
    // bottom is occupied by the editor's bottom bar.)
    final editorRect = tester.getRect(find.byType(GjImageComponent));
    await tester.tapAt(Offset(400, editorRect.bottom + 100));
    await tester.pump();

    final selection = editor.composer.selection;
    expect(selection, isNotNull);
    expect(selection!.isCollapsed, isTrue);
    expect(selection.extent.nodeId, imageId);
    expect(
      selection.extent.nodePosition,
      const UpstreamDownstreamNodePosition.downstream(),
    );
  });

  testWidgets('Typing after a blank-space tap starts a fresh paragraph after '
      'the trailing image', (tester) async {
    var note = buildNote("Hello\n\n![x](./a.jpg)", title: "Img");

    var errors = await pumpEditor(tester, note);
    expect(errors, isEmpty);

    final superEditor = tester.widget<SuperEditor>(find.byType(SuperEditor));
    final editor = superEditor.editor;

    final editorRect = tester.getRect(find.byType(GjImageComponent));
    await tester.tapAt(Offset(400, editorRect.bottom + 100));
    await tester.pump();

    // The on-device IME path (document_delta_editing._insertPlainText) runs
    // exactly these two steps for a caret sitting on an image edge: first a
    // block newline (spawns a paragraph after the image), then the text.
    editor.execute([InsertNewlineAtCaretRequest()]);
    await tester.pump();
    editor.execute([
      InsertTextRequest(
        documentPosition: editor.composer.selection!.extent,
        textToInsert: 'typed',
        attributions: {},
      ),
    ]);

    // 图片后新起段落承载文字，图片节点仍在其前。
    final nodes = editor.document.toList();
    expect(nodes.length, 3);
    expect(nodes[0], isA<ParagraphNode>());
    expect(nodes[1], isA<ImageNode>());
    expect((nodes[2] as ParagraphNode).text.toPlainText(), 'typed');

    // 序列化 markdown：图片 markup 在 typed 文字之前。
    final bodyState =
        tester.state<SuperEditorBodyState>(find.byType(SuperEditorBody));
    bodyState.flushPendingWrite();
    await tester.pump();

    final body =
        tester.state<MarkdownEditorState>(find.byType(MarkdownEditor))
            .getNote()
            .body;
    expect(body, contains('typed'));
    expect(body.indexOf('![x](./a.jpg)'), lessThan(body.indexOf('typed')));
  });

  testWidgets('Focus change after an external reload keeps the old composer '
      'usable (regression: Cannot add new events after calling close)',
      (tester) async {
    var errors = <FlutterErrorDetails>[];
    var originalOnError = FlutterError.onError;
    FlutterError.onError = (details) => errors.add(details);

    var controller = TextEditingController(text: "Hello World");
    var focusTarget = FocusNode();

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Focus(focusNode: focusTarget, child: const SizedBox()),
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.all(16),
                        sliver: SuperEditorBody(
                          textController: controller,
                          imageDir: '/gj_test_images',
                          autofocus: true,
                          onChanged: () {},
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      // Bounded pumps, not pumpAndSettle: a focused super_editor blinks its
      // caret and keeps scheduling frames forever.
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SuperEditor), findsOneWidget);

      // The autofocus grabbed focus inside the editor body.
      final primaryFocus = FocusManager.instance.primaryFocus;
      expect(primaryFocus, isNotNull);
      expect(
        primaryFocus!.context
            ?.findAncestorStateOfType<SuperEditorBodyState>(),
        isNotNull,
      );

      // External change (image insertion, undo, search replace): reload the
      // whole document while the old editor holds focus and a selection.
      controller.text = "Hello external reload";

      // Simulate the system focus fight seen on some phones: move focus
      // away right after the reload. Before the fix, the old composer was
      // disposed synchronously while the old SuperEditor widget was still
      // mounted, so this focus change executed a ClearSelectionRequest on
      // it and threw "Bad state: Cannot add new events after calling close"
      // - which fails this test as an uncaught exception.
      focusTarget.requestFocus();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    } finally {
      FlutterError.onError = originalOnError;
    }

    expect(
      errors.where(
          (e) => e.toString().contains('Cannot add new events after calling close')),
      isEmpty,
    );
  });
}

class _NoopEditorCommon implements EditorCommon {
  @override
  void discardChanges(Note note) {}

  @override
  void renameNote(Note note) {}

  @override
  void editTags(Note note) {}

  @override
  void deleteNote(Note note) {}

  @override
  void moveNoteToFolderSelected(Note note) {}

  @override
  void exitEditorSelected(Note note) {}
}
