package dev.openmaps.open_maps

import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        preferHighRefreshRate()
    }

    /// Ask for the display's fastest mode at the current resolution.
    ///
    /// Android runs app content it knows nothing about at the "normal"
    /// frame-rate category — 60 Hz — so on a 90/120 Hz phone the map
    /// scrolled at half the rate of every other app, which reads as lag
    /// even with 3 ms frames. This is a vote, not a command: the system
    /// still arbitrates (user's screen setting, battery saver, thermals),
    /// and LTPO panels still drop to low rates when the screen is static.
    private fun preferHighRefreshRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val display =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display
            else @Suppress("DEPRECATION") windowManager.defaultDisplay
        val current = display?.mode ?: return
        val best = display.supportedModes
            .filter {
                it.physicalWidth == current.physicalWidth &&
                    it.physicalHeight == current.physicalHeight
            }
            .maxByOrNull { it.refreshRate } ?: return
        // Vote even when the active mode is already the fastest: without a
        // vote the system is free to drop this window to 60 Hz later.
        window.attributes = window.attributes.apply {
            preferredDisplayModeId = best.modeId
        }
    }
}
