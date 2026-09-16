package com.example.camera_parent

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.util.Log

class NetworkMonitor(private val context: Context) {

    private val manager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private var started = false

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            Log.i(TAG, "NETWORK_AVAILABLE")
            ConnectivityChannel.sendNetworkState(true)
        }

        override fun onLost(network: Network) {
            // A lost callback can be followed by another active network.
            // Recalculate the overall state instead of blindly reporting offline.
            val online = hasInternet()
            Log.i(TAG, "NETWORK_LOST; online=$online")
            ConnectivityChannel.sendNetworkState(online)
        }

        override fun onCapabilitiesChanged(
            network: Network,
            capabilities: NetworkCapabilities
        ) {
            val online = capabilities.hasCapability(
                NetworkCapabilities.NET_CAPABILITY_INTERNET
            ) && capabilities.hasCapability(
                NetworkCapabilities.NET_CAPABILITY_VALIDATED
            )
            ConnectivityChannel.sendNetworkState(online)
        }
    }

    fun start() {
        if (started) return
        started = true

        try {
            manager.registerNetworkCallback(
                NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .build(),
                callback
            )
            ConnectivityChannel.sendNetworkState(hasInternet())
        } catch (e: Exception) {
            started = false
            Log.w(TAG, "Unable to register network callback", e)
        }
    }

    fun stop() {
        if (!started) return
        try {
            manager.unregisterNetworkCallback(callback)
        } catch (_: Exception) {
        } finally {
            started = false
        }
    }

    private fun hasInternet(): Boolean {
        val network = manager.activeNetwork ?: return false
        val capabilities = manager.getNetworkCapabilities(network) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    companion object {
        private const val TAG = "NetworkMonitor"
    }
}
