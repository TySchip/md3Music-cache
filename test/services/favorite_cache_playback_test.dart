import 'dart:typed_data';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/controlled_audio_service.dart';
import '../test_helpers/fake_secure_storage.dart';

class RecordingAudio extends ControlledAudioService {
  final urls = <String>[];
  @override
  Future<void> setPlaylist(
    List<just_audio.UriAudioSource> sources, {
    int startIndex = 0,
    Duration? initialPosition,
  }) {
    urls.add(sources[startIndex].uri.toString());
    return super.setPlaylist(
      sources,
      startIndex: startIndex,
      initialPosition: initialPosition,
    );
  }

  @override
  Future<void> setUrl(
    String url, {
    double? loudnessLufs,
    double? loudnessPeakDb,
    Duration? initialPosition,
    dynamic tag,
  }) {
    urls.add(url);
    return super.setUrl(url, initialPosition: initialPosition, tag: tag);
  }
}

class OfflineApi implements HttpClientAdapter {
  int playbackRequests = 0;
  Completer<ResponseBody>? registration;
  Completer<void>? registrationStarted;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.contains('/song/url')) playbackRequests++;
    if (registration != null && options.path.contains('/register/dev')) {
      registrationStarted?.complete();
      return registration!.future;
    }
    return ResponseBody.fromString(
      '{"status":1,"data":{}}',
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
  const cacheUri =
      'md3cache://aaaaaaaaaaaaaaaa_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  Song song(String id) => Song(
    id: id,
    title: id,
    artist: 'artist',
    album: 'album',
    duration: const Duration(minutes: 4),
    isOnline: true,
  );

  test(
    'saved account becomes available before device registration returns',
    () async {
      SharedPreferences.setMockInitialValues({});
      installFakeSecureStorage();
      final api = KugouApiClient();
      await api.clearCookies();
      await api.setLoginCookies(
        'offline-fixture-token',
        'offline-fixture-user',
      );
      KugouApiClient.markServerReady();
      final original = api.dio.httpClientAdapter;
      final offline = OfflineApi()
        ..registration = Completer<ResponseBody>()
        ..registrationStarted = Completer<void>();
      api.dio.httpClientAdapter = offline;
      final provider = KugouProvider();
      try {
        await offline.registrationStarted!.future.timeout(
          const Duration(seconds: 3),
        );
        expect(offline.registration!.isCompleted, isFalse);
        expect(provider.isLoggedIn, isTrue);
        expect(provider.userid, 'offline-fixture-user');
      } finally {
        await api.clearCookies();
        offline.registration!.complete(
          ResponseBody.fromString(
            '{"status":1,"data":{}}',
            200,
            headers: {
              'content-type': ['application/json'],
            },
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
        api.dio.httpClientAdapter = original;
        uninstallFakeSecureStorage();
      }
    },
  );

  for (final playlist in [false, true]) {
    test(
      'cached ${playlist ? 'playlist and next track' : 'single track'} bypasses login and URL resolution',
      () async {
        SharedPreferences.setMockInitialValues({});
        installFakeSecureStorage();
        final api = KugouApiClient();
        await api.clearCookies();
        final original = api.dio.httpClientAdapter;
        final offline = OfflineApi();
        api.dio.httpClientAdapter = offline;
        KugouApiClient.markServerReady();
        final audio = RecordingAudio();
        AudioServiceLoader.setTestOverride(() async => audio);
        PlayerProvider.resolveLocalAudioPath = (_, _) async => cacheUri;
        PlayerProvider.cachedAudioQuality = (_) => '128';
        var loginPrompted = false;
        final player = PlayerProvider()
          ..onLoginRequired = () => loginPrompted = true;
        try {
          await player.audioReady.timeout(const Duration(seconds: 8));
          final first = playlist
              ? player.playOnlinePlaylist([song('a'), song('b')], 0)
              : player.playOnlineSong(song('a'));
          await audio
              .waitForPlaylistLoads(1)
              .timeout(const Duration(seconds: 5));
          await audio.completeSourceLoad(0);
          await first;
          expect(audio.urls.last, cacheUri);
          expect(player.currentQualityLabel, '标准音质');
          expect(loginPrompted, isFalse);
          expect(offline.playbackRequests, 0);
          if (playlist) {
            final next = player.playSongAt(1);
            await audio
                .waitForPlaylistLoads(2)
                .timeout(const Duration(seconds: 5));
            await audio.completeSourceLoad(1);
            await next;
            expect(player.currentSong!.id, 'b');
            expect(audio.urls.last, cacheUri);
            expect(loginPrompted, isFalse);
            expect(offline.playbackRequests, 0);
          }
        } finally {
          player.dispose();
          await audio.dispose();
          AudioServiceLoader.setTestOverride(null);
          PlayerProvider.resolveLocalAudioPath = null;
          PlayerProvider.cachedAudioQuality = null;
          api.dio.httpClientAdapter = original;
          uninstallFakeSecureStorage();
        }
      },
    );
  }
}
