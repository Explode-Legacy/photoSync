import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photobridge/core/motion_photo.dart';

List<int> segment(int marker, List<int> body) => [
  0xFF,
  marker,
  (body.length + 2) >> 8,
  (body.length + 2) & 0xFF,
  ...body,
];

void main() {
  // SOI, APP1 Exif, APP1 (Apple) XMP, DQT, SOS + data, EOI.
  final exif = segment(0xE1, [...'Exif'.codeUnits, 0, 0, 1, 2, 3]);
  final appleXmp = segment(0xE1, [
    ...utf8.encode(
      'http://ns.adobe.com/xap/1.0/\u0000<x:xmpmeta>apple</x:xmpmeta>',
    ),
  ]);
  final dqt = segment(0xDB, List.filled(10, 7));
  final scan = [0xFF, 0xDA, 0, 4, 9, 9, 42, 43, 44, 0xFF, 0xD9];
  final jpeg = [0xFF, 0xD8, ...exif, ...appleXmp, ...dqt, ...scan];

  test('XMP goes after EXIF, replacing the old XMP; image data untouched', () {
    final out = withMotionXmp(jpeg, videoLength: 1234);
    final text = latin1.decode(out);
    expect(text.indexOf('Exif'), lessThan(text.indexOf('MotionPhoto="1"')));
    expect(text.indexOf('MotionPhoto="1"'), lessThan(text.indexOf('ÿÛ')));
    expect(text, isNot(contains('apple')));
    expect(text, contains('MicroVideoOffset="1234"'));
    expect(text, contains('Item:Length="1234"'));
    expect(out.sublist(out.length - scan.length), scan);
  });

  test('motion photo = JPEG with XMP, then exactly the video', () async {
    final dir = await Directory.systemTemp.createTemp('mp');
    final still = File('${dir.path}/s.jpg')..writeAsBytesSync(jpeg);
    final video = List.generate(5000, (i) => i % 256);
    final mp4 = File('${dir.path}/v.mp4')..writeAsBytesSync(video);
    final out = await buildMotionPhoto(
      still: still,
      video: mp4,
      out: File('${dir.path}/IMG_1.MP.jpg'),
    );
    final bytes = out.readAsBytesSync();
    // The video starts where the XMP says: its length from the end.
    expect(bytes.sublist(bytes.length - video.length), video);
    expect(bytes.sublist(0, 2), [0xFF, 0xD8]);
    await dir.delete(recursive: true);
  });

  test('refuses non-JPEG stills', () {
    expect(
      () => withMotionXmp([1, 2, 3, 4], videoLength: 1),
      throwsFormatException,
    );
  });
}
