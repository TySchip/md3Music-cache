# MD3Music 缓存版

基于 `zzyoxml/md3Music` v6.4.1（提交 `3709b4b3286b78f5e6f176cc37d0f610b0c4c00d`）修改。

## 使用

- 这是独立安装的 Android 应用，包名 `com.md3music.md3music.offline`，显示名称“MD3Music 缓存版”，需要重新登录。
- 在“我的收藏”右上角点击离线缓存图标，或进入“设置 → 缓存与数据 → 我喜欢 · 离线缓存”。
- 默认开启 Wi-Fi 自动缓存，读取完整云端“我喜欢”，按歌单原始加入顺序从新到旧补全整首歌曲，无需播放。
- 默认上限为 5GB（5,000,000,000 字节），音频、未完成片段和保存的封面共同计入。完整歌曲不能拆分填满最后一点空间；收藏不足时保存全部可获取歌曲。
- 新喜欢歌曲优先加入，空间不足时移除足够数量的最旧本地缓存；播放次数不改变优先级。缓存淘汰不会取消喜欢。
- 完整歌曲显示“已缓存”；使用“仅显示已缓存”可在无网时连续播放。获取失败的歌曲可通过刷新重试。
- 关闭自动缓存会保留已完成歌曲。清理歌曲缓存后，下一次同步会自动补回，若希望一直保持空缓存，应先关闭自动缓存。
- 应用运行、后台播放及锁屏期间处理任务，退出任务后不再安排后台检查。Android 的省电及前台服务限制仍可能暂停任务，回到应用后会继续。

## 实现

音频使用 Android Media3 `SimpleCache`，缓存补全与正在播放的同一音源共享片段。缓存请求绑定实际 Wi-Fi Network，网络丢失时中断请求；已缓存歌曲从 `md3cache://` 本地数据源播放，不依赖临时播放 URL、设备注册完成或在线登录验证。

收藏快照使用现有完整分页与版本核对逻辑；失败时保留上次快照。目录按账号保存，音质按任务创建时的 Wi-Fi 播放设置确定，已完成歌曲不会因设置变化自动重新获取。音频保存在应用私有持久目录；普通图片、临时缓存清理与歌曲缓存管理分开。

封面与歌词尽力保存。不可获取的音源及试听片段不标为完整缓存；实际可用歌曲与音质仍由原音源接口决定。

## 构建

已使用 Flutter 3.47.5 / Dart 3.13.4、JDK 21、Android SDK 36、NDK 28.2.13676358、Gradle 9.3.1。保留 `pubspec.lock` 以固定验证过的 Flutter 依赖。

```powershell
$env:FLUTTER_WINDOWS = 'false'
flutter pub get
flutter build apk --flavor lite --release --target-platform android-arm64 --split-per-abi
```

本机仓库原有 Gradle 镜像不可用时，可使用官方 Gradle 9.3.1 执行：

```powershell
flutter build apk --config-only --flavor lite --release --target-platform android-arm64 --split-per-abi
cd android
gradle -Ptarget-platform=android-arm64 -Psplit-per-abi=true -Ptarget=lib/main.dart :app:assembleLiteRelease
```

在运行 Flutter 测试后构建 Release 时，保留上述 Release 配置生成步骤；直接使用 `--no-pub` 可能复用测试模式生成的插件注册表，导致 `IntegrationTestPlugin` 编译错误。

自行签名按原项目 `android/keystore.properties` 的配置方式提供 `storeFile`、`storePassword`、`keyAlias` 和 `keyPassword`。签名私钥和密码不包含在源码交付包内；重新编译的签名不同则不能覆盖已安装版本。

## 验证

Flutter 测试覆盖缓存顺序、字节容量、取消喜欢、增量变化、手动清理与恢复、账号隔离、分页失败保护、离线启动、单曲/歌单/下一首播放和窄屏布局。原生测试使用 Robolectric 模拟 Android 网络状态，以及 MockWebServer 提供真实 HTTP 音频字节，核对续传、并行播放共用缓存、断网读取、Wi-Fi 限制、封面空间及容量淘汰。

```powershell
flutter test test/core/services/favorite_audio_cache_test.dart test/services/favorite_cache_playback_test.dart test/modules/library/favorite_cache_page_test.dart test/services/playlist_track_order_test.dart
cd android
gradle :just_audio:testDebugUnitTest --tests com.ryanheise.just_audio.FavoriteAudioCacheTest
```

真机验收：登录后连接 Wi-Fi，等待几首显示“已缓存”；开启飞行模式并彻底关闭、重开应用，验证播放、拖动进度和连续切歌；再检查锁屏、Wi-Fi 中断恢复以及新喜欢歌曲的增量替换。桌面测试不能替代真实手机、真实账号和音频输出验证。
