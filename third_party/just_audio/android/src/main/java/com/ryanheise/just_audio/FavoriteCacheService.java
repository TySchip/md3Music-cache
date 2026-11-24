package com.ryanheise.just_audio;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;

/** Visible, non-sticky service: it never schedules work after the app exits. */
public final class FavoriteCacheService extends Service {
    private static final String CHANNEL = "favorite_audio_cache";
    private static final int ID = 5041;
    private static FavoriteCacheService service;
    private static long lastUpdate;
    @Override public void onCreate() {
        super.onCreate(); service = this;
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager.class).createNotificationChannel(
                    new NotificationChannel(CHANNEL, "喜欢歌曲缓存", NotificationManager.IMPORTANCE_LOW));
        }
    }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        show(intent == null ? "我喜欢" : intent.getStringExtra("title"), 0, 0);
        return START_NOT_STICKY;
    }
    static synchronized void update(String title, long bytes, long total) {
        long now = android.os.SystemClock.elapsedRealtime();
        if (service != null && now - lastUpdate > 500) {
            lastUpdate = now; service.show(title, bytes, total);
        }
    }
    static synchronized void waitForWifi() {
        if (service != null) service.show("等待 Wi-Fi，连接后继续缓存", 0, 0);
    }
    private void show(String title, long bytes, long total) {
        Notification.Builder builder = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (launch != null) builder.setContentIntent(PendingIntent.getActivity(this, 0, launch,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
        startForeground(ID, builder.setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("正在缓存我喜欢的歌曲").setContentText(title)
                .setOngoing(true).setOnlyAlertOnce(true)
                .setProgress(100, total > 0 ? (int)(bytes * 100 / total) : 0, total <= 0).build());
    }
    @Override public void onTaskRemoved(Intent rootIntent) { stopSelf(); }
    @Override public void onDestroy() {
        service = null; FavoriteAudioCache.stopCaching(); super.onDestroy();
    }
    @Override public void onTimeout(int startId, int fgsType) {
        FavoriteAudioCache.stopCaching(); stopSelf();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}
