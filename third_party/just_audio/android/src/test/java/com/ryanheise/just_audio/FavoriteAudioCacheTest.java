package com.ryanheise.just_audio;

import static org.junit.Assert.*;
import static org.mockito.Mockito.mock;
import static org.robolectric.Shadows.shadowOf;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.Uri;
import androidx.media3.common.C;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.cache.SimpleCache;
import okhttp3.mockwebserver.MockWebServer;
import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.RecordedRequest;
import okhttp3.mockwebserver.Dispatcher;
import okhttp3.mockwebserver.SocketPolicy;
import okio.Buffer;
import io.flutter.plugin.common.BinaryMessenger;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.HttpURLConnection;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowConnectivityManager;
import org.robolectric.shadows.ShadowNetwork;
import org.robolectric.shadows.ShadowNetworkCapabilities;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, manifest = Config.NONE)
public class FavoriteAudioCacheTest {
    private FavoriteAudioCache manager;
    private MockWebServer server;
    private String url;
    private final AtomicLong transferred = new AtomicLong();
    private byte[] payload;
    private boolean truncate;
    private boolean slow;
    private boolean loseWifi;
    private final CountDownLatch requested = new CountDownLatch(1);
    private ShadowConnectivityManager connectivity;
    private Network network;

    private NetworkCapabilities capabilities(int transport) {
        NetworkCapabilities caps = ShadowNetworkCapabilities.newInstance();
        shadowOf(caps).addTransportType(transport);
        shadowOf(caps).addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET);
        shadowOf(caps).addCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
        return caps;
    }

    private Object invoke(String name, Class<?>[] types, Object... args) throws Exception {
        Method method = FavoriteAudioCache.class.getDeclaredMethod(name, types);
        method.setAccessible(true);
        try { return method.invoke(manager, args); }
        catch (java.lang.reflect.InvocationTargetException e) { throw (Exception)e.getCause(); }
    }
    private void field(String name, Object value) throws Exception {
        Field field = FavoriteAudioCache.class.getDeclaredField(name);
        field.setAccessible(true); field.set(manager, value);
    }
    private static String key(int n) { return "aaaaaaaaaaaaaaaa_" + String.format("%064x", n); }
    private void download(String key, List<String> order) throws Exception {
        invoke("download", new Class<?>[] {String.class, String.class, String.class,
                long.class, List.class, long.class}, key, url, "fixture", (long)payload.length, order, 0L);
    }
    @SuppressWarnings("unchecked")
    private Map<String, Object> status() throws Exception {
        return (Map<String, Object>)invoke("status", new Class<?>[0]);
    }

    @Before public void setup() throws Exception {
        Context context = RuntimeEnvironment.getApplication();
        connectivity = shadowOf((ConnectivityManager)context.getSystemService(Context.CONNECTIVITY_SERVICE));
        connectivity.clearAllNetworks();
        network = ShadowNetwork.newInstance(123);
        connectivity.addNetwork(network, org.robolectric.shadows.ShadowNetworkInfo.newInstance(
                android.net.NetworkInfo.DetailedState.CONNECTED, ConnectivityManager.TYPE_WIFI, 0, true, true));
        connectivity.setNetworkCapabilities(network, capabilities(NetworkCapabilities.TRANSPORT_WIFI));
        Constructor<FavoriteAudioCache> constructor = FavoriteAudioCache.class.getDeclaredConstructor(Context.class, BinaryMessenger.class);
        constructor.setAccessible(true);
        manager = constructor.newInstance(context, mock(BinaryMessenger.class));
        Map<?, ?> existing = (Map<?, ?>)status().get("entries");
        for (Object key : existing.keySet()) invoke("remove", new Class<?>[] {String.class}, key.toString());
        field("accountPrefix", "aaaaaaaaaaaaaaaa_");
        // The transport is a real local HTTP server; only Android's socket binding is substituted.
        manager.connectionFactory = (wifi, address) -> (HttpURLConnection)address.openConnection();
        Field singleton = FavoriteAudioCache.class.getDeclaredField("instance");
        singleton.setAccessible(true); singleton.set(null, manager);
        payload = new byte[1200000];
        for (int i = 0; i < payload.length; i++) payload[i] = (byte)(i * 31);
        server = new MockWebServer();
        server.setDispatcher(new Dispatcher() {
          @Override public MockResponse dispatch(RecordedRequest request) {
            String range = request.getHeader("Range");
            MockResponse response = new MockResponse();
            int start = 0, end = payload.length - 1;
            if (range != null) {
                String[] parts = range.substring(6).split("-", -1);
                start = Integer.parseInt(parts[0]);
                if (!parts[1].isEmpty()) end = Math.min(end, Integer.parseInt(parts[1]));
                response.setHeader("Content-Range", "bytes " + start + "-" + end + "/" + payload.length);
            }
            response.setHeader("Accept-Ranges", "bytes");
            int count = end - start + 1;
            requested.countDown();
            if (loseWifi) connectivity.clearAllNetworks();
            int sent = truncate ? Math.min(count, 100000) : count;
            response.setResponseCode(range == null ? 200 : 206)
                    .setBody(new Buffer().write(payload, start, sent)).setHeader("Content-Length", count);
            if (truncate) response.setSocketPolicy(SocketPolicy.DISCONNECT_AT_END);
            if (slow) response.setBodyDelay(100, TimeUnit.MILLISECONDS);
            transferred.addAndGet(sent);
            return response;
          }
        });
        server.start(); url = server.url("/audio").toString();
    }

    @After public void teardown() throws Exception {
        server.close();
        invoke("cancel", new Class<?>[0]);
        Field executor = FavoriteAudioCache.class.getDeclaredField("worker"); executor.setAccessible(true);
        ((ExecutorService)executor.get(manager)).shutdownNow();
        Field cache = FavoriteAudioCache.class.getDeclaredField("cache"); cache.setAccessible(true);
        ((SimpleCache)cache.get(manager)).release();
        Field singleton = FavoriteAudioCache.class.getDeclaredField("instance"); singleton.setAccessible(true); singleton.set(null, null);
    }

    @Test public void fullCacheSeeksOfflineAndDoesNotRequestTheServerAgain() throws Exception {
        download(key(1), List.of(key(1)));
        assertEquals(payload.length, transferred.get());
        connectivity.clearAllNetworks(); server.close();
        DataSource source = FavoriteAudioCache.playbackFactory(null, key(1), true).createDataSource();
        int offset = 680000;
        source.open(new DataSpec.Builder().setUri(Uri.parse("md3cache://" + key(1)))
                .setPosition(offset).setLength(3000).build());
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(); byte[] buffer = new byte[1024];
        for (int read; (read = source.read(buffer, 0, buffer.length)) != C.RESULT_END_OF_INPUT; ) bytes.write(buffer, 0, read);
        source.close();
        assertArrayEquals(Arrays.copyOfRange(payload, offset, offset + 3000), bytes.toByteArray());
        assertEquals(payload.length, transferred.get());
    }

    @Test public void truncatedTransferIsNotCompleteAndResumesOnlyMissingBytes() throws Exception {
        truncate = true;
        try { download(key(1), List.of(key(1))); fail("must reject truncated response"); }
        catch (java.io.IOException expected) { }
        Map<?, ?> entry = (Map<?, ?>)((Map<?, ?>)status().get("entries")).get(key(1));
        assertFalse(Boolean.TRUE.equals(entry.get("complete")));
        truncate = false;
        download(key(1), List.of(key(1)));
        assertEquals(payload.length, transferred.get());
        entry = (Map<?, ?>)((Map<?, ?>)status().get("entries")).get(key(1));
        assertEquals(true, entry.get("complete"));
    }

    @Test public void largeNewFavoriteEvictsSeveralOldSongsWithinByteBudget() throws Exception {
        field("maxBytes", 100000L);
        payload = new byte[40000]; download(key(1), List.of(key(1)));
        payload = new byte[35000]; download(key(2), List.of(key(1), key(2)));
        payload = new byte[25000]; download(key(3), List.of(key(1), key(2), key(3)));
        payload = new byte[55000]; download(key(4), List.of(key(4), key(1), key(2), key(3)));
        Map<?, ?> entries = (Map<?, ?>)status().get("entries");
        assertTrue(entries.containsKey(key(4))); assertTrue(entries.containsKey(key(1)));
        assertFalse(entries.containsKey(key(2))); assertFalse(entries.containsKey(key(3)));
        assertEquals(95000L, status().get("usedBytes"));
    }

    @Test public void cellularTransportCannotStartACacheRequest() throws Exception {
        connectivity.setNetworkCapabilities(network, capabilities(NetworkCapabilities.TRANSPORT_CELLULAR));
        try { download(key(1), List.of(key(1))); fail("must wait for Wi-Fi"); }
        catch (java.io.IOException expected) { }
        assertEquals(0, transferred.get());
    }

    @Test public void playbackAndBackgroundFillShareTheSameNetworkBytes() throws Exception {
        slow = true;
        ExecutorService executor = Executors.newSingleThreadExecutor();
        try {
            Future<?> task = executor.submit(() -> {
                try { download(key(1), List.of(key(1))); }
                catch (Exception e) { throw new RuntimeException(e); }
            });
            assertTrue(requested.await(5, TimeUnit.SECONDS));
            DataSource source = FavoriteAudioCache.playbackFactory(null, key(1), false).createDataSource();
            source.open(new DataSpec.Builder().setUri(url).build());
            ByteArrayOutputStream bytes = new ByteArrayOutputStream(); byte[] buffer = new byte[8192];
            for (int n; (n = source.read(buffer, 0, buffer.length)) != C.RESULT_END_OF_INPUT; ) bytes.write(buffer, 0, n);
            source.close(); task.get(10, TimeUnit.SECONDS);
            assertArrayEquals(payload, bytes.toByteArray());
            assertEquals(payload.length, transferred.get());
        } finally { executor.shutdownNow(); }
    }

    @Test public void lossOfWifiInterruptsTheCurrentRead() throws Exception {
        loseWifi = true;
        try { download(key(1), List.of(key(1))); fail("must interrupt on lost Wi-Fi"); }
        catch (java.io.IOException expected) { }
        Map<?, ?> entry = (Map<?, ?>)((Map<?, ?>)status().get("entries")).get(key(1));
        assertTrue(entry == null || !Boolean.TRUE.equals(entry.get("complete")));
    }

    @Test public void coverBytesCountAgainstTheLimitAndFollowSongRemoval() throws Exception {
        download(key(1), List.of(key(1)));
        payload = new byte[30000];
        field("maxBytes", 1250000L);
        invoke("saveArtwork", new Class<?>[] {String.class, String.class, long.class}, key(1), url, 0L);
        assertEquals(1230000L, status().get("usedBytes"));
        invoke("remove", new Class<?>[] {String.class}, key(1));
        assertEquals(0L, status().get("usedBytes"));
    }

    @Test public void cachedUriCannotReadAnotherAccountsFiles() {
        assertEquals(key(1), FavoriteAudioCache.keyForUri(Uri.parse("md3cache://" + key(1))));
        assertNull(FavoriteAudioCache.keyForUri(Uri.parse("md3cache://bbbbbbbbbbbbbbbb_" + String.format("%064x", 1))));
    }
}
