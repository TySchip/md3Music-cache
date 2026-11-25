<div align="center">

<img src="assets/images/app_icon.png" width="112" alt="MD3Music 应用图标" />

# MD3Music 缓存版

<img src="https://readme-typing-svg.demolab.com?font=Fira+Code&amp;weight=600&amp;size=24&amp;pause=1400&amp;color=38BDF8&amp;center=true&amp;vCenter=true&amp;width=620&amp;lines=Your+favorites%2C+ready+offline.;Wi-Fi+auto+cache+%C2%B7+5+GB+%C2%B7+Android" alt="Your favorites, ready offline." />

<p>🎵 只缓存「我喜欢」 · 📶 Wi-Fi 自动补全 · ✈️ 无网也能听</p>

[![Android](https://img.shields.io/badge/Android-arm64--v8a-3DDC84?style=flat-square&logo=android&logoColor=white)](https://github.com/TySchip/md3Music-cache/releases/tag/v6.4.1-cache.2) [![Base](https://img.shields.io/badge/Upstream-v6.4.1-38BDF8?style=flat-square)](https://github.com/zzyoxml/md3Music/tree/3709b4b3286b78f5e6f176cc37d0f610b0c4c00d) [![Cache](https://img.shields.io/badge/Auto_Cache-5_GB-38BDF8?style=flat-square)](CACHE_BUILD.md) [![License](https://img.shields.io/badge/License-AGPL--3.0-blue?style=flat-square)](LICENSE)

**[⬇ 下载 Android APK](https://github.com/TySchip/md3Music-cache/releases/download/v6.4.1-cache.2/MD3Music-6.4.1-cache.2-arm64.apk)** · **[📦 全部附件](https://github.com/TySchip/md3Music-cache/releases/tag/v6.4.1-cache.2)** · **[🛠 使用与构建](CACHE_BUILD.md)**

</div>

## ✨ 为喜欢的歌留出离线空间

基于 [zzyoxml/md3Music](https://github.com/zzyoxml/md3Music) **v6.4.1** 的 Android 修改版，为云端「我喜欢」增加持久离线缓存。无需逐首播放或手动下载，打开应用并连接 Wi-Fi 后就会按收藏顺序补全歌曲。

这是独立维护的修改版。保留原项目 Material 3 / Apple Music 风格界面，本次发布提供 **arm64 标准版（lite）**。标准版不包含上游 full 版的 3D 封面和端侧人声分离模型。

> **当前为预发布版本。** `cache.2` 修复 VPN 分流场景下无法缓存、同名收藏歌单选择和进度条引发的列表跳动。已在 Redmi K70 Ultra / Android 14 上观察到无需播放即可缓存、已用空间持续增长和多首完整状态。长时间锁屏、写满容量及离线冷启动仍需进一步验收，详见 [验证记录](CACHE_VALIDATION.md)。

## 📦 缓存规则

| 项目 | 行为 |
| --- | --- |
| 缓存范围 | 完整云端「我喜欢」，无需先播放，按账号隔离；同账号存在「默认收藏」与「我喜欢」时优先后者 |
| 填充顺序 | 收藏加入顺序从新到旧；界面排序、播放次数和最近播放时间不影响保留顺序 |
| 容量 | 默认 **5 GB = 5,000,000,000 字节**，按实际音频、未完成片段和已保存封面计量；整首保存，允许少量余量 |
| 新增喜欢 | 新歌优先；空间不足时移除足够数量的最旧本地缓存，不取消歌曲的喜欢 |
| 取消喜欢 | 成功同步后移除对应缓存，按优先级补入下一首；同步失败保留上次完整列表 |
| 网络 | 自动缓存仅用 Wi-Fi；中断后停止，重新连接后续传；移动网络播放沿用原设置 |
| 离线播放 | 完整缓存优先从本地播放，支持拖动和连续切歌，不依赖过期在线地址 |
| 音质 | 创建任务时取 Wi-Fi 播放音质，记录实际取得的音质；已有完整缓存不因设置变化重新传输 |
| 后台 | 应用运行期间支持后台与锁屏任务及进度通知；彻底退出后暂停，下次打开继续 |
| 管理 | 自动缓存开关、容量选择、已用空间、清理入口、状态提示和「仅显示已缓存」筛选 |

缓存一首完整歌曲所需的音频数据，与下载同音质的这首歌接近；节省流量来自 Wi-Fi 获取后反复离线播放。封面和歌词尽力保存，失败不影响音频缓存。

## 🚀 安装与使用

1. 从 [Release](https://github.com/TySchip/md3Music-cache/releases/tag/v6.4.1-cache.2) 下载 `MD3Music-6.4.1-cache.2-arm64.apk`，在支持 arm64 的 Android 7.0 及以上设备安装。
2. 应用名称为 **MD3Music 缓存版**，包名为 `com.md3music.md3music.offline`，可与原版并存。首次使用需要重新登录。
3. 连接 Wi-Fi，进入「我的收藏」右上角缓存图标，或「设置 → 缓存与数据 → 我喜欢 · 离线缓存」。默认开启自动缓存，默认容量 5 GB。
4. 等待歌曲标为「已缓存」。断网时打开「仅显示已缓存」即可浏览和连续播放。

关闭自动缓存会停止补全并保留已完成歌曲。手动清理后，下次自动整理会补回；想保持空缓存，应先关闭自动缓存。

Android 的省电策略及前台服务限制可能暂停后台任务；回到应用后会继续。收藏不足容量时会保存全部可取得歌曲，无法获取的歌曲会显示失败并继续处理后续歌曲。

## 🧰 源码与验证

- [使用、实现与构建说明](CACHE_BUILD.md)
- [测试范围、构建与签名记录](CACHE_VALIDATION.md)
- [缓存控制器](lib/core/services/favorite_audio_cache.dart) / [Android Media3 共享缓存](third_party/just_audio/android/src/main/java/com/ryanheise/just_audio/FavoriteAudioCache.java)
- Release 同时提供完整源码 ZIP、相对于上游 v6.4.1 的补丁、验证日志及 SHA-256 校验清单。

音频保存在应用私有持久目录。卸载应用或清除应用数据会删除缓存。交付 APK 自行签名，签名私钥和密码不进入仓库或 Release；自行重新签名的包不能直接覆盖已安装的不同签名版本。

## 🙏 来源与致谢

播放器、界面、酷狗 API 接入及原有能力来自 **[zzyoxml/md3Music](https://github.com/zzyoxml/md3Music)**。本次基线为提交 [`3709b4b`](https://github.com/zzyoxml/md3Music/commit/3709b4b3286b78f5e6f176cc37d0f610b0c4c00d)，修改集中在 Android「我喜欢」缓存、离线播放接入及对应测试。

保留 [上游 README](README.upstream.md)、[贡献指南](CONTRIBUTING.md)、[免责声明](DISCLAIMER.md) 和原有版权声明，沿用 [GNU AGPL v3](LICENSE)。本仓库不附带歌曲音频，音源可用性与音质由原接口和账号权限决定。

<div align="center">
<sub>由 TySchip 维护缓存修改 · 感谢原项目与依赖作者</sub>
</div>
