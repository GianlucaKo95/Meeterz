package de.koeven.meeterz.ev

import android.util.Log
import de.koeven.meeterz.AppState
import de.koeven.meeterz.data.VehicleStatus
import de.koeven.meeterz.nav.NavigationController
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.abs

/**
 * Laden verfolgen (wie ChargingSession.swift): Sobald das Auto „lädt“ meldet, Fortschritt bis zum Ziel-Akkustand,
 * Ladeleistung und Restzeit. Zwischen den Meldungen wird der Akkustand aus der Ladeleistung hochgerechnet.
 */
object ChargingSession {
    data class View(val percent: Double, val start: Double, val target: Double, val powerKW: Double,
                    val remainingSeconds: Double?, val done: Boolean) {
        val progress get() = if (target > start) ((percent - start) / (target - start)).coerceIn(0.0, 1.0) else 1.0
        /** „⚡ 54 % → 80 % · 18 Min.“ */
        val short get() = if (done) "⚡ ${Math.round(percent)} % – genug geladen"
            else "⚡ ${Math.round(percent)} % → ${Math.round(target)} %" + (remainingSeconds?.let { " · ${maxOf(1, Math.round(it / 60))} Min." } ?: "")
    }

    private val _view = MutableStateFlow<View?>(null)
    /** null = es wird gerade nicht geladen */
    val view: StateFlow<View?> = _view

    /** Zuletzt übernommener Ladeplan – liefert das Ladeziel an der jeweiligen Säule */
    @Volatile var plan: ChargePlanner.Plan? = null

    private var active = false
    private var startPercent = 0.0
    private var reportedPercent = 0.0
    private var reportedAt = 0L
    private var powerKW = 0.0
    private var target = 80.0
    private var chosenByUser = false
    private var announcedDone = false
    private var ticker: Job? = null

    /** Ziel von Hand („Bis 90 %“) – dann nicht mehr automatisch nachführen */
    fun setTarget(percent: Double) { target = percent; chosenByUser = true; announcedDone = false; refresh() }

    /** Aus jeder neuen Live-Meldung */
    fun update(status: VehicleStatus) {
        val soc = status.soc
        if (!EvSettings.enabled || soc == null || status.ageSeconds >= 15 * 60 || status.charging != true) { end(); return }
        if (!active) {
            active = true
            startPercent = soc
            chosenByUser = false
            announcedDone = false
            target = target()
            Log.i("Meeterz", "Laden erkannt: ${soc.toInt()} % → Ziel ${target.toInt()} %")
            ticker = AppState.scope.launch { while (isActive) { delay(5_000); refresh() } }
        } else if (!chosenByUser) {
            // Ladeziel des Autos kann später ankommen oder im Auto geändert werden
            val t = target()
            if (abs(t - target) >= 1) target = t
        }
        reportedPercent = soc
        reportedAt = status.measuredAt
        powerKW = abs(status.powerKw ?: 0.0)
        refresh()
    }

    private fun end() {
        if (!active) return
        active = false
        ticker?.cancel(); ticker = null
        _view.value = null
        Log.i("Meeterz", "Laden beendet bei ${reportedPercent.toInt()} %")
    }

    /** Akkustand jetzt (hochgerechnet seit der letzten Meldung, höchstens 3 Minuten weit) */
    private fun percentNow(): Double {
        val vehicle = EvSettings.vehicle ?: return reportedPercent
        if (powerKW <= 0) return reportedPercent
        val dt = minOf((System.currentTimeMillis() / 1000 - reportedAt).toDouble().coerceAtLeast(0.0), 180.0)
        return minOf(100.0, reportedPercent + powerKW * 0.92 * dt / 3600 / vehicle.battery * 100)
    }

    private fun refresh() {
        if (!active) return
        val percent = percentNow()
        val status = AppState.vehicle.status.value
        // Restzeit des Autos nur, wenn sie sich auf dasselbe Ziel bezieht
        val remaining = status?.liveChargeRemaining?.takeIf { status.carChargeTarget?.let { abs(it - target) < 1 } ?: true }
            ?: EvSettings.vehicle?.takeIf { percent < target }?.let { ChargePlanner.chargeTime(it, percent, target, maxOf(powerKW, 3.0) * 1.05) }
        val done = percent >= target - 0.3
        _view.value = View(percent, startPercent, target, powerKW, remaining, done)
        if (done && !announcedDone) {
            announcedDone = true
            val text = "Genug geladen: ${Math.round(percent)} % – weiter geht's"
            de.koeven.meeterz.live.PushService.show(AppState.appContextOrNull() ?: return, "Meeterz", text)
            NavigationController.announce(text)
        }
    }

    /** Ziel: Abfahrts-% des nächstgelegenen Stopps im übernommenen Plan (bis 1 km), sonst Ladeziel des Autos, sonst 80 % */
    private fun target(): Double {
        val car = AppState.vehicle.status.value?.carChargeTarget
        val here = AppState.lastLocation
        val stop = here?.let { h -> plan?.stops?.minByOrNull { ChargePlanner.distance(it.site.lat, it.site.lng, h.latitude, h.longitude) } }
        if (here != null && stop != null && ChargePlanner.distance(stop.site.lat, stop.site.lng, here.latitude, here.longitude) < 1_000) {
            val planned = minOf(100.0, Math.ceil(stop.departurePercent) + 1)
            return car?.let { minOf(it, planned) } ?: planned
        }
        return car ?: 80.0
    }
}
