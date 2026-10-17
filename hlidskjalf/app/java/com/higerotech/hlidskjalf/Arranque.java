package com.higerotech.hlidskjalf;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Abre el tablero al encender la tablet. Si Hlidskjalf ya es la pantalla de inicio, Android lo
 * abre por su cuenta y esto no hace nada nuevo (la actividad es singleTask); si no lo es, cubre
 * el caso tras un corte de luz.
 */
public class Arranque extends BroadcastReceiver {
    @Override
    public void onReceive(Context contexto, Intent intent) {
        if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
            contexto.startActivity(new Intent(contexto, Tablero.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        }
    }
}
