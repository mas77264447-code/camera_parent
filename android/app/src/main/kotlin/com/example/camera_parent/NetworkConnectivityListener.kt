
package com.example.camera_parent

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper

class NetworkConnectivityListener(
    private val context: Context,
    private val callback: (Boolean) -> Unit
) {

    private val connectivity =
        context.getSystemService(Context.CONNECTIVITY_SERVICE)
                as ConnectivityManager

    // ✅ إصلاح: onAvailable/onLost من ConnectivityManager تُستدعى على thread
    // خلفي داخلي (ConnectivityThread)، وليس الـ main thread. استدعاء
    // MethodChannel.invokeMethod من أي thread غير الـ main يسبب:
    // "Methods marked with @UiThread must be executed on the main thread".
    // نستخدم Handler(Looper.getMainLooper()) لتمرير القيمة إلى الـ callback
    // على الـ main thread قبل ما توصل لـ ConnectivityChannel.
    private val mainHandler = Handler(Looper.getMainLooper())

    fun start() {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        connectivity.registerNetworkCallback(
            request,
            object : ConnectivityManager.NetworkCallback() {

                override fun onAvailable(network: Network) {
                    mainHandler.post { callback(true) }
                }

                override fun onLost(network: Network) {
                    mainHandler.post { callback(false) }
                }
            }
        )
    }
}
