// Regenerates all Android launcher / quick-action icons plus the in-app logo
// from a procedural "solid-glass ledger" design (ledger yellow + white glass).
//
// Design: rounded square with a diagonal #ffd54f -> #f0a500 gradient, a white
// glass panel (vertical sheen + top rim light + soft shadow) holding a yellow
// ledger book with white ruled lines and a darker binding band.
//
// Usage: dart run tool/generate_icons.dart
import 'dart:io';
import 'dart:math';

import 'package:image/image.dart' as im;

const design = 1024; // logical design canvas
const ss = 4; // supersampling factor (AA via downscale)

int col(int r, int g, int b, [int a = 255]) => im.getColor(r, g, b, a);

int over(int dst, int src) {
  final sa = im.getAlpha(src) / 255.0;
  if (sa >= 1.0) return src;
  final da = im.getAlpha(dst) / 255.0;
  final oa = sa + da * (1.0 - sa);
  if (oa <= 0.0) return 0;
  int ch(int s, int d) =>
      ((s * sa + d * da * (1.0 - sa)) / oa).round().clamp(0, 255);
  return col(
    ch(im.getRed(src), im.getRed(dst)),
    ch(im.getGreen(src), im.getGreen(dst)),
    ch(im.getBlue(src), im.getBlue(dst)),
    (oa * 255).round(),
  );
}

double sdRoundRect(double px, double py, double cx, double cy, double hw,
    double hh, double r) {
  final qx = (px - cx).abs() - (hw - r);
  final qy = (py - cy).abs() - (hh - r);
  final ax = max(qx, 0.0), ay = max(qy, 0.0);
  return sqrt(ax * ax + ay * ay) + min(max(qx, qy), 0.0) - r;
}

double sdSeg(double px, double py, double ax, double ay, double bx, double by) {
  final abx = bx - ax, aby = by - ay;
  final apx = px - ax, apy = py - ay;
  final len2 = abx * abx + aby * aby;
  final t = len2 <= 0 ? 0.0 : ((apx * abx + apy * aby) / len2).clamp(0.0, 1.0);
  final dx = apx - abx * t, dy = apy - aby * t;
  return sqrt(dx * dx + dy * dy);
}

int capsule(double px, double py, double ax, double ay, double bx, double by,
    double r, int color) {
  if (sdSeg(px, py, ax, ay, bx, by) - r > 0) return 0;
  return color;
}

int lerpC(List<int> c1, List<int> c2, double t, [int a = 255]) => col(
      (c1[0] + (c2[0] - c1[0]) * t).round(),
      (c1[1] + (c2[1] - c1[1]) * t).round(),
      (c1[2] + (c2[2] - c1[2]) * t).round(),
      a,
    );

enum Mask { rounded, circle, full }

/// Diagonal ledger-yellow gradient, masked to the icon shape.
int paintBg(double x, double y, Mask mask) {
  switch (mask) {
    case Mask.rounded:
      if (sdRoundRect(x, y, 512, 512, 512, 512, 225) > 0) return 0;
      break;
    case Mask.circle:
      final dx = x - 512, dy = y - 512;
      if (dx * dx + dy * dy > 512 * 512) return 0;
      break;
    case Mask.full:
      break;
  }
  return lerpC(
      const [255, 213, 79], const [240, 165, 0], (x + y) / (2 * design));
}

/// Launcher / foreground: white glass panel holding a yellow ledger book.
int glassLedger(double x, double y, Mask mask) {
  var c = paintBg(x, y, mask);
  // Soft shadow below the panel.
  final ds = sdRoundRect(x, y, 512, 538, 320, 300, 90);
  if (ds < 64) {
    final a = ((1 - max(ds, 0.0) / 64) * 62).round();
    if (a > 0) c = over(c, col(74, 52, 8, a));
  }
  // White glass panel with a vertical sheen.
  final dp = sdRoundRect(x, y, 512, 512, 320, 300, 90);
  if (dp <= 0) {
    final ty = ((y - 212) / 600).clamp(0.0, 1.0);
    c = over(c, col(255, 254, 252, (255 * (0.97 - 0.09 * ty)).round()));
    // 1px rim light along the top edge.
    if (dp > -3.5 && y < 512) c = over(c, col(255, 255, 255, 200));
  }
  // Ledger book with diagonal cover gradient.
  final db = sdRoundRect(x, y, 512, 512, 150, 170, 34);
  if (db <= 0) {
    final t = ((x - 362) + (y - 342)) / 640;
    var b = lerpC(const [247, 183, 49], const [221, 146, 0], t);
    if (x >= 382 && x <= 438) b = over(b, col(140, 88, 0, 140)); // binding
    c = over(c, b);
  }
  // Ruled lines (rounded caps).
  for (final oy in const [-62.0, 0.0, 62.0]) {
    final line = capsule(x, y, 460, 512 + oy, 636, 512 + oy, 11,
        col(255, 255, 255, 248));
    if (line != 0) c = over(c, line);
  }
  return c;
}

const _ink = [30, 24, 8];

int _inkColor() => col(_ink[0], _ink[1], _ink[2], 250);

/// Quick-action tile: ledger book glyph (dark cover, white lines).
int tileBook(double x, double y, Mask mask) {
  var c = paintBg(x, y, mask);
  if (sdRoundRect(x, y, 512, 512, 205, 240, 48) <= 0) {
    c = over(c, _inkColor());
    for (final oy in const [-78.0, 0.0, 78.0]) {
      final l = capsule(x, y, 384, 512 + oy, 664, 512 + oy, 15,
          col(255, 255, 255, 250));
      if (l != 0) c = over(c, l);
    }
  }
  return c;
}

/// Quick-action tile: markdown "M plus down arrow" in a dark plate.
int tileMarkdown(double x, double y, Mask mask) {
  var c = paintBg(x, y, mask);
  if (sdRoundRect(x, y, 512, 512, 215, 155, 42) <= 0) {
    c = over(c, _inkColor());
  }
  const segs = <List<double>>[
    [-130, 64, -130, -64], // M left stem
    [-130, -64, -60, 6], // M left diagonal
    [-60, 6, 10, -64], // M right diagonal
    [10, -64, 10, 64], // M right stem
    [95, -58, 95, 26], // arrow stem
    [63, 26, 95, 58], // arrow head left
    [127, 26, 95, 58], // arrow head right
  ];
  for (final s in segs) {
    final l = capsule(x, y, s[0] + 512, s[1] + 512, s[2] + 512, s[3] + 512, 13,
        col(255, 255, 255, 250));
    if (l != 0) c = over(c, l);
  }
  return c;
}

/// Quick-action tile: three checklist rows.
int tileTasks(double x, double y, Mask mask) {
  var c = paintBg(x, y, mask);
  for (final ry in const [-82.0, 0.0, 82.0]) {
    final segs = <List<double>>[
      [-198, ry - 10, -160, ry + 26], // check down stroke
      [-160, ry + 26, -114, ry - 30], // check up stroke
      [-88, ry + 2, 190, ry + 2], // ruled line
    ];
    for (final s in segs) {
      final l = capsule(x, y, s[0] + 512, s[1] + 512, s[2] + 512, s[3] + 512,
          15, _inkColor());
      if (l != 0) c = over(c, l);
    }
  }
  return c;
}

im.Image renderMaster(int Function(double x, double y) paint) {
  const s = design * ss;
  final img = im.Image(s, s);
  final data = img.data;
  var i = 0;
  for (var y = 0; y < s; y++) {
    final ly = (y + 0.5) / ss;
    for (var x = 0; x < s; x++) {
      data[i++] = paint((x + 0.5) / ss, ly);
    }
  }
  return img;
}

/// Premultiplied box-filter downscale (no dark fringes on transparent edges).
im.Image downscale(im.Image src, int w, int h) {
  final out = im.Image(w, h);
  final outData = out.data;
  final srcData = src.data;
  final sw = src.width, sh = src.height;
  final dx = sw / w, dy = sh / h;
  var oi = 0;
  for (var oy = 0; oy < h; oy++) {
    final y1 = (oy * dy).floor();
    var y2 = max(((oy + 1) * dy).ceil(), y1 + 1);
    y2 = min(y2, sh);
    for (var ox = 0; ox < w; ox++) {
      final x1 = (ox * dx).floor();
      var x2 = max(((ox + 1) * dx).ceil(), x1 + 1);
      x2 = min(x2, sw);
      var ar = 0, ag = 0, ab = 0, aa = 0, n = 0;
      for (var sy = y1; sy < y2; sy++) {
        var si = sy * sw + x1;
        for (var sx = x1; sx < x2; sx++, si++) {
          final c = srcData[si];
          final a = im.getAlpha(c);
          ar += im.getRed(c) * a;
          ag += im.getGreen(c) * a;
          ab += im.getBlue(c) * a;
          aa += a;
          n++;
        }
      }
      var r = 0, g = 0, b = 0;
      if (aa > 0) {
        // ar/aa is already the averaged 0..255 channel (premultiplied mean).
        r = (ar / aa).round();
        g = (ag / aa).round();
        b = (ab / aa).round();
      }
      outData[oi++] = col(r, g, b, (aa / n).round());
    }
  }
  return out;
}

void writePng(im.Image img, String path) {
  final f = File(path)..createSync(recursive: true);
  f.writeAsBytesSync(im.encodePng(img));
  stdout.writeln('wrote $path (${img.width}x${img.height})');
}

void main() {
  final root = Directory.current.path;
  final res = '$root/android/app/src/main/res';
  const launcherSizes = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };
  const foregroundSizes = {
    'mdpi': 108,
    'hdpi': 162,
    'xhdpi': 216,
    'xxhdpi': 324,
    'xxxhdpi': 432,
  };

  // 1. Launcher icon (rounded) + in-app logo + notification drawable.
  var m = renderMaster((x, y) => glassLedger(x, y, Mask.rounded));
  for (final e in launcherSizes.entries) {
    writePng(downscale(m, e.value, e.value),
        '$res/mipmap-${e.key}/launcher_icon.png');
  }
  writePng(downscale(m, 260, 260), '$res/drawable/icon.png');
  writePng(downscale(m, design, design), '$root/assets/icon/icon.png');

  // 2. Adaptive-icon foreground: full-bleed gradient, panel inside safe zone.
  m = renderMaster((x, y) => glassLedger(x, y, Mask.full));
  for (final e in foregroundSizes.entries) {
    for (final set in const ['ic_book', 'ic_markdown', 'ic_tasks']) {
      writePng(downscale(m, e.value, e.value),
          '$res/mipmap-${e.key}/${set}_foreground.png');
    }
  }

  // 3. Quick-action tiles (square + round variants).
  final tiles = {
    'ic_book': tileBook,
    'ic_markdown': tileMarkdown,
    'ic_tasks': tileTasks,
  };
  for (final t in tiles.entries) {
    m = renderMaster((x, y) => t.value(x, y, Mask.rounded));
    for (final e in launcherSizes.entries) {
      writePng(downscale(m, e.value, e.value),
          '$res/mipmap-${e.key}/${t.key}.png');
    }
    m = renderMaster((x, y) => t.value(x, y, Mask.circle));
    for (final e in launcherSizes.entries) {
      writePng(downscale(m, e.value, e.value),
          '$res/mipmap-${e.key}/${t.key}_round.png');
    }
  }
  stdout.writeln('done');
}
