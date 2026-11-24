import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:md3music/core/services/favorite_audio_cache.dart';
import 'package:md3music/modules/library/favorite_cache_page.dart';

class IdleBackend extends Fake implements FavoriteCacheBackend {
  @override
  Future<void> cancel() async {}
}

class IdleStore extends Fake implements FavoriteCacheStore {}

void main() {
  for (final width in [320.0, 412.0]) {
    testWidgets('cache controls fit ${width.toInt()}px Android screen', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final cache = FavoriteAudioCache(
        backend: IdleBackend(),
        store: IdleStore(),
        fetchSongs: () async => [],
        resolveSong: (_, _) async => null,
        wifiQuality: () async => '128',
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: cache,
          child: const MaterialApp(home: FavoriteCachePage()),
        ),
      );
      expect(find.text('Wi-Fi 自动缓存我喜欢'), findsOneWidget);
      expect(find.text('仅显示已缓存'), findsOneWidget);
      expect(find.text('5 GB'), findsOneWidget);
      await tester.tap(find.text('仅显示已缓存'));
      await tester.pump();
      expect(cache.onlyCached, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      cache.dispose();
    });
  }
}
