import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// An append-only set of ids stored one per line.
///
/// Used to remember what was already sent, received and imported, so
/// nothing is transferred twice and received photos are never echoed back.
class IdLedger {
  IdLedger._(this._file, this._ids);

  final File _file;
  final Set<String> _ids;
  Future<void> _pending = Future.value();

  static Future<IdLedger> open(String name) async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/$name.txt');
    final ids = <String>{};
    if (await file.exists()) {
      ids.addAll((await file.readAsLines()).where((l) => l.isNotEmpty));
    }
    return IdLedger._(file, ids);
  }

  int get length => _ids.length;

  bool contains(String id) => _ids.contains(id);

  Future<void> add(String id) {
    if (!_ids.add(id)) return _pending;
    // Chain writes so concurrent adds never interleave.
    return _pending = _pending.then(
      (_) => _file.writeAsString('$id\n', mode: FileMode.append, flush: true),
    );
  }

  Future<void> clear() async {
    _ids.clear();
    await _pending;
    if (await _file.exists()) await _file.delete();
  }
}
