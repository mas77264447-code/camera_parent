package com.example.camera_parent

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * يراقب "الشبكة الافتراضية" فقط (وليس كل شبكة).
 *
 * المشكلة السابقة: registerNetworkCallback يُبلّغ عن كل شبكة على حدة، فانقطاع
 * Wi‑Fi مع بقاء البيانات يُعتبر "لا إنترنت"، ولا يصل حدث عودة عند الانتقال.
 * الآن: onAvailable = تغيّرت/عادت الشبكة الافتراضية، و onLost فقط إذا فُقدت
 * الشبكة الحالية فعلاً ولم يبقَ بديل.
 */
class NetworkConnectivityListener(
    private val context: Context,
    private val callback: (Boolean) -> Unit
) {

    private val connectivity =
        context.getSystemService(Context.CONNECTIVITY_SERVICE)
                as ConnectivityManager

    // onAvailable/onLost تأتي من thread خلفي؛ MethodChannel يحتاج main thread.
    private val mainHandler = Handler(Looper.getMainLooper())

    private var current: Network? = null

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {

        override fun onAvailable(network: Network) {
            current = network
            mainHandler.post { callback(true) }
        }

        override fun onLost(network: Network) {
            if (network == current) {
                current = null
                mainHandler.post { callback(false) }
            }
        }
    }

    fun start() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            connectivity.registerDefaultNetworkCallback(networkCallback)
        } else {
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            connectivity.registerNetworkCallback(request, networkCallback)
        }
    }
}
