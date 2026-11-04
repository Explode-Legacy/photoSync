import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photobridge/core/media_library.dart';
import 'package:photobridge/core/server.dart';

void main() {
  test('sniffKind reads the bytes, not the name', () async {
    final dir = await Directory.systemTemp.createTemp('sniff');
    Future<String?> kind(String name, List<int> head) => sniffKind(
      File('${dir.path}/$name')
        ..writeAsBytesSync([...head, ...List.filled(16, 0)]),
    );
    List<int> ftyp(String brand) => [0, 0, 0, 24, ...'ftyp$brand'.codeUnits];
    // The bug: a JPEG labelled as a Live Photo video.
    expect(await kind('IMG_1.MOV', [0xFF, 0xD8, 0xFF, 0xE0]), 'image');
    expect(await kind('a.heic', ftyp('heic')), 'image');
    expect(await kind('a.mov', ftyp('qt  ')), 'video');
    expect(await kind('a.mp4', ftyp('isom')), 'video');
    expect(await kind('a.png', [0x89, ...'PNG'.codeUnits]), 'image');
    expect(await kind('a.bin', [1, 2, 3]), isNull);
    await dir.delete(recursive: true);
  });

  test('shortError keeps one readable line', () {
    const e =
        'PlatformException(saveVideo, java.lang.IllegalArgumentException: '
        'MIME type image/jpeg cannot be inserted into content://media/external/video/media; '
        'expected MIME type under video/*\n at android.database.DatabaseUtils.readException…, null)';
    final s = shortError(e);
    expect(s, startsWith('MIME type image/jpeg cannot be inserted'));
    expect(s, isNot(contains('\n')));
    expect(s.length, lessThanOrEqualTo(160));
  });

  test('names are fixed to match the real content', () {
    // A video that arrived named like a photo (the "MIME type image/jpeg"
    // error), and the reverse.
    expect(nameForKind('IMG_1.JPG', 'video', 'mov'), 'IMG_1.mov');
    expect(nameForKind('IMG_1.MOV', 'image', 'heic'), 'IMG_1.heic');
    // Names that already fit stay exactly as they were.
    expect(nameForKind('IMG_1.HEIC', 'image', 'heic'), 'IMG_1.HEIC');
    expect(nameForKind('clip.MP4', 'video', 'mov'), 'clip.MP4');
    expect(nameForKind('noext', 'video', 'mp4'), 'noext.mp4');
  });
}
