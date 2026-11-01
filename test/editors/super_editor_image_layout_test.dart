/*
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitjournal/editors/super_editor_body.dart';
import 'package:gitjournal/l10n.dart';
import 'package:image/image.dart' as im;
import 'package:path/path.dart' as p;

/// Regression tests for the image layout rules in [GjImageComponent]:
///  - `|width` is a maximum width (small images are never upscaled);
///  - images narrower than the column hug the start edge;
///  - very tall images fold into a 2:3 box with a badge and open a full
///    screen viewer when tapped.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gj_image_layout_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  String writePng(String name, int width, int height) {
    final image = im.Image(width, height);
    im.fill(image, im.getColor(120, 140, 180));
    final file = File(p.join(tempDir.path, name));
    file.writeAsBytesSync(im.encodePng(image));
    return name;
  }

  Future<void> pumpEditor(WidgetTester tester, String body) async {
    final controller = TextEditingController(text: body);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: gitJournalLocalizationDelegates,
          supportedLocales: gitJournalSupportedLocales,
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SuperEditorBody(
                    textController: controller,
                    imageDir: tempDir.path,
                    autofocus: false,
                    onChanged: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      // Real file IO + codec for the FileImage need real async time.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pumpAndSettle();
  }

  RenderImage renderedImage(WidgetTester tester) =>
      tester.renderObject<RenderImage>(find.byType(RawImage).first);

  testWidgets('|600 is a max-width: a 100x50 image is not upscaled',
      (tester) async {
    var fileName = writePng('small.png', 100, 50);

    await pumpEditor(tester, 'Hello\n\n![small]($fileName|600)\n\nBye');

    final render = renderedImage(tester);
    // Natural size kept: 600 is only an upper bound. The old forced-width
    // behavior rendered this 600 wide.
    expect(render.size.width, 100.0);
    expect(render.size.height, 50.0);

    // Narrow images hug the start edge instead of floating centered
    // (16 = page padding; centered would be ~350).
    expect(render.localToGlobal(Offset.zero).dx, lessThan(150.0));
  });

  testWidgets('images taller than 3:1 fold into a 2:3 box with a badge',
      (tester) async {
    var fileName = writePng('long.png', 60, 300); // ratio 5:1

    await pumpEditor(tester, '![long]($fileName|600)');

    // Folded display box: 600 wide (the |600 cap) and 1.5x that tall.
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is SizedBox &&
            w.width == 600.0 &&
            w.height == 900.0 &&
            w.child is ClipRect,
      ),
      findsOneWidget,
    );
    expect(find.text('Long image'), findsOneWidget);
  });

  testWidgets('a folded image is viewed full screen through the long-press '
      'menu (tap is a no-op)', (tester) async {
    var fileName = writePng('long.png', 60, 300);

    // 折叠盒是 768x1152，默认 800x600 的窗口放不下菜单；加高窗口。
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpEditor(tester, '![long]($fileName)');

    // 单击无操作：不弹全屏、不弹菜单。
    await tester.tap(find.byType(GjImageComponent));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.byIcon(Icons.zoom_out_map), findsNothing);

    // 长按 → 菜单 → 查看大图 → 全屏查看器。
    await tester.longPress(find.byType(GjImageComponent));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.zoom_out_map), findsOneWidget);

    await tester.tap(find.byIcon(Icons.zoom_out_map));
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('image menu stays inside the viewport when the image fills '
      'the screen', (tester) async {
    // 高/宽 2:1 的满宽大图：渲染高度 768x2 = 1536，远超 600 高的窗口，
    // 图片上下都贴不到。菜单必须钉在视口内（底栏上方 8px）而不是落到
    // 屏幕外（真机反馈：只看得到"查看大图"一行）。
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var fileName = writePng('tall.png', 400, 800); // ratio 2:1, below 3:1

    await pumpEditor(tester, '![tall]($fileName)');

    await tester.longPress(find.byType(GjImageComponent));
    await tester.pumpAndSettle();

    final menuFinder = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_ImageSelectionMenu',
    );
    expect(menuFinder, findsOneWidget);

    final menuRect = tester.getRect(menuFinder);
    expect(menuRect.top, greaterThanOrEqualTo(0.0));
    expect(menuRect.bottom, lessThanOrEqualTo(600.0));
    expect(menuRect.left, greaterThanOrEqualTo(0.0));
    expect(menuRect.right, lessThanOrEqualTo(800.0));
  });

  testWidgets('a 2:1 image whose rendered height exceeds 1.5x the viewport '
      'folds even though it is below the 3:1 ratio', (tester) async {
    // 折叠阈值扩展：高/宽 2:1 不满旧阈值 3，但满宽渲染 768x1536 超过
    // 1.5 倍视口（600 高）→ 折叠，避免满屏大图遮死编辑区。
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var fileName = writePng('tall.png', 400, 800); // ratio 2:1

    await pumpEditor(tester, '![tall]($fileName)');

    expect(
      find.byWidgetPredicate(
        (w) =>
            w is SizedBox &&
            w.width == 768.0 &&
            w.height == 1152.0 &&
            w.child is ClipRect,
      ),
      findsOneWidget,
    );
    expect(find.text('Long image'), findsOneWidget);
  });

  testWidgets('normal portrait photos (ratio 1.5) never fold at phone-like '
      'proportions', (tester) async {
    // 红线：普通竖拍照片（高/宽 1.3~2）不折叠。手机比例窗口
    // （列宽 ~368，视口 900）下渲染高度 552 远小于 1.5 倍视口。
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var fileName = writePng('photo.png', 400, 600); // ratio 1.5

    await pumpEditor(tester, '![photo]($fileName)');

    // 折叠盒若存在会是 SizedBox(368x552, ClipRect)——即列宽 x 1.5 倍列宽。
    expect(
      find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 368.0 && w.height == 552.0,
      ),
      findsNothing,
    );
    expect(find.text('Long image'), findsNothing);
  });
}
