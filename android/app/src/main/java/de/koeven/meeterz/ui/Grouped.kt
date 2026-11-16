package de.koeven.meeterz.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import de.koeven.meeterz.tr

/*
 * Gruppierte Listen wie die iOS-Einstellungen (List mit Sections, Theme.panel als Zeilenfläche, Theme.ink dahinter):
 * Abschnitt mit Überschrift und Fußtext, Zeilen mit Pfeil, Schalter, Auswahlmenü, Stepper oder Aktion.
 */

/** Ganze Seite: Kopfzeile mit Zurück und Titel in der Mitte, darunter scrollbarer Inhalt auf dem Hintergrund */
@Composable
fun GroupedPage(title: String, onBack: () -> Unit, trailing: @Composable () -> Unit = {}, content: @Composable ColumnScope.() -> Unit) {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Box(Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 4.dp)) {
                IconButton(onClick = onBack, modifier = Modifier.align(Alignment.CenterStart)) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, tr("Zurück"), tint = MaterialTheme.colorScheme.primary)
                }
                Text(title, Modifier.align(Alignment.Center).padding(horizontal = 56.dp), style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
                Box(Modifier.align(Alignment.CenterEnd)) { trailing() }
            }
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()).navigationBarsPadding()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
                content = content,
            )
        }
    }
}

/** Abschnitt: Überschrift, Zeilen auf der Fläche (Trennlinien setzt [GroupDivider]), Fußtext */
@Composable
fun Group(header: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        header?.let {
            Text(it, Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Surface(shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surface) {
            Column(Modifier.fillMaxWidth(), content = content)
        }
        footer?.let {
            Text(it, Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
fun GroupDivider() = HorizontalDivider(Modifier.padding(start = 16.dp), color = MaterialTheme.colorScheme.outlineVariant)

@Composable
private fun RowShell(onClick: (() -> Unit)?, icon: ImageVector?, content: @Composable RowScope.() -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        icon?.let {
            Icon(it, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(14.dp))
        }
        content()
    }
}

/** Zeile mit Wert und Pfeil (iOS: NavigationLink mit LabeledContent) */
@Composable
fun NavRow(title: String, value: String? = null, icon: ImageVector? = null, onClick: () -> Unit) = RowShell(onClick, icon) {
    Text(title, Modifier.weight(1f))
    value?.takeIf { it.isNotBlank() }?.let {
        Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(start = 8.dp).weight(1f, fill = false))
    }
    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** Zeile mit Wert ohne Aktion (iOS: LabeledContent) */
@Composable
fun ValueRow(title: String, value: String) = RowShell(null, null) {
    Text(title, Modifier.weight(1f))
    Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** Schalter (iOS: Toggle mit Mint) */
@Composable
fun ToggleRow(title: String, checked: Boolean, subtitle: String? = null, icon: ImageVector? = null, onChange: (Boolean) -> Unit) =
    RowShell({ onChange(!checked) }, icon) {
        Column(Modifier.weight(1f).padding(end = 12.dp)) {
            Text(title)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        Switch(checked, onChange, colors = SwitchDefaults.colors(checkedTrackColor = MaterialTheme.colorScheme.primary))
    }

/** Auswahl als Menü (iOS: Picker im Menüstil) */
@Composable
fun MenuRow(title: String, options: List<String>, selected: Int, icon: ImageVector? = null, onSelect: (Int) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        RowShell({ open = true }, icon) {
            Text(title, Modifier.weight(1f))
            Text(options.getOrElse(selected) { "" }, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        DropdownMenu(open, { open = false }, Modifier.align(Alignment.CenterEnd)) {
            options.forEachIndexed { i, label ->
                DropdownMenuItem(text = { Text(label) }, onClick = { open = false; onSelect(i) },
                    trailingIcon = { if (i == selected) Icon(Icons.Default.Check, null, tint = MaterialTheme.colorScheme.primary) })
            }
        }
    }
}

/** Stepper (iOS: Stepper mit LabeledContent) */
@Composable
fun StepperRow(title: String, value: String, canDecrease: Boolean, canIncrease: Boolean, onDecrease: () -> Unit, onIncrease: () -> Unit) =
    RowShell(null, null) {
        Column(Modifier.weight(1f)) {
            Text(title)
            Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
        }
        Surface(shape = RoundedCornerShape(8.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onDecrease, enabled = canDecrease) { Icon(Icons.Default.Remove, tr("Weniger")) }
                Box(Modifier.width(1.dp).heightIn(min = 20.dp).background(MaterialTheme.colorScheme.outlineVariant))
                IconButton(onClick = onIncrease, enabled = canIncrease) { Icon(Icons.Default.Add, tr("Mehr")) }
            }
        }
    }

/** Aktion als Textzeile (iOS: Button in der Liste); rot = zerstörend */
@Composable
fun ActionRow(title: String, destructive: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) =
    RowShell(if (enabled) onClick else null, null) {
        Text(title, color = when {
            !enabled -> MaterialTheme.colorScheme.onSurfaceVariant
            destructive -> MaterialTheme.colorScheme.error
            else -> MaterialTheme.colorScheme.primary
        })
    }

/** Segmentierte Auswahl (iOS: Picker .segmented) */
@Composable
fun SegmentedRow(options: List<String>, selected: Int, onSelect: (Int) -> Unit) {
    Surface(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), shape = RoundedCornerShape(9.dp),
        color = MaterialTheme.colorScheme.surfaceVariant) {
        Row(Modifier.padding(2.dp)) {
            options.forEachIndexed { i, label ->
                val on = i == selected
                Box(Modifier.weight(1f).heightIn(min = 32.dp)
                    .background(if (on) MaterialTheme.colorScheme.surfaceContainerHighest else Color.Transparent, RoundedCornerShape(7.dp))
                    .clickable { onSelect(i) }, contentAlignment = Alignment.Center) {
                    Text(label, style = MaterialTheme.typography.bodySmall, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal)
                }
            }
        }
    }
}
