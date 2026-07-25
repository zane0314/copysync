package xyz.copyweb;

import android.app.Activity;
import android.app.AlertDialog;
import android.annotation.SuppressLint;
import android.app.DownloadManager;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.BroadcastReceiver;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.res.ColorStateList;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.provider.Settings;
import android.provider.DocumentsContract;
import android.provider.MediaStore;
import android.provider.OpenableColumns;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.util.Log;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.webkit.JavascriptInterface;
import android.webkit.MimeTypeMap;
import android.widget.Toast;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ProgressBar;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.RadioGroup;
import android.widget.TextView;
import android.widget.Spinner;
import android.widget.ArrayAdapter;
import android.webkit.CookieManager;
import android.webkit.ValueCallback;
import android.webkit.WebView;
import android.webkit.WebSettings;
import android.webkit.WebChromeClient;
import android.webkit.WebViewClient;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.OutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import org.json.JSONObject;

public final class MainActivity extends Activity {
    private static final int PICK_FILES = 1;
    private static final int ALLOW_UPDATES = 2;
    private static final String UPDATE_MANIFEST = "https://copy-direct.example.com/api/update/android";
    private static final String BASE = "https://copy-direct.example.com/";
    private static final String SITE = BASE + "?app=android";
    private static final String NOTIFICATION_CHANNEL = "copysync_delivery";
    private static final String PREFS = "copysync";
    private static final String SYNC_MODE = "sync_mode";
    private static final String RECEIVE_DIRECTORY = "CopySync";
    private static final String RECEIVED_FILE_PREFIX = "received_file_";
    private static final String PENDING_DOWNLOAD_PREFIX = "pending_download_";
    private static final String LOG_TAG = "CopySync";
    private static final String[] FILE_MANAGER_PACKAGES = {
            "com.sec.android.app.myfiles",
            "com.google.android.apps.nbu.files",
            "com.google.android.documentsui"
    };
    private WebView webView;
    private Intent pendingShare;
    private boolean sharePromptShown;
    private ValueCallback<Uri[]> fileChooser;
    private long updateDownloadId = -1;
    private final ConcurrentHashMap<Long, DownloadRecord> regularDownloads = new ConcurrentHashMap<>();
    private String expectedUpdateSha;
    private Uri pendingUpdate;
    private float pullStartY;
    private boolean pullStartedAtTop;
    private View pullIndicator;
    private boolean pullRefreshing;
    private static final class DownloadRecord {
        final String deliveryId;
        final String name;
        final String mime;
        DownloadRecord(String deliveryId, String name, String mime) {
            this.deliveryId = deliveryId == null ? "" : deliveryId;
            this.name = name;
            this.mime = mime == null || mime.isEmpty() ? "application/octet-stream" : mime;
        }
    }
    private final BroadcastReceiver downloadReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            long id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1);
            try {
                if (id == updateDownloadId) finishUpdateDownload();
                else {
                    DownloadRecord record = regularDownloads.remove(id);
                    if (record == null) record = loadPendingDownload(id);
                    if (record != null) finishRegularDownload(id, record);
                }
            } catch (RuntimeException error) {
                Log.e(LOG_TAG, "download completion failed", error);
                DownloadRecord record = loadPendingDownload(id);
                clearPendingDownload(id);
                if (record != null) notifyWebLocalFileFailed(record.deliveryId, record.name);
            }
        }
    };

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        createNotificationChannel();
        ensureReceiveFolder();
        webView = new WebView(this);
        webView.setWebViewClient(new WebViewClient() {
            @Override public void onPageFinished(WebView view, String url) {
                CookieManager.getInstance().flush();
                installDeliveryListener();
                if (pendingShare != null && !sharePromptShown) showShareReview();
            }
        });
        webView.setWebChromeClient(new WebChromeClient() {
            @Override public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (fileChooser != null) fileChooser.onReceiveValue(null);
                fileChooser = callback;
                boolean imagesOnly = false;
                for (String accept : params.getAcceptTypes()) if (accept != null && accept.startsWith("image/")) imagesOnly = true;
                Intent pick;
                if (imagesOnly) {
                    pick = new Intent(Intent.ACTION_PICK).setDataAndType(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "image/*");
                } else {
                    pick = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");
                }
                pick.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
                startActivityForResult(pick, PICK_FILES);
                return true;
            }
        });
        webView.getSettings().setJavaScriptEnabled(true);
        webView.getSettings().setDomStorageEnabled(true);
        webView.getSettings().setCacheMode(WebSettings.LOAD_NO_CACHE);
        webView.getSettings().setAllowFileAccess(false);
        webView.setOnTouchListener((view, event) -> {
            if (event.getAction() == MotionEvent.ACTION_DOWN) {
                pullStartY = event.getY();
                pullStartedAtTop = !webView.canScrollVertically(-1) && !pullRefreshing;
            } else if (event.getAction() == MotionEvent.ACTION_MOVE) {
                if (pullStartedAtTop && !pullRefreshing && !webView.canScrollVertically(-1)) {
                    float dy = event.getY() - pullStartY;
                    if (dy > 0) showPullIndicator(dy);
                }
            } else if (event.getAction() == MotionEvent.ACTION_UP) {
                view.performClick();
                float dy = event.getY() - pullStartY;
                if (pullStartedAtTop && !pullRefreshing && !webView.canScrollVertically(-1) && dy > dp(96)) {
                    startPullRefresh();
                } else {
                    hidePullIndicator();
                }
                pullStartedAtTop = false;
            } else if (event.getAction() == MotionEvent.ACTION_CANCEL) {
                pullStartedAtTop = false;
                if (!pullRefreshing) hidePullIndicator();
            }
            return false;
        });
        CookieManager.getInstance().setAcceptCookie(true);
        webView.addJavascriptInterface(new NativeBridge(), "CopySyncNative");
        webView.setDownloadListener((url, userAgent, contentDisposition, mimeType, contentLength) -> downloadFromWeb(url, userAgent, contentDisposition, mimeType));
        setContentView(buildAppLayout());
        pendingShare = isShareIntent(getIntent()) ? getIntent() : null;
        webView.loadUrl(SITE);
        IntentFilter downloads = new IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE);
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(downloadReceiver, downloads, Context.RECEIVER_NOT_EXPORTED);
        else registerReceiver(downloadReceiver, downloads);
        reconcilePendingDownloads();
        checkForUpdate();
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (isShareIntent(intent)) {
            pendingShare = intent;
            sharePromptShown = false;
            showShareReview();
        }
    }

    @Override protected void onPause() {
        CookieManager.getInstance().flush();
        super.onPause();
    }

    @Override public void onBackPressed() {
        if (webView.canGoBack()) webView.goBack(); else super.onBackPressed();
    }

    private View buildAppLayout() {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.rgb(250, 249, 247));
        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        column.addView(webView, new LinearLayout.LayoutParams(-1, 0, 1));
        LinearLayout nav = new LinearLayout(this);
        nav.setGravity(Gravity.CENTER);
        nav.setPadding(dp(6), dp(5), dp(6), dp(7));
        nav.setBackgroundColor(Color.WHITE);
        nav.setElevation(dp(8));
        nav.addView(navButton("收件箱", R.drawable.ic_nav_inbox, "window.showAndroidSection?.('inbox')"));
        nav.addView(navButton("发送", R.drawable.ic_nav_send, "window.showAndroidSection?.('home')"));
        nav.addView(navButton("网盘", R.drawable.ic_nav_drive, "window.showAndroidSection?.('drive')"));
        Button settings = navButton("设置", R.drawable.ic_nav_settings, null);
        settings.setOnClickListener(v -> showSettings());
        nav.addView(settings);
        column.addView(nav, new LinearLayout.LayoutParams(-1, dp(70)));
        root.addView(column, new FrameLayout.LayoutParams(-1, -1));
        pullIndicator = buildPullIndicator();
        FrameLayout.LayoutParams indicatorParams = new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        root.addView(pullIndicator, indicatorParams);
        return root;
    }

    private View buildPullIndicator() {
        LinearLayout pill = new LinearLayout(this);
        pill.setGravity(Gravity.CENTER);
        pill.setPadding(dp(10), dp(8), dp(10), dp(8));
        GradientDrawable background = new GradientDrawable();
        background.setColor(Color.WHITE);
        background.setCornerRadius(dp(22));
        pill.setBackground(background);
        pill.setElevation(dp(6));
        ProgressBar spinner = new ProgressBar(this);
        spinner.setIndeterminateTintList(ColorStateList.valueOf(Color.rgb(11, 92, 62)));
        pill.addView(spinner, new LinearLayout.LayoutParams(dp(26), dp(26)));
        pill.setVisibility(View.GONE);
        pill.setTranslationY(-dp(72));
        return pill;
    }

    private void showPullIndicator(float dy) {
        if (pullIndicator == null) return;
        float progress = Math.min(1f, dy / dp(96));
        pullIndicator.setVisibility(View.VISIBLE);
        pullIndicator.setAlpha(progress);
        pullIndicator.setTranslationY(-dp(72) + Math.min(dy * 0.5f, dp(88)));
        pullIndicator.setScaleX(0.7f + 0.3f * progress);
        pullIndicator.setScaleY(0.7f + 0.3f * progress);
    }

    private void startPullRefresh() {
        if (pullIndicator == null) return;
        pullRefreshing = true;
        pullIndicator.setVisibility(View.VISIBLE);
        pullIndicator.animate().alpha(1f).scaleX(1f).scaleY(1f).translationY(dp(16)).setDuration(160).start();
        webView.evaluateJavascript("window.pullRefresh ? window.pullRefresh() : location.reload()", null);
    }

    private void hidePullIndicator() {
        pullRefreshing = false;
        if (pullIndicator == null || pullIndicator.getVisibility() != View.VISIBLE) return;
        pullIndicator.animate().alpha(0f).translationY(-dp(72)).setDuration(180)
                .withEndAction(() -> pullIndicator.setVisibility(View.GONE)).start();
    }

    private Button navButton(String title, int icon, String script) {
        Button button = new Button(this);
        button.setText(title);
        button.setTextSize(11);
        button.setTextColor(Color.rgb(11, 92, 62));
        button.setAllCaps(false);
        button.setBackgroundColor(Color.TRANSPARENT);
        button.setMinHeight(0);
        button.setMinimumHeight(0);
        button.setPadding(0, dp(4), 0, dp(2));
        button.setCompoundDrawablesWithIntrinsicBounds(0, icon, 0, 0);
        button.setCompoundDrawableTintList(ColorStateList.valueOf(Color.rgb(11, 92, 62)));
        button.setCompoundDrawablePadding(dp(2));
        button.setLayoutParams(new LinearLayout.LayoutParams(0, -1, 1));
        if (script != null) button.setOnClickListener(v -> webView.evaluateJavascript(script, null));
        return button;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private void showSettings() {
        LinearLayout body = new LinearLayout(this);
        body.setOrientation(LinearLayout.VERTICAL);
        body.setPadding(dp(8), dp(6), dp(8), 0);
        TextView copy = new TextView(this);
        copy.setText("当前设备：Android 手机\n网页入口：copy-direct.example.com\n\n后台同步模式");
        copy.setTextSize(16);
        copy.setLineSpacing(dp(5), 1);
        body.addView(copy);
        RadioGroup modes = new RadioGroup(this);
        String[] values = {"realtime", "saving", "off"};
        String[] labels = {"实时（约 12 秒）", "节能（亮屏 1 分钟，熄屏 5 分钟）", "关闭（不保活、不轮询、无常驻通知）"};
        String current = getSharedPreferences(PREFS, MODE_PRIVATE).getString(SYNC_MODE, "realtime");
        for (int i = 0; i < labels.length; i++) {
            android.widget.RadioButton choice = new android.widget.RadioButton(this);
            choice.setId(i + 1);
            choice.setTag(values[i]);
            choice.setText(labels[i]);
            choice.setChecked(values[i].equals(current));
            modes.addView(choice);
        }
        body.addView(modes);
        Button downloads = new Button(this);
        downloads.setText("打开 CopySync 接收文件夹");
        downloads.setAllCaps(false);
        downloads.setOnClickListener(v -> revealReceivedFile("", "*/*"));
        body.addView(downloads);
        new AlertDialog.Builder(this).setTitle("CopySync 设置").setView(body)
                .setPositiveButton("保存", (d, w) -> {
                    View selected = modes.findViewById(modes.getCheckedRadioButtonId());
                    setSyncMode(selected == null ? "realtime" : String.valueOf(selected.getTag()));
                })
                .setNeutralButton("打开网页", (d, w) -> startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(BASE))))
                .setNegativeButton("退出后台同步", (d, w) -> setSyncMode("off")).show();
    }

    private void setSyncMode(String mode) {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString(SYNC_MODE, mode).apply();
        Intent receiver = new Intent(this, SyncService.class);
        stopService(receiver);
        if ("off".equals(mode)) {
            getSystemService(NotificationManager.class).cancel(41);
            Toast.makeText(this, "后台同步已退出", Toast.LENGTH_SHORT).show();
            return;
        }
        receiver.putExtra("mode", mode).putExtra("cookie", CookieManager.getInstance().getCookie(BASE));
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(receiver); else startService(receiver);
        Toast.makeText(this, "saving".equals(mode) ? "已切换为节能模式" : "已切换为实时模式", Toast.LENGTH_SHORT).show();
    }

    private void installDeliveryListener() {
        webView.evaluateJavascript("(function(){fetch('/api/me').then(r=>{if(r.ok)CopySyncNative.shareReady()});fetch('/api/devices/android/heartbeat',{method:'POST'}).catch(()=>{})})()", null);
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel channel = new NotificationChannel(NOTIFICATION_CHANNEL, "CopySync 接收提醒", NotificationManager.IMPORTANCE_HIGH);
            channel.setDescription("其他设备发送内容到 Android 时提醒");
            getSystemService(NotificationManager.class).createNotificationChannel(channel);
        }
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS}, 9);
    }

    private final class NativeBridge {
        @JavascriptInterface public void loginSucceeded() {
            CookieManager.getInstance().flush();
            shareReady();
        }

        @JavascriptInterface public void refreshDone() {
            runOnUiThread(() -> hidePullIndicator());
        }

        @JavascriptInterface public void shareReady() {
            runOnUiThread(() -> {
                String mode = getSharedPreferences(PREFS, MODE_PRIVATE).getString(SYNC_MODE, "realtime");
                if ("off".equals(mode)) {
                    stopService(new Intent(MainActivity.this, SyncService.class));
                    return;
                }
                Intent receiver = new Intent(MainActivity.this, SyncService.class)
                        .putExtra("mode", mode)
                        .putExtra("cookie", CookieManager.getInstance().getCookie(BASE));
                if (Build.VERSION.SDK_INT >= 26) startForegroundService(receiver); else startService(receiver);
                if (pendingShare != null && !sharePromptShown) showShareReview();
            });
        }
        @JavascriptInterface public void receiveFile(String deliveryId, String itemId, String name, String mime) {
            runOnUiThread(() -> runFileAction(deliveryId, name, () -> MainActivity.this.receiveFile(deliveryId, itemId, name, mime)));
        }

        @JavascriptInterface public void saveSent(String itemId, String name, String mime) {
            String deliveryId = "sent:" + itemId;
            runOnUiThread(() -> runFileAction(deliveryId, name, () -> MainActivity.this.receiveFile(deliveryId, itemId, name, mime)));
        }

        @JavascriptInterface public String localFileState(String deliveryId) {
            try {
                return MainActivity.this.localFileState(deliveryId);
            } catch (RuntimeException error) {
                Log.e(LOG_TAG, "local file state failed for " + deliveryId, error);
                return "missing";
            }
        }

        @JavascriptInterface public void copyText(String text) {
            runOnUiThread(() -> {
                ClipboardManager clipboard = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                clipboard.setPrimaryClip(ClipData.newPlainText("CopySync", text == null ? "" : text));
            });
        }

        @JavascriptInterface public void revealReceived(String deliveryId, String itemId, String name, String mime) {
            runOnUiThread(() -> runFileAction(deliveryId, name, () -> {
                String localName = getSharedPreferences(PREFS, MODE_PRIVATE).getString(RECEIVED_FILE_PREFIX + deliveryId, "");
                if (localName.isEmpty() || !receivedFileExists(localName)) receiveFile(deliveryId, itemId, name, mime);
                else revealReceivedFile(localName, mime);
            }));
        }

        @JavascriptInterface public void showDevices(String json) {
            runOnUiThread(() -> {
                try {
                    org.json.JSONArray rows = new org.json.JSONArray(json);
                    StringBuilder message = new StringBuilder();
                    for (int i = 0; i < rows.length(); i++) {
                        JSONObject row = rows.getJSONObject(i);
                        message.append(row.optBoolean("online") ? "● " : "○ ").append(row.optString("name")).append('\n');
                    }
                    new AlertDialog.Builder(MainActivity.this).setTitle("我的设备").setMessage(message.length() > 0 ? message.toString() : "登录后显示设备").setPositiveButton("完成", null).show();
                } catch (Exception ignored) { Toast.makeText(MainActivity.this, "设备信息暂不可用", Toast.LENGTH_SHORT).show(); }
            });
        }
    }

    private void downloadFromWeb(String url, String userAgent, String disposition, String mime) {
        runFileAction("", "文件", () -> {
            String name = uniqueReceiveName(android.webkit.URLUtil.guessFileName(url, disposition, mime));
            enqueueDownload(url, userAgent, "", name, mime);
        });
    }

    private void runFileAction(String deliveryId, String name, Runnable action) {
        try {
            action.run();
        } catch (RuntimeException error) {
            Log.e(LOG_TAG, "file action failed for " + deliveryId, error);
            if (deliveryId != null && !deliveryId.isEmpty()) notifyWebLocalFileFailed(deliveryId, name);
            Toast.makeText(this, "文件操作失败，CopySync 已保持运行，请重试", Toast.LENGTH_LONG).show();
        }
    }

    private void receiveFile(String deliveryId, String itemId, String originalName, String mime) {
        String state = localFileState(deliveryId);
        String savedName = getSharedPreferences(PREFS, MODE_PRIVATE).getString(RECEIVED_FILE_PREFIX + deliveryId, "");
        if ("ready".equals(state) && !savedName.isEmpty()) {
            revealReceivedFile(savedName, mime);
            return;
        }
        if ("pending".equals(state)) return;
        String name = uniqueReceiveName(originalName);
        enqueueDownload(BASE + "download/" + itemId, "CopySync-Android", deliveryId, name, mime);
    }

    private void enqueueDownload(String url, String userAgent, String deliveryId, String name, String mime) {
        String effectiveMime = mime == null || mime.isEmpty() ? "application/octet-stream" : mime;
        DownloadManager.Request request = new DownloadManager.Request(Uri.parse(url)).setTitle(name)
                .setMimeType(effectiveMime).setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, RECEIVE_DIRECTORY + "/" + name);
        String cookie = CookieManager.getInstance().getCookie(BASE);
        if (cookie != null && !cookie.isEmpty()) request.addRequestHeader("Cookie", cookie);
        if (userAgent != null && !userAgent.isEmpty()) request.addRequestHeader("User-Agent", userAgent);
        long id = ((DownloadManager)getSystemService(DOWNLOAD_SERVICE)).enqueue(request);
        DownloadRecord record = new DownloadRecord(deliveryId, name, effectiveMime);
        regularDownloads.put(id, record);
        savePendingDownload(id, record);
    }

    private void finishRegularDownload(long id, DownloadRecord record) {
        finishRegularDownload(id, record, true);
    }

    private void finishRegularDownload(long id, DownloadRecord record, boolean revealSent) {
        try {
            DownloadManager manager = (DownloadManager)getSystemService(DOWNLOAD_SERVICE);
            Uri uri = manager.getUriForDownloadedFile(id);
            if (uri == null && !receivedFileExists(record.name)) {
                clearPendingDownload(id);
                notifyWebLocalFileFailed(record.deliveryId, record.name);
                return;
            }
            markDownloadReady(id, record, revealSent);
        } catch (RuntimeException error) {
            Log.e(LOG_TAG, "finish download failed", error);
            regularDownloads.remove(id);
            clearPendingDownload(id);
            notifyWebLocalFileFailed(record.deliveryId, record.name);
        }
    }

    private void markDownloadReady(long id, DownloadRecord record, boolean revealSent) {
        regularDownloads.remove(id);
        clearPendingDownload(id);
        if (record.deliveryId.isEmpty()) return;
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString(RECEIVED_FILE_PREFIX + record.deliveryId, record.name).apply();
        if (record.deliveryId.startsWith("sent:")) {
            notifyWebLocalFileReady(record.deliveryId, record.name);
            if (revealSent) runOnUiThread(() -> revealReceivedFile(record.name, record.mime));
        } else {
            ackDownloaded(record.deliveryId, () -> notifyWebLocalFileReady(record.deliveryId, record.name));
        }
    }

    private void notifyWebLocalFileReady(String deliveryId, String name) {
        String script = "window.copySyncLocalFileReady&&copySyncLocalFileReady(" + JSONObject.quote(deliveryId) + "," + JSONObject.quote(name) + ")";
        runOnUiThread(() -> webView.evaluateJavascript(script, null));
    }

    private void notifyWebLocalFileFailed(String deliveryId, String name) {
        String script = "window.copySyncLocalFileFailed&&copySyncLocalFileFailed(" + JSONObject.quote(deliveryId) + "," + JSONObject.quote(name) + ")";
        runOnUiThread(() -> webView.evaluateJavascript(script, null));
    }

    private void revealReceivedFile(String name, String mime) {
        Uri folder;
        try {
            folder = DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", "primary:Download/" + RECEIVE_DIRECTORY);
        } catch (RuntimeException error) {
            Log.e(LOG_TAG, "cannot build receive folder URI", error);
            Toast.makeText(this, "请在系统文件管理器中打开“下载/" + RECEIVE_DIRECTORY + "”", Toast.LENGTH_LONG).show();
            return;
        }
        for (String packageName : FILE_MANAGER_PACKAGES) {
            try {
                startActivity(externalFolderIntent(folder, name).setPackage(packageName));
                return;
            } catch (RuntimeException error) {
                Log.d(LOG_TAG, "file manager cannot open folder: " + packageName, error);
            }
        }
        try {
            startActivity(externalFolderIntent(folder, name));
            return;
        } catch (RuntimeException error) {
            Log.w(LOG_TAG, "generic external folder ACTION_VIEW rejected", error);
        }
        for (String packageName : FILE_MANAGER_PACKAGES) {
            try {
                Intent launch = getPackageManager().getLaunchIntentForPackage(packageName);
                if (launch == null) continue;
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
                startActivity(launch);
                Toast.makeText(this, "已打开系统文件管理器，请进入“下载/" + RECEIVE_DIRECTORY + "”", Toast.LENGTH_LONG).show();
                return;
            } catch (RuntimeException error) {
                Log.d(LOG_TAG, "file manager launch rejected: " + packageName, error);
            }
        }
        Toast.makeText(this, "请在系统文件管理器中打开“下载/" + RECEIVE_DIRECTORY + "”", Toast.LENGTH_LONG).show();
    }

    private Intent externalFolderIntent(Uri folder, String name) {
        Intent intent = new Intent(Intent.ACTION_VIEW).setDataAndType(folder, DocumentsContract.Document.MIME_TYPE_DIR)
                .addCategory(Intent.CATEGORY_DEFAULT)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP
                        | Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        if (name != null && !name.isEmpty()) intent.putExtra(Intent.EXTRA_TITLE, name);
        return intent;
    }

    private String safeReceiveName(String originalName) {
        String name = originalName == null ? "" : new File(originalName).getName().trim();
        name = name.replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]", "_");
        return name.isEmpty() ? "CopySync-file" : name;
    }

    private String uniqueReceiveName(String originalName) {
        String name = safeReceiveName(originalName);
        if (!receivedFileExists(name)) return name;
        String extension = name.lastIndexOf('.') > 0 ? name.substring(name.lastIndexOf('.')) : "";
        String base = extension.isEmpty() ? name : name.substring(0, name.length() - extension.length());
        return base + "-" + System.currentTimeMillis() + extension;
    }

    private boolean receivedFileExists(String name) {
        String safeName = safeReceiveName(name);
        if (Build.VERSION.SDK_INT >= 29) {
            String relativePath = Environment.DIRECTORY_DOWNLOADS + "/" + RECEIVE_DIRECTORY + "/";
            try (Cursor cursor = getContentResolver().query(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    new String[]{MediaStore.MediaColumns._ID},
                    MediaStore.MediaColumns.DISPLAY_NAME + "=? AND " + MediaStore.MediaColumns.RELATIVE_PATH + "=?",
                    new String[]{safeName, relativePath}, null)) {
                if (cursor != null && cursor.moveToFirst()) return true;
            } catch (Exception ignored) {}
        }
        try {
            File directory = new File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), RECEIVE_DIRECTORY);
            return new File(directory, safeName).isFile();
        } catch (RuntimeException error) {
            Log.w(LOG_TAG, "legacy file lookup rejected", error);
            return false;
        }
    }

    private void ensureReceiveFolder() {
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                ContentValues values = new ContentValues();
                values.put(MediaStore.MediaColumns.DISPLAY_NAME, ".copysync-init");
                values.put(MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream");
                values.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/" + RECEIVE_DIRECTORY);
                values.put(MediaStore.MediaColumns.IS_PENDING, 1);
                Uri marker = getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
                if (marker != null) {
                    try (OutputStream ignored = getContentResolver().openOutputStream(marker)) {}
                    getContentResolver().delete(marker, null, null);
                }
            } catch (Exception ignored) {}
        } else {
            new File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), RECEIVE_DIRECTORY).mkdirs();
        }
    }

    private void savePendingDownload(long id, DownloadRecord record) {
        try {
            JSONObject json = new JSONObject().put("deliveryId", record.deliveryId).put("name", record.name).put("mime", record.mime);
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString(PENDING_DOWNLOAD_PREFIX + id, json.toString()).apply();
        } catch (Exception ignored) {}
    }

    private DownloadRecord loadPendingDownload(long id) {
        try {
            String value = getSharedPreferences(PREFS, MODE_PRIVATE).getString(PENDING_DOWNLOAD_PREFIX + id, "");
            if (value.isEmpty()) return null;
            JSONObject json = new JSONObject(value);
            return new DownloadRecord(json.optString("deliveryId"), json.optString("name", "CopySync-file"), json.optString("mime"));
        } catch (Exception ignored) { return null; }
    }

    private String localFileState(String deliveryId) {
        String savedName = getSharedPreferences(PREFS, MODE_PRIVATE).getString(RECEIVED_FILE_PREFIX + deliveryId, "");
        boolean deleted = !savedName.isEmpty();
        if (deleted && receivedFileExists(savedName)) return "ready";
        if (deleted) getSharedPreferences(PREFS, MODE_PRIVATE).edit().remove(RECEIVED_FILE_PREFIX + deliveryId).apply();
        String pendingState = reconcilePendingDelivery(deliveryId);
        if (!"missing".equals(pendingState)) return pendingState;
        return deleted ? "deleted" : "missing";
    }

    private String reconcilePendingDelivery(String deliveryId) {
        DownloadManager manager = (DownloadManager)getSystemService(DOWNLOAD_SERVICE);
        for (java.util.Map.Entry<String, ?> entry : getSharedPreferences(PREFS, MODE_PRIVATE).getAll().entrySet()) {
            if (!entry.getKey().startsWith(PENDING_DOWNLOAD_PREFIX) || !(entry.getValue() instanceof String)) continue;
            long id;
            DownloadRecord record;
            try {
                id = Long.parseLong(entry.getKey().substring(PENDING_DOWNLOAD_PREFIX.length()));
                JSONObject json = new JSONObject((String)entry.getValue());
                record = new DownloadRecord(json.optString("deliveryId"), json.optString("name", "CopySync-file"), json.optString("mime"));
            } catch (Exception ignored) { continue; }
            if (!deliveryId.equals(record.deliveryId)) continue;
            if (receivedFileExists(record.name)) {
                markDownloadReady(id, record, false);
                return "ready";
            }
            try (Cursor cursor = manager.query(new DownloadManager.Query().setFilterById(id))) {
                if (cursor == null || !cursor.moveToFirst()) {
                    regularDownloads.remove(id);
                    clearPendingDownload(id);
                    continue;
                }
                int status = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS));
                if (status == DownloadManager.STATUS_SUCCESSFUL) {
                    finishRegularDownload(id, record, false);
                    return receivedFileExists(record.name) ? "ready" : "missing";
                }
                if (status == DownloadManager.STATUS_FAILED) {
                    regularDownloads.remove(id);
                    clearPendingDownload(id);
                    continue;
                }
                return "pending";
            } catch (Exception ignored) {
                regularDownloads.remove(id);
                clearPendingDownload(id);
            }
        }
        return "missing";
    }

    private void clearPendingDownload(long id) {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().remove(PENDING_DOWNLOAD_PREFIX + id).apply();
    }

    private void reconcilePendingDownloads() {
        DownloadManager manager = (DownloadManager)getSystemService(DOWNLOAD_SERVICE);
        List<Long> ids = new ArrayList<>();
        for (String key : getSharedPreferences(PREFS, MODE_PRIVATE).getAll().keySet()) {
            if (!key.startsWith(PENDING_DOWNLOAD_PREFIX)) continue;
            try { ids.add(Long.parseLong(key.substring(PENDING_DOWNLOAD_PREFIX.length()))); }
            catch (NumberFormatException ignored) {}
        }
        for (long id : ids) {
            DownloadRecord record = loadPendingDownload(id);
            if (record == null) {
                clearPendingDownload(id);
                continue;
            }
            if (receivedFileExists(record.name)) {
                markDownloadReady(id, record, false);
                continue;
            }
            try (Cursor cursor = manager.query(new DownloadManager.Query().setFilterById(id))) {
                if (cursor == null || !cursor.moveToFirst()) {
                    regularDownloads.remove(id);
                    clearPendingDownload(id);
                    continue;
                }
                int status = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS));
                if (status == DownloadManager.STATUS_SUCCESSFUL) {
                    regularDownloads.remove(id);
                    finishRegularDownload(id, record, false);
                } else if (status == DownloadManager.STATUS_FAILED) {
                    regularDownloads.remove(id);
                    clearPendingDownload(id);
                    notifyWebLocalFileFailed(record.deliveryId, record.name);
                }
            } catch (Exception ignored) {}
        }
    }

    private void ackDownloaded(String deliveryId, Runnable completion) {
        new Thread(() -> {
            try {
                HttpURLConnection connection = (HttpURLConnection)new URL(BASE + "api/deliveries/" + deliveryId + "/ack").openConnection();
                connection.setRequestMethod("POST");
                connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
                String cookie = CookieManager.getInstance().getCookie(BASE);
                if (cookie != null) connection.setRequestProperty("Cookie", cookie);
                connection.setDoOutput(true);
                try (OutputStream output = connection.getOutputStream()) { output.write("status=downloaded".getBytes(java.nio.charset.StandardCharsets.UTF_8)); }
                connection.getResponseCode();
                connection.disconnect();
            } catch (Exception ignored) {}
            finally { if (completion != null) runOnUiThread(completion); }
        }).start();
    }

    private boolean isShareIntent(Intent intent) {
        return intent != null && (Intent.ACTION_SEND.equals(intent.getAction()) || Intent.ACTION_SEND_MULTIPLE.equals(intent.getAction()));
    }

    private void showShareReview() {
        if (pendingShare == null || sharePromptShown) return;
        String cookie = CookieManager.getInstance().getCookie(BASE);
        if (cookie == null || !cookie.contains("webclip_session")) {
            Toast.makeText(this, "请先登录 CopySync，登录后会继续发送", Toast.LENGTH_LONG).show();
            return;
        }
        sharePromptShown = true;
        LinearLayout body = new LinearLayout(this);
        body.setOrientation(LinearLayout.VERTICAL);
        body.setPadding(dp(20), dp(8), dp(20), 0);
        TextView summary = new TextView(this);
        summary.setText(shareSummary(pendingShare));
        summary.setTextSize(16);
        body.addView(summary);
        Spinner target = new Spinner(this);
        String[] targetNames = {"全部设备", "Mac", "网页临时设备"};
        target.setAdapter(new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, targetNames));
        body.addView(target);
        CheckBox syncWeb = new CheckBox(this);
        syncWeb.setText("目标是否同步到网页");
        syncWeb.setChecked(true);
        body.addView(syncWeb);
        new AlertDialog.Builder(this).setTitle("发送到 CopySync").setView(body)
                .setPositiveButton("发送", (dialog, which) -> {
                    String[] targets = {"all", "mac", "web"};
                    Intent share = pendingShare;
                    pendingShare = null;
                    uploadShare(share, targets[target.getSelectedItemPosition()], syncWeb.isChecked());
                })
                .setNegativeButton("取消", (dialog, which) -> { pendingShare = null; })
                .setOnCancelListener(dialog -> pendingShare = null).show();
    }

    private String shareSummary(Intent intent) {
        String text = intent.getStringExtra(Intent.EXTRA_TEXT);
        ArrayList<Uri> uris = sharedUris(intent);
        if (!uris.isEmpty()) return uris.size() == 1 ? "1 个文件或图片" : uris.size() + " 个文件或图片";
        if (text == null || text.trim().isEmpty()) return "没有可发送的内容";
        text = text.replace('\n', ' ').trim();
        return text.length() > 90 ? text.substring(0, 90) + "…" : text;
    }

    private ArrayList<Uri> sharedUris(Intent intent) {
        ArrayList<Uri> result = new ArrayList<>();
        if (Intent.ACTION_SEND_MULTIPLE.equals(intent.getAction())) {
            ArrayList<Uri> list = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
            if (list != null) result.addAll(list);
        } else {
            Uri one = intent.getParcelableExtra(Intent.EXTRA_STREAM);
            if (one != null) result.add(one);
        }
        if (intent.getClipData() != null) for (int i = 0; i < intent.getClipData().getItemCount(); i++) {
            Uri uri = intent.getClipData().getItemAt(i).getUri();
            if (uri != null && !result.contains(uri)) result.add(uri);
        }
        return result;
    }

    private void uploadShare(Intent share, String target, boolean syncWeb) {
        Toast.makeText(this, "正在发送…", Toast.LENGTH_SHORT).show();
        new Thread(() -> {
            HttpURLConnection connection = null;
            try {
                ArrayList<Uri> uris = sharedUris(share);
                boolean files = !uris.isEmpty();
                String boundary = "CopySync-" + System.currentTimeMillis();
                connection = (HttpURLConnection)new URL(BASE + (files ? "api/upload" : "api/text")).openConnection();
                connection.setRequestMethod("POST");
                connection.setDoOutput(true);
                connection.setChunkedStreamingMode(64 * 1024);
                connection.setRequestProperty("Content-Type", "multipart/form-data; boundary=" + boundary);
                connection.setRequestProperty("Cookie", CookieManager.getInstance().getCookie(BASE));
                try (OutputStream output = connection.getOutputStream()) {
                    writeField(output, boundary, "source_device", "android");
                    writeField(output, boundary, "target_device", target);
                    writeField(output, boundary, "web_visible", syncWeb ? "1" : "0");
                    writeField(output, boundary, "ttl", "604800");
                    if (files) {
                        byte[] buffer = new byte[64 * 1024];
                        for (Uri uri : uris) {
                            String name = displayName(uri);
                            String type = getContentResolver().getType(uri);
                            if (type == null) type = "application/octet-stream";
                            output.write(("--" + boundary + "\r\nContent-Disposition: form-data; name=\"files\"; filename=\"" + name.replace("\"", "") + "\"\r\nContent-Type: " + type + "\r\n\r\n").getBytes("UTF-8"));
                            try (InputStream input = getContentResolver().openInputStream(uri)) {
                                if (input == null) throw new IllegalStateException("无法读取 " + name);
                                for (int size; (size = input.read(buffer)) > 0;) output.write(buffer, 0, size);
                            }
                            output.write("\r\n".getBytes("UTF-8"));
                        }
                    } else {
                        writeField(output, boundary, "text", share.getStringExtra(Intent.EXTRA_TEXT));
                    }
                    output.write(("--" + boundary + "--\r\n").getBytes("UTF-8"));
                }
                int status = connection.getResponseCode();
                if (status < 200 || status >= 300) throw new IllegalStateException("服务器返回 " + status);
                runOnUiThread(() -> { Toast.makeText(this, "已发送", Toast.LENGTH_SHORT).show(); webView.reload(); });
            } catch (Exception error) {
                runOnUiThread(() -> Toast.makeText(this, "发送失败：" + error.getMessage(), Toast.LENGTH_LONG).show());
            } finally {
                if (connection != null) connection.disconnect();
            }
        }).start();
    }

    private void writeField(OutputStream output, String boundary, String name, String value) throws Exception {
        if (value == null) value = "";
        output.write(("--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + name + "\"\r\n\r\n" + value + "\r\n").getBytes("UTF-8"));
    }

    private String displayName(Uri uri) {
        try (Cursor cursor = getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) return cursor.getString(0);
        } catch (Exception ignored) {}
        String name = uri.getLastPathSegment();
        return name == null ? "CopySync-file" : name;
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == ALLOW_UPDATES) {
            if (Build.VERSION.SDK_INT < 26 || getPackageManager().canRequestPackageInstalls()) installUpdate();
            return;
        }
        if (requestCode != PICK_FILES || fileChooser == null) return;
        ArrayList<Uri> files = new ArrayList<>();
        if (resultCode == RESULT_OK && data != null) {
            if (data.getData() != null) files.add(data.getData());
            if (data.getClipData() != null) for (int i = 0; i < data.getClipData().getItemCount(); i++) files.add(data.getClipData().getItemAt(i).getUri());
        }
        fileChooser.onReceiveValue(files.toArray(new Uri[0]));
        fileChooser = null;
    }

    @Override protected void onDestroy() {
        unregisterReceiver(downloadReceiver);
        super.onDestroy();
    }

    private void checkForUpdate() {
        new Thread(() -> {
            HttpURLConnection connection = null;
            try {
                connection = (HttpURLConnection) new URL(UPDATE_MANIFEST).openConnection();
                connection.setConnectTimeout(5000);
                connection.setReadTimeout(5000);
                try (InputStream input = connection.getInputStream()) {
                    ByteArrayOutputStream output = new ByteArrayOutputStream();
                    byte[] buffer = new byte[8192];
                    for (int size; (size = input.read(buffer)) > 0;) output.write(buffer, 0, size);
                    String json = output.toString("UTF-8");
                    JSONObject manifest = new JSONObject(json);
                    long current = Build.VERSION.SDK_INT >= 28
                            ? getPackageManager().getPackageInfo(getPackageName(), 0).getLongVersionCode()
                            : getPackageManager().getPackageInfo(getPackageName(), 0).versionCode;
                    if (manifest.getLong("versionCode") > current) runOnUiThread(() -> showUpdate(manifest));
                }
            } catch (Exception ignored) {
            } finally {
                if (connection != null) connection.disconnect();
            }
        }).start();
    }

    private void showUpdate(JSONObject manifest) {
        new AlertDialog.Builder(this)
                .setTitle("发现 Copy Web " + manifest.optString("version"))
                .setMessage(manifest.optString("notes", "下载后由 Android 确认更新。"))
                .setPositiveButton("立即更新", (dialog, which) -> downloadUpdate(manifest))
                .setNegativeButton("稍后", null)
                .show();
    }

    private void downloadUpdate(JSONObject manifest) {
        String url = manifest.optString("url");
        expectedUpdateSha = manifest.optString("sha256").toLowerCase(Locale.ROOT);
        if (url.isEmpty() || expectedUpdateSha.isEmpty()) return;
        java.io.File old = new java.io.File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "CopyWeb-update.apk");
        old.delete();
        DownloadManager.Request request = new DownloadManager.Request(Uri.parse(url))
                .setTitle("Copy Web 更新")
                .setDescription("正在下载最新版")
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                .setDestinationInExternalFilesDir(this, Environment.DIRECTORY_DOWNLOADS, "CopyWeb-update.apk");
        updateDownloadId = ((DownloadManager) getSystemService(DOWNLOAD_SERVICE)).enqueue(request);
        Toast.makeText(this, "开始下载更新", Toast.LENGTH_SHORT).show();
    }

    private void finishUpdateDownload() {
        DownloadManager manager = (DownloadManager) getSystemService(DOWNLOAD_SERVICE);
        try (Cursor cursor = manager.query(new DownloadManager.Query().setFilterById(updateDownloadId))) {
            if (!cursor.moveToFirst() || cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)) != DownloadManager.STATUS_SUCCESSFUL) {
                Toast.makeText(this, "更新下载失败", Toast.LENGTH_LONG).show();
                return;
            }
        }
        pendingUpdate = manager.getUriForDownloadedFile(updateDownloadId);
        if (pendingUpdate == null || !expectedUpdateSha.equals(sha256(pendingUpdate))) {
            Toast.makeText(this, "更新校验失败", Toast.LENGTH_LONG).show();
            return;
        }
        if (Build.VERSION.SDK_INT >= 26 && !getPackageManager().canRequestPackageInstalls()) {
            startActivityForResult(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + getPackageName())), ALLOW_UPDATES);
        } else {
            installUpdate();
        }
    }

    private String sha256(Uri uri) {
        try (InputStream input = getContentResolver().openInputStream(uri)) {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] buffer = new byte[65536];
            for (int size; (size = input.read(buffer)) > 0;) digest.update(buffer, 0, size);
            StringBuilder value = new StringBuilder();
            for (byte b : digest.digest()) value.append(String.format("%02x", b & 0xff));
            return value.toString();
        } catch (Exception error) {
            return "";
        }
    }

    private void installUpdate() {
        if (pendingUpdate == null) return;
        Intent install = new Intent(Intent.ACTION_VIEW)
                .setDataAndType(pendingUpdate, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
        startActivity(install);
    }
}
