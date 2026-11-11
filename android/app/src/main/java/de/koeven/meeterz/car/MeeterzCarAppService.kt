package de.koeven.meeterz.car

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import androidx.car.app.CarAppService
import androidx.car.app.CarToast
import androidx.car.app.AppManager
import androidx.car.app.model.Action
import androidx.car.app.model.Alert
import androidx.car.app.model.CarText
import androidx.car.app.versioning.CarAppApiLevels
import de.koeven.meeterz.ev.ChargeMonitor
import androidx.car.app.Screen
import androidx.car.app.ScreenManager
import androidx.car.app.Session
import androidx.car.app.validation.HostValidator
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import com.mapbox.maps.MapInitOptions
import com.mapbox.maps.extension.androidauto.MapboxCarMap
import com.mapbox.navigation.core.lifecycle.MapboxNavigationApp
import com.mapbox.navigation.ui.androidauto.map.MapboxCarMapLoader
import de.koeven.meeterz.AppState
import de.koeven.meeterz.Diag
import de.koeven.meeterz.nav.NavigationController
import kotlinx.coroutines.launch

/** Android Auto (Gegenstück zu CarPlay) */
class MeeterzCarAppService : CarAppService() {
    // ponytail: alle Hosts zulassen, bis die App bei Google eingereicht wird – dann HostValidator mit Googles Liste
    override fun createHostValidator() = HostValidator.ALLOW_ALL_HOSTS_VALIDATOR

    override fun onCreateSession(): Session = MeeterzCarSession()
}

/**
 * Eigene Bildschirme (statt Mapbox' fertiger), damit die Ansagen mit unseren Regeln laufen – Mapbox' eigene
 * Sprachausgabe käme sonst doppelt – und damit Freunde auf der Karte und im Menü erscheinen.
 * Karte, Pfeil, Routenlinie, Kamera und Abbiegeanzeige kommen weiter aus Mapbox' Android-Auto-Bausteinen.
 */
class MeeterzCarSession : Session() {
    private fun showSuggestion(sg: ChargeMonitor.Suggestion) {
        val plan = sg.plan
        if (carContext.carAppApiLevel < CarAppApiLevels.LEVEL_5 || plan == null) {
            CarToast.makeText(carContext, "${sg.title} – ${sg.subtitle}", CarToast.LENGTH_LONG).show()
            NavigationController.announce(sg.title)
            return
        }
        val alert = Alert.Builder(1, CarText.create(sg.title), 20_000)
            .setSubtitle(CarText.create(sg.subtitle))
            .addAction(Action.Builder().setTitle("Übernehmen").setOnClickListener {
                carContext.getCarService(AppManager::class.java).dismissAlert(1)
                AppState.scope.launch { ChargeMonitor.adopt(carContext, plan) }
            }.build())
            .addAction(Action.Builder().setTitle("Nein").setOnClickListener {
                carContext.getCarService(AppManager::class.java).dismissAlert(1)
            }.build())
            .build()
        carContext.getCarService(AppManager::class.java).showAlert(alert)
        NavigationController.announce(sg.title)
    }

    private var navigationEndedAt = 0L

    /** „Fährt Annika bei dir mit?“ – Ja blendet sie für die Fahrt aus. Nicht während/kurz nach der Führung (wie CarPlay). */
    private fun askPassenger(f: de.koeven.meeterz.data.FriendRow): Boolean {
        if (NavigationController.guidance.value != null || System.currentTimeMillis() - navigationEndedAt < 60_000) return false
        if (carContext.carAppApiLevel < CarAppApiLevels.LEVEL_5) return false
        Diag.log("Mitfahrer-Frage: ${f.displayName}")
        val manager = carContext.getCarService(AppManager::class.java)
        val alert = Alert.Builder(2, CarText.create("Fährt ${f.firstName} bei dir mit?"), 20_000)
            .setSubtitle(CarText.create("Dann blende ich ${f.firstName} für diese Fahrt aus"))
            .addAction(Action.Builder().setTitle("Ja, ausblenden").setOnClickListener {
                manager.dismissAlert(2); de.koeven.meeterz.social.Passengers.setRiding(f.friendId, true)
            }.build())
            .addAction(Action.Builder().setTitle("Nein").setOnClickListener { manager.dismissAlert(2) }.build())
            .build()
        manager.showAlert(alert)
        return true
    }

    val carMap = MapboxCarMap()
    private val mapLoader = MapboxCarMapLoader()

    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onCreate(owner: LifecycleOwner) {
                MapboxNavigationApp.attach(owner)
                carMap.setup(carContext, MapInitOptions(carContext))
                carMap.registerObserver(mapLoader)
                // Freie Fahrt: Standort auf der Straße auch ohne Route (wie CarPlay)
                if (ContextCompat.checkSelfPermission(carContext, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) {
                    @Suppress("MissingPermission")
                    MapboxNavigationApp.current()?.startTripSession()
                }
            }

            override fun onDestroy(owner: LifecycleOwner) {
                de.koeven.meeterz.social.Passengers.reset()   // Mitfahrer gelten bis zum Trennen (wie CarPlay)
                carMap.unregisterObserver(mapLoader)
                MapboxNavigationApp.detach(owner)
            }
        })
    }

    override fun onCreateScreen(intent: Intent): Screen {
        // Führung beginnt oder endet (auch vom Handy aus): Bildschirm wechseln – erst nach dem Start-Bildschirm
        lifecycleScope.launch {
            var guidingShown = false
            NavigationController.guidance.collect { g ->
                val guiding = g != null
                if (guiding == guidingShown) return@collect
                guidingShown = guiding
                if (!guiding) { navigationEndedAt = System.currentTimeMillis(); de.koeven.meeterz.social.Convoy.reset() }
                val sm = carContext.getCarService(ScreenManager::class.java)
                sm.popToRoot()
                if (guiding) sm.push(GuidanceScreen(carContext, carMap))
            }
        }
        // Nachricht eines Freundes: kurz anzeigen und vorlesen (wie CarPlay)
        lifecycleScope.launch {
            AppState.messages.received.collect { m ->
                CarToast.makeText(carContext, "${m.firstName}: ${m.body}", CarToast.LENGTH_LONG).show()
                // Automatische Verspätung: kam sie gerade schon als Moment „verspätet sich“, nicht noch einmal vorlesen
                if (m.automatic) {
                    if (de.koeven.meeterz.sound.SoundMoments.lateRecentlyNotified(m.otherId)) return@collect
                    de.koeven.meeterz.sound.SoundMoments.noteLateNotified(m.otherId)
                }
                NavigationController.announce("${m.firstName} schreibt: ${m.body}")
            }
        }
        // Sound-Pack-Momente: kurzer Hinweis (CarPlay: friendNotice)
        lifecycleScope.launch {
            de.koeven.meeterz.sound.SoundMoments.notices.collect { n -> CarToast.makeText(carContext, n.text, CarToast.LENGTH_LONG).show() }
        }
        // Alle 30 s (wie der CarPlay-Takt): Mitfahrer, „fährt auch hierher“, Konvoi
        lifecycleScope.launch {
            while (true) {
                kotlinx.coroutines.delay(30_000)
                de.koeven.meeterz.social.Passengers.check { askPassenger(it) }
                de.koeven.meeterz.social.Convoy.announceHeadingHere { title, subtitle, _ ->
                    CarToast.makeText(carContext, "$title – $subtitle", CarToast.LENGTH_LONG).show()
                }
                de.koeven.meeterz.social.Convoy.check { text, _ -> CarToast.makeText(carContext, text, CarToast.LENGTH_LONG).show() }
            }
        }
        // Neuer Ladeplan unterwegs: Hinweis mit „Übernehmen“ (CarPlay: Navigationshinweis)
        lifecycleScope.launch {
            ChargeMonitor.suggestions.collect { sg -> showSuggestion(sg) }
        }
        return FreeDriveScreen(carContext, carMap)
    }
}
