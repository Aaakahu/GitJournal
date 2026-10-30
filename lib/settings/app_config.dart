/*
 * SPDX-FileCopyrightText: 2020-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:gitjournal/logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppConfig extends ChangeNotifier {
  // singleton
  static final AppConfig _singleton = AppConfig._internal();
  factory AppConfig() => _singleton;
  AppConfig._internal();
  static AppConfig get instance => _singleton;

  //
  // Properties
  //
  var onBoardingCompleted = false;
  var collectCrashReports = true;

  int version = 0;

  bool proMode = false;

  var validateProMode = true;

  var debugLogLevel = 'v';

  var experimentalSubfolders = false;
  var experimentalMarkdownToolbar = false;
  var experimentalAccounts = false;
  var experimentalTagAutoCompletion = false;

  // Live Markdown preview in the editor (split screen)
  var livePreview = false;

  // WYSIWYG markdown editing (super_editor). Notes that can't round-trip
  // safely fall back to the plain text editor automatically.
  var richMarkdownEditor = true;

  // User created memo folders, as repo relative paths (repo root direct
  // children only). The physical directory is created lazily when the first
  // note is written into it.
  var memoFolders = <String>[];

  void load(SharedPreferences pref) {
    onBoardingCompleted = pref.getBool("onBoardingCompleted") ?? true;

    collectCrashReports =
        pref.getBool("collectCrashReports") ?? collectCrashReports;

    version = pref.getInt("appSettingsVersion") ?? version;
    proMode = pref.getBool("proMode") ?? proMode;
    validateProMode = pref.getBool("validateProMode") ?? validateProMode;

    debugLogLevel = pref.getString("debugLogLevel") ?? debugLogLevel;
    experimentalSubfolders =
        pref.getBool("experimentalSubfolders") ?? experimentalSubfolders;
    experimentalMarkdownToolbar = pref.getBool("experimentalMarkdownToolbar") ??
        experimentalMarkdownToolbar;
    experimentalAccounts =
        pref.getBool("experimentalAccounts") ?? experimentalAccounts;
    experimentalTagAutoCompletion =
        pref.getBool("experimentalTagAutoCompletion") ??
            experimentalTagAutoCompletion;
    livePreview = pref.getBool("livePreview") ?? livePreview;
    richMarkdownEditor =
        pref.getBool("richMarkdownEditor") ?? richMarkdownEditor;
    memoFolders = pref.getStringList("memoFolders") ?? memoFolders;
  }

  Future<void> save() async {
    var pref = await SharedPreferences.getInstance();
    var defaultSet = AppConfig._internal();

    pref.setBool("onBoardingCompleted", onBoardingCompleted);

    _setBool(pref, "collectCrashReports", collectCrashReports,
        defaultSet.collectCrashReports);

    _setBool(pref, "proMode", proMode, defaultSet.proMode);
    _setBool(
        pref, "validateProMode", validateProMode, defaultSet.validateProMode);
    _setString(pref, "debugLogLevel", debugLogLevel, defaultSet.debugLogLevel);
    _setBool(pref, "experimentalSubfolders", experimentalSubfolders,
        defaultSet.experimentalSubfolders);
    _setBool(pref, "experimentalMarkdownToolbar", experimentalMarkdownToolbar,
        defaultSet.experimentalMarkdownToolbar);
    _setBool(pref, "experimentalAccounts", experimentalAccounts,
        defaultSet.experimentalAccounts);
    _setBool(
        pref,
        "experimentalTagAutoCompletion",
        experimentalTagAutoCompletion,
        defaultSet.experimentalTagAutoCompletion);
    _setBool(pref, "livePreview", livePreview, defaultSet.livePreview);
    _setBool(pref, "richMarkdownEditor", richMarkdownEditor,
        defaultSet.richMarkdownEditor);

    if (memoFolders.isEmpty) {
      await pref.remove("memoFolders");
    } else {
      await pref.setStringList("memoFolders", memoFolders);
    }

    pref.setInt("appSettingsVersion", version);

    notifyListeners();
  }

  Map<String, String> toMap() {
    return {
      "onBoardingCompleted": onBoardingCompleted.toString(),
      "collectCrashReports": collectCrashReports.toString(),
      "version": version.toString(),
      'validateProMode': validateProMode.toString(),
      'proMode': proMode.toString(),
      'debugLogLevel': debugLogLevel,
      'experimentalMarkdownToolbar': experimentalMarkdownToolbar.toString(),
      'experimentalAccounts': experimentalAccounts.toString(),
      'experimentalTagAutoCompletion': experimentalTagAutoCompletion.toString(),
      'livePreview': livePreview.toString(),
      'memoFolders': memoFolders.toString(),
    };
  }

  Future<void> _setString(
    SharedPreferences pref,
    String key,
    String value,
    String defaultValue,
  ) async {
    if (value == defaultValue) {
      await pref.remove(key);
    } else {
      await pref.setString(key, value);
    }
  }

  Future<void> _setBool(
    SharedPreferences pref,
    String key,
    bool value,
    bool defaultValue,
  ) async {
    if (value == defaultValue) {
      await pref.remove(key);
    } else {
      await pref.setBool(key, value);
    }
  }
}

extension Date on SharedPreferences {
  DateTime? getDateTime(String key) {
    try {
      var v = getInt(key);
      if (v == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(v * 1000);
    } catch (e, st) {
      Log.e("getDataTime", ex: e, stacktrace: st);
      return null;
    }
  }
}
