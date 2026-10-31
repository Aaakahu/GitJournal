/*
 * SPDX-FileCopyrightText: 2019-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app/theme/app_radii.dart';
import 'app/theme/expressive_surfaces.dart';
import 'settings/settings.dart';
import 'themes/glass_theme.dart';

class Themes {
  /// Global font: Geist via google_fonts. Falls back to the bundled Lato
  /// (see pubspec fonts:) when Geist is unavailable - never crashes.
  static TextTheme? _globalFont(TextTheme? base) {
    try {
      return GoogleFonts.getTextTheme('Geist', base);
    } catch (_) {
      // Geist isn't in the google_fonts catalog; the bundled 'Lato'
      // fontFamily below takes over.
      return base;
    }
  }

  static const _pageTransitions = PageTransitionsTheme(builders: {
    TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
  });

  static final _light = ThemeData(
    colorScheme: ColorScheme.fromSwatch(
      primarySwatch: Colors.green,
    ).copyWith(
      primary: const Color(0xFF66bb6a),
      secondary: const Color(0xff6d4c41),
      onPrimary: Colors.black,
    ),
    brightness: Brightness.light,
    fontFamily: 'Lato',
    textTheme: _globalFont(null),
    primaryColor: const Color(0xFF66bb6a),
    primaryColorLight: const Color(0xFF98ee99),
    primaryColorDark: const Color(0xFF338a3e),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: const Color(0xFF338a3e),
      selectionHandleColor: const Color(0xFF66bb6a),
      selectionColor: Colors.grey[400],
    ),
    pageTransitionsTheme: _pageTransitions,
    useMaterial3: false,
  );

  static final _dark = ThemeData(
    colorScheme: ColorScheme.fromSwatch(
      primarySwatch: Colors.grey,
      brightness: Brightness.dark,
    ).copyWith(
      primary: const Color(0xff212121),
      secondary: const Color(0xff689f38),
    ),
    brightness: Brightness.dark,
    fontFamily: 'Lato',
    textTheme: _globalFont(null),
    primaryColor: const Color(0xff212121),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Color(0xFF66bb6a),
      selectionHandleColor: Color(0xFF66bb6a),
      selectionColor: Color(0xff689f38),
    ),
    pageTransitionsTheme: _pageTransitions,
    checkboxTheme: CheckboxThemeData(
      fillColor:
          WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
        if (states.contains(WidgetState.disabled)) {
          return null;
        }
        if (states.contains(WidgetState.selected)) {
          return const Color(0xFF66bb6a);
        }
        return null;
      }),
    ),
    radioTheme: RadioThemeData(
      fillColor:
          WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
        if (states.contains(WidgetState.disabled)) {
          return null;
        }
        if (states.contains(WidgetState.selected)) {
          return const Color(0xFF66bb6a);
        }
        return null;
      }),
    ),
    switchTheme: SwitchThemeData(
      thumbColor:
          WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
        if (states.contains(WidgetState.disabled)) {
          return null;
        }
        if (states.contains(WidgetState.selected)) {
          return const Color(0xFF66bb6a);
        }
        return null;
      }),
      trackColor:
          WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
        if (states.contains(WidgetState.disabled)) {
          return null;
        }
        if (states.contains(WidgetState.selected)) {
          return const Color(0xFF66bb6a);
        }
        return null;
      }),
    ),
    useMaterial3: false,
  );

  static ThemeData _glass(Brightness brightness) {
    final t =
        brightness == Brightness.light ? GlassTokens.light : GlassTokens.dark;
    final onPrimary = brightness == Brightness.light ? Colors.white : t.base;
    // Ink on ledger yellow reads far better than white on yellow.
    final onAccent = brightness == Brightness.light ? t.primary : t.base;

    return ThemeData(
      brightness: brightness,
      useMaterial3: false,
      fontFamily: 'Lato',
      textTheme: _globalFont(null),
      colorScheme: ColorScheme.fromSwatch(
        primarySwatch: Colors.green,
        brightness: brightness,
      ).copyWith(
        primary: t.primary,
        onPrimary: onPrimary,
        secondary: t.accent,
        onSecondary: onAccent,
        error: t.destructive,
        onError: Colors.white,
        surface: Color.alphaBlend(t.card, t.base),
        onSurface: t.foreground,
        onSurfaceVariant: t.foreground.withAlpha(153),
      ),
      primaryColor: t.primary,
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: t.primary,
          foregroundColor: onPrimary,
        ),
      ),
      scaffoldBackgroundColor:
          brightness == Brightness.light ? Colors.transparent : t.base,
      canvasColor: Color.alphaBlend(t.popover, t.base),
      cardColor: Color.alphaBlend(t.card, t.base),
      dividerColor: t.edge,
      iconTheme: IconThemeData(color: t.foreground),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: t.accent,
        selectionHandleColor: t.accent,
        selectionColor: t.accent.withAlpha(77),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: t.foreground,
        titleTextStyle: TextStyle(
          color: t.foreground,
          fontSize: 20,
          fontWeight: FontWeight.w500,
          fontFamily: 'Lato',
        ),
      ),
      cardTheme: CardThemeData(
        color: ExpressiveSurfaces.cardColor(brightness, t),
        elevation: 0,
        shape: ExpressiveSurfaces.cardShape(t),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Color.alphaBlend(t.popover, t.base),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.dialog),
          side: ExpressiveSurfaces.cardBorderSide(t),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: Color.alphaBlend(t.popover, t.base),
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadii.dialog),
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: t.accent,
        foregroundColor: onAccent,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) {
          if (states.contains(WidgetState.disabled)) return null;
          if (states.contains(WidgetState.selected)) return t.accent;
          return null;
        }),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) {
          if (states.contains(WidgetState.disabled)) return null;
          if (states.contains(WidgetState.selected)) return t.accent;
          return null;
        }),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) {
          if (states.contains(WidgetState.disabled)) return null;
          if (states.contains(WidgetState.selected)) return t.accent;
          return null;
        }),
        trackColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) {
          if (states.contains(WidgetState.disabled)) return null;
          if (states.contains(WidgetState.selected)) return t.accent;
          return null;
        }),
      ),
      pageTransitionsTheme: _pageTransitions,
      extensions: <ThemeExtension<dynamic>>{t},
    );
  }

  static final glassLight = _glass(Brightness.light);
  static final glassDark = _glass(Brightness.dark);

  static ThemeData fromName(String name) {
    switch (name) {
      case GLASS_LIGHT_THEME_NAME:
        return glassLight;
      case GLASS_DARK_THEME_NAME:
        return glassDark;
      case DEFAULT_LIGHT_THEME_NAME_LEGACY:
        return _light;
      case DEFAULT_DARK_THEME_NAME_LEGACY:
        return _dark;
      default:
        throw Exception("Theme not found - $name");
    }
  }
}
