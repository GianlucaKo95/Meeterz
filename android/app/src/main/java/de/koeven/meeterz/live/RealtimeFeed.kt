package de.koeven.meeterz.live

import de.koeven.meeterz.Diag
import de.koeven.meeterz.data.Backend
import io.github.jan.supabase.realtime.PostgresAction
import io.github.jan.supabase.realtime.RealtimeChannel
import io.github.jan.supabase.realtime.channel
import io.github.jan.supabase.realtime.postgresChangeFlow
import io.github.jan.supabase.realtime.realtime
import io.github.jan.supabase.postgrest.query.filter.FilterOperator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Live-Änderungen einer Tabelle, die nach einem Abbruch wiederkommen (wie RealtimeFeed.swift): Schließt der Server
 * den Kanal, neu abonnieren und nach jeder Wiederverbindung einmal alles laden (verpasste Änderungen).
 */
class RealtimeFeed(
    private val scope: CoroutineScope,
    private val topic: String,
    private val table: String,
    private val filterColumn: String? = null,
    private val filterValue: String? = null,
    private val onChange: suspend () -> Unit,
) {
    private var channel: RealtimeChannel? = null
    private var jobs: List<Job> = emptyList()
    private var wanted = false

    fun start() { wanted = true; scope.launch { connect() } }

    fun stop() { wanted = false; scope.launch { teardown() } }

    private suspend fun connect() {
        if (!wanted || channel != null) return
        val ch = Backend.client.channel(topic)
        val changes = ch.postgresChangeFlow<PostgresAction>(schema = "public") {
            table = this@RealtimeFeed.table
            if (filterColumn != null && filterValue != null) filter(filterColumn, FilterOperator.EQ, filterValue)
        }
        channel = ch
        jobs = listOf(
            scope.launch { changes.collect { onChange() } },
            scope.launch {
                var joined = false
                ch.status.collect { status ->
                    when (status) {
                        RealtimeChannel.Status.SUBSCRIBED -> {
                            if (joined) { Diag.log("Live-Verbindung $topic wieder da"); onChange() }
                            joined = true
                        }
                        RealtimeChannel.Status.UNSUBSCRIBED -> if (joined) {
                            Diag.log("Live-Verbindung $topic vom Server beendet – verbinde neu")
                            joined = false
                            scope.launch { teardown(); delay(3_000); connect() }
                        }
                        else -> Unit
                    }
                }
            },
        )
        runCatching { ch.subscribe() }.onFailure { Diag.log("Live-Verbindung $topic: ${it.message}") }
        onChange()   // Anfangsstand
    }

    private suspend fun teardown() {
        jobs.forEach { it.cancel() }; jobs = emptyList()
        channel?.let { runCatching { Backend.client.realtime.removeChannel(it) } }
        channel = null
    }
}
