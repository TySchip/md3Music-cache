import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/favorite_audio_cache.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

class MemoryStore implements FavoriteCacheStore {
  final data = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String account) async => data[account];
  @override
  Future<void> write(String account, Map<String, dynamic> json) async {
    data[account] = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
  }
}

class MemoryBackend implements FavoriteCacheBackend {
  @override
  Future<void> activate(String prefix) async {}
  @override
  Future<void> pause() => cancel();
  bool wifi = true;
  final disk = <String, int>{};
  final transferred = <String>[];
  int limit = favoriteCacheDefaultBytes;
  int get used => disk.values.fold(0, (a, b) => a + b);
  Completer<void>? blocked;
  @override
  Future<Map<String, dynamic>> status() async => {
    'wifi': wifi,
    'usedBytes': used,
    'entries': disk.map(
      (key, bytes) => MapEntry(key, {'complete': true, 'bytes': bytes}),
    ),
  };
  @override
  Future<void> configure(
    String prefix,
    List<String> keys,
    bool enabled,
    int maxBytes,
  ) async {
    limit = maxBytes;
    disk.removeWhere((key, _) => key.startsWith(prefix) && !keys.contains(key));
  }

  @override
  Future<void> register(String key, String url) async {}
  @override
  Future<Map<String, dynamic>> download(
    FavoriteCacheEntry entry,
    String url,
    String title,
    List<String> order,
  ) async {
    if (blocked != null) await blocked!.future;
    if (!wifi) throw StateError('Wi-Fi disconnected');
    for (final key in order.reversed) {
      if (used + entry.expectedBytes <= limit) break;
      disk.remove(key);
    }
    disk[entry.key] = entry.expectedBytes;
    transferred.add(title);
    return {'bytes': entry.expectedBytes};
  }

  @override
  Future<void> cancel() async {
    final pending = blocked;
    blocked = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  @override
  Future<void> clear() async => disk.clear();
}

Song song(String id) => Song(
  id: id,
  title: id,
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 4),
  isOnline: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryBackend backend;
  late MemoryStore store;
  late List<Song> favorites;
  late Map<String, int> sizes;
  late FavoriteAudioCache cache;
  var snapshotFails = false;
  var resolutionFails = <String>{};
  var quality = '128';
  FavoriteAudioCache create() => FavoriteAudioCache(
    backend: backend,
    store: store,
    fetchSongs: () async {
      if (snapshotFails) throw StateError('page 2 failed');
      return favorites;
    },
    wifiQuality: () async => quality,
    resolveSong: (song, requested) async => resolutionFails.contains(song.id)
        ? null
        : KugouPlayUrl(
            url: 'https://audio.invalid/${song.id}',
            quality: requested,
            fileSize: sizes[song.id] ?? 1,
          ),
  );

  setUp(() {
    backend = MemoryBackend();
    store = MemoryStore();
    favorites = ['new', 'middle', 'old'].map(song).toList();
    sizes = {'new': 40, 'middle': 35, 'old': 25};
    snapshotFails = false;
    resolutionFails = {};
    quality = '128';
    cache = create()..setAccount('account-a');
    cache.maxBytes = 100;
  });
  tearDown(() => cache.dispose());

  test(
    'fills favorites newest first without playback, then transfers nothing',
    () async {
      await cache.sync();
      expect(backend.transferred, ['new', 'middle', 'old']);
      expect(backend.used, 100);
      await cache.sync();
      expect(backend.transferred, hasLength(3));
      expect(await cache.resolveLocal('new', 'flac'), startsWith('md3cache:'));
    },
  );

  test(
    'one large new favorite evicts several oldest songs, never changes favorites',
    () async {
      await cache.sync();
      final priorFavorites = [...favorites];
      favorites = [song('latest'), ...favorites];
      sizes['latest'] = 55;
      await cache.sync();
      expect(backend.used, 95);
      expect(cache.isComplete('latest'), isTrue);
      expect(cache.isComplete('new'), isTrue);
      expect(cache.isComplete('middle'), isFalse);
      expect(cache.isComplete('old'), isFalse);
      expect(
        favorites.skip(1).map((s) => s.id),
        priorFavorites.map((s) => s.id),
      );
    },
  );

  test('unlike removes its cache and fills the next older favorite', () async {
    favorites = [song('new'), song('middle'), song('old'), song('older')];
    sizes['older'] = 30;
    await cache.sync();
    favorites = favorites.where((s) => s.id != 'middle').toList();
    await cache.sync();
    expect(cache.isComplete('middle'), isFalse);
    expect(cache.isComplete('older'), isTrue);
    expect(backend.used, 95);
  });

  test(
    'partial cloud failure preserves the entire old catalog and audio',
    () async {
      await cache.sync();
      final disk = Map.of(backend.disk);
      snapshotFails = true;
      favorites = [song('partial')];
      await cache.sync();
      expect(cache.songs.map((s) => s.id), ['new', 'middle', 'old']);
      expect(backend.disk, disk);
      expect(cache.error, contains('page 2 failed'));
    },
  );

  test(
    'cold restart offline restores catalog and resolves without URL request',
    () async {
      await cache.sync();
      cache.dispose();
      backend.wifi = false;
      cache = create()..setAccount('account-a');
      resolutionFails = {'new', 'middle', 'old'};
      await cache.sync();
      expect(cache.songs, hasLength(3));
      expect(await cache.resolveLocal('old', 'high'), startsWith('md3cache:'));
      expect(backend.transferred, hasLength(3));
    },
  );

  test(
    'manual clear refills on next sync; changed quality does not recache complete songs',
    () async {
      await cache.sync();
      quality = 'flac';
      await cache.sync();
      expect(backend.transferred, hasLength(3));
      await cache.clear();
      expect(backend.used, 0);
      await cache.sync();
      expect(backend.transferred, hasLength(6));
      expect(cache.entries['new']!.quality, '128');
    },
  );

  test(
    'failure skips one source, retries later; never caches non-favorites',
    () async {
      resolutionFails = {'middle'};
      await cache.sync();
      expect(backend.transferred, ['new', 'old']);
      expect(cache.label('middle'), contains('无法获取'));
      resolutionFails.clear();
      await cache.sync();
      expect(cache.isComplete('middle'), isTrue);
      expect(await cache.resolveLocal('not-favorite', '128'), isNull);
    },
  );

  test(
    'Wi-Fi required; account switch cannot expose another account audio',
    () async {
      backend.wifi = false;
      await cache.sync();
      expect(backend.transferred, isEmpty);
      backend.wifi = true;
      await cache.sync();
      cache.setAccount('account-b');
      backend.wifi = false;
      await cache.sync();
      expect(await cache.resolveLocal('new', '128'), isNull);
      expect(
        favoriteCacheKey('account-a', 'new', '128'),
        isNot(favoriteCacheKey('account-b', 'new', '128')),
      );
    },
  );

  test('lowering the limit trims only the old tail', () async {
    await cache.sync();
    await cache.setLimit(80);
    await cache.sync();
    expect(backend.used, 75);
    expect(cache.isComplete('new'), isTrue);
    expect(cache.isComplete('middle'), isTrue);
    expect(cache.isComplete('old'), isFalse);
  });

  test('a newly liked song replaces an in-flight old snapshot', () async {
    backend.blocked = Completer<void>();
    final flight = cache.sync();
    await Future<void>.delayed(Duration.zero);
    favorites = [song('latest'), ...favorites];
    sizes['latest'] = 55;
    cache.requestSync();
    await flight;
    expect(cache.songs.first.id, 'latest');
    expect(cache.isComplete('latest'), isTrue);
    expect(cache.isComplete('new'), isTrue);
    expect(cache.isComplete('old'), isFalse);
    expect(backend.used, lessThanOrEqualTo(100));
  });

  test(
    'changing a setting before cold-start sync preserves the saved catalog',
    () async {
      await cache.sync();
      cache.dispose();
      cache = create()..setAccount('account-a');
      await cache.setEnabled(false);
      await cache.sync();
      expect(cache.songs, hasLength(3));
      expect(cache.enabled, isFalse);
      expect(await cache.resolveLocal('new', 'high'), startsWith('md3cache:'));
      expect(backend.transferred, hasLength(3));
    },
  );
}
