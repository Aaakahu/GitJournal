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
import 'package:gitjournal/editors/editing_session_registry.dart';
import 'package:gitjournal/editors/markdown_editor.dart';
import 'package:gitjournal/l10n.dart';
import 'package:gitjournal/settings/app_config.dart';
import 'package:gitjournal/settings/settings.dart';
import 'package:gitjournal/themes.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    var repoPath = '${p.separator}editing_session_registry_test';
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

  tearDown(() {
    EditingSessionRegistry.endSession('note.md');
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
    var errors = <FlutterErrorDetails>[];
    var originalOnError = FlutterError.onError;
    FlutterError.onError = (details) => errors.add(details);

    try {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppConfig>.value(value: AppConfig()),
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

  Finder bodyText(String s) => find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().contains(s),
      );

  test('registry begin/end tracks the lease', () {
    expect(EditingSessionRegistry.isBeingEdited('a.md'), isFalse);

    EditingSessionRegistry.beginSession('a.md');
    expect(EditingSessionRegistry.isBeingEdited('a.md'), isTrue);

    EditingSessionRegistry.endSession('a.md');
    expect(EditingSessionRegistry.isBeingEdited('a.md'), isFalse);
  });

  testWidgets('登记期间 updateNote 回调不触发正文重载', (tester) async {
    var note = buildNote('editor content', title: 'T');
    var errors = await pumpEditor(tester, note);
    expect(errors, isEmpty);
    expect(bodyText('editor content'), findsWidgets);

    // 同步重载送来同路径、不同正文的新 Note 对象：租约在手，编辑器内容不被覆盖。
    EditingSessionRegistry.beginSession(note.filePath);
    var remote = buildNote('remote sync content', title: 'T');
    expect(remote.filePath, note.filePath);

    errors = await pumpEditor(tester, remote);
    expect(errors, isEmpty);
    expect(bodyText('remote sync content'), findsNothing);
    expect(bodyText('editor content'), findsWidgets);

    // 租约注销后（编辑器退出），外部更新照常重载。
    EditingSessionRegistry.endSession(remote.filePath);
    var remote2 = buildNote('final sync content', title: 'T');
    errors = await pumpEditor(tester, remote2);
    expect(errors, isEmpty);
    expect(bodyText('final sync content'), findsWidgets);
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
