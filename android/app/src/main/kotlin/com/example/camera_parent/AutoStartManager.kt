package com.example.camera_parent

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings

object AutoStartManager {

    fun openAutoStartSettings(context: Context) {

        val manufacturer =
            android.os.Build.MANUFACTURER.lowercase()

        try {

            val intent = Intent()

            when {

                manufacturer.contains("xiaomi") -> {
                    intent.component = ComponentName(
                        "com.miui.securitycenter",
                        "com.miui.permcenter.autostart.AutoStartManagementActivity"
                    )
                }


                manufacturer.contains("huawei") -> {
                    intent.component = ComponentName(
                        "com.huawei.systemmanager",
                        "com.huawei.systemmanager.optimize.process.ProtectActivity"
                    )
                }


                manufacturer.contains("oppo") -> {
                    intent.component = ComponentName(
                        "com.coloros.safecenter",
                        "com.coloros.safecenter.permission.startup.StartupAppListActivity"
                    )
                }


                manufacturer.contains("vivo") -> {
                    intent.component = ComponentName(
                        "com.vivo.permissionmanager",
                        "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"
                    )
                }


                else -> {
                    intent.action =
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS

                    intent.data =
                        Uri.parse(
                            "package:${context.packageName}"
                        )
                }
            }


            intent.flags =
                Intent.FLAG_ACTIVITY_NEW_TASK

            context.startActivity(intent)


        } catch (e: Exception) {

            val fallback =
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                )

            fallback.data =
                Uri.parse(
                    "package:${context.packageName}"
                )

            fallback.flags =
                Intent.FLAG_ACTIVITY_NEW_TASK

            context.startActivity(fallback)
        }
    }
}