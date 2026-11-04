import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Builds an Android "Motion Photo" from an iPhone Live Photo: a JPEG with
/// the MP4 appended and XMP saying where it starts, which Google Photos and
/// most Android galleries play as a moving photo.
///
/// Both the current Motion Photo format (Container directory) and the older
/// "MicroVideo" tags are written, for older galleries. Offsets count from
/// the end of the file, so EXIF added later (see MediaLibrary._stampExif)
/// doesn't break them.
Future<File> buildMotionPhoto({
  required File still,
  required File video,
  required File out,
}) async {
  final jpeg = await still.readAsBytes();
  final mp4 = await video.readAsBytes();
  final sink = out.openWrite();
  try {
    sink.add(withMotionXmp(jpeg, videoLength: mp4.length));
    sink.add(mp4);
  } finally {
    await sink.close();
  }
  return out;
}

const _xmpHeader = 'http://ns.adobe.com/xap/1.0/\u0000';

String motionXmp(int videoLength) =>
    '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
    '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
    '<rdf:Description rdf:about=""'
    ' xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"'
    ' xmlns:Container="http://ns.google.com/photos/1.0/container/"'
    ' xmlns:Item="http://ns.google.com/photos/1.0/container/item/"'
    ' GCamera:MotionPhoto="1"'
    ' GCamera:MotionPhotoVersion="1"'
    ' GCamera:MotionPhotoPresentationTimestampUs="-1"'
    ' GCamera:MicroVideo="1"'
    ' GCamera:MicroVideoVersion="1"'
    ' GCamera:MicroVideoOffset="$videoLength"'
    ' GCamera:MicroVideoPresentationTimestampUs="-1">'
    '<Container:Directory><rdf:Seq>'
    '<rdf:li rdf:parseType="Resource"><Container:Item'
    ' Item:Mime="image/jpeg" Item:Semantic="Primary"'
    ' Item:Length="0" Item:Padding="0"/></rdf:li>'
    '<rdf:li rdf:parseType="Resource"><Container:Item'
    ' Item:Mime="video/mp4" Item:Semantic="MotionPhoto"'
    ' Item:Length="$videoLength" Item:Padding="0"/></rdf:li>'
    '</rdf:Seq></Container:Directory>'
    '</rdf:Description></rdf:RDF></x:xmpmeta>';

/// [jpeg] with our XMP segment in place of any XMP it had, right after its
/// APP0/APP1 (EXIF) headers.
Uint8List withMotionXmp(List<int> jpeg, {required int videoLength}) {
  if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) {
    throw const FormatException('Not a JPEG');
  }
  final payload = utf8.encode(_xmpHeader + motionXmp(videoLength));
  final segLen = payload.length + 2;
  if (segLen > 0xFFFF) throw const FormatException('XMP too large');
  final ours = [0xFF, 0xE1, segLen >> 8, segLen & 0xFF, ...payload];

  final out = BytesBuilder(copy: false)..add([0xFF, 0xD8]);
  var pos = 2;
  var inserted = false;
  // Walk the header segments up to the image data.
  while (pos + 4 <= jpeg.length && jpeg[pos] == 0xFF) {
    final marker = jpeg[pos + 1];
    if (marker == 0xDA || marker == 0xD9) break; // start of scan / end
    final len = (jpeg[pos + 2] << 8) | jpeg[pos + 3];
    final end = pos + 2 + len;
    if (end > jpeg.length) break;
    final segment = jpeg.sublist(pos, end);
    final isApp0or1 = marker == 0xE0 || marker == 0xE1;
    final isXmp =
        marker == 0xE1 &&
        len > 2 + _xmpHeader.length &&
        utf8.decode(
              segment.sublist(4, 4 + _xmpHeader.length),
              allowMalformed: true,
            ) ==
            _xmpHeader;
    if (!isApp0or1 && !inserted) {
      out.add(ours);
      inserted = true;
    }
    if (!isXmp) out.add(segment); // the old XMP is replaced by ours
    pos = end;
  }
  if (!inserted) out.add(ours);
  out.add(jpeg.sublist(pos));
  return out.toBytes();
}
