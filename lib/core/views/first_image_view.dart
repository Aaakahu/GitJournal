/*
 * SPDX-FileCopyrightText: 2019-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter/material.dart';

import 'package:nested/nested.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:universal_io/io.dart';

import 'package:gitjournal/core/note.dart';
import 'package:gitjournal/utils/markdown.dart';
import 'package:gitjournal/widgets/expressive_image_frame.dart';
import 'notes_materialized_view.dart';

typedef NotesFirstImageView = NotesMaterializedView<String>;

class NoteFirstImageProvider extends SingleChildStatelessWidget {
  final String repoId;

  const NoteFirstImageProvider({
    super.key,
    super.child,
    required this.repoId,
  });

  @override
  Widget buildWithChild(BuildContext context, Widget? child) {
    return Provider(
      create: (_) {
        return NotesFirstImageView(
          name: 'first_image',
          repoId: repoId,
          computeFn: _compute,
        );
      },
      child: child,
    );
  }

  static NotesFirstImageView of(BuildContext context) {
    return Provider.of<NotesFirstImageView>(context);
  }
}

// Returns the absolute path of the note's first local image,
// or an empty string if there is none.
Future<String> _compute(Note note) async {
  var imagePath = firstLocalImagePath(note.body);
  if (imagePath == null) return "";

  var fullPath = p.normalize(
    p.join(note.repoPath, note.parent.folderPath, imagePath),
  );
  var file = File(fullPath);
  if (!file.existsSync()) return "";
  return fullPath;
}

/// Renders the note's first image as a thumbnail. The image path is fetched
/// through the materialized view, so the body isn't re-parsed and the
/// filesystem isn't hit on every frame.
class NoteFirstImageThumbnail extends StatelessWidget {
  final Note note;
  final double? width;
  final double? height;

  /// Caps the image height while keeping its intrinsic aspect ratio; the
  /// cover fit crops the overflow. The leading [height] stays an exact fit.
  final double? maxHeight;
  final int cacheWidth;

  const NoteFirstImageThumbnail({
    super.key,
    required this.note,
    this.width,
    this.height,
    this.maxHeight,
    this.cacheWidth = 256,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: NoteFirstImageProvider.of(context).fetch(note),
      builder: (context, snapshot) {
        var path = snapshot.data;
        if (path == null || path.isEmpty) {
          return const SizedBox();
        }
        Widget image = Image.file(
          File(path),
          width: width,
          height: height,
          fit: BoxFit.cover,
          cacheWidth: cacheWidth,
          frameBuilder: expressiveImageFrameBuilder,
          errorBuilder: (_, __, ___) => const SizedBox(),
        );
        if (maxHeight != null) {
          image = ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight!),
            child: image,
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(4.0),
          child: image,
        );
      },
    );
  }
}
