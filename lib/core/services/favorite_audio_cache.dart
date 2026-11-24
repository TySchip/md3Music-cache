import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/models/song.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';

const favoriteCacheDefaultBytes = 5 * 1000 * 1000 * 1000;

String favoriteCachePrefix(String account) =>
    '${sha256.convert(utf8.encode(account)).toString().substring(0, 16)}_';

String favoriteCacheKey(String account, String songId, String quality) =>
    '${favoriteCachePrefix(account)}${sha256.convert(utf8.encode('$songId\u0000$quality'))}';

class FavoriteCacheEntry {
  final String key;
  final String quality;
  final int expectedBytes;
  bool complete = false;
  String? error;
  KugouLyric? lyric;
  String? artworkUri;

  FavoriteCacheEntry(this.key, this.quality, this.expectedBytes);

  Map<String, dynamic> toJson() => {
    'key': key,
    'quality': quality,
    'bytes': expectedBytes,
    'error': error,
    if (lyric != null)
      'lyric': {
        'content': lyric!.content,
        'decodeContent': lyric!.decodedContent,
        'decodeKrcContent': lyric!.decodedKrcContent,
        'translated_content': lyric!.translatedContent,
        'roma': lyric!.romaContent,
      },
  };

  factory FavoriteCacheEntry.fromJson(Map<String, dynamic> json) =>
      FavoriteCacheEntry(
          json['key'] as String,
          json['quality'] as String,
          (json['bytes'] as num).toInt(),
        )
        ..error = json['error'] as String?
        ..lyric = json['lyric'] == null
            ? null
            : KugouLyric(
                content: (json['lyric'] as Map)['content'] as String? ?? '',
                decodedContent:
                    (json['lyric'] as Map)['decodeContent'] as String?,
                decodedKrcContent:
                    (json['lyric'] as Map)['decodeKrcContent'] as String?,
                translatedContent:
                    (json['lyric'] as Map)['translated_content'] as String?,
                romaContent: (json['lyric'] as Map)['roma'] as String?,
              );
}

/// Cache state is read from disk on startup, never trusted from a saved URL.
abstract class FavoriteCacheBackend {
  Future<void> activate(String prefix) async {}
  Future<void> pause();
  Future<Map<String, dynamic>> status();
  Future<void> configure(
    String prefix,
    List<String> keys,
    bool enabled,
    int maxBytes,
  );
  Future<void> register(String key, String url);
  Future<Map<String, dynamic>> download(
    FavoriteCacheEntry entry,
    String url,
    String title,
    List<String> order,
  );
  Future<void> cancel();
  Future<void> clear();
}

class AndroidFavoriteCacheBackend implements FavoriteCacheBackend {
  static const channel = MethodChannel('com.md3music/favorite_cache');
  VoidCallback? onPlaybackReleased;
  AndroidFavoriteCacheBackend() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'playbackReleased') onPlaybackReleased?.call();
    });
  }
  Future<void> cacheArtwork(String key, String url) =>
      channel.invokeMethod('artwork', {'key': key, 'url': url});
  @override
  Future<void> activate(String prefix) =>
      channel.invokeMethod('activate', {'prefix': prefix});
  Future<Map<String, dynamic>> _map(
    String method, [
    Map<String, dynamic>? args,
  ]) async => Map<String, dynamic>.from(
    await channel.invokeMethod<Map>(method, args) ?? const {},
  );
  @override
  Future<Map<String, dynamic>> status() => _map('status');
  @override
  Future<void> configure(
    String prefix,
    List<String> keys,
    bool enabled,
    int maxBytes,
  ) async {
    await channel.invokeMethod('configure', {
      'prefix': prefix,
      'keys': keys,
      'enabled': enabled,
      'maxBytes': maxBytes,
    });
  }

  @override
  Future<void> register(String key, String url) =>
      channel.invokeMethod('register', {'key': key, 'url': url});
  @override
  Future<Map<String, dynamic>> download(
    FavoriteCacheEntry entry,
    String url,
    String title,
    List<String> order,
  ) => _map('download', {
    'key': entry.key,
    'url': url,
    'title': title,
    'bytes': entry.expectedBytes,
    'order': order,
  });
  @override
  Future<void> cancel() => channel.invokeMethod('cancel');
  @override
  Future<void> pause() => channel.invokeMethod('pause');
  @override
  Future<void> clear() => channel.invokeMethod('clear');
}

abstract class FavoriteCacheStore {
  Future<Map<String, dynamic>?> read(String account);
  Future<void> write(String account, Map<String, dynamic> json);
}

class FileFavoriteCacheStore implements FavoriteCacheStore {
  Future<void> _pending = Future<void>.value();
  Future<File> _file(String account) async {
    final dir = await getApplicationSupportDirectory();
    return File(
      '${dir.path}/favorite_cache_${favoriteCachePrefix(account)}.json',
    );
  }

  @override
  Future<Map<String, dynamic>?> read(String account) async {
    await _pending;
    final file = await _file(account);
    if (!await file.exists()) return null;
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  @override
  Future<void> write(String account, Map<String, dynamic> json) {
    final content = jsonEncode(json);
    return _pending = _pending.catchError((Object _) {}).then((_) async {
      final file = await _file(account);
      final temp = File('${file.path}.part');
      await temp.writeAsString(content, flush: true);
      await temp.rename(file.path);
    });
  }
}

/// An authoritative snapshot: partial pages throw and must not replace the catalog.
Future<List<Song>> fetchFavoriteCacheSnapshot(KugouApiClient api) async {
  final response = await api.getAllUserPlaylists(noCache: true);
  if (response == null || response['data'] is! Map) {
    throw StateError('无法完整同步我喜欢，已保留原有缓存');
  }
  final info = (response['data'] as Map)['info'];
  if (info is! List) throw StateError('收藏列表不完整');
  KugouPlaylistBrief? favorite;
  for (final raw in info) {
    if (raw is Map && ('${raw['is_def']}' == '2' || raw['name'] == '我喜欢')) {
      favorite = KugouPlaylistBrief.fromJson(Map<String, dynamic>.from(raw));
      break;
    }
  }
  if (favorite == null || favorite.listId.isEmpty) throw StateError('未找到我喜欢歌单');
  // This loader verifies all pages, count and playlist version before returning.
  // sort=0 is the front insertion position used by the favorites add endpoint.
  return (await api.getPlaylistTrackOrder(favorite.listId)).songs;
}

class FavoriteAudioCache extends ChangeNotifier with WidgetsBindingObserver {
  final FavoriteCacheBackend backend;
  final FavoriteCacheStore store;
  final Future<List<Song>> Function() fetchSongs;
  final Future<KugouPlayUrl?> Function(Song song, String quality) resolveSong;
  final Future<String> Function() wifiQuality;
  final Future<KugouLyric?> Function(Song song)? fetchLyric;
  final bool observePlatform;
  List<Song> songs = [];
  Map<String, FavoriteCacheEntry> entries = {};
  String? account;
  bool enabled = true;
  int maxBytes = favoriteCacheDefaultBytes;
  int usedBytes = 0;
  bool wifi = false;
  bool running = false;
  String? activeKey;
  double progress = 0;
  String? error;
  bool onlyCached = false;
  bool _disposed = false;
  bool _requested = false;
  bool _loaded = false;
  int _epoch = 0;
  Timer? _debounce;
  StreamSubscription<List<ConnectivityResult>>? _network;
  Future<void>? _flight;
  Future<void>? _accountReady;
  Listenable? _favorites;

  void listenToFavorites(Listenable favorites) {
    _favorites?.removeListener(requestSync);
    _favorites = favorites;
    favorites.addListener(requestSync);
  }

  FavoriteAudioCache({
    required this.backend,
    required this.store,
    required this.fetchSongs,
    required this.resolveSong,
    required this.wifiQuality,
    this.fetchLyric,
    this.observePlatform = false,
  }) {
    if (observePlatform) {
      WidgetsBinding.instance.addObserver(this);
      _network = Connectivity().onConnectivityChanged.listen(
        (_) => requestSync(),
      );
    }
  }

  factory FavoriteAudioCache.android() {
    final api = KugouApiClient();
    final backend = AndroidFavoriteCacheBackend();
    final cache = FavoriteAudioCache(
      backend: backend,
      store: FileFavoriteCacheStore(),
      fetchSongs: () => fetchFavoriteCacheSnapshot(api),
      resolveSong: (song, quality) => api.getSongUrlWithFallback(
        song.id,
        quality: quality,
        albumId: song.albumId,
        albumAudioId: song.albumAudioId,
      ),
      wifiQuality: () => SettingsRepository().getQualityForNetwork(true),
      fetchLyric: (song) => api
          .getLyric(song.id, songName: song.title)
          .timeout(const Duration(seconds: 6), onTimeout: () => null),
      observePlatform: true,
    );
    backend.onPlaybackReleased = () {
      if (cache.entries.values.any((entry) => entry.error == '空间不足或旧歌曲正在播放')) {
        cache.requestSync();
      }
    };
    cache._accountReady = api.isLoggedInWhenReady().then((_) {
      if (!cache._disposed) cache.setAccount(api.userid);
    });
    return cache;
  }

  List<Song> get displaySongs => songs.map((song) {
    final artwork = entries[song.id]?.artworkUri;
    return artwork == null ? song : song.copyWith(artworkUri: artwork);
  }).toList();

  void setAccount(String? value) {
    if (account == value) return;
    account = value;
    songs = [];
    entries = {};
    _loaded = false;
    error = null;
    onlyCached = false;
    unawaited(
      backend.activate(value == null ? '' : favoriteCachePrefix(value)),
    );
    requestSync();
  }

  bool isComplete(String id) => entries[id]?.complete ?? false;
  String label(String id) {
    final entry = entries[id];
    if (entry?.complete ?? false) {
      return '已缓存 · ${KugouQuality.labelOf(entry!.quality)}';
    }
    if (activeKey != null && entry?.key == activeKey) {
      return '正在缓存 ${(progress * 100).floor()}%';
    }
    if (entry?.error != null) return entry!.error!;
    return !enabled
        ? '自动缓存已关闭'
        : wifi
        ? '等待缓存'
        : '等待 Wi-Fi';
  }

  void toggleOnlyCached() {
    onlyCached = !onlyCached;
    notifyListeners();
  }

  void requestSync() {
    if (_disposed) return;
    _epoch++;
    _requested = true;
    unawaited(backend.pause().catchError((Object _) {}));
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(sync()),
    );
  }

  /// Public so refresh actions and tests can await a settled pass.
  Future<void> sync() {
    _debounce?.cancel();
    _requested = true;
    return _flight ??= _drain().whenComplete(() => _flight = null);
  }

  Future<void> _drain() async {
    running = true;
    _notify();
    try {
      while (_requested && !_disposed) {
        _requested = false;
        final epoch = _epoch;
        try {
          await _pass(epoch);
        } catch (e) {
          if (_current(epoch)) error = _message(e);
        }
      }
    } finally {
      if (!wifi && enabled && account != null) {
        await backend.pause().catchError((Object _) {});
      } else {
        await backend.cancel().catchError((Object _) {});
      }
      running = false;
      activeKey = null;
      _notify();
    }
  }

  bool _current(int epoch) => !_disposed && epoch == _epoch;
  String _message(Object e) => e is PlatformException
      ? e.message ?? '缓存暂不可用，请重试'
      : '$e'.replaceFirst('Bad state: ', '');
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _loadCatalog() async {
    final uid = account;
    if (_loaded || uid == null) return;
    final saved = await store.read(uid);
    if (account != uid || _loaded || _disposed) return;
    if (saved != null) {
      songs = (saved['songs'] as List)
          .map((s) => Song.fromJson(Map<String, dynamic>.from(s as Map)))
          .toList();
      entries = (saved['entries'] as Map).map(
        (id, e) => MapEntry(
          '$id',
          FavoriteCacheEntry.fromJson(Map<String, dynamic>.from(e as Map)),
        ),
      );
      enabled = saved['enabled'] as bool? ?? true;
      maxBytes =
          (saved['maxBytes'] as num?)?.toInt() ?? favoriteCacheDefaultBytes;
    }
    _loaded = true;
  }

  Future<void> _pass(int epoch) async {
    final uid = account;
    if (uid == null) return;
    await _loadCatalog();
    if (!_current(epoch)) return;
    await refreshState();
    if (!_current(epoch)) return;
    await backend.configure(
      favoriteCachePrefix(uid),
      songs.map((s) => entries[s.id]?.key).whereType<String>().toList(),
      enabled,
      maxBytes,
    );
    if (!_current(epoch)) return;
    await refreshState();
    if (!enabled || !wifi) {
      _notify();
      return;
    }
    final snapshot = await fetchSongs();
    if (!_current(epoch)) return;
    final seen = <String>{};
    songs = snapshot.where((s) => s.id.isNotEmpty && seen.add(s.id)).toList();
    entries.removeWhere((id, _) => !seen.contains(id));
    error = null;
    await _save(uid);
    await backend.configure(
      favoriteCachePrefix(uid),
      songs.map((s) => entries[s.id]?.key).whereType<String>().toList(),
      enabled,
      maxBytes,
    );
    if (!_current(epoch)) return;
    await refreshState();
    final quality = await wifiQuality();
    var committedBytes = 0;
    for (final song in songs.toList()) {
      if (!_current(epoch)) return;
      await refreshState();
      if (!wifi || !enabled) return;
      var entry = entries[song.id];
      if (entry?.complete ?? false) {
        committedBytes += entry!.expectedBytes;
        if (committedBytes > maxBytes) {
          // A lowered limit must remove the old tail, even when no task is pending.
          final keep = songs
              .takeWhile((s) => s.id != song.id)
              .map((s) => entries[s.id]?.key)
              .whereType<String>()
              .toList();
          await backend.configure(
            favoriteCachePrefix(uid),
            keep,
            enabled,
            maxBytes,
          );
          await refreshState();
          break;
        }
        continue;
      }
      try {
        final source = await resolveSong(song, entry?.quality ?? quality);
        if (!_current(epoch)) return;
        if (source == null ||
            source.isTrial ||
            source.url.isEmpty ||
            source.fileSize <= 0) {
          throw StateError('无法获取完整歌曲，待重试');
        }
        final oldLyric = entry?.lyric;
        entry = FavoriteCacheEntry(
          favoriteCacheKey(uid, song.id, source.quality),
          source.quality,
          source.fileSize,
        )..lyric = oldLyric;
        entries[song.id] = entry;
        if (committedBytes + source.fileSize > maxBytes) {
          final keep = songs
              .takeWhile((s) => s.id != song.id)
              .map((s) => entries[s.id]?.key)
              .whereType<String>()
              .toList();
          await backend.configure(
            favoriteCachePrefix(uid),
            keep,
            enabled,
            maxBytes,
          );
          await refreshState();
          break;
        }
        await _save(uid);
        activeKey = entry.key;
        progress = 0;
        _notify();
        final timer = Timer.periodic(const Duration(seconds: 1), (_) {
          unawaited(refreshState().catchError((Object _) {}));
        });
        Map<String, dynamic> result;
        try {
          final order = songs
              .map(
                (s) =>
                    entries[s.id]?.key ?? favoriteCacheKey(uid, s.id, quality),
              )
              .toList();
          result = await backend.download(
            entry,
            source.url,
            song.displayName,
            order,
          );
        } finally {
          timer.cancel();
        }
        if (!_current(epoch)) return;
        if (result['limit'] == true) {
          entry.error = '空间不足或旧歌曲正在播放';
          break;
        }
        await refreshState();
        if (!entry.complete) throw StateError('歌曲尚未完整缓存');
        entry.error = null;
        committedBytes += entry.expectedBytes;
        if (backend is AndroidFavoriteCacheBackend && song.artworkUri != null) {
          try {
            await (backend as AndroidFavoriteCacheBackend).cacheArtwork(
              entry.key,
              song.artworkUri!,
            );
          } catch (_) {
            /* Cover failure must not interrupt the music queue. */
          }
          if (!_current(epoch)) return;
          await refreshState();
        }
        if (entry.lyric == null && fetchLyric != null && wifi) {
          try {
            entry.lyric = await fetchLyric!(song);
          } catch (_) {
            /* Lyrics are optional; audio remains available. */
          }
          if (!_current(epoch)) return;
        }
      } catch (e) {
        if (!_current(epoch)) return;
        entry ??= FavoriteCacheEntry(
          favoriteCacheKey(uid, song.id, quality),
          quality,
          0,
        );
        entries[song.id] = entry;
        entry.error = _message(e);
        if (entry.error == '请打开应用以继续缓存') {
          error = entry.error;
          await _save(uid);
          break;
        }
      }
      await _save(uid);
      _notify();
    }
    if (_current(epoch)) {
      await _save(uid);
      _notify();
    }
  }

  Future<void> refreshState() async {
    final epoch = _epoch;
    final state = await backend.status();
    if (!_current(epoch)) return;
    wifi = state['wifi'] == true;
    usedBytes = (state['usedBytes'] as num?)?.toInt() ?? 0;
    final statuses = state['entries'] as Map? ?? const {};
    for (final entry in entries.values) {
      final status = statuses[entry.key] as Map?;
      entry.complete =
          status?['complete'] == true &&
          (status?['bytes'] as num?)?.toInt() == entry.expectedBytes;
      entry.artworkUri = status?['artwork'] as String?;
    }
    activeKey = state['activeKey'] as String?;
    final total = (state['total'] as num?)?.toDouble() ?? 0;
    progress = total > 0
        ? ((state['progress'] as num?)?.toDouble() ?? 0) / total
        : 0;
    _notify();
  }

  Future<void> _save(String uid) => store.write(uid, {
    'songs': songs.map((s) => s.toJson()).toList(),
    'entries': entries.map((id, entry) => MapEntry(id, entry.toJson())),
    'enabled': enabled,
    'maxBytes': maxBytes,
  });

  Future<String?> resolveLocal(String id, String quality) async {
    await _accountReady;
    await syncIfLoading();
    final entry = entries[id];
    return entry != null && entry.complete ? 'md3cache://${entry.key}' : null;
  }

  String? cachedQuality(String id) =>
      isComplete(id) ? entries[id]?.quality : null;

  Future<KugouLyric?> restoreLyric(String id) async {
    await _accountReady;
    await syncIfLoading();
    return isComplete(id) ? entries[id]?.lyric : null;
  }

  void storeLyric(String id, KugouLyric lyric) {
    final entry = entries[id];
    if (entry == null || account == null) return;
    entry.lyric = lyric;
    unawaited(_save(account!).catchError((Object _) {}));
  }

  Future<void> syncIfLoading() async {
    // Do not await an entire 5GB sync just to start playback.
    if (!_loaded && account != null) {
      await _loadCatalog();
      await refreshState();
    }
  }

  Future<void> registerPlaying(Song song, String quality, String url) async {
    final entry = entries[song.id];
    if (entry != null &&
        entry.quality == quality &&
        !url.startsWith('md3cache:')) {
      try {
        await backend.register(entry.key, url);
      } catch (_) {
        // An unavailable cache must not block the normal online audio source.
      }
    }
  }

  Future<void> setEnabled(bool value) async {
    await _loadCatalog();
    enabled = value;
    _epoch++;
    _requested = false;
    await backend.cancel();
    if (account != null) await _save(account!);
    _notify();
    if (value) requestSync();
  }

  Future<void> setLimit(int bytes) async {
    await _loadCatalog();
    maxBytes = bytes;
    if (account != null) await _save(account!);
    requestSync();
  }

  Future<void> clear() async {
    _epoch++;
    _requested = false;
    await backend.clear();
    await refreshState();
    _notify();
    // Deliberate deletion is refilled at the next ordinary sync trigger.
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) requestSync();
    if (state == AppLifecycleState.detached) {
      _epoch++;
      _requested = false;
      unawaited(backend.cancel());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _debounce?.cancel();
    unawaited(_network?.cancel());
    unawaited(backend.cancel());
    _favorites?.removeListener(requestSync);
    if (observePlatform) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
