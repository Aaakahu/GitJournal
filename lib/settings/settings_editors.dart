/*
 * SPDX-FileCopyrightText: 2019-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter/material.dart';
import 'package:gitjournal/l10n.dart';
import 'package:gitjournal/settings/settings.dart';
import 'package:gitjournal/settings/settings_storage.dart';
import 'package:gitjournal/settings/widgets/settings_list_preference.dart';
import 'package:provider/provider.dart';

class SettingsEditorsScreen extends StatefulWidget {
  static const routePath = '/settings/editors';

  @override
  SettingsEditorsScreenState createState() => SettingsEditorsScreenState();
}

class SettingsEditorsScreenState extends State<SettingsEditorsScreen> {
  @override
  Widget build(BuildContext context) {
    var settings = context.watch<Settings>();

    var body = ListView(children: <Widget>[
      const DefaultFileFormatTile(),
      ListPreference(
        title: context.loc.settingsEditorsDefaultState,
        currentOption: settings.markdownDefaultView.toPublicString(context),
        options: SettingsMarkdownDefaultView.options
            .map((f) => f.toPublicString(context))
            .toList(),
        onChange: (String publicStr) {
          var val =
              SettingsMarkdownDefaultView.fromPublicString(context, publicStr);
          settings.markdownDefaultView = val;
          settings.save();
          setState(() {});
        },
      ),
    ]);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.loc.settingsEditorsTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
      ),
      body: body,
    );
  }
}
