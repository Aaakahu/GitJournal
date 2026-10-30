/*
 * SPDX-FileCopyrightText: 2019-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gitjournal/l10n.dart';
import 'package:gitjournal/repository_manager.dart';
import 'package:gitjournal/settings/app_config.dart';
import 'package:gitjournal/settings/settings.dart';
import 'package:provider/provider.dart';

class AppDrawerHeader extends StatelessWidget {
  const AppDrawerHeader({super.key});

  @override
  Widget build(BuildContext context) {
    var appConfig = context.watch<AppConfig>();
    var repoManager = context.watch<RepositoryManager>();

    var top = Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const DecoratedBox(
          decoration: BoxDecoration(
            image: DecorationImage(
              image: AssetImage('assets/icon/icon.png'),
            ),
          ),
          child: SizedBox(width: 64, height: 64),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 8, 0),
          child: ThemeSwitcherButton(),
        ),
      ],
    );

    var repoName = Text(
      repoManager.repoFolderName(repoManager.currentId),
      style: Theme.of(context).textTheme.titleLarge,
    );

    var header = DrawerHeader(
      margin: const EdgeInsets.all(0.0),
      decoration: BoxDecoration(
        color: Theme.of(context).highlightColor,
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          top,
          repoName,
        ],
      ),
    );

    if (!appConfig.proMode) {
      return header;
    }

    var isDesktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;
    return Banner(
      message: isDesktop ? context.loc.beta : context.loc.pro,
      location: BannerLocation.topStart,
      color: Theme.of(context).colorScheme.secondary,
      child: header,
    );
  }
}

class ThemeSwitcherButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      child: const FaIcon(FontAwesomeIcons.solidMoon),
      onTap: () {
        var theme = Theme.of(context);
        var settings = context.read<Settings>();

        if (theme.brightness == Brightness.light) {
          settings.theme = SettingsTheme.Dark;
        } else {
          settings.theme = SettingsTheme.Light;
        }
        settings.save();
      },
    );
  }
}
