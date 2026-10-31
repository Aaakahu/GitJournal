/*
 * SPDX-FileCopyrightText: 2019-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter/material.dart';
import 'package:git_setup/screens.dart';
import 'package:gitjournal/analytics/analytics.dart';
import 'package:gitjournal/l10n.dart';
import 'package:gitjournal/logger/logger.dart';
import 'package:gitjournal/repository_manager.dart';
import 'package:gitjournal/screens/home_screen.dart';
import 'package:gitjournal/screens/memo_folders_screen.dart';
import 'package:gitjournal/settings/settings_git_remote.dart';
import 'package:gitjournal/settings/settings_screen.dart';
import 'package:gitjournal/widgets/app_drawer_header.dart';
import 'package:provider/provider.dart';

class AppDrawer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    var currentRoute = ModalRoute.of(context)!.settings.name;
    var divider = const Row(children: <Widget>[Expanded(child: Divider())]);
    var repoManager = context.watch<RepositoryManager>();
    var repo = repoManager.currentRepo;

    return Drawer(
      child: ListView(
        // Important: Remove any padding from the ListView.
        padding: EdgeInsets.zero,
        children: <Widget>[
          const AppDrawerHeader(),
          _buildDrawerTile(
            context,
            icon: Icons.note,
            title: context.loc.drawerAll,
            onTap: () => _navTopLevel(context, HomeScreen.routePath),
            selected: currentRoute == HomeScreen.routePath,
          ),
          _buildDrawerTile(
            context,
            icon: Icons.folder,
            title: context.loc.memoFoldersTitle,
            onTap: () => _navTopLevel(context, MemoFoldersScreen.routePath),
            selected: currentRoute == MemoFoldersScreen.routePath,
          ),
          divider,
          // Git 配置：完整的 SSH/HTTP 远端设置（1.90.4 入口恢复）。
          _buildDrawerTile(
            context,
            icon: Icons.settings_remote,
            title: context.loc.settingsGitRemoteTitle,
            onTap: () => _navTopLevel(context, GitRemoteSettingsScreen.routePath),
            selected: currentRoute == GitRemoteSettingsScreen.routePath,
          ),
          // 仓库尚未配置远端时，显示初始配置向导（SSH/HTTP 选择）。
          if (repo?.remoteGitRepoConfigured == false)
            _buildDrawerTile(
              context,
              icon: Icons.sync,
              title: context.loc.drawerSetup,
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, GitHostSetupScreen.routePath);
                logEvent(Event.DrawerSetupGitHost);
              },
            ),
          divider,
          _buildDrawerTile(
            context,
            icon: Icons.settings,
            title: context.loc.settingsTitle,
            onTap: () => _navTopLevel(context, SettingsScreen.routePath),
            selected: currentRoute == SettingsScreen.routePath,
          ),
        ],
      ),
    );
  }

  Widget _buildDrawerTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required void Function() onTap,
    bool selected = false,
  }) {
    var theme = Theme.of(context);
    var listTileTheme = ListTileTheme.of(context);
    var textStyle = theme.textTheme.bodyLarge!.copyWith(
      color: selected ? theme.colorScheme.secondary : listTileTheme.textColor,
    );

    var tile = ListTile(
      leading: Icon(icon, color: textStyle.color),
      title: Text(title, style: textStyle),
      onTap: onTap,
      selected: selected,
    );
    return Container(
      color: selected ? theme.highlightColor : theme.scaffoldBackgroundColor,
      child: tile,
    );
  }
}

void _navTopLevel(BuildContext context, String toRoute) {
  var fromRoute = ModalRoute.of(context)!.settings.name;
  Log.i("Routing from $fromRoute -> $toRoute");

  // Always first pop the AppBar
  Navigator.pop(context);

  if (fromRoute == toRoute) {
    return;
  }

  var wasParent = false;
  Navigator.popUntil(
    context,
    (route) {
      if (route.isFirst) {
        return true;
      }
      wasParent = route.settings.name == toRoute;
      if (wasParent) {
        Log.i("Router popping ${route.settings.name}");
      }
      return wasParent;
    },
  );
  if (!wasParent) {
    Navigator.pushNamed(context, toRoute);
  }
}
