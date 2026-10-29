/*
 * SPDX-FileCopyrightText: 2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter/material.dart';
import 'package:gitjournal/l10n.dart';
import 'package:gitjournal/settings/settings.dart';
import 'package:gitjournal/themes.dart';
import 'package:gitjournal/themes/glass_theme.dart';
import 'package:provider/provider.dart';

class SettingsThemeScreen extends StatefulWidget {
  static const routePath = '/settings/ui/theme';

  final Brightness brightness;

  const SettingsThemeScreen(this.brightness, {super.key});

  @override
  _SettingsThemeState createState() => _SettingsThemeState();
}

class _ThemeOption {
  final String internalName;
  final String label;
  final ThemeData themeData;

  const _ThemeOption(this.internalName, this.label, this.themeData);
}

class _SettingsThemeState extends State<SettingsThemeScreen> {
  @override
  Widget build(BuildContext context) {
    var settings = context.watch<Settings>();
    var selected = widget.brightness == Brightness.light
        ? settings.lightTheme
        : settings.darkTheme;

    var glassName = widget.brightness == Brightness.light
        ? GLASS_LIGHT_THEME_NAME
        : GLASS_DARK_THEME_NAME;
    var options = <_ThemeOption>[
      _ThemeOption(glassName, "Glass", Themes.fromName(glassName)),
      _ThemeOption(
        DEFAULT_LIGHT_THEME_NAME_LEGACY,
        context.loc.settingsThemeLight,
        Themes.fromName(DEFAULT_LIGHT_THEME_NAME_LEGACY),
      ),
      _ThemeOption(
        DEFAULT_DARK_THEME_NAME_LEGACY,
        context.loc.settingsThemeDark,
        Themes.fromName(DEFAULT_DARK_THEME_NAME_LEGACY),
      ),
    ];

    var title = widget.brightness == Brightness.light
        ? context.loc.settingsThemeLight
        : context.loc.settingsThemeDark;

    var body = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (var option in options)
          _optionCard(context, option, selected, settings),
      ],
    );

    return Theme(
      data: Themes.fromName(selected),
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              Navigator.of(context).pop();
            },
          ),
        ),
        body: body,
      ),
    );
  }

  Widget _optionCard(
    BuildContext context,
    _ThemeOption option,
    String selected,
    Settings settings,
  ) {
    var isSelected = option.internalName == selected;
    var tokens = option.themeData.extension<GlassTokens>();

    var row = InkWell(
      onTap: () {
        if (widget.brightness == Brightness.light) {
          settings.lightTheme = option.internalName;
        } else {
          settings.darkTheme = option.internalName;
        }
        settings.save();
      },
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            ..._swatches(option.themeData).map(_swatchDot),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                option.label,
                style: option.themeData.textTheme.titleMedium,
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check_circle,
                color: option.themeData.colorScheme.secondary,
              ),
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Theme(
        data: option.themeData,
        child: tokens == null
            ? Container(
                decoration: BoxDecoration(
                  color: option.themeData.cardColor,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: option.themeData.dividerColor),
                ),
                child: row,
              )
            : GlassPanel(
                fill: tokens.card,
                padding: EdgeInsets.zero,
                child: row,
              ),
      ),
    );
  }

  List<Color> _swatches(ThemeData theme) {
    final tokens = theme.extension<GlassTokens>();
    if (tokens != null) {
      return [tokens.base, tokens.card, tokens.primary, tokens.accent];
    }
    return [
      theme.scaffoldBackgroundColor,
      theme.cardColor,
      theme.colorScheme.primary,
      theme.colorScheme.secondary,
    ];
  }

  Widget _swatchDot(Color color) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black26),
        ),
      ),
    );
  }
}
