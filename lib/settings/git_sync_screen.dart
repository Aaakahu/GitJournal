/*
 * SPDX-FileCopyrightText: 2019-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:git_setup/keygen.dart';
import 'package:git_setup/screens.dart';
import 'package:git_setup/sshkey.dart';
import 'package:gitjournal/l10n.dart';
import 'package:gitjournal/logger/logger.dart';
import 'package:gitjournal/repository.dart';
import 'package:gitjournal/settings/git_config.dart';
import 'package:gitjournal/settings/settings.dart';
import 'package:gitjournal/settings/widgets/settings_list_preference.dart';
import 'package:gitjournal/ssh/keygen.dart';
import 'package:gitjournal/utils/utils.dart';
import 'package:gitjournal/widgets/setup.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:universal_io/io.dart';

/// 统一的「Git 同步」页面：仓库 / 同步 / SSH 密钥 / 危险操作 四个分区。
///
/// repo 与 gitConfig 由入口（抽屉）以构造参数传入 —— 无仓库时
/// provider 层不提供 repo 相关 provider，不能 context.watch。
class GitSyncScreen extends StatefulWidget {
  static const routePath = '/settings/gitSync';

  final GitJournalRepo? repo;
  final GitConfig? gitConfig;

  const GitSyncScreen({
    super.key,
    required this.repo,
    required this.gitConfig,
  });

  @override
  GitSyncScreenState createState() => GitSyncScreenState();
}

class GitSyncScreenState extends State<GitSyncScreen> {
  var _remoteUrl = "";
  DateTime? _lastSyncTime;
  var _syncing = false;
  var _canResetHard = false;

  @override
  void initState() {
    super.initState();

    var repo = widget.repo;
    if (repo == null) {
      // 未配置仓库 = 打开即配置向导（路由由 AppRouter 注册）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.of(context).pushReplacementNamed(GitHostSetupScreen.routePath);
      });
      return;
    }

    repo.remoteConfigs().then((list) {
      if (!mounted) return;
      setState(() {
        _remoteUrl = list.isEmpty ? "" : list.first.url;
      });
    });
    repo.canResetHard().then((canReset) {
      if (!mounted) return;
      setState(() {
        _canResetHard = canReset;
      });
    }).catchError((e, st) {
      Log.e("GitSyncScreen canResetHard", ex: e, stacktrace: st);
    });
  }

  @override
  Widget build(BuildContext context) {
    var repo = widget.repo;
    var gitConfig = widget.gitConfig;
    var textTheme = Theme.of(context).textTheme;
    var loc = context.loc;

    if (repo == null || gitConfig == null) {
      // 正在跳往配置向导。
      return Scaffold(
        appBar: AppBar(title: Text(loc.drawerGitSync)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    var settings = repo.settings;

    var body = ListView(
      children: [
        _SectionHeader(loc.gitSyncRepoSectionTitle, loc.gitSyncRepoSectionDesc),
        ListTile(
          title: Text(loc.gitSyncRemoteUrl),
          subtitle: Text(_remoteUrl.isEmpty ? "—" : _remoteUrl),
        ),
        ListTile(
          title: Text(loc.settingsGitRemoteBranch),
          subtitle: Text(repo.currentBranch ?? "—"),
        ),
        Button(
          text: loc.settingsGitRemoteChangeHostTitle,
          onPressed: _reconfigureGitHost,
        ),
        _SectionHeader(
            loc.gitSyncSyncSectionTitle, loc.gitSyncSyncSectionDesc),
        Button(
          text: _syncing ? loc.gitSyncSyncing : loc.gitSyncSyncNow,
          onPressed: _syncNow,
        ),
        ListTile(
          title: Text(loc.gitSyncLastSync),
          subtitle: Text(_lastSyncTime == null
              ? "—"
              : DateFormat('yyyy-MM-dd HH:mm').format(_lastSyncTime!)),
        ),
        ListPreference(
          title: loc.settingsSshSyncFreq,
          currentOption:
              settings.remoteSyncFrequency.toPublicString(context),
          options: RemoteSyncFrequency.options
              .map((f) => f.toPublicString(context))
              .toList(),
          onChange: (String publicStr) {
            var val = RemoteSyncFrequency.fromPublicString(context, publicStr);
            settings.remoteSyncFrequency = val;
            settings.save();
            setState(() {});
          },
        ),
        _SectionHeader(
            loc.gitSyncSshSectionTitle, loc.gitSyncSshSectionDesc),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Text(
            loc.setupSshKeyUserProvidedPublic,
            style: textTheme.bodyLarge,
            textAlign: TextAlign.left,
          ),
        ),
        const SizedBox(height: 16.0),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: PublicKeyWidget(gitConfig.sshPublicKey),
        ),
        const SizedBox(height: 16.0),
        Button(
          text: loc.setupSshKeyCopy,
          onPressed: () => _copyKeyToClipboard(context),
        ),
        Button(
          text: loc.setupSshKeyRegenerate,
          onPressed: () => _generateSshKey(context),
        ),
        Button(
          text: loc.setupSshKeyChoiceCustom,
          onPressed: _customSshKeys,
        ),
        _SectionHeader(loc.gitSyncDangerSectionTitle,
            loc.gitSyncDangerSectionDesc,
            danger: true),
        if (_canResetHard)
          RedButton(
            text: loc.settingsGitRemoteResetHardTitle,
            onPressed: _resetGitHost,
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.drawerGitSync),
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

  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
    });

    // Transient server failures (e.g. "GitPush failed: unpack error") get
    // one automatic retry after a short wait. The button keeps its
    // "syncing" state the whole time, so a second tap is a no-op, and the
    // error is only surfaced after both attempts failed.
    Object? error;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!mounted) return;
      }
      try {
        await widget.repo!.syncNotes();
        if (!mounted) return;
        setState(() {
          _syncing = false;
          _lastSyncTime = DateTime.now();
        });
        return;
      } catch (ex, st) {
        Log.e("GitSyncScreen syncNotes", ex: ex, stacktrace: st);
        error = ex;
      }
    }

    if (!mounted) return;
    setState(() {
      _syncing = false;
    });
    showErrorSnackbar(context, error!);
  }

  void _customSshKeys() {
    var route = MaterialPageRoute(
      builder: (context) => Scaffold(
        body: GitHostUserProvidedKeysPage(
          doneFunction: _updateKeys,
          saveText: context.loc.setupSshKeySave,
        ),
        appBar: AppBar(
          title: Text(context.loc.setupSshKeyChoiceCustom),
        ),
      ),
      settings: const RouteSettings(name: '/settings/gitSync/customKeys'),
    );
    Navigator.push(context, route);
  }

  void _updateKeys(String publicKey, String privateKey, String password) {
    var config = widget.gitConfig!;

    if (publicKey.isEmpty || privateKey.isEmpty) {
      return;
    }
    config.sshPublicKey = publicKey;
    config.sshPrivateKey = privateKey;
    config.sshPassword = password;
    config.save();

    Navigator.of(context).pop();
  }

  void _copyKeyToClipboard(BuildContext context) {
    Clipboard.setData(ClipboardData(text: widget.gitConfig!.sshPublicKey));
    showSnackbar(context, context.loc.setupSshKeyCopied);
  }

  void _generateSshKey(BuildContext context) {
    var keyType = widget.gitConfig!.sshKeyType;
    var comment =
        "GitJournal-${Platform.operatingSystem}-${DateTime.now().toIso8601String().substring(0, 10)}"; // only the date

    GitJournalKeygen()
        .generate(type: keyType, comment: comment)
        .then((SshKey? sshKey) {
      if (sshKey == null) return;
      var config = widget.gitConfig!;
      config.sshPublicKey = sshKey.publicKey;
      config.sshPrivateKey = sshKey.privateKey;
      config.sshPassword = sshKey.password;
      config.save();

      Log.d("PublicKey: ${sshKey.publicKey}");
      if (!mounted) return;
      _copyKeyToClipboard(context);
    });
  }

  Future<void> _reconfigureGitHost() async {
    var ok = await showDialog(
      context: context,
      builder: (_) => IrreversibleActionConfirmationDialog(
        title: context.loc.settingsGitRemoteChangeHostTitle,
        subtitle: context.loc.settingsGitRemoteChangeHostSubtitle,
      ),
    );
    if (ok == null) {
      return;
    }

    var repo = widget.repo!;
    var gitDir = repo.gitBaseDirectory;

    // Figure out the next available folder
    String repoFolderName = "journal_";
    var num = 0;
    while (true) {
      var repoFolderPath = p.join(gitDir, "$repoFolderName$num");
      if (!Directory(repoFolderPath).existsSync()) {
        try {
          await repo.init(repoFolderPath);
        } catch (ex) {
          showErrorSnackbar(context, ex);
        }
        break;
      }
      num++;
    }
    repoFolderName = repoFolderName + num.toString();

    var storageConfig = repo.storageConfig;
    storageConfig.folderName = repoFolderName;
    storageConfig.storeInternally = true;
    await storageConfig.save();

    var route = MaterialPageRoute(
      builder: (context) => GitJournalGitSetupScreen(
        repoFolderName: repoFolderName,
        onCompletedFunction: repo.completeGitHostSetup,
      ),
      settings: const RouteSettings(name: '/setupRemoteGit'),
    );
    await Navigator.push(context, route);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _resetGitHost() async {
    var ok = await showDialog(
      context: context,
      builder: (_) => IrreversibleActionConfirmationDialog(
        title: context.loc.settingsGitRemoteResetHardTitle,
        subtitle: context.loc.settingsGitRemoteResetHardSubtitle,
      ),
    );
    if (ok == null) {
      return;
    }

    try {
      await widget.repo!.resetHard();
    } catch (ex) {
      showErrorSnackbar(context, ex);
    }

    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

/// 分区标题 + 一句话说明；danger = true 时标题为红色（危险区）。
class _SectionHeader extends StatelessWidget {
  final String title;
  final String desc;
  final bool danger;

  const _SectionHeader(this.title, this.desc, {this.danger = false});

  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);
    var titleColor = danger ? Colors.red : theme.colorScheme.secondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            title,
            style: TextStyle(color: titleColor, fontWeight: FontWeight.bold),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 8.0),
          child: Text(desc, style: theme.textTheme.bodySmall),
        ),
      ],
    );
  }
}

class Button extends StatelessWidget {
  final String text;
  final void Function() onPressed;

  const Button({required this.text, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          style: ButtonStyle(
            backgroundColor:
                WidgetStateProperty.all<Color>(theme.primaryColor),
            foregroundColor:
                WidgetStateProperty.all<Color>(theme.colorScheme.onPrimary),
          ),
          onPressed: onPressed,
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelLarge
                ?.copyWith(color: theme.colorScheme.onPrimary),
          ),
        ),
      ),
    );
  }
}

class RedButton extends StatelessWidget {
  final String text;
  final void Function() onPressed;

  const RedButton({required this.text, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.all<Color>(Colors.red),
        ),
        onPressed: onPressed,
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}

class IrreversibleActionConfirmationDialog extends StatelessWidget {
  final String title;
  final String subtitle;

  const IrreversibleActionConfirmationDialog(
      {required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: Text(subtitle),
      actions: <Widget>[
        TextButton(
          child: Text(context.loc.settingsGitRemoteChangeHostCancel),
          onPressed: () => Navigator.of(context).pop(),
        ),
        TextButton(
          child: Text(context.loc.settingsGitRemoteChangeHostOk),
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}
