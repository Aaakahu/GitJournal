/*
 * SPDX-FileCopyrightText: 2026 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gitjournal/core/folder/flattened_filtered_notes_folder.dart';
import 'package:gitjournal/core/folder/notes_folder_fs.dart';
import 'package:gitjournal/core/markdown/md_yaml_note_serializer.dart';
import 'package:gitjournal/core/note.dart';
import 'package:gitjournal/core/views/first_image_view.dart';
import 'package:gitjournal/core/views/inline_tags_view.dart';
import 'package:gitjournal/folder_views/folder_view.dart';
import 'package:gitjournal/l10n.dart';
import 'package:gitjournal/repository.dart';
import 'package:gitjournal/settings/app_config.dart';
import 'package:gitjournal/utils/utils.dart';
import 'package:gitjournal/widgets/app_bar_menu_button.dart';
import 'package:gitjournal/widgets/future_builder_with_progress.dart';
import 'package:gitjournal/widgets/rename_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

/// Apple-Notes style folders screen: All Notes, the default memo folder
/// (repo root), the user created memo folders and the tags.
class MemoFoldersScreen extends StatelessWidget {
  static const routePath = '/memoFolders';

  const MemoFoldersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    var rootFolder = context.watch<NotesFolderFS>();
    var appConfig = context.watch<AppConfig>();

    var allNotesCount = rootFolder.getAllNotes().length;
    var defaultFolderCount = rootFolder.notes.length;

    var memoFolderTiles = <Widget>[
      for (var folderPath in appConfig.memoFolders)
        _buildMemoFolderTile(context, rootFolder, folderPath),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(context.loc.memoFoldersTitle),
        leading: GJAppBarMenuButton(),
      ),
      body: ListView(
        children: <Widget>[
          ListTile(
            leading: FaIcon(
              FontAwesomeIcons.noteSticky,
              color: Theme.of(context).textTheme.displayLarge!.color,
            ),
            title: Text(context.loc.screensHomeAllNotes),
            trailing: Text('$allNotesCount'),
            onTap: () {
              // The card wall with everything is the initial route.
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
          ),
          ListTile(
            leading: FaIcon(
              FontAwesomeIcons.folder,
              color: Theme.of(context).textTheme.displayLarge!.color,
            ),
            title: Text(context.loc.memoFoldersDefault),
            trailing: Text('$defaultFolderCount'),
            onTap: () => _pushFolderView(context, rootFolder),
          ),
          ...memoFolderTiles,
          const Divider(),
          ListTile(
            leading: FaIcon(
              FontAwesomeIcons.folderPlus,
              color: Theme.of(context).textTheme.displayLarge!.color,
            ),
            title: Text(context.loc.memoFoldersNewFolder),
            onTap: () => _createMemoFolder(context),
          ),
          const Divider(),
          _TagsSection(),
        ],
      ),
    );
  }

  Widget _buildMemoFolderTile(
    BuildContext context,
    NotesFolderFS rootFolder,
    String folderPath,
  ) {
    var folder = rootFolder.getFolderWithSpec(folderPath);
    var numNotes = folder?.notes.length ?? 0;

    return ListTile(
      leading: FaIcon(
        FontAwesomeIcons.folder,
        color: Theme.of(context).textTheme.displayLarge!.color,
      ),
      title: Text(folderPath),
      trailing: Text('$numNotes'),
      onTap: () {
        var folder = rootFolder.getOrBuildFolderWithSpec(folderPath);
        _pushFolderView(context, folder);
      },
      onLongPress: () => _showMemoFolderActions(context, folderPath),
    );
  }

  void _pushFolderView(BuildContext context, NotesFolderFS folder) {
    var route = MaterialPageRoute(
      builder: (context) => FolderView(notesFolder: folder),
      settings: const RouteSettings(name: '/folder/'),
    );
    Navigator.push(context, route);
  }

  Future<void> _createMemoFolder(BuildContext context) async {
    var folderName = await showDialog<String>(
      context: context,
      builder: (_) => _NewMemoFolderDialog(),
    );
    if (folderName is! String || !context.mounted) return;

    var appConfig = context.read<AppConfig>();
    if (appConfig.memoFolders.contains(folderName)) {
      showSnackbar(context, context.loc.memoFoldersDuplicateName);
      return;
    }

    appConfig.memoFolders.add(folderName);
    await appConfig.save();
  }

  Future<void> _showMemoFolderActions(BuildContext context, String folderPath) async {
    var action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.edit),
            title: Text(context.loc.screensFoldersActionsRename),
            onTap: () => Navigator.of(context).pop('rename'),
          ),
          ListTile(
            leading: const Icon(Icons.delete),
            title: Text(context.loc.screensFoldersActionsDelete),
            onTap: () => Navigator.of(context).pop('delete'),
          ),
        ],
      ),
    );
    if (action == null || !context.mounted) return;

    if (action == 'rename') {
      await _renameMemoFolder(context, folderPath);
    } else if (action == 'delete') {
      await _deleteMemoFolder(context, folderPath);
    }
  }

  Future<void> _renameMemoFolder(
    BuildContext context,
    String folderPath,
  ) async {
    var newName = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(
        oldPath: folderPath,
        inputDecoration: context.loc.screensFoldersActionsDecoration,
        dialogTitle: context.loc.screensFoldersActionsRename,
      ),
    );
    if (newName is! String || !context.mounted) return;

    if (p.basename(newName) != newName) {
      showErrorSnackbar(context, context.loc.screensFoldersActionsEmpty);
      return;
    }

    var appConfig = context.read<AppConfig>();
    var rootFolder = context.read<NotesFolderFS>();

    if (folderPath != newName && appConfig.memoFolders.contains(newName)) {
      showSnackbar(context, context.loc.memoFoldersDuplicateName);
      return;
    }

    var folder = rootFolder.getFolderWithSpec(folderPath);
    if (folder == null) {
      // The folder was never materialized on disk - just update the list.
      var i = appConfig.memoFolders.indexOf(folderPath);
      if (i != -1) {
        appConfig.memoFolders[i] = newName;
        await appConfig.save();
      }
      return;
    }

    var repo = context.read<GitJournalRepo>();

    // Collected before the rename for cache invalidation - the first-image
    // cache is keyed by (oid, mtime) which a folder rename doesn't change.
    var notes = folder.getAllNotes().toList();

    try {
      await repo.renameFolder(folder, newName);
    } catch (ex) {
      if (!context.mounted) return;
      showErrorSnackbar(context, ex);
      return;
    }

    var i = appConfig.memoFolders.indexOf(folderPath);
    if (i != -1) {
      appConfig.memoFolders[i] = newName;
      await appConfig.save();
    }

    await _invalidateFirstImages(context, notes);
  }

  Future<void> _deleteMemoFolder(
    BuildContext context,
    String folderPath,
  ) async {
    var confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.loc.memoFoldersDeleteConfirmTitle),
        content: Text(context.loc.memoFoldersDeleteConfirmBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.loc.screensFoldersDialogDiscard),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.loc.screensFoldersActionsDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    var appConfig = context.read<AppConfig>();
    var rootFolder = context.read<NotesFolderFS>();
    var repo = context.read<GitJournalRepo>();

    // Data safety: never delete the notes - move them back into the repo
    // root (the default memo folder). The physical directory is left alone.
    var notes = <Note>[];
    var folder = rootFolder.getFolderWithSpec(folderPath);
    if (folder != null) {
      notes = folder.getAllNotes().toList();
      if (notes.isNotEmpty) {
        try {
          await repo.moveNotes(notes, rootFolder);
        } catch (ex) {
          if (!context.mounted) return;
          showErrorSnackbar(context, ex);
          return;
        }
      }
    }

    appConfig.memoFolders.remove(folderPath);
    await appConfig.save();

    await _invalidateFirstImages(context, notes);
  }

  Future<void> _invalidateFirstImages(
    BuildContext context,
    List<Note> notes,
  ) async {
    if (notes.isEmpty || !context.mounted) return;
    var firstImageView = NoteFirstImageProvider.of(context);
    for (var note in notes) {
      await firstImageView.invalidate(note);
    }
  }
}

class _TagsSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    var rootFolder = context.watch<NotesFolderFS>();
    var inlineTagsView = InlineTagsProvider.of(context);

    return FutureBuilderWithProgress(future: () async {
      var allTags = await rootFolder.getNoteTagsRecursively(inlineTagsView);
      return _buildWithTagList(context, SplayTreeSet.from(allTags));
    }());
  }

  Widget _buildWithTagList(BuildContext context, Iterable<String> tags) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 8.0),
          child: Text(
            context.loc.screensTagsTitle,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        if (tags.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 16.0),
            child: Text(
              context.loc.screensTagsEmpty,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        for (var tag in tags)
          ListTile(
            leading: FaIcon(
              FontAwesomeIcons.tag,
              color: Theme.of(context).textTheme.displayLarge!.color,
            ),
            title: Text(tag),
            onTap: () => _pushTagView(context, tag),
          ),
      ],
    );
  }

  void _pushTagView(BuildContext context, String tag) {
    var route = MaterialPageRoute(
      builder: (context) => FutureBuilderWithProgress(
        future: _tagFolderView(context, tag),
      ),
      settings: const RouteSettings(name: '/tag/'),
    );
    Navigator.push(context, route);
  }
}

Future<FolderView> _tagFolderView(BuildContext context, String tag) async {
  var rootFolder = context.read<NotesFolderFS>();
  var inlineTagsView = InlineTagsProvider.of(context);

  var folder = await FlattenedFilteredNotesFolder.load(
    rootFolder,
    filter: (Note n) async {
      if (n.tags.contains(tag)) {
        return true;
      }

      var inlineTags = await inlineTagsView.fetch(n);
      if (inlineTags.contains(tag)) {
        return true;
      }

      return false;
    },
    title: tag,
  );

  final propNames = NoteSerializationSettings();
  return FolderView(
    notesFolder: folder,
    newNoteExtraProps: {
      propNames.tagsKey: [tag],
    },
  );
}

class _NewMemoFolderDialog extends StatefulWidget {
  @override
  _NewMemoFolderDialogState createState() => _NewMemoFolderDialogState();
}

class _NewMemoFolderDialogState extends State<_NewMemoFolderDialog> {
  final TextEditingController _textController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    var form = Form(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextFormField(
            decoration: InputDecoration(
              labelText: context.loc.screensFoldersActionsDecoration,
            ),
            validator: (value) {
              if (value!.isEmpty) {
                return context.loc.screensFoldersActionsEmpty;
              }
              if (value.contains(p.separator)) {
                return context.loc.screensFoldersActionsEmpty;
              }
              return "";
            },
            autofocus: true,
            keyboardType: TextInputType.text,
            textCapitalization: TextCapitalization.words,
            controller: _textController,
          ),
        ],
      ),
    );

    return AlertDialog(
      title: Text(context.loc.memoFoldersNewFolder),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.loc.screensFoldersDialogDiscard),
        ),
        TextButton(
          onPressed: () {
            var newFolderName = _textController.text.trim();
            if (newFolderName.isEmpty) {
              return;
            }
            return Navigator.of(context).pop(newFolderName);
          },
          child: Text(context.loc.screensFoldersDialogCreate),
        ),
      ],
      content: form,
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }
}
