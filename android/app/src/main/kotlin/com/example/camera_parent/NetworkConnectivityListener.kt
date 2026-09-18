
package com.example.camera_parent

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest

class NetworkConnectivityListener(
    private val context: Context,
    private val callback: (Boolean) -> Unit
) {

    private val connectivity =
        context.getSystemService(Context.CONNECTIVITY_SERVICE)
                as ConnectivityManager

    fun start() {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        connectivity.registerNetworkCallback(
            request,
            object : ConnectivityManager.NetworkCallback() {

                override fun onAvailable(network: Network) {
                    callback(true)
                }

                override fun onLost(network: Network) {
                    callback(false)
                }
            }
        )
    }
}
