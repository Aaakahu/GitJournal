/*
 * SPDX-FileCopyrightText: 2019-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter/foundation.dart' as foundation;
import 'package:flutter/material.dart';
import 'package:gitjournal/core/folder/notes_folder_fs.dart';
import 'package:gitjournal/core/note_storage.dart';
import 'package:gitjournal/l10n.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/note.dart';
import '../logger/logger.dart';
import '../repository.dart';

Future<String> getVersionString({bool includeAppName = true}) async {
  var info = await PackageInfo.fromPlatform();
  var versionText = "";
  if (includeAppName) {
    versionText += "${info.appName} ";
  }
  versionText += "${info.version}+${info.buildNumber}";

  if (foundation.kDebugMode) {
    versionText += " (Debug)";
  }

  return versionText;
}

SnackBar buildUndoDeleteSnackbar(
    BuildContext context, GitJournalRepo repo, Note deletedNote) {
  return SnackBar(
    content: Text(context.loc.widgetsFolderViewNoteDeleted),
    action: SnackBarAction(
      label: context.loc.widgetsFolderViewUndo,
      onPressed: () {
        Log.d("Undoing delete");
        repo.undoRemoveNote(deletedNote);
      },
    ),
  );
}

void showSnackbar(BuildContext context, String message) {
  var snackBar = SnackBar(content: Text(message));
  ScaffoldMessenger.of(context)
    ..removeCurrentSnackBar()
    ..showSnackBar(snackBar);
}

void showErrorMessageSnackbar(BuildContext context, String message) {
  var snackBar = SnackBar(content: Text(message));
  ScaffoldMessenger.of(context)
    ..removeCurrentSnackBar()
    ..showSnackBar(snackBar);
}

void showErrorSnackbar(BuildContext context, Object error) {
  assert(
    error is Error || error is Exception || error is String,
    "Error is ${error.runtimeType}",
  );
  var message = error.toString();
  showErrorMessageSnackbar(context, message);
}

Future<void> showAlertDialog(
    BuildContext context, String title, String message) async {
  var dialog = AlertDialog(
    title: Text(title),
    content: Text(message),
  );
  return showDialog(context: context, builder: (context) => dialog);
}

bool folderWithSpecExists(BuildContext context, String spec) {
  var rootFolder = context.read<NotesFolderFS>();

  return rootFolder.getFolderWithSpec(spec) != null;
}

Future<void> shareNote(Note note) async {
  await Share.share(NoteStorage.serialize(note));
}
