import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/favorite_audio_cache.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/fake_secure_storage.dart';

class FavoriteSnapshotApi implements HttpClientAdapter {
  bool namedPlaylist = true;
  final requestedLists = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    final Map<String, dynamic> data;
    if (options.path == '/user/playlist') {
      data = {
        'info': [
          {
            'name': '默认收藏',
            'listid': 'default',
            'is_def': 2,
            'type': 0,
            'source': 0,
            'count': 1,
            'list_ver': 1,
          },
          if (namedPlaylist)
            {
              'name': '我喜欢',
              'listid': 'liked',
              'is_def': 0,
              'type': 0,
              'source': 0,
              'count': 1,
              'list_ver': 1,
            },
        ],
      };
    } else {
      final list = '${options.queryParameters['listid']}';
      requestedLists.add(list);
      data = {
        'count': 1,
        'info': [
          {'hash': list, 'filename': list, 'fileid': 1, 'sort': 0},
        ],
      };
    }
    return ResponseBody.fromString(
      jsonEncode({'status': 1, 'data': data}),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late KugouApiClient api;
  late HttpClientAdapter original;
  late FavoriteSnapshotApi server;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    api = KugouApiClient();
    await api.setLoginCookies('fixture-token', 'fixture-user');
    KugouApiClient.markServerReady();
    original = api.dio.httpClientAdapter;
    server = FavoriteSnapshotApi();
    api.dio.httpClientAdapter = server;
  });
  tearDown(() async {
    api.dio.httpClientAdapter = original;
    await api.clearCookies();
    uninstallFakeSecureStorage();
  });

  test('我喜欢 takes priority over an earlier 默认收藏 playlist', () async {
    final songs = await fetchFavoriteCacheSnapshot(api);
    expect(server.requestedLists, ['liked']);
    expect(songs.single.id, 'liked');
  });

  test('a renamed default favorites playlist remains the fallback', () async {
    server.namedPlaylist = false;
    final songs = await fetchFavoriteCacheSnapshot(api);
    expect(server.requestedLists, ['default']);
    expect(songs.single.id, 'default');
  });
}
