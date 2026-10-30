/*
 * SPDX-FileCopyrightText: 2019-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:gitjournal/utils/markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:test/test.dart';

import 'lib.dart';

void main() {
  setUpAll(gjSetupAllTests);

  group('ImageMarkupRegex', () {
    test('Plain image markup', () {
      var match = imageMarkupRegex.firstMatch('![Image](./abc.jpg)')!;
      expect(match.group(2), './abc.jpg');
      expect(match.group(3), null);
    });

    test('Image markup with width suffix', () {
      var match = imageMarkupRegex.firstMatch('![](img/pic.png|600)')!;
      expect(match.group(2), 'img/pic.png');
      expect(match.group(3), '600');
    });

    test('Multiple images', () {
      var matches =
          imageMarkupRegex.allMatches('a ![x](1.jpg) b ![y](2.jpg|12) c');
      expect(matches.length, 2);
    });

    test('Remote image with width suffix is matched too', () {
      var match = imageMarkupRegex.firstMatch('![](https://x.com/a.png|64)')!;
      expect(match.group(2), 'https://x.com/a.png');
      expect(match.group(3), '64');
    });
  });

  group('FirstLocalImagePath', () {
    test('No image', () {
      expect(firstLocalImagePath('hello world'), null);
      expect(firstLocalImagePath('![remote](https://x.com/a.png)'), null);
    });

    test('Local image', () {
      expect(firstLocalImagePath('![Image](./abc.jpg)'), './abc.jpg');
      expect(firstLocalImagePath('![](img/pic.png|600)'), 'img/pic.png');
    });

    test('Skips remote images', () {
      expect(
        firstLocalImagePath(
            '![remote](https://x.com/a.png) ![local](./b.jpg)'),
        './b.jpg',
      );
    });
  });

  group('ImageUrlWidthSuffixRegex', () {
    test('Percent encoded suffix (as parsed by package:markdown)', () {
      var match = imageUrlWidthSuffixRegex.firstMatch('./abc.jpg%7C600')!;
      expect(match.group(1), './abc.jpg');
      expect(match.group(2), '600');
    });

    test('Plain url is untouched', () {
      expect(imageUrlWidthSuffixRegex.firstMatch('./abc.jpg'), null);
    });

    test('Matches what package:markdown produces', () {
      var doc = md.Document(
        inlineSyntaxes: md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
      );
      var nodes = doc.parseInline('![](./abc.jpg|600)');
      var img = nodes.whereType<md.Element>().single;
      expect(img.tag, 'img');
      expect(img.attributes['src'], './abc.jpg%7C600');

      var match = imageUrlWidthSuffixRegex.firstMatch(img.attributes['src']!)!;
      expect(match.group(1), './abc.jpg');
      expect(match.group(2), '600');
    });
  });
}
