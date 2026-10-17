package com.higerotech.hlidskjalf;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.Log;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

/**
 * Hlidskjalf: muestra el tablero de midgard a pantalla completa, con la pantalla siempre encendida.
 *
 * La página se refresca sola (pide el resumen cada 15 s y avisa si pierde la conexión); esta
 * actividad solo cubre lo que la página no puede: la primera carga sin red, la navegación fuera
 * del tablero y una recarga completa cada 6 h para que el WebView no acumule memoria en una
 * tablet de 1 GB.
 *
 * La URL vive en files/url (la escribe instalar.sh con run-as); lleva el token en el fragmento.
 * Salida del kiosco: cinco toques seguidos en la esquina superior izquierda abren los Ajustes.
 */
public class Tablero extends Activity {
    private static final String TAG = "Hlidskjalf";
    // Solo si falta files/url (instalar.sh la escribe siempre). RFC 5737, como el resto del repo.
    private static final String URL_DEFECTO = "http://192.0.2.10:1880/hlidskjalf/";
    private static final long REINTENTO_MS = 30_000;
    private static final long RECARGA_MS = 6 * 3600_000L;
    private static final int ESQUINA_PX = 120;
    private static final int TOQUES_SALIDA = 5;
    private static final long VENTANA_TOQUES_MS = 4_000;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private WebView web;
    private String url;
    private int toques;
    private long primerToque;

    private final Runnable cargar = new Runnable() {
        @Override public void run() { cargar(); }
    };

    @Override
    protected void onCreate(Bundle estado) {
        super.onCreate(estado);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_FULLSCREEN);

        web = new WebView(this);
        web.setBackgroundColor(Color.rgb(13, 17, 23));
        WebSettings ajustes = web.getSettings();
        ajustes.setJavaScriptEnabled(true);
        ajustes.setDomStorageEnabled(true);          // el token se guarda en localStorage
        ajustes.setAllowFileAccess(false);
        ajustes.setAllowContentAccess(false);
        ajustes.setSupportZoom(false);
        ajustes.setBuiltInZoomControls(false);
        web.setLongClickable(false);
        web.setOnLongClickListener(new View.OnLongClickListener() {
            @Override public boolean onLongClick(View v) { return true; }   // sin menú de selección
        });
        web.setWebViewClient(new Cliente());
        setContentView(web);
        cargar();
    }

    private void cargar() {
        handler.removeCallbacks(cargar);
        url = leerUrl();
        Log.i(TAG, "cargando el tablero de " + sinFragmento(url));
        web.loadUrl(url);
        handler.postDelayed(cargar, RECARGA_MS);
    }

    private void reintentar(String motivo) {
        Log.w(TAG, "sin tablero: " + motivo);
        handler.removeCallbacks(cargar);
        // Colores en rgb(): en contenido cargado como datos, «#» puede cortar el documento.
        String html = "<html style=\"background:rgb(13,17,23)\"><body style=\"margin:0;background:rgb(13,17,23);"
                + "color:rgb(230,237,243);font:24px sans-serif;"
                + "display:flex;align-items:center;justify-content:center;height:100vh;text-align:center\">"
                + "<div><b style=\"color:rgb(248,81,73)\">Sin conexión con midgard</b><br><small style=\"color:rgb(139,148,158)\">"
                + escapar(motivo) + "<br>Reintento en " + (REINTENTO_MS / 1000) + " s</small></div></body></html>";
        web.loadDataWithBaseURL(null, html, "text/html", "utf-8", null);
        handler.postDelayed(cargar, REINTENTO_MS);
    }

    private String leerUrl() {
        File f = new File(getFilesDir(), "url");
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] b = new byte[(int) Math.min(f.length(), 4096)];
            int n = in.read(b);
            String u = new String(b, 0, Math.max(n, 0), StandardCharsets.UTF_8).trim();
            if (u.startsWith("http://") || u.startsWith("https://")) return u;
        } catch (IOException e) {
            Log.i(TAG, "sin files/url, uso " + URL_DEFECTO);
        }
        return URL_DEFECTO;
    }

    private static String sinFragmento(String u) {
        int i = u.indexOf('#');
        return i < 0 ? u : u.substring(0, i);   // el fragmento lleva el token: no va al log
    }

    private static String escapar(String s) {
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
    }

    private boolean mismoOrigen(String otra) {
        String base = sinFragmento(url);
        int fin = base.indexOf('/', base.indexOf("//") + 2);
        String origen = fin < 0 ? base : base.substring(0, fin);
        return otra.startsWith(origen + "/") || otra.equals(origen);
    }

    private class Cliente extends WebViewClient {
        @Override
        public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest req) {
            return !mismoOrigen(req.getUrl().toString());   // kiosco: no se sale del tablero
        }

        @Override
        public void onReceivedError(WebView v, WebResourceRequest req, WebResourceError err) {
            if (req.isForMainFrame()) reintentar(String.valueOf(err.getDescription()));
        }

        @Override
        public void onReceivedHttpError(WebView v, WebResourceRequest req, WebResourceResponse res) {
            if (req.isForMainFrame() && res.getStatusCode() >= 500) reintentar("HTTP " + res.getStatusCode());
        }
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent ev) {
        if (ev.getActionMasked() == MotionEvent.ACTION_DOWN && ev.getX() < ESQUINA_PX && ev.getY() < ESQUINA_PX) {
            long ahora = System.currentTimeMillis();
            if (ahora - primerToque > VENTANA_TOQUES_MS) {
                primerToque = ahora;
                toques = 0;
            }
            if (++toques >= TOQUES_SALIDA) {
                toques = 0;
                startActivity(new Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                return true;
            }
        }
        return super.dispatchTouchEvent(ev);
    }

    @Override
    public void onBackPressed() {
        cargar();   // kiosco: atrás recarga en vez de salir
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        cargar();   // inicio pulsado estando en el tablero, o URL nueva tras instalar.sh
    }

    @Override
    public void onWindowFocusChanged(boolean foco) {
        super.onWindowFocusChanged(foco);
        if (foco) {
            getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    | View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    | View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        web.onResume();
    }

    @Override
    protected void onPause() {
        web.onPause();
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        web.destroy();
        super.onDestroy();
    }
}
