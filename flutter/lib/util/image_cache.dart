import 'dart:typed_data';

import '../src/rust/api/history.dart' as api_history;

/// Tiny LRU image cache. The Rust core stores images as external PNGs and only
/// hands back raw bytes on demand ([api_history.getImageData]); we memoize the
/// decode bytes per item id so scrolling/re-clicking does not re-cross the FFI
/// boundary. Replaces the old Svelte-side base64 LRU (`src/stores/clipboard.ts`)
/// — images are now raw `Uint8List`, never data URLs.
const int _kMaxEntries = 50;

final Map<BigInt, Uint8List> _cache = {};

/// Fetch image bytes for [id], serving from cache when available. Returns
/// `null` for non-image items or failed reads (mirrors the Rust `Option`).
Future<Uint8List?> getImageData(BigInt id) async {
  final cached = _cache[id];
  if (cached != null) return cached;
  final result = await api_history.getImageData(id: id);
  if (result != null) {
    if (_cache.length >= _kMaxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[id] = result;
  }
  return result;
}

/// Drop one entry (used after delete).
void evictImage(BigInt id) => _cache.remove(id);

/// Drop everything (used after history replace / clear).
void clearImageCache() => _cache.clear();
