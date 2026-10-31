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

  testWidgets('Tapping an image toggles the |240 thumbnail suffix',
      (tester) async {
    var note = buildNote("Hello\n\n![x](./a.jpg)\n\nBye", title: "Img");

    var errors = await pumpEditor(tester, note);
    expect(errors, isEmpty);
    expect(find.byType(GjImageComponent), findsOneWidget);

    final editorState =
        tester.state<MarkdownEditorState>(find.byType(MarkdownEditor));

    await tester.tap(find.byType(GjImageComponent));
    await tester.pump(const Duration(milliseconds: 400));
    expect(editorState.getNote().body, "Hello\n\n![x](./a.jpg|240)\n\nBye");

    // The document reloaded with the suffix, so the component is new: tap
    // again to go back to full width.
    expect(find.byType(GjImageComponent), findsOneWidget);
    await tester.tap(find.byType(GjImageComponent));
    await tester.pump(const Duration(milliseconds: 400));
    expect(editorState.getNote().body, "Hello\n\n![x](./a.jpg)\n\nBye");
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
