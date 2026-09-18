
package com.example.camera_parent

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest

class NetworkMonitor(
    private val context: Context
) {

    private val manager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE)
                as ConnectivityManager

    fun start() {

        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        manager.registerNetworkCallback(
            request,
            object : ConnectivityManager.NetworkCallback() {

                override fun onAvailable(network: Network) {
                    android.util.Log.i(
                        "NetworkMonitor",
                        "NETWORK_AVAILABLE"
                    )
                }

                override fun onLost(network: Network) {
                    android.util.Log.w(
                        "NetworkMonitor",
                        "NETWORK_LOST"
                    )
                }
            }
        )
    }
}
