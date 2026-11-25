import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/services/favorite_audio_cache.dart';
import '../../providers/player_provider.dart';
import '../../widgets/song_list_item.dart';

class FavoriteCachePage extends StatelessWidget {
  const FavoriteCachePage({super.key});

  static String storageLabel(int bytes) =>
      '${(bytes / 1000000000).toStringAsFixed(2)} GB';

  @override
  Widget build(BuildContext context) {
    final cache = context.watch<FavoriteAudioCache>();
    final songs = cache.onlyCached
        ? cache.displaySongs.where((s) => cache.isComplete(s.id)).toList()
        : cache.displaySongs;
    return Scaffold(
      appBar: AppBar(
        title: const Text('我喜欢 · 离线缓存'),
        actions: [
          IconButton(
            tooltip: '同步并重试',
            icon: const Icon(Icons.refresh),
            onPressed: cache.requestSync,
          ),
        ],
      ),
      body: Column(
        children: [
          SwitchListTile(
            title: const Text('Wi-Fi 自动缓存我喜欢'),
            subtitle: const Text('最新收藏优先，空间满后移除最旧的本地缓存'),
            value: cache.enabled,
            onChanged: cache.setEnabled,
          ),
          ListTile(
            title: Text(
              '已用 ${storageLabel(cache.usedBytes)} / ${storageLabel(cache.maxBytes)}',
            ),
            subtitle: Text(
              cache.account == null
                  ? '请先登录酷狗账号'
                  : !cache.enabled
                  ? '已暂停，已缓存歌曲仍可播放'
                  : !cache.wifi
                  ? '等待 Wi-Fi，已缓存歌曲可离线播放'
                  : cache.running
                  ? '正在整理缓存'
                  : '缓存已就绪',
            ),
            trailing: DropdownButton<int>(
              value: cache.maxBytes,
              items: [2, 5, 10]
                  .map(
                    (gb) => DropdownMenuItem(
                      value: gb * 1000000000,
                      child: Text('$gb GB'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) cache.setLimit(value);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('仅显示已缓存'),
                  selected: cache.onlyCached,
                  onSelected: (_) => cache.toggleOnlyCached(),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('清理歌曲缓存？'),
                        content: const Text('不会取消喜欢。自动缓存开启时，下次同步会重新补回。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('清理'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) await cache.clear();
                  },
                  child: const Text('清理歌曲缓存'),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 4,
            child: cache.activeKey == null
                ? null
                : LinearProgressIndicator(value: cache.progress.clamp(0, 1)),
          ),
          if (cache.error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(cache.error!),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                cache.requestSync();
                await cache.sync();
              },
              child: songs.isEmpty
                  ? ListView(
                      children: const [
                        Padding(
                          padding: EdgeInsets.all(32),
                          child: Text('暂无可显示的歌曲。连接 Wi-Fi 后同步“我喜欢”。'),
                        ),
                      ],
                    )
                  : ListView.builder(
                      itemCount: songs.length,
                      itemBuilder: (context, index) {
                        final song = songs[index];
                        return SongListItem(
                          song: song,
                          subtitleOverride: Text(
                            '${song.artist} · ${cache.label(song.id)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => context
                              .read<PlayerProvider>()
                              .playOnlinePlaylist(songs, index),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
