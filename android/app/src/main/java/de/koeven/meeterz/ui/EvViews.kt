package de.koeven.meeterz.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.mapbox.navigation.base.route.NavigationRoute
import de.koeven.meeterz.ev.ChargePlanner
import de.koeven.meeterz.ev.EvData
import de.koeven.meeterz.ev.EvSettings
import de.koeven.meeterz.ev.EvVehicle
import kotlinx.coroutines.launch

/** Ladeplan in der Routenvorschau (wie ChargePlanCard auf iOS) */
@Composable
fun ChargePlanSection(route: NavigationRoute, adopted: ChargePlanner.Plan?, onAdopt: suspend (ChargePlanner.Plan) -> Unit) {
    val version by EvSettings.version.collectAsState()
    if (!EvSettings.enabled || EvSettings.vehicle == null) return
    var outcome by remember(route.id) { mutableStateOf<ChargePlanner.Outcome?>(null) }
    var loading by remember(route.id) { mutableStateOf(true) }
    var adopting by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(route.id, version, adopted) {
        if (adopted != null) return@LaunchedEffect
        loading = true
        outcome = EvSettings.plan(route)
        loading = false
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        HorizontalDivider()
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Ladeplan", fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            val soc = Math.round(EvSettings.chargePercent)
            Text(if (EvSettings.liveSoc != null) "Start $soc % (live)" else "Start $soc %", style = MaterialTheme.typography.bodySmall)
        }
        if (adopted != null) {
            Text(adopted.summary, fontWeight = FontWeight.SemiBold)
            Stops(adopted)
            Text("✓ Ladestopps sind in der Route", color = MeeterzColors.mintLight, style = MaterialTheme.typography.bodySmall)
        } else when (val o = outcome) {
            null -> if (loading) Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.padding(end = 8.dp).size(16.dp), strokeWidth = 2.dp); Text("Berechne …")
            }
            is ChargePlanner.Outcome.Unreachable -> Text(
                "Mit den Ladesäulen entlang der Route nicht planbar (Reichweite ca. ${o.reachKm.toInt()} km). " +
                    "Meeterz kennt Schnelllader in Deutschland, den Nachbarländern und Italien.",
                style = MaterialTheme.typography.bodySmall)
            is ChargePlanner.Outcome.Planned -> {
                Text(o.plan.summary, fontWeight = FontWeight.SemiBold)
                if (!o.plan.direct) {
                    Stops(o.plan)
                    FilledTonalButton(enabled = !adopting, onClick = {
                        adopting = true
                        scope.launch { onAdopt(o.plan); adopting = false }
                    }) { Text(if (adopting) "Übernehme …" else "Ladestopps übernehmen") }
                }
            }
        }
        Text(EvData.ATTRIBUTION, style = MaterialTheme.typography.labelSmall)
    }
}

@Composable
private fun Stops(plan: ChargePlanner.Plan) {
    for (s in plan.stops) {
        Row {
            Text("${(s.distanceFromStart / 1000).toInt()} km", Modifier.width(56.dp), style = MaterialTheme.typography.bodySmall)
            Column {
                Text(s.site.title, fontWeight = FontWeight.SemiBold)
                Text("${ChargeSiteText.power(s.site)} · ${Math.round(s.arrivalPercent)} → ${Math.round(s.departurePercent)} % · ${Math.round(s.chargeTime / 60)} Min.",
                    style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

object ChargeSiteText {
    fun power(site: de.koeven.meeterz.ev.ChargeSite) = if (site.powerKnown) "${site.maxKW.toInt()} kW" else "Leistung unbekannt"
}

/** E-Auto einstellen: an/aus, Fahrzeug aus dem Katalog, Ziel-Akkustand, Akkustand ohne Live-Daten */
@Composable
fun EvSettingsDialog(onClose: () -> Unit) {
    var enabled by remember { mutableStateOf(EvSettings.enabled) }
    var vehicle by remember { mutableStateOf(EvSettings.vehicle) }
    var arrival by remember { mutableStateOf(EvSettings.arrivalPercent.toFloat()) }
    var minCharger by remember { mutableStateOf(EvSettings.minAtChargerPercent.toFloat()) }
    var manual by remember { mutableStateOf(EvSettings.manualPercent.toFloat()) }
    var search by remember { mutableStateOf("") }
    var picking by remember { mutableStateOf(EvSettings.vehicle == null) }
    val all = remember { EvSettings.vehicles() }

    AlertDialog(
        onDismissRequest = onClose,
        confirmButton = {
            TextButton(onClick = {
                EvSettings.enabled = enabled; EvSettings.vehicle = vehicle
                EvSettings.arrivalPercent = arrival.toDouble(); EvSettings.minAtChargerPercent = minCharger.toDouble()
                EvSettings.manualPercent = manual.toDouble()
                onClose()
            }) { Text("Fertig") }
        },
        dismissButton = { TextButton(onClick = onClose) { Text("Abbrechen") } },
        title = { Text("E-Auto") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Ladeplanung", Modifier.weight(1f)); Switch(enabled, { enabled = it })
                }
                if (enabled) {
                    if (picking || vehicle == null) {
                        OutlinedTextField(search, { search = it }, label = { Text("Fahrzeug suchen") }, singleLine = true)
                        val matches = all.filter { v -> search.split(" ").filter { it.isNotBlank() }.all { v.fullName.contains(it, ignoreCase = true) } }
                        LazyColumn(Modifier.heightIn(max = 260.dp)) {
                            items(matches.take(60), key = EvVehicle::id) { v ->
                                Column(Modifier.fillMaxWidth().clickable { vehicle = v; picking = false }.padding(vertical = 8.dp)) {
                                    Text(v.fullName, fontWeight = FontWeight.SemiBold)
                                    Text("${v.battery} kWh · ${v.consumption} kWh/100 km" + (v.dcMax?.let { " · ${it.toInt()} kW DC" } ?: ""),
                                        style = MaterialTheme.typography.bodySmall)
                                }
                            }
                        }
                    } else {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(vehicle!!.fullName, Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
                            TextButton(onClick = { picking = true }) { Text("Ändern") }
                        }
                    }
                    Text("Ankunft mit mindestens ${arrival.toInt()} %")
                    Slider(arrival, { arrival = Math.round(it).toFloat() }, valueRange = 5f..60f)
                    Text("An der Ladesäule mindestens ${minCharger.toInt()} %")
                    Slider(minCharger, { minCharger = Math.round(it).toFloat() }, valueRange = 3f..30f)
                    if (EvSettings.liveSoc == null) {
                        Text("Akkustand jetzt ${manual.toInt()} % (ohne Live-Daten vom Auto)")
                        Slider(manual, { manual = Math.round(it).toFloat() }, valueRange = 5f..100f)
                    } else {
                        Text("Akkustand ${Math.round(EvSettings.liveSoc!!)} % live vom Auto", style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        },
    )
}
