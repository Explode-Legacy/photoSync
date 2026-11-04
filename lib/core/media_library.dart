import 'dart:io';

import 'package:native_exif/native_exif.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import 'motion_photo.dart';

import 'server.dart' show DateFix;

/// A photo/video exported to a readable file for upload.
class ExportedAsset {
  ExportedAsset(this.file, this.name, this.kind);

  final File file;
  final String name;

  /// `image` or `video`.
  final String kind;
}

/// One photo or video that can be sent, from whichever [PhotoSource].
class SourceItem {
  SourceItem({
    required this.id,
    required this.title,
    required this.created,
    required this.export,
    this.location,
  });

  /// Stable id, used in the sent/imported ledgers.
  final String id;
  final String title;
  final DateTime created;

  /// (latitude, longitude), if known.
  final (double, double)? location;

  /// Gets a readable file for upload.
  final Future<ExportedAsset?> Function() export;
}

/// Where a device's photos come from and where received ones go: the
/// photo library on phones, a chosen folder on the Mac.
abstract class PhotoSource {
  Future<bool> requestPermission();

  /// Everything that may need sending, oldest first.
  Future<List<SourceItem>> pending({
    required DateTime since,
    required bool includeVideos,
  });

  Future<List<SourceItem>> byIds(List<String> ids);

  /// Whether a photo saved earlier (by [save]) is still there.
  Future<bool> exists(String id);

  /// The album (Android/Mac: folder) each of [ids] is in, when it has one.
  Future<Map<String, String>> albumsFor(Set<String> ids);

  /// Applies corrected capture dates to photos received earlier, matched by
  /// file name, where the file has no date of its own. Returns how many
  /// changed.
  Future<int> repairDates(List<DateFix> fixes);

  /// Frees any temporary copies made by [SourceItem.export].
  Future<void> releaseExports();

  /// Saves a received photo or video (into [album], if given) and returns
  /// its new id.
  Future<String> save(
    File file, {
    required String name,
    required String kind,
    DateTime? created,
    (double, double)? location,
    String album = '',
  });
}

/// Ids of a Live Photo's video part: the photo's id plus this.
const kLiveSuffix = '#live';

/// What a file really is, from its first bytes: `image`, `video`, or null
/// when unknown. Names and labels can be wrong; the bytes aren't.
Future<String?> sniffKind(File file) async {
  final List<int> h;
  try {
    final raf = await file.open();
    try {
      h = await raf.read(16);
    } finally {
      await raf.close();
    }
  } catch (_) {
    return null;
  }
  bool at(int offset, String ascii) =>
      h.length >= offset + ascii.length &&
      String.fromCharCodes(h.sublist(offset, offset + ascii.length)) == ascii;
  if (h.length >= 3 && h[0] == 0xFF && h[1] == 0xD8 && h[2] == 0xFF) {
    return 'image'; // JPEG
  }
  if (h.length >= 4 && h[0] == 0x89 && at(1, 'PNG')) return 'image';
  if (at(0, 'GIF8') || (at(0, 'RIFF') && at(8, 'WEBP'))) return 'image';
  if (at(4, 'ftyp')) {
    final brand = h.length >= 12 ? String.fromCharCodes(h.sublist(8, 12)) : '';
    const images = {'heic', 'heix', 'heim', 'heis', 'mif1', 'msf1', 'avif'};
    return images.contains(brand) ? 'image' : 'video'; // qt, isom, mp4…
  }
  return null;
}

/// Thin wrapper around photo_manager for reading and saving media.
class MediaLibrary implements PhotoSource {
  static const _pageSize = 200;

  @override
  Future<bool> requestPermission() async {
    final state = await PhotoManager.requestPermissionExtend();
    return state.hasAccess;
  }

  /// All assets created at or after [since], oldest first.
  Future<List<AssetEntity>> assetsSince(
    DateTime since, {
    required bool includeVideos,
  }) async {
    final type = includeVideos ? RequestType.common : RequestType.image;
    final filter = FilterOptionGroup(
      createTimeCond: DateTimeCond(
        min: since,
        max: DateTime.now().add(const Duration(days: 1)),
      ),
      orders: const [OrderOption(type: OrderOptionType.createDate, asc: true)],
    );
    final count = await PhotoManager.getAssetCount(
      filterOption: filter,
      type: type,
    );
    final out = <AssetEntity>[];
    for (var start = 0; start < count; start += _pageSize) {
      out.addAll(
        await PhotoManager.getAssetListRange(
          start: start,
          end: (start + _pageSize).clamp(0, count),
          filterOption: filter,
          type: type,
        ),
      );
    }
    return out;
  }

  @override
  Future<List<SourceItem>> pending({
    required DateTime since,
    required bool includeVideos,
  }) async => [
    for (final a in await assetsSince(since, includeVideos: includeVideos))
      ..._items(a, includeVideos: includeVideos),
  ];

  @override
  Future<List<SourceItem>> byIds(List<String> ids) async => [
    for (final id in ids)
      // Ids ending in [kLiveSuffix] (older versions sent the motion part
      // separately) are now part of the photo's own Motion Photo.
      if (!id.endsWith(kLiveSuffix))
        if (await AssetEntity.fromId(id) case final a?)
          Platform.isIOS && a.isLivePhoto ? _motionItem(a) : _item(a),
  ];

  @override
  Future<bool> exists(String id) async =>
      await AssetEntity.fromId(_baseId(id)) != null;

  static String _baseId(String id) => id.endsWith(kLiveSuffix)
      ? id.substring(0, id.length - kLiveSuffix.length)
      : id;

  /// The photo; a Live Photo (iPhone) goes as an Android Motion Photo.
  Iterable<SourceItem> _items(
    AssetEntity a, {
    required bool includeVideos,
  }) sync* {
    yield Platform.isIOS && a.isLivePhoto ? _motionItem(a) : _item(a);
  }

  SourceItem _item(AssetEntity a) => SourceItem(
    id: a.id,
    title: a.title ?? a.id,
    created: a.createDateTime,
    location: _locationOf(a),
    export: () => export(a),
  );

  /// A Live Photo as one Motion Photo (JPEG still + MP4, see
  /// motion_photo.dart), which Android galleries play. Falls back to the
  /// plain original photo if either part can't be had.
  SourceItem _motionItem(AssetEntity a) {
    final title = a.title ?? a.id;
    final dot = title.lastIndexOf('.');
    final name = '${dot > 0 ? title.substring(0, dot) : title}.MP.jpg';
    return SourceItem(
      id: a.id,
      title: name,
      created: a.createDateTime,
      location: _locationOf(a),
      export: () async {
        try {
          // MP4 (not MOV): Motion Photos carry MP4, and it also keeps the
          // plugin's cache from handing back the still instead.
          final video = await a.loadFile(
            withSubtype: true,
            darwinFileType: PMDarwinAVFileType.mp4,
          );
          // The rendered still is a JPEG (the original may be HEIC).
          final still = await a.loadFile(isOrigin: false);
          if (video != null &&
              still != null &&
              await sniffKind(video) == 'video' &&
              await _isJpeg(still)) {
            final dir = await _motionDir();
            final out = File(
              '${dir.path}/${a.id.hashCode.toUnsigned(32)}-$name',
            );
            await buildMotionPhoto(still: still, video: video, out: out);
            return ExportedAsset(out, name, 'image');
          }
        } catch (_) {
          // Fall through to the plain photo.
        }
        return export(a);
      },
    );
  }

  static Future<bool> _isJpeg(File f) async {
    final raf = await f.open();
    try {
      final h = await raf.read(3);
      return h.length == 3 && h[0] == 0xFF && h[1] == 0xD8 && h[2] == 0xFF;
    } finally {
      await raf.close();
    }
  }

  static Future<Directory> _motionDir() async =>
      Directory('${(await getTemporaryDirectory()).path}/motion').create();

  @override
  Future<Map<String, String>> albumsFor(Set<String> ids) async {
    final wanted = {for (final id in ids) _baseId(id)};
    final found = <String, String>{};
    try {
      final paths = await PhotoManager.getAssetPathList(
        hasAll: false,
        // iPhone: only albums the user made, not Recents/Favorites/...
        pathFilterOption: const PMPathFilter(
          darwin: PMDarwinPathFilter(
            type: [PMDarwinAssetCollectionType.album],
            subType: [PMDarwinAssetCollectionSubtype.albumRegular],
          ),
        ),
      );
      for (final path in paths) {
        // Android folders that aren't albums in any useful sense.
        if (const {'Camera', 'PhotoBridge', 'DCIM'}.contains(path.name)) {
          continue;
        }
        final count = await path.assetCountAsync;
        for (var start = 0; start < count; start += _pageSize) {
          final page = await path.getAssetListRange(
            start: start,
            end: (start + _pageSize).clamp(0, count),
          );
          for (final a in page) {
            if (wanted.contains(a.id)) found.putIfAbsent(a.id, () => path.name);
          }
          if (found.length == wanted.length) break;
        }
        if (found.length == wanted.length) break;
      }
    } catch (_) {
      // Albums are a nicety; send without them.
    }
    return {for (final id in ids) id: ?found[_baseId(id)]};
  }

  /// Photos says 0,0 when an asset has no location.
  static (double, double)? _locationOf(AssetEntity asset) {
    final lat = asset.latitude, lng = asset.longitude;
    if (lat == null || lng == null || (lat == 0 && lng == 0)) return null;
    return (lat, lng);
  }

  /// Newest-first page of the library, for the manual picker.
  Future<List<AssetEntity>> recentPage(int page, {int pageSize = 120}) {
    return PhotoManager.getAssetListPaged(
      page: page,
      pageCount: pageSize,
      type: RequestType.common,
      filterOption: FilterOptionGroup(
        orders: const [OrderOption(type: OrderOptionType.createDate)],
      ),
    );
  }

  /// Gets the original file (downloading from iCloud if needed).
  Future<ExportedAsset?> export(AssetEntity asset) async {
    final file = await asset.originFile ?? await asset.file;
    if (file == null) return null;
    final fileName = file.path.split('/').last;
    var name = await asset.titleAsync;
    if (name.isEmpty) name = fileName;
    // Make sure the extension matches the bytes we actually send
    // (e.g. iOS may hand us a .MOV for a title ending in something else).
    final ext = fileName.contains('.') ? fileName.split('.').last : '';
    if (ext.isNotEmpty &&
        !name.toLowerCase().endsWith('.${ext.toLowerCase()}')) {
      final dot = name.lastIndexOf('.');
      name = '${dot > 0 ? name.substring(0, dot) : name}.$ext';
    }
    final kind = asset.type == AssetType.video ? 'video' : 'image';
    return ExportedAsset(file, name, kind);
  }

  /// iOS copies originals into the plugin cache; free that space.
  @override
  Future<void> releaseExports() async {
    if (!Platform.isIOS) return;
    await PhotoManager.clearFileCache();
    try {
      await (await _motionDir()).delete(recursive: true);
    } catch (_) {}
  }

  /// Saves a received file into the gallery and returns the new asset id.
  ///
  /// [created] and [location] come from the sender's library. They matter
  /// for files that carry no metadata of their own, such as WhatsApp images.
  @override
  Future<String> save(
    File file, {
    required String name,
    required String kind,
    DateTime? created,
    (double, double)? location,
    String album = '',
  }) async {
    // Trust the content over the sender's label (a mislabelled file would
    // otherwise be refused by Android's gallery).
    kind = await sniffKind(file) ?? kind;
    if (Platform.isAndroid && kind == 'image') {
      await _stampExif(file.path, created, location);
    }
    final sub = album.isEmpty ? '' : '/$album';
    AssetEntity entity;
    if (kind == 'video') {
      entity = await PhotoManager.editor.saveVideo(
        file,
        title: name,
        relativePath: 'Movies/PhotoBridge$sub',
        creationDate: created,
      );
    } else {
      entity = await PhotoManager.editor.saveImageWithPath(
        file.path,
        title: name,
        relativePath: 'Pictures/PhotoBridge$sub',
        creationDate: created,
        latitude: location?.$1,
        longitude: location?.$2,
      );
    }
    // Android's media scanner overwrites "date taken" with the file's own
    // time when there is no EXIF date (always for videos), so set it again.
    if (Platform.isAndroid && created != null) {
      try {
        entity = await PhotoManager.editor.android.updateCreationDate(
          entity: entity,
          creationDate: created,
        );
      } catch (_) {}
    }
    if (Platform.isIOS && album.isNotEmpty) await _addToAlbum(entity, album);
    return entity.id;
  }

  /// iPhone: puts a received photo into the sender's album, creating it.
  Future<void> _addToAlbum(AssetEntity entity, String album) async {
    try {
      final albums = await PhotoManager.getAssetPathList(
        hasAll: false,
        pathFilterOption: const PMPathFilter(
          darwin: PMDarwinPathFilter(
            type: [PMDarwinAssetCollectionType.album],
            subType: [PMDarwinAssetCollectionSubtype.albumRegular],
          ),
        ),
      );
      final target =
          albums.where((p) => p.name == album).firstOrNull ??
          await PhotoManager.editor.darwin.createAlbum(album);
      if (target != null) {
        await PhotoManager.editor.copyAssetToPath(
          asset: entity,
          pathEntity: target,
        );
      }
    } catch (_) {
      // The photo is saved either way.
    }
  }

  @override
  Future<int> repairDates(List<DateFix> fixes) async {
    // Only Android keeps the file's own (missing) date; iPhone saves with
    // the date it was given.
    if (!Platform.isAndroid || fixes.isEmpty) return 0;
    final byName = {for (final f in fixes) f.name.toLowerCase(): f};
    final filter = CustomFilter.sql(
      where: "relative_path LIKE 'Pictures/PhotoBridge%'",
    );
    final count = await PhotoManager.getAssetCount(
      filterOption: filter,
      type: RequestType.image,
    );
    var fixed = 0;
    for (var start = 0; start < count; start += _pageSize) {
      final page = await PhotoManager.getAssetListRange(
        start: start,
        end: (start + _pageSize).clamp(0, count),
        filterOption: filter,
        type: RequestType.image,
      );
      for (final a in page) {
        final fix = byName[(a.title ?? '').toLowerCase()];
        if (fix == null) continue;
        if (a.createDateTime.difference(fix.created).abs() <
            const Duration(minutes: 1)) {
          continue;
        }
        final file = await a.originFile;
        if (file == null) continue;
        // Camera photos have their own EXIF date, which is right: leave them.
        if (!await _stampExif(file.path, fix.created, fix.location)) continue;
        try {
          await PhotoManager.editor.android.updateCreationDate(
            entity: a,
            creationDate: fix.created,
          );
          fixed++;
        } catch (_) {}
      }
    }
    return fixed;
  }

  /// Formats Android's ExifInterface can write.
  static final _exifWritable = RegExp(
    r'\.(jpe?g|png|webp)$',
    caseSensitive: false,
  );

  /// Fills in the capture date and GPS when the image lacks them. Existing
  /// values (e.g. camera photos) are never touched.
  /// Returns true when the date was missing and has been written.
  Future<bool> _stampExif(
    String path,
    DateTime? created,
    (double, double)? location,
  ) async {
    if (!_exifWritable.hasMatch(path)) return false;
    if (created == null && location == null) return false;
    var wroteDate = false;
    Exif? exif;
    try {
      exif = await Exif.fromPath(path);
      final values = <String, Object>{};
      if (created != null && await exif.getOriginalDate() == null) {
        final local = created.toLocal();
        final stamp = _exifDate(local);
        values['DateTimeOriginal'] = stamp;
        values['DateTimeDigitized'] = stamp;
        values['DateTime'] = stamp;
        values['OffsetTimeOriginal'] = _exifOffset(local.timeZoneOffset);
        wroteDate = true;
      }
      if (location case (final lat, final lng)
          when await exif.getLatLong() == null) {
        values['GPSLatitude'] = lat;
        values['GPSLongitude'] = lng;
      }
      if (values.isNotEmpty) await exif.writeAttributes(values);
    } catch (_) {
      // Unreadable metadata: save the file as it is.
      wroteDate = false;
    } finally {
      await exif?.close();
    }
    return wroteDate;
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _exifDate(DateTime t) =>
      '${t.year}:${_two(t.month)}:${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  static String _exifOffset(Duration d) {
    final m = d.inMinutes.abs();
    return '${d.isNegative ? '-' : '+'}${_two(m ~/ 60)}:${_two(m % 60)}';
  }
}
