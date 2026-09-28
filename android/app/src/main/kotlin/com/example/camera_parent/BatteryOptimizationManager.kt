package com.example.camera_parent

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings


object BatteryOptimizationManager {

    fun requestDisable(context: Context) {

        val powerManager =
            context.getSystemService(Context.POWER_SERVICE)
                    as PowerManager


        val packageName = context.packageName


        if (!powerManager.isIgnoringBatteryOptimizations(packageName)) {

            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
            )

            intent.data = Uri.parse(
                "package:$packageName"
            )

            intent.flags =
                Intent.FLAG_ACTIVITY_NEW_TASK


            context.startActivity(intent)
        }
    }
}