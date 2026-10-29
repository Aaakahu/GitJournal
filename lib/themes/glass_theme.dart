/*
 * SPDX-FileCopyrightText: 2026 GitJournal fork contributors
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * "Glass" theme — solid-glass design tokens (deeplethe/solid-glass, MIT).
 * Card layer is a solid-color approximation; blur is reserved for floating
 * layers (blurSigma) to keep mobile BackdropFilter cost down.
 */
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// solid-glass tokens for one brightness.
@immutable
class GlassTokens extends ThemeExtension<GlassTokens> {
  /// Scaffold base color (light #e4e6ea / dark #0d0d0d).
  final Color base;

  /// Panel layer - rgba(248,249,251,.44) / rgba(255,255,255,.045).
  final Color panel;

  /// Card layer - rgba(250,250,252,.60) / rgba(79,79,82,.46).
  final Color card;

  /// Popover layer (menus, dialogs) - rgba(251,251,253,.96) / rgba(56,56,58,.96).
  final Color popover;

  /// Rim light along the top edge (light 90% white / dark 16% white).
  final Color rim;

  /// Secondary stop of the top highlight, fainter than [rim].
  final Color inner;

  /// Hairline border (light rgba(35,42,53,.13) / dark rgba(255,255,255,.11)).
  final Color edge;

  /// Drop shadow below panels (light rgba(28,33,44,.28) / dark rgba(0,0,0,.60)).
  final Color shade;

  /// 1px contact shadow (rgba(0,0,0,.18)).
  final Color contact;

  /// Ink primary (light #1a1a1a / dark #f0f0f0).
  final Color primary;

  /// Brand teal (light #10b981 / dark #34d399).
  final Color accent;

  /// Destructive #dc2626.
  final Color destructive;

  /// Foreground text/icon color.
  final Color foreground;

  /// blur(26px) ≈ sigma 13; floating layers only.
  final double blurSigma;

  const GlassTokens({
    required this.base,
    required this.panel,
    required this.card,
    required this.popover,
    required this.rim,
    required this.inner,
    required this.edge,
    required this.shade,
    required this.contact,
    required this.primary,
    required this.accent,
    required this.destructive,
    required this.foreground,
    required this.blurSigma,
  });

  static const light = GlassTokens(
    base: Color(0xFFe4e6ea),
    panel: Color(0x70F8F9FB), // rgba(248,249,251,.44)
    card: Color(0x99FAFAFC), // rgba(250,250,252,.60)
    popover: Color(0xF5FBFBFD), // rgba(251,251,253,.96)
    rim: Color(0xE6FFFFFF), // 90% white
    inner: Color(0x59FFFFFF), // 35% white
    edge: Color(0x212A3521), // rgba(35,42,53,.13)
    shade: Color(0x471C212C), // rgba(28,33,44,.28)
    contact: Color(0x2E000000), // rgba(0,0,0,.18)
    primary: Color(0xFF1a1a1a),
    accent: Color(0xFF10b981),
    destructive: Color(0xFFdc2626),
    foreground: Color(0xFF0d0d0d),
    blurSigma: 13.0,
  );

  static const dark = GlassTokens(
    base: Color(0xFF0d0d0d),
    panel: Color(0x0BFFFFFF), // rgba(255,255,255,.045)
    card: Color(0x754F4F52), // rgba(79,79,82,.46)
    popover: Color(0xF538383A), // rgba(56,56,58,.96)
    rim: Color(0x29FFFFFF), // 16% white
    inner: Color(0x0FFFFFFF), // 6% white
    edge: Color(0x1CFFFFFF), // rgba(255,255,255,.11)
    shade: Color(0x99000000), // rgba(0,0,0,.60)
    contact: Color(0x2E000000), // rgba(0,0,0,.18)
    primary: Color(0xFFf0f0f0),
    accent: Color(0xFF34d399),
    destructive: Color(0xFFdc2626),
    foreground: Color(0xFFfafafa),
    blurSigma: 13.0,
  );

  @override
  GlassTokens copyWith({
    Color? base,
    Color? panel,
    Color? card,
    Color? popover,
    Color? rim,
    Color? inner,
    Color? edge,
    Color? shade,
    Color? contact,
    Color? primary,
    Color? accent,
    Color? destructive,
    Color? foreground,
    double? blurSigma,
  }) {
    return GlassTokens(
      base: base ?? this.base,
      panel: panel ?? this.panel,
      card: card ?? this.card,
      popover: popover ?? this.popover,
      rim: rim ?? this.rim,
      inner: inner ?? this.inner,
      edge: edge ?? this.edge,
      shade: shade ?? this.shade,
      contact: contact ?? this.contact,
      primary: primary ?? this.primary,
      accent: accent ?? this.accent,
      destructive: destructive ?? this.destructive,
      foreground: foreground ?? this.foreground,
      blurSigma: blurSigma ?? this.blurSigma,
    );
  }

  @override
  GlassTokens lerp(ThemeExtension<GlassTokens>? other, double t) {
    if (other is! GlassTokens) return this;
    return GlassTokens(
      base: Color.lerp(base, other.base, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      card: Color.lerp(card, other.card, t)!,
      popover: Color.lerp(popover, other.popover, t)!,
      rim: Color.lerp(rim, other.rim, t)!,
      inner: Color.lerp(inner, other.inner, t)!,
      edge: Color.lerp(edge, other.edge, t)!,
      shade: Color.lerp(shade, other.shade, t)!,
      contact: Color.lerp(contact, other.contact, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      destructive: Color.lerp(destructive, other.destructive, t)!,
      foreground: Color.lerp(foreground, other.foreground, t)!,
      blurSigma: lerpDouble(blurSigma, other.blurSigma, t),
    );
  }

  static double lerpDouble(double a, double b, double t) =>
      a + (b - a) * t;

  @override
  bool operator ==(Object other) =>
      other is GlassTokens &&
      other.base == base &&
      other.panel == panel &&
      other.card == card &&
      other.popover == popover &&
      other.rim == rim &&
      other.inner == inner &&
      other.edge == edge &&
      other.shade == shade &&
      other.contact == contact &&
      other.primary == primary &&
      other.accent == accent &&
      other.destructive == destructive &&
      other.foreground == foreground &&
      other.blurSigma == blurSigma;

  @override
  int get hashCode => Object.hash(base, panel, card, popover, rim, inner, edge,
      shade, contact, primary, accent, destructive, foreground, blurSigma);
}

/// Rounded glass container. Solid-color approximation of frosted glass;
/// pass [blur] on true floating layers (dialogs, sheets) to add the real
/// [GlassTokens.blurSigma] BackdropFilter.
class GlassPanel extends StatelessWidget {
  final Widget? child;

  /// Glass fill; defaults to [GlassTokens.panel].
  final Color? fill;
  final EdgeInsetsGeometry padding;

  /// 14 for surfaces, 11 for control-level elements.
  final double radius;
  final bool blur;

  const GlassPanel({
    super.key,
    this.child,
    this.fill,
    this.padding = const EdgeInsets.all(16),
    this.radius = 14,
    this.blur = false,
  });

  @override
  Widget build(BuildContext context) {
    final tokens =
        Theme.of(context).extension<GlassTokens>() ?? GlassTokens.light;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            offset: const Offset(0, 12),
            blurRadius: 32,
            spreadRadius: -14,
            color: tokens.shade,
          ),
          BoxShadow(
            offset: const Offset(0, 1),
            blurRadius: 2,
            color: tokens.contact,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            ColoredBox(color: fill ?? tokens.panel, child: child == null
                ? null
                : Padding(padding: padding, child: child)),
            // Top 1px rim light: rim -> inner -> transparent.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      tokens.rim,
                      tokens.inner,
                      tokens.rim.withAlpha(0),
                    ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
              ),
            ),
            // Hairline edge drawn above the fill.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    border: Border.all(color: tokens.edge),
                  ),
                ),
              ),
            ),
            if (blur)
              Positioned.fill(
                child: IgnorePointer(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: tokens.blurSigma,
                      sigmaY: tokens.blurSigma,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Card-layer glass (fainter fill than [GlassPanel], same shadow/rim recipe).
class GlassCard extends StatelessWidget {
  final Widget? child;
  final EdgeInsetsGeometry padding;
  final double radius;

  const GlassCard({
    super.key,
    this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 14,
  });

  @override
  Widget build(BuildContext context) {
    final tokens =
        Theme.of(context).extension<GlassTokens>() ?? GlassTokens.light;
    return GlassPanel(
      fill: tokens.card,
      padding: padding,
      radius: radius,
      child: child,
    );
  }
}

/// Ambient light backdrop for the light glass theme: base color plus three
/// radial glows (teal 7% / blue 11% / teal 4%). The dark theme does not add
/// any ambient light - [GlassTokens.dark].base is used as-is.
class GlassBackground extends StatelessWidget {
  final Widget? child;

  const GlassBackground({super.key, this.child});

  @override
  Widget build(BuildContext context) {
    final tokens =
        Theme.of(context).extension<GlassTokens>() ?? GlassTokens.light;

    return DecoratedBox(
      decoration: BoxDecoration(color: tokens.base),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _glow(tokens.accent.withAlpha(18), const Alignment(-0.7, -0.8), 1.0),
          _glow(
              const Color(0xFF3b82f6).withAlpha(28), // 蓝 11%
              const Alignment(0.8, -0.6),
              0.9),
          _glow(tokens.accent.withAlpha(10), const Alignment(-0.2, 1.0), 0.8),
          if (child != null) child!,
        ],
      ),
    );
  }

  Widget _glow(Color color, Alignment center, double radius) {
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: center,
            radius: radius,
            colors: [color, color.withAlpha(0)],
            stops: const [0.0, 1.0],
          ),
        ),
      ),
    );
  }
}
