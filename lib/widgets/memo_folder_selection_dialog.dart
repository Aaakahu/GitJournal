/*
 * SPDX-FileCopyrightText: 2026 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter/material.dart';
import 'package:gitjournal/core/folder/notes_folder_fs.dart';
import 'package:gitjournal/l10n.dart';
import 'package:gitjournal/settings/app_config.dart';
import 'package:provider/provider.dart';

/// Dialog listing the default memo folder (repo root) and the user created
/// memo folders. Returns the selected [NotesFolderFS].
class MemoFolderSelectionDialog extends StatelessWidget {
  const MemoFolderSelectionDialog({super.key});

  @override
  Widget build(BuildContext context) {
    var rootFolder = context.read<NotesFolderFS>();
    var memoFolders = context.watch<AppConfig>().memoFolders;

    return SimpleDialog(
      title: Text(context.loc.memoFoldersMoveToTitle),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(rootFolder),
          child: ListTile(
            leading: const Icon(Icons.folder),
            title: Text(context.loc.memoFoldersDefault),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        for (var folderPath in memoFolders)
          SimpleDialogOption(
            onPressed: () {
              var folder = rootFolder.getOrBuildFolderWithSpec(folderPath);
              Navigator.of(context).pop(folder);
            },
            child: ListTile(
              leading: const Icon(Icons.folder),
              title: Text(folderPath),
              contentPadding: EdgeInsets.zero,
            ),
          ),
      ],
    );
  }
}
