import 'dart:async';
import 'dart:io' show SocketException, gzip;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:vector_map_tiles/vector_map_tiles.dart';

import 'api_client.dart';

/// Minimal PMTiles v3 reader over HTTP range requests, exposed as a
/// [VectorTileProvider]. Enough to read Overture's hosted archives: header,
/// Hilbert tile ids, gzip-compressed root/leaf directories, gzip tiles.
///
/// One instance per archive URL (see [forUri]) so the header and root
/// directory are fetched once for the whole app, and every range request
/// goes through one keep-alive [http.Client] rather than a cold TLS
/// handshake per tile.
class PmTilesVectorTileProvider extends VectorTileProvider {
  final Uri uri;
  final int _minZoom;
  final int _maxZoom;
  final http.Client _client;

  @override
  TileOffset get tileOffset => TileOffset.DEFAULT;

  static const _requestTimeout = Duration(seconds: 15);
  static const _retryDelay = Duration(milliseconds: 400);

  /// Payloads above this are inflated in a short-lived isolate; smaller
  /// ones aren't worth the isolate spawn.
  @visibleForTesting
  static const isolateThresholdBytes = 32 * 1024;

  Future<_Header>? _headerFuture;
  final Map<int, Future<List<_Entry>>> _dirCache = {};

  static final _byUri = <String, PmTilesVectorTileProvider>{};

  PmTilesVectorTileProvider(
    this.uri, {
    int minZoom = 0,
    int maxZoom = 14,
    http.Client? client,
  }) : _minZoom = minZoom,
       _maxZoom = maxZoom,
       _client = client ?? ApiClient.shared;

  /// Shared provider for [uri]; the zoom range is fixed on first use.
  factory PmTilesVectorTileProvider.forUri(
    Uri uri, {
    int minZoom = 0,
    int maxZoom = 14,
  }) => _byUri.putIfAbsent(
    uri.toString(),
    () => PmTilesVectorTileProvider(uri, minZoom: minZoom, maxZoom: maxZoom),
  );

  @override
  int get maximumZoom => _maxZoom;
  @override
  int get minimumZoom => _minZoom;

  @override
  Future<Uint8List> provide(TileIdentity tile) async {
    final h = await _loadHeader();
    final id = zxyToTileId(tile.z, tile.x, tile.y);
    var entries = await _dir(h.rootOffset, h.rootLength, h);
    for (var depth = 0; depth < 4; depth++) {
      final e = _find(entries, id);
      if (e == null) return Uint8List(0);
      if (e.runLength > 0) {
        final bytes = await _range(h.tileDataOffset + e.offset, e.length);
        return h.tileCompression == 2 ? _gunzip(bytes) : bytes;
      }
      entries = await _dir(h.leafOffset + e.offset, e.length, h);
    }
    return Uint8List(0);
  }

  /// Inflates [bytes], off the UI isolate when the payload is big enough
  /// to matter (dense city tiles inflate to several MB and block for tens
  /// of milliseconds).
  static Future<Uint8List> _gunzip(Uint8List bytes) async {
    if (bytes.length < isolateThresholdBytes) {
      return _asUint8List(gzip.decode(bytes));
    }
    return Isolate.run(() => _asUint8List(gzip.decode(bytes)));
  }

  /// `gzip.decode` already returns a `Uint8List`; avoid a second copy.
  static Uint8List _asUint8List(List<int> list) =>
      list is Uint8List ? list : Uint8List.fromList(list);

  Future<_Header> _loadHeader() => _headerFuture ??=
      () async {
        final b = await _range(0, 127);
        if (b.length < 127 ||
            String.fromCharCodes(b.sublist(0, 7)) != 'PMTiles' ||
            b[7] != 3) {
          throw ProviderException(
            message: 'Not a PMTiles v3 archive: $uri',
            retryable: Retryable.none,
          );
        }
        final d = ByteData.sublistView(b);
        int u64(int o) => d.getUint64(o, Endian.little);
        return _Header(
          rootOffset: u64(8),
          rootLength: u64(16),
          leafOffset: u64(40),
          tileDataOffset: u64(56),
          internalCompression: b[97],
          tileCompression: b[98],
        );
      }().onError((Object e, StackTrace s) {
        _headerFuture = null;
        Error.throwWithStackTrace(e, s);
      });

  Future<List<_Entry>> _dir(int offset, int length, _Header h) =>
      _dirCache[offset] ??=
          () async {
            var bytes = await _range(offset, length);
            if (h.internalCompression == 2) bytes = await _gunzip(bytes);
            return _decodeDir(bytes);
          }().onError((Object e, StackTrace s) {
            unawaited(_dirCache.remove(offset));
            Error.throwWithStackTrace(e, s);
          });

  /// One byte-range GET with a timeout and a single retry on transient
  /// failures (connection reset, timeout, 5xx, 429).
  Future<Uint8List> _range(int offset, int length) async {
    final headers = {'Range': 'bytes=$offset-${offset + length - 1}'};
    for (var attempt = 0; ; attempt++) {
      final lastAttempt = attempt > 0;
      try {
        final res = await _client
            .get(uri, headers: headers)
            .timeout(_requestTimeout);
        if (res.statusCode == 206 || res.statusCode == 200) {
          return res.bodyBytes;
        }
        final transient = res.statusCode >= 500 || res.statusCode == 429;
        if (!transient || lastAttempt) {
          throw ProviderException(
            message: 'HTTP ${res.statusCode} reading $uri',
            statusCode: res.statusCode,
            retryable: transient ? Retryable.retry : Retryable.none,
          );
        }
      } on ProviderException {
        rethrow;
      } on TimeoutException {
        if (lastAttempt) {
          throw ProviderException(
            message: 'Timed out reading $uri',
            retryable: Retryable.retry,
          );
        }
      } on SocketException {
        if (lastAttempt) {
          throw ProviderException(
            message: 'Network error reading $uri',
            retryable: Retryable.retry,
          );
        }
      } on http.ClientException {
        if (lastAttempt) {
          throw ProviderException(
            message: 'Network error reading $uri',
            retryable: Retryable.retry,
          );
        }
      }
      await Future<void>.delayed(_retryDelay * (attempt + 1));
    }
  }

  static _Entry? _find(List<_Entry> entries, int id) {
    var lo = 0, hi = entries.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final v = entries[mid].tileId;
      if (v == id) return entries[mid];
      if (v < id) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (hi >= 0) {
      final e = entries[hi];
      if (e.runLength == 0) return e; // leaf directory
      if (id - e.tileId < e.runLength) return e;
    }
    return null;
  }

  static List<_Entry> _decodeDir(Uint8List b) {
    var pos = 0;
    int varint() {
      var shift = 0, result = 0;
      while (true) {
        if (pos >= b.length) {
          throw ProviderException(
            message: 'Truncated PMTiles directory',
            retryable: Retryable.retry,
          );
        }
        final byte = b[pos++];
        result |= (byte & 0x7f) << shift;
        if (byte < 0x80) return result;
        shift += 7;
      }
    }

    final n = varint();
    final ids = List<int>.filled(n, 0);
    var last = 0;
    for (var i = 0; i < n; i++) {
      last += varint();
      ids[i] = last;
    }
    final runs = List<int>.generate(n, (_) => varint());
    final lens = List<int>.generate(n, (_) => varint());
    final offs = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final v = varint();
      offs[i] = (v == 0 && i > 0) ? offs[i - 1] + lens[i - 1] : v - 1;
    }
    return List.generate(
      n,
      (i) => _Entry(ids[i], offs[i], lens[i], runs[i]),
      growable: false,
    );
  }

  /// Hilbert-curve tile id per the PMTiles spec.
  static int zxyToTileId(int z, int x, int y) {
    var acc = 0;
    for (var t = 0; t < z; t++) {
      acc += 1 << (2 * t);
    }
    final n = 1 << z;
    var d = 0, rx = 0, ry = 0, s = n >> 1;
    var xx = x, yy = y;
    while (s > 0) {
      rx = (xx & s) > 0 ? 1 : 0;
      ry = (yy & s) > 0 ? 1 : 0;
      d += s * s * ((3 * rx) ^ ry);
      if (ry == 0) {
        if (rx == 1) {
          xx = s - 1 - xx;
          yy = s - 1 - yy;
        }
        final t = xx;
        xx = yy;
        yy = t;
      }
      s >>= 1;
    }
    return acc + d;
  }
}

class _Header {
  final int rootOffset, rootLength, leafOffset, tileDataOffset;
  final int internalCompression, tileCompression;
  _Header({
    required this.rootOffset,
    required this.rootLength,
    required this.leafOffset,
    required this.tileDataOffset,
    required this.internalCompression,
    required this.tileCompression,
  });
}

class _Entry {
  final int tileId, offset, length, runLength;
  const _Entry(this.tileId, this.offset, this.length, this.runLength);
}
