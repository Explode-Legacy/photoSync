import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

/// A photo/video exported to a readable file for upload.
class ExportedAsset {
  ExportedAsset(this.file, this.name, this.kind);

  final File file;
  final String name;

  /// `image` or `video`.
  final String kind;
}

/// Thin wrapper around photo_manager for reading and saving media.
class MediaLibrary {
  static const _pageSize = 200;

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
  Future<void> releaseExports() async {
    if (Platform.isIOS) await PhotoManager.clearFileCache();
  }

  /// Saves a received file into the gallery and returns the new asset id.
  Future<String> save(
    File file, {
    required String name,
    required String kind,
    DateTime? created,
  }) async {
    final AssetEntity entity;
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
      );
    }
    return entity.id;
  }
}
