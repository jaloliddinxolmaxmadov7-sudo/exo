package uz.ezome.app;

import android.Manifest;
import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ContentValues;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.print.PrintAttributes;
import android.print.PrintDocumentAdapter;
import android.print.PrintManager;
import android.provider.MediaStore;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;
import android.webkit.PermissionRequest;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import androidx.core.content.FileProvider;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/** ezome — do'kon tizimi. Saytni ilova ichida ochadi: kamera-skaner, chek rasmi, yorliq chop etish, zaxira saqlash. */
public class MainActivity extends Activity {
    static final String HOME = "https://jaloliddinxolmaxmadov7-sudo.github.io/exo/";
    static final String HOST = "jaloliddinxolmaxmadov7-sudo.github.io";
    static final String PATH = "/exo";
    static final int REQ_FILE = 11, REQ_CAM = 12, REQ_CAM_FILE = 13;

    WebView web;
    WebView printView;
    ValueCallback<Uri[]> fileCb;
    WebChromeClient.FileChooserParams fileParams;
    PermissionRequest pendingPerm;
    Uri camUri;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        web = new WebView(this);
        setContentView(web);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(true);
        s.setUserAgentString(s.getUserAgentString() + " EzomeApp/1");
        CookieManager.getInstance().setAcceptCookie(true);

        web.addJavascriptInterface(new Bridge(), "EzAndroid");
        web.setWebViewClient(new Client());
        web.setWebChromeClient(new Chrome());

        if (b != null) web.restoreState(b);
        else web.loadUrl(HOME);
    }

    static boolean ours(Uri u) {
        return u != null && "https".equals(u.getScheme()) && HOST.equalsIgnoreCase(u.getHost())
                && u.getPath() != null && u.getPath().startsWith(PATH);
    }

    class Client extends WebViewClient {
        @Override
        public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
            Uri u = r.getUrl();
            if (ours(u)) return false;
            try {
                startActivity(new Intent(Intent.ACTION_VIEW, u));
            } catch (ActivityNotFoundException ignored) {
            }
            return true;
        }

        @Override
        public void onReceivedError(WebView v, WebResourceRequest r, WebResourceError e) {
            if (!r.isForMainFrame()) return;
            String html = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head>"
                    + "<body style='font-family:sans-serif;background:#f2f3ef;display:flex;align-items:center;justify-content:center;height:90vh;margin:0'>"
                    + "<div style='text-align:center;padding:24px'><div style='font-size:48px'>📶</div>"
                    + "<h2 style='margin:8px 0'>Internet yo'q</h2><p style='color:#666'>Internetni yoqing va qayta urinib ko'ring.</p>"
                    + "<a href='" + HOME + "' style='display:inline-block;margin-top:12px;padding:12px 22px;background:#1f6bff;color:#fff;border-radius:12px;text-decoration:none;font-weight:600'>Qayta urinish</a>"
                    + "</div></body></html>";
            v.loadDataWithBaseURL(HOME, html, "text/html", "UTF-8", null);
        }
    }

    class Chrome extends WebChromeClient {
        @Override
        public void onPermissionRequest(final PermissionRequest req) {
            runOnUiThread(() -> {
                boolean wantsCam = false;
                for (String r : req.getResources())
                    if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(r)) wantsCam = true;
                if (!wantsCam || !ours(req.getOrigin())) {
                    req.deny();
                    return;
                }
                if (hasCam()) {
                    req.grant(new String[]{PermissionRequest.RESOURCE_VIDEO_CAPTURE});
                } else {
                    if (pendingPerm != null) pendingPerm.deny();
                    pendingPerm = req;
                    requestPermissions(new String[]{Manifest.permission.CAMERA}, REQ_CAM);
                }
            });
        }

        @Override
        public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> cb, FileChooserParams p) {
            if (fileCb != null) fileCb.onReceiveValue(null);
            fileCb = cb;
            fileParams = p;
            if (isImage(p) && !hasCam()) {
                requestPermissions(new String[]{Manifest.permission.CAMERA}, REQ_CAM_FILE);
            } else {
                openChooser();
            }
            return true;
        }
    }

    boolean hasCam() {
        return checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED;
    }

    static boolean isImage(WebChromeClient.FileChooserParams p) {
        if (p == null) return false;
        for (String t : p.getAcceptTypes()) if (t != null && t.startsWith("image")) return true;
        return false;
    }

    void openChooser() {
        WebChromeClient.FileChooserParams p = fileParams;
        boolean img = isImage(p);
        boolean multi = p != null && p.getMode() == WebChromeClient.FileChooserParams.MODE_OPEN_MULTIPLE;

        Intent pick = new Intent(Intent.ACTION_GET_CONTENT);
        pick.addCategory(Intent.CATEGORY_OPENABLE);
        pick.setType(img ? "image/*" : "*/*");
        if (multi) pick.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);

        List<Intent> extra = new ArrayList<>();
        camUri = null;
        if (img && hasCam()) {
            try {
                File dir = new File(getCacheDir(), "cam");
                if (!dir.exists()) dir.mkdirs();
                File f = new File(dir, "chek_" + System.currentTimeMillis() + ".jpg");
                camUri = FileProvider.getUriForFile(this, "uz.ezome.app.files", f);
                Intent cam = new Intent(MediaStore.ACTION_IMAGE_CAPTURE);
                cam.putExtra(MediaStore.EXTRA_OUTPUT, camUri);
                cam.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_READ_URI_PERMISSION);
                if (cam.resolveActivity(getPackageManager()) != null) extra.add(cam);
                else camUri = null;
            } catch (Exception e) {
                camUri = null;
            }
        }

        Intent chooser = Intent.createChooser(pick, img ? "Rasm: kamera yoki galereya" : "Faylni tanlang");
        if (!extra.isEmpty()) chooser.putExtra(Intent.EXTRA_INITIAL_INTENTS, extra.toArray(new Intent[0]));
        try {
            startActivityForResult(chooser, REQ_FILE);
        } catch (ActivityNotFoundException e) {
            if (fileCb != null) fileCb.onReceiveValue(null);
            fileCb = null;
        }
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        if (req != REQ_FILE) {
            super.onActivityResult(req, res, data);
            return;
        }
        Uri[] out = null;
        if (res == RESULT_OK) {
            if (data != null && data.getClipData() != null) {
                int n = data.getClipData().getItemCount();
                out = new Uri[n];
                for (int i = 0; i < n; i++) out[i] = data.getClipData().getItemAt(i).getUri();
            } else if (data != null && data.getData() != null) {
                out = new Uri[]{data.getData()};
            } else if (camUri != null) {
                out = new Uri[]{camUri};
            }
        }
        if (fileCb != null) fileCb.onReceiveValue(out);
        fileCb = null;
        fileParams = null;
    }

    @Override
    public void onRequestPermissionsResult(int req, String[] perms, int[] res) {
        boolean ok = res.length > 0 && res[0] == PackageManager.PERMISSION_GRANTED;
        if (req == REQ_CAM && pendingPerm != null) {
            if (ok) pendingPerm.grant(new String[]{PermissionRequest.RESOURCE_VIDEO_CAPTURE});
            else pendingPerm.deny();
            pendingPerm = null;
        } else if (req == REQ_CAM_FILE) {
            openChooser();
        }
    }

    /** Sayt chaqiradigan yordamchilar: window.EzAndroid.save(...) va window.EzAndroid.printHtml(...) */
    class Bridge {
        @JavascriptInterface
        public String save(String name, String data) {
            String fn = (name == null ? "ezome.txt" : name).replaceAll("[^A-Za-z0-9._-]", "_");
            if (fn.isEmpty()) fn = "ezome.txt";
            String mime = fn.endsWith(".json") ? "application/json" : fn.endsWith(".csv") ? "text/csv" : fn.endsWith(".html") ? "text/html" : "text/plain";
            byte[] bytes = (data == null ? "" : data).getBytes(StandardCharsets.UTF_8);
            try {
                if (Build.VERSION.SDK_INT >= 29) {
                    ContentValues cv = new ContentValues();
                    cv.put(MediaStore.Downloads.DISPLAY_NAME, fn);
                    cv.put(MediaStore.Downloads.MIME_TYPE, mime);
                    cv.put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/ezome");
                    Uri u = getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv);
                    if (u == null) return "";
                    try (OutputStream os = getContentResolver().openOutputStream(u)) {
                        if (os == null) return "";
                        os.write(bytes);
                    }
                    return "Download/ezome/" + fn;
                } else {
                    File dir = new File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "ezome");
                    if (!dir.exists()) dir.mkdirs();
                    File f = new File(dir, fn);
                    try (FileOutputStream os = new FileOutputStream(f)) {
                        os.write(bytes);
                    }
                    return f.getAbsolutePath();
                }
            } catch (Exception e) {
                return "";
            }
        }

        @JavascriptInterface
        public void printHtml(final String html, final String name) {
            runOnUiThread(() -> {
                final String job = (name == null || name.isEmpty()) ? "ezome-yorliq" : name.replace(".html", "");
                printView = new WebView(MainActivity.this);
                printView.getSettings().setJavaScriptEnabled(false);
                printView.setWebViewClient(new WebViewClient() {
                    @Override
                    public void onPageFinished(WebView v, String url) {
                        v.postDelayed(() -> {
                            PrintManager pm = (PrintManager) getSystemService(PRINT_SERVICE);
                            PrintDocumentAdapter a = v.createPrintDocumentAdapter(job);
                            PrintAttributes attrs = new PrintAttributes.Builder()
                                    .setMediaSize(new PrintAttributes.MediaSize("ez30x20", "Yorliq 30×20 mm", 1181, 787))
                                    .setMinMargins(PrintAttributes.Margins.NO_MARGINS)
                                    .build();
                            if (pm != null) pm.print(job, a, attrs);
                        }, 300);
                    }
                });
                printView.loadDataWithBaseURL(HOME, html == null ? "" : html, "text/html", "UTF-8", null);
            });
        }
    }

    @Override
    public void onBackPressed() {
        if (web != null && web.canGoBack()) web.goBack();
        else super.onBackPressed();
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        if (web != null) web.saveState(out);
    }

    @Override
    protected void onPause() {
        super.onPause();
        CookieManager.getInstance().flush();
        if (web != null) web.onPause();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (web != null) web.onResume();
    }
}
