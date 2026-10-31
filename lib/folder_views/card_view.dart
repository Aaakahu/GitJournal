/*
 * SPDX-FileCopyrightText: 2019-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter/material.dart';

import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import 'package:gitjournal/core/folder/notes_folder.dart';
import 'package:gitjournal/core/notes/note.dart';
import 'package:gitjournal/folder_views/empty_text_sliver.dart';
import 'package:gitjournal/folder_views/note_tile.dart';

class CardView extends StatelessWidget {
  final NoteSelectedFunction noteTapped;
  final NoteSelectedFunction noteLongPressed;
  final NoteBoolPropertyFunction isNoteSelected;

  final NotesFolder folder;
  final String? emptyText;
  final bool fixedHeight;

  final String searchTerm;

  const CardView({
    required this.folder,
    required this.noteTapped,
    required this.noteLongPressed,
    required this.isNoteSelected,
    required this.emptyText,
    required this.searchTerm,
    this.fixedHeight = false,
  });

  @override
  Widget build(BuildContext context) {
    if (folder.isEmpty) {
      if (emptyText != null) {
        return EmptyTextSliver(emptyText: emptyText!);
      } else {
        return const SliverToBoxAdapter(child: SizedBox());
      }
    }

    Widget buildTile(BuildContext context, int index) {
      var note = folder.notes[index];
      var tile = NoteTile(
        note: note,
        noteTapped: noteTapped,
        noteLongPressed: noteLongPressed,
        selected: isNoteSelected(note),
        searchTerm: searchTerm,
      );
      if (fixedHeight) {
        return StaggeredGridTile.extent(
          crossAxisCellCount: 1,
          mainAxisExtent: 200.0,
          child: tile,
        );
      }
      return StaggeredGridTile.fit(crossAxisCellCount: 1, child: tile);
    }

    var gridView = SliverMasonryGrid.extent(
      itemBuilder: buildTile,
      childCount: folder.notes.length,
      maxCrossAxisExtent: 180.0,
      mainAxisSpacing: 8.0,
      crossAxisSpacing: 8.0,
    );

    return SliverPadding(
      sliver: gridView,
      padding: const EdgeInsets.fromLTRB(8.0, 12.0, 8.0, 12.0 + 48.0),
    );
  }
}
