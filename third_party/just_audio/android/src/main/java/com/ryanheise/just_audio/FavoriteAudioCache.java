package com.ryanheise.just_audio;

import android.content.Context;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import androidx.media3.common.C;
import androidx.media3.database.StandaloneDatabaseProvider;
import androidx.media3.datasource.BaseDataSource;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.cache.CacheDataSource;
import androidx.media3.datasource.cache.CacheWriter;
import androidx.media3.datasource.cache.ContentMetadata;
import androidx.media3.datasource.cache.ContentMetadataMutations;
import androidx.media3.datasource.cache.NoOpCacheEvictor;
import androidx.media3.datasource.cache.SimpleCache;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.ByteArrayOutputStream;
import java.io.FileOutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** One process-wide cache shared by both ExoPlayers and the favorites worker. */
public final class FavoriteAudioCache {
    private static FavoriteAudioCache instance;
    private final Context context;
    private final SimpleCache cache;
    private final File artworkDir;
    private long artworkBytes;
    private final Set<HttpURLConnection> artworkConnections = ConcurrentHashMap.newKeySet();
    private final ConnectivityManager connectivity;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Map<String, String> urls = new ConcurrentHashMap<>();
    private final Set<WifiSource> connections = ConcurrentHashMap.newKeySet();
    private final Map<String, Integer> pins = new HashMap<>();
    private final Set<String> deferredRemoval = new HashSet<>();
    private volatile CacheWriter writer;
    private volatile String activeKey;
    private volatile long maxBytes = 5L * 1000 * 1000 * 1000;
    private volatile long downloadLimit;
    private volatile long generation;
    private volatile boolean enabled = true;
    private volatile String accountPrefix = "";
    private volatile long progress;
    private volatile long total;
    private volatile boolean rangeSupported = true;
    private MethodChannel channel;
    private final MethodChannel.MethodCallHandler methodHandler;
    interface ConnectionFactory { HttpURLConnection open(Network network, URL url) throws IOException; }
    ConnectionFactory connectionFactory = (network, url) -> (HttpURLConnection)network.openConnection(url);

    private FavoriteAudioCache(Context context, BinaryMessenger messenger) {
        this.context = context.getApplicationContext();
        cache = new SimpleCache(new File(context.getFilesDir(), "favorite_audio"),
                new NoOpCacheEvictor(), new StandaloneDatabaseProvider(context));
        artworkDir = new File(context.getFilesDir(), "favorite_artwork");
        artworkDir.mkdirs();
        File[] artworkFiles = artworkDir.listFiles();
        if (artworkFiles != null) for (File file : artworkFiles) artworkBytes += file.length();
        connectivity = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        channel = new MethodChannel(messenger, "com.md3music/favorite_cache");
        methodHandler = (call, result) -> {
            try {
                switch (call.method) {
                case "activate": {
                    accountPrefix = call.argument("prefix");
                    urls.clear();
                    result.success(null); break;
                }
                case "status": result.success(status()); break;
                case "configure": {
                    enabled = Boolean.TRUE.equals(call.argument("enabled"));
                    maxBytes = ((Number)call.argument("maxBytes")).longValue();
                    if (!enabled) cancel();
                    String prefix = call.argument("prefix");
                    List<String> keep = call.argument("keys");
                    worker.execute(() -> {
                        try {
                            for (String key : new HashSet<>(cache.getKeys())) {
                                if (key.startsWith(prefix) && !keep.contains(key)) remove(key);
                            }
                            for (String key : new HashSet<>(cache.getKeys())) {
                                if (space() <= maxBytes) break;
                                if (!key.startsWith(prefix)) remove(key);
                            }
                            for (int i = keep.size() - 1; i >= 0 && space() > maxBytes; i--) remove(keep.get(i));
                            main.post(() -> result.success(status()));
                        } catch (Exception e) { fail(result, e); }
                    });
                    break;
                }
                case "register": {
                    String url = call.argument("url");
                    String key = call.argument("key");
                    if (!validKey(key)) throw new IOException("Invalid cache key");
                    urls.put(url, key);
                    result.success(null);
                    break;
                }
                case "artwork": {
                    String key = call.argument("key");
                    String url = call.argument("url");
                    long request = generation;
                    worker.execute(() -> {
                        try { saveArtwork(key, url, request); main.post(() -> result.success(null)); }
                        catch (Exception e) { fail(result, e); }
                    });
                    break;
                }
                case "download": {
                    String key = call.argument("key");
                    String url = call.argument("url");
                    String title = call.argument("title");
                    long length = ((Number)call.argument("bytes")).longValue();
                    List<String> order = call.argument("order");
                    long request = generation;
                    worker.execute(() -> {
                        try {
                            Map<String, Object> response = download(key, url, title, length, order, request);
                            main.post(() -> result.success(response));
                        } catch (Exception e) { fail(result, e); }
                    });
                    break;
                }
                case "cancel": cancel(); result.success(null); break;
                case "pause": pause(); result.success(null); break;
                case "clear": {
                    cancel();
                    worker.execute(() -> {
                        try {
                            for (String key : new HashSet<>(cache.getKeys())) remove(key);
                            main.post(() -> result.success(status()));
                        } catch (Exception e) { fail(result, e); }
                    });
                    break;
                }
                default: result.notImplemented();
                }
            } catch (Exception e) { result.error("favorite_cache", e.getMessage(), null); }
        };
        channel.setMethodCallHandler(methodHandler);
        connectivity.registerNetworkCallback(new NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(),
                new ConnectivityManager.NetworkCallback() {
                    @Override public void onLost(Network network) {
                        // Close sockets on the lost network; never migrate them to cellular.
                        for (WifiSource source : connections) {
                            if (network.equals(source.network)) source.disconnect();
                        }
                        for (HttpURLConnection connection : artworkConnections) connection.disconnect();
                    }
                });
    }

    static synchronized void attach(Context context, BinaryMessenger messenger) {
        if (instance == null) instance = new FavoriteAudioCache(context, messenger);
        else {
            instance.channel.setMethodCallHandler(null);
            instance.channel = new MethodChannel(messenger, "com.md3music/favorite_cache");
            instance.channel.setMethodCallHandler(instance.methodHandler);
        }
    }

    static void detach() {
        if (instance != null) {
            instance.cancel();
            instance.channel.setMethodCallHandler(null);
        }
    }

    public static void stopCaching() { if (instance != null) instance.cancel(); }

    static boolean validKey(String key) { return key != null && key.matches("[a-f0-9]{16}_[a-f0-9]{64}"); }

    static String keyForUri(Uri uri) {
        if (instance == null) return null;
        if ("md3cache".equals(uri.getScheme())) {
            String key = uri.getHost();
            return validKey(key) && key.startsWith(instance.accountPrefix) &&
                    !instance.accountPrefix.isEmpty() ? key : null;
        }
        String key = instance.urls.get(uri.toString());
        return key != null && key.startsWith(instance.accountPrefix) ? key : null;
    }

    static DataSource.Factory playbackFactory(DataSource.Factory upstream, String key, boolean localOnly) {
        FavoriteAudioCache owner = instance;
        if (owner == null || key == null) return upstream;
        return () -> {
            CacheDataSource.Factory factory = new CacheDataSource.Factory().setCache(owner.cache)
                    .setFlags(CacheDataSource.FLAG_BLOCK_ON_CACHE | CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR);
            if (!localOnly && key.equals(owner.activeKey) && owner.enabled && owner.wifi() != null) {
                long request = owner.generation;
                factory.setUpstreamDataSourceFactory(() -> owner.new WifiSource(request));
            } else {
                factory.setCacheWriteDataSinkFactory(null)
                        .setUpstreamDataSourceFactory(localOnly ? null : upstream);
            }
            return owner.new PinnedSource(factory.createDataSource(), key);
        };
    }

    private void fail(MethodChannel.Result result, Exception error) {
        main.post(() -> result.error("favorite_cache", error.getMessage(), null));
    }

    private Network wifi() {
        for (Network network : connectivity.getAllNetworks()) {
            NetworkCapabilities caps = connectivity.getNetworkCapabilities(network);
            if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                    && !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                    && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return network;
        }
        return null;
    }

    private synchronized void remove(String key) throws IOException {
        if (pins.getOrDefault(key, 0) > 0) { deferredRemoval.add(key); return; }
        cache.removeResource(key);
        File artwork = new File(artworkDir, key);
        long length = artwork.length();
        if (artwork.delete()) artworkBytes -= length;
        deferredRemoval.remove(key);
    }

    private synchronized long space() { return cache.getCacheSpace() + artworkBytes; }

    private void saveArtwork(String key, String address, long request) throws Exception {
        if (!validKey(key) || !key.startsWith(accountPrefix)) throw new IOException("Invalid artwork key");
        File target = new File(artworkDir, key);
        if (target.exists()) return;
        Network network = wifi();
        if (network == null || !enabled || request != generation) return;
        long allowance = Math.min(256 * 1024, maxBytes - space());
        if (allowance <= 0) return;
        URL url = new URL(address);
        for (int redirect = 0; redirect < 6; redirect++) {
            if (!url.getProtocol().equals("http") && !url.getProtocol().equals("https")) return;
            HttpURLConnection connection = connectionFactory.open(network, url);
            artworkConnections.add(connection);
            try {
                connection.setConnectTimeout(8000); connection.setReadTimeout(8000);
                connection.setInstanceFollowRedirects(false);
                int code = connection.getResponseCode();
                if (code >= 300 && code <= 308 && code != 304) {
                    String location = connection.getHeaderField("Location");
                    if (location == null) return;
                    url = new URL(url, location); continue;
                }
                if (code != 200 || connection.getContentLengthLong() > allowance) return;
                ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                try (InputStream input = connection.getInputStream()) {
                    byte[] buffer = new byte[8192];
                    for (int n; (n = input.read(buffer)) >= 0; ) {
                        if (request != generation || bytes.size() + n > allowance) return;
                        bytes.write(buffer, 0, n);
                    }
                }
                if (bytes.size() == 0 || request != generation) return;
                try (FileOutputStream output = new FileOutputStream(target)) { bytes.writeTo(output); }
                catch (IOException e) { target.delete(); throw e; }
                synchronized (this) { artworkBytes += target.length(); }
                return;
            } finally { artworkConnections.remove(connection); connection.disconnect(); }
        }
    }

    private synchronized boolean reserve(String key, long length, List<String> order) throws IOException {
        long ownBytes = bytes(key);
        List<String> candidates = new ArrayList<>(cache.getKeys());
        candidates.sort(Comparator.comparingInt((String k) -> order.indexOf(k)).reversed());
        // Other accounts are isolated and are lower priority than this account's favorites.
        candidates.sort((a, b) -> Boolean.compare(order.contains(a), order.contains(b)));
        int rank = order.indexOf(key);
        for (String other : candidates) {
            if (space() - ownBytes + length <= maxBytes) break;
            if (other.equals(key) || (order.contains(other) && order.indexOf(other) < rank)) continue;
            remove(other);
        }
        downloadLimit = maxBytes - (space() - ownBytes);
        return length <= downloadLimit;
    }

    private Map<String, Object> download(String key, String url, String title, long length,
            List<String> order, long request) throws Exception {
        if (!validKey(key) || !order.contains(key)) throw new IOException("Invalid cache task");
        if (!enabled || request != generation || wifi() == null) throw new IOException("等待 Wi-Fi");
        if (length <= 0) throw new IOException("无法确认完整音频大小");
        if (!reserve(key, length, order)) return Collections.singletonMap("limit", true);
        urls.put(url, key);
        activeKey = key;
        progress = bytes(key);
        total = length;
        rangeSupported = true;
        Intent service = new Intent(context, FavoriteCacheService.class).putExtra("title", title);
        try {
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(service);
            else context.startService(service);
        } catch (RuntimeException e) {
            activeKey = null;
            throw new IOException("请打开应用以继续缓存", e);
        }
        try {
            CacheDataSource source = new CacheDataSource.Factory().setCache(cache)
                    .setFlags(CacheDataSource.FLAG_BLOCK_ON_CACHE)
                    .setUpstreamDataSourceFactory(() -> new WifiSource(request)).createDataSource();
            ContentMetadataMutations metadata = new ContentMetadataMutations();
            ContentMetadataMutations.setContentLength(metadata, length);
            cache.applyContentMetadataMutations(key, metadata);
            // Release the cache hole between chunks so playback can start immediately.
            for (long offset = 0; offset < length; ) {
                if (request != generation) throw new IOException("缓存已暂停");
                long chunk = rangeSupported ? Math.min(512 * 1024, length - offset) : length - offset;
                writer = new CacheWriter(source, new DataSpec.Builder().setUri(url).setKey(key)
                        .setPosition(offset).setLength(chunk).build(), new byte[64 * 1024],
                        (contentLength, cached, added) -> {
                            progress = bytes(key);
                            FavoriteCacheService.update(title, progress, length);
                        });
                writer.cache();
                offset += chunk;
            }
            long actual = ContentMetadata.getContentLength(cache.getContentMetadata(key));
            if (actual <= 0 || !cache.isCached(key, 0, actual) || actual != length) {
                throw new IOException("音频未完整保存或大小已变化");
            }
            return Collections.singletonMap("bytes", actual);
        } finally { writer = null; activeKey = null; }
    }

    private long bytes(String key) {
        long bytes = 0;
        for (androidx.media3.datasource.cache.CacheSpan span : cache.getCachedSpans(key)) bytes += span.length;
        return bytes;
    }

    private Map<String, Object> status() {
        Map<String, Object> state = new HashMap<>();
        Map<String, Object> entries = new HashMap<>();
        for (String key : cache.getKeys()) {
            long length = ContentMetadata.getContentLength(cache.getContentMetadata(key));
            Map<String, Object> entry = new HashMap<>();
            entry.put("bytes", bytes(key));
            entry.put("complete", length > 0 && cache.isCached(key, 0, length));
            File artwork = new File(artworkDir, key);
            if (artwork.exists()) entry.put("artwork", Uri.fromFile(artwork).toString());
            entries.put(key, entry);
        }
        state.put("entries", entries);
        state.put("usedBytes", space());
        state.put("wifi", wifi() != null);
        state.put("activeKey", activeKey);
        state.put("progress", progress);
        state.put("total", total);
        return state;
    }

    private void cancel() {
        pause();
        context.stopService(new Intent(context, FavoriteCacheService.class));
    }

    private void pause() {
        generation++;
        CacheWriter current = writer;
        if (current != null) current.cancel();
        for (WifiSource source : connections) source.disconnect();
        for (HttpURLConnection connection : artworkConnections) connection.disconnect();
        FavoriteCacheService.waitForWifi();
    }

    private final class PinnedSource implements DataSource {
        private final DataSource source;
        private final String key;
        private boolean opened;
        PinnedSource(DataSource source, String key) { this.source = source; this.key = key; }
        @Override public long open(DataSpec spec) throws IOException {
            synchronized (FavoriteAudioCache.this) {
                pins.put(key, pins.getOrDefault(key, 0) + 1); opened = true;
            }
            try { return source.open(spec.buildUpon().setKey(key).build()); }
            catch (IOException e) { close(); throw e; }
        }
        @Override public int read(byte[] buffer, int offset, int length) throws IOException {
            return source.read(buffer, offset, length);
        }
        @Override public Uri getUri() { return source.getUri(); }
        @Override public Map<String, List<String>> getResponseHeaders() { return source.getResponseHeaders(); }
        @Override public void addTransferListener(androidx.media3.datasource.TransferListener listener) {
            source.addTransferListener(listener);
        }
        @Override public void close() throws IOException {
            try { source.close(); } finally {
                synchronized (FavoriteAudioCache.this) {
                    if (opened) {
                        opened = false;
                        pins.put(key, pins.getOrDefault(key, 1) - 1);
                        if (deferredRemoval.contains(key)) remove(key);
                        if (pins.getOrDefault(key, 0) == 0) {
                            main.post(() -> channel.invokeMethod("playbackReleased", null));
                        }
                    }
                }
            }
        }
    }

    /** A request is bound to an actual Wi-Fi Network, including DNS and redirects. */
    private final class WifiSource extends BaseDataSource {
        private final long request;
        private Network network;
        private HttpURLConnection connection;
        private InputStream input;
        private Uri uri;
        private long remaining;
        private boolean opened;
        WifiSource(long request) { super(true); this.request = request; }
        private void check() throws IOException {
            if (!enabled || request != generation || network == null) throw new IOException("等待 Wi-Fi");
            NetworkCapabilities caps = connectivity.getNetworkCapabilities(network);
            if (caps == null || !caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) throw new IOException("等待 Wi-Fi");
        }
        @Override public long open(DataSpec spec) throws IOException {
            transferInitializing(spec);
            network = wifi(); check(); connections.add(this);
            URL url = new URL(spec.uri.toString());
            for (int redirects = 0; redirects <= 8; redirects++) {
                check();
                if (!url.getProtocol().equals("http") && !url.getProtocol().equals("https")) throw new IOException("不支持的音频协议");
                connection = connectionFactory.open(network, url);
                connection.setConnectTimeout(15000); connection.setReadTimeout(15000);
                connection.setInstanceFollowRedirects(false);
                connection.setRequestProperty("Accept-Encoding", "identity");
                connection.setRequestProperty("User-Agent", androidx.media3.common.util.Util.getUserAgent(context, "just_audio"));
                if (spec.position > 0 || spec.length != C.LENGTH_UNSET) {
                    String range = "bytes=" + spec.position + "-";
                    if (spec.length != C.LENGTH_UNSET) range += spec.position + spec.length - 1;
                    connection.setRequestProperty("Range", range);
                }
                int code = connection.getResponseCode();
                if (code >= 300 && code <= 308 && code != 304) {
                    String location = connection.getHeaderField("Location"); connection.disconnect();
                    if (location == null) throw new IOException("无效的音频重定向");
                    url = new URL(url, location); continue;
                }
                if (code != 200 && code != 206) throw new IOException("音频请求失败 HTTP " + code);
                if (code == 200) rangeSupported = false;
                long size = connection.getContentLengthLong();
                String contentRange = connection.getHeaderField("Content-Range");
                long fullSize = size;
                if (code == 206) {
                    if (contentRange == null || !contentRange.startsWith("bytes " + spec.position + "-")) throw new IOException("音频续传范围不一致");
                    try { fullSize = Long.parseLong(contentRange.substring(contentRange.lastIndexOf('/') + 1)); }
                    catch (NumberFormatException e) { throw new IOException("无法确认音频总大小", e); }
                }
                if (fullSize <= 0 || fullSize > downloadLimit || fullSize != total) throw new IOException("音频大小已变化或超出缓存空间");
                input = connection.getInputStream();
                if (code == 200 && spec.position > 0) {
                    long skip = spec.position;
                    while (skip > 0) { check(); long n = input.skip(skip); if (n <= 0) throw new IOException("音频被截断"); skip -= n; }
                    size -= spec.position;
                }
                remaining = spec.length == C.LENGTH_UNSET ? size : Math.min(size, spec.length);
                uri = Uri.parse(url.toString()); opened = true; transferStarted(spec); return remaining;
            }
            throw new IOException("音频重定向过多");
        }
        @Override public int read(byte[] buffer, int offset, int length) throws IOException {
            check();
            if (remaining == 0) return C.RESULT_END_OF_INPUT;
            int read = input.read(buffer, offset, (int)Math.min(length, remaining));
            if (read < 0) throw new IOException("音频传输中断");
            remaining -= read; bytesTransferred(read); return read;
        }
        @Override public Uri getUri() { return uri; }
        @Override public Map<String, List<String>> getResponseHeaders() {
            return connection == null ? Collections.emptyMap() : connection.getHeaderFields();
        }
        void disconnect() { if (connection != null) connection.disconnect(); }
        @Override public void close() throws IOException {
            connections.remove(this);
            try { if (input != null) input.close(); } finally {
                disconnect(); input = null;
                if (opened) { opened = false; transferEnded(); }
            }
        }
    }
}
