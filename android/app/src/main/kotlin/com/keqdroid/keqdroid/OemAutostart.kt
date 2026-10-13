package com.keqdroid.keqdroid

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings

// разрешения Автозапуск в Android нет: состояние снаружи не прочитать, экран каждая прошивка прячет по-своему.
// экраны из библиотеки AutoStarter, realme она не знает, хотя у него та же ColorOS
object OemAutostart {

    private class Vendor(val brands: Set<String>, val screens: List<ComponentName>)

    private val vendors = listOf(
        Vendor(
            setOf("xiaomi", "redmi", "poco"),
            listOf(
                ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity",
                ),
            ),
        ),
        // на свежих ColorOS автозапуск переехал в батарею приложения (dontkillmyapp), старые экраны чужим закрыты
        Vendor(
            setOf("oppo", "realme", "oneplus"),
            listOf(
                ComponentName(
                    "com.coloros.safecenter",
                    "com.coloros.safecenter.permission.startup.StartupAppListActivity",
                ),
                ComponentName(
                    "com.coloros.safecenter",
                    "com.coloros.safecenter.startupapp.StartupAppListActivity",
                ),
                ComponentName(
                    "com.oppo.safe",
                    "com.oppo.safe.permission.startup.StartupAppListActivity",
                ),
                ComponentName(
                    "com.oneplus.security",
                    "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity",
                ),
            ),
        ),
        Vendor(
            setOf("vivo", "iqoo"),
            listOf(
                ComponentName(
                    "com.iqoo.secure",
                    "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
                ),
                ComponentName(
                    "com.vivo.permissionmanager",
                    "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
                ),
                ComponentName(
                    "com.iqoo.secure",
                    "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager",
                ),
            ),
        ),
        Vendor(
            setOf("huawei", "honor"),
            listOf(
                ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                ),
                ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.optimize.process.ProtectActivity",
                ),
            ),
        ),
        Vendor(
            setOf("asus"),
            listOf(
                ComponentName(
                    "com.asus.mobilemanager",
                    "com.asus.mobilemanager.autostart.AutoStartActivity",
                ),
            ),
        ),
    )

    const val KIND_NONE = "none"
    const val KIND_SCREEN = "screen"
    const val KIND_APP_DETAILS = "appDetails"

    private fun vendor(): Vendor? {
        val names = setOf(Build.BRAND.lowercase(), Build.MANUFACTURER.lowercase())
        return vendors.firstOrNull { v -> v.brands.any { it in names } }
    }

    // неэкспортированный экран резолвится, но открывается SecurityException
    private fun screens(context: Context): List<Intent> =
        vendor()?.screens.orEmpty().mapNotNull { screen ->
            val intent = Intent().setComponent(screen).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val info = runCatching { context.packageManager.resolveActivity(intent, 0) }.getOrNull()
            intent.takeIf { info?.activityInfo?.exported == true }
        }

    // в карточке приложения искать придётся самому, и сказать это надо до перехода
    fun kind(context: Context): String = when {
        vendor() == null -> KIND_NONE
        screens(context).isNotEmpty() -> KIND_SCREEN
        else -> KIND_APP_DETAILS
    }

    fun open(context: Context) {
        for (intent in screens(context)) {
            if (runCatching { context.startActivity(intent) }.isSuccess) return
        }
        context.startActivity(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}
