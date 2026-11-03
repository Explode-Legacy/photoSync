import 'dart:io';

import 'package:native_exif/native_exif.dart';
import 'package:photo_manager/photo_manager.dart';

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

  /// Frees any temporary copies made by [SourceItem.export].
  Future<void> releaseExports();

  /// Saves a received photo or video and returns its new id.
  Future<String> save(
    File file, {
    required String name,
    required String kind,
    DateTime? created,
    (double, double)? location,
  });
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
      _item(a),
  ];

  @override
  Future<List<SourceItem>> byIds(List<String> ids) async => [
    for (final id in ids)
      if (await AssetEntity.fromId(id) case final a?) _item(a),
  ];

  SourceItem _item(AssetEntity a) => SourceItem(
    id: a.id,
    title: a.title ?? a.id,
    created: a.createDateTime,
    location: _locationOf(a),
    export: () => export(a),
  );

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
    if (Platform.isIOS) await PhotoManager.clearFileCache();
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
  }) async {
    if (Platform.isAndroid && kind == 'image') {
      await _stampExif(file.path, created, location);
    }
    AssetEntity entity;
    if (kind == 'video') {
      entity = await PhotoManager.editor.saveVideo(
        file,
        title: name,
        relativePath: 'Movies/PhotoBridge',
        creationDate: created,
      );
    } else {
      entity = await PhotoManager.editor.saveImageWithPath(
        file.path,
        title: name,
        relativePath: 'Pictures/PhotoBridge',
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
    return entity.id;
  }

  /// Formats Android's ExifInterface can write.
  static final _exifWritable = RegExp(
    r'\.(jpe?g|png|webp)$',
    caseSensitive: false,
  );

  /// Fills in the capture date and GPS when the image lacks them. Existing
  /// values (e.g. camera photos) are never touched.
  Future<void> _stampExif(
    String path,
    DateTime? created,
    (double, double)? location,
  ) async {
    if (!_exifWritable.hasMatch(path)) return;
    if (created == null && location == null) return;
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
      }
      if (location case (final lat, final lng)
          when await exif.getLatLong() == null) {
        values['GPSLatitude'] = lat;
        values['GPSLongitude'] = lng;
      }
      if (values.isNotEmpty) await exif.writeAttributes(values);
    } catch (_) {
      // Unreadable metadata: save the file as it is.
    } finally {
      await exif?.close();
    }
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
