package de.koeven.meeterz

import de.koeven.meeterz.nav.Announcer
import de.koeven.meeterz.nav.ContinueInstructions
import de.koeven.meeterz.nav.Direction
import de.koeven.meeterz.nav.FinalTurn
import de.koeven.meeterz.nav.LandmarkInstructions
import de.koeven.meeterz.nav.LegState
import de.koeven.meeterz.nav.ManeuverType
import de.koeven.meeterz.nav.MotorwayDirection
import de.koeven.meeterz.nav.MotorwayPhrases
import de.koeven.meeterz.nav.RoadNames
import de.koeven.meeterz.nav.Step
import de.koeven.meeterz.nav.StepAnnouncements
import de.koeven.meeterz.nav.ThenInstructions
import de.koeven.meeterz.nav.Voice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Dieselben Fälle wie MeeterzTests (RoadNamesTests.swift, LandmarkInstructionsTests.swift) */
class AnnouncementsTest {
    @Test fun dropsCodeNextToName() {
        assertEquals("Rechts abbiegen auf Hauptstraße", RoadNames.remove("L 91", "Rechts abbiegen auf Hauptstraße/L 91"))
        assertEquals("Rechts abbiegen auf Hauptstraße", RoadNames.remove("L 91", "Rechts abbiegen auf L 91/Hauptstraße"))
        assertEquals("Links abbiegen auf Hauptstraße.", RoadNames.remove("L 91", "Links abbiegen auf Hauptstraße (L 91)."))
        assertEquals("Weiter auf Hauptstraße", RoadNames.remove("L 91", "Weiter auf Hauptstraße, L91"))
        assertEquals("Weiter auf L 91", RoadNames.remove("L 91", "Weiter auf L 91"))
        assertEquals("Rechts auf Am Wehrhahn abbiegen.", RoadNames.remove("L 392", "Rechts auf Am Wehrhahn, L 392 abbiegen."))
    }

    @Test fun removesThenClause() {
        assertEquals("Rechts abbiegen.", ThenInstructions.withoutThen("Rechts abbiegen, dann links abbiegen."))
        assertEquals("In 200 Metern rechts abbiegen auf Hauptstraße", ThenInstructions.withoutThen("In 200 Metern rechts abbiegen auf Hauptstraße, dann links abbiegen"))
        assertEquals("Rechts auf Am Wehrhahn abbiegen.", ThenInstructions.withoutThen("Rechts auf Am Wehrhahn abbiegen. Dann Rechts abbiegen."))
        assertEquals("Links auf Aki-Schmidt-Platz abbiegen.", ThenInstructions.withoutThen("Links auf Aki-Schmidt-Platz abbiegen. Dann, in 20 Metern, Links abbiegen."))
    }

    @Test fun motorwayDirection() {
        assertEquals("Rechts halten auf die Ausfahrt 13, Richtung Krefeld. Dann Rechts halten auf A 57.",
            MotorwayDirection.insert("Richtung Krefeld", "Rechts halten auf die Ausfahrt 13. Dann Rechts halten auf A 57."))
        assertEquals("In 3 Kilometern Rechts halten auf A 3, Richtung Köln.", MotorwayDirection.insert("Richtung Köln", "In 3 Kilometern Rechts halten auf A 3."))
        assertEquals(listOf("Duisburg-Baerl"), MotorwayDirection.joinFragments(listOf("Duisburg", "-Baerl")))
        assertEquals(listOf("Dortmund", "Oberhausen"), MotorwayDirection.joinFragments(listOf("Dortmund", " Oberhausen")))
        assertEquals(listOf("Duisburg-Baerl", "Duisburg-Homberg", "Moers-Meerbeck"),
            MotorwayDirection.joinFragments(listOf("Duisburg", "-Baerl", "-Homberg", "Moers-Meerbeck")))
        assertEquals("In 800 Metern An der Ausfahrt 3 abfahren in Richtung Duisburg-Baerl.",
            MotorwayDirection.repairFragments("In 800 Metern An der Ausfahrt 3 abfahren in Richtung Duisburg, -Baerl."))
        assertEquals("Richtung Dortmund, Oberhausen.", MotorwayDirection.repairFragments("Richtung Dortmund, Oberhausen."))
        assertEquals("In 800 Metern Auf A 3 in Richtung Arnhem über die Ausfahrt 8 abfahren.",
            MotorwayDirection.firstTargetOnly("In 800 Metern Auf A 3 in Richtung Arnhem, Hannover über die Ausfahrt 8 abfahren."))
        assertEquals("In 800 Metern An der Ausfahrt 3 abfahren in Richtung Duisburg-Baerl.",
            MotorwayDirection.firstTargetOnly("In 800 Metern An der Ausfahrt 3 abfahren in Richtung Duisburg, -Baerl, -Homberg."))
        assertEquals("In Richtung B 7 nach Rechts abbiegen.", MotorwayDirection.firstTargetOnly("In Richtung B 7, A 52 nach Rechts abbiegen."))
        assertEquals("In 800 Metern An der Ausfahrt 8 abfahren.",
            MotorwayDirection.shortExit(MotorwayDirection.withoutDirection("In 800 Metern Auf A 57 in Richtung Köln, Krefeld über die Ausfahrt 8 abfahren.")))
        assertEquals("In 800 Metern An der Ausfahrt 3 abfahren.", MotorwayDirection.withoutDirection("In 800 Metern An der Ausfahrt 3 abfahren in Richtung Duisburg, -Baerl."))
        assertEquals("Rechts halten auf A 42. Dann Rechts halten auf A 42.",
            MotorwayDirection.withoutDirection("Rechts halten auf A 42 in Richtung Dortmund, Oberhausen. Dann Rechts halten auf A 42."))
    }

    @Test fun onRampPhrase() {
        assertEquals("In 500 Metern rechts auf die Auffahrt A 42 Richtung Dortmund fahren.",
            MotorwayPhrases.phrase("In 500 Metern Auf die Auffahrt nach rechts auf A 42 abfahren.", "rechts", "A 42", listOf("Dortmund")))
        assertEquals("Rechts auf die Auffahrt A 42 fahren. Dann Links halten.",
            MotorwayPhrases.phrase("Auf die Auffahrt nach rechts auf A 42 abfahren. Dann Links halten.", "rechts", "A 42", emptyList()))
        assertEquals("In 1,5 Kilometern auf die Auffahrt A 3 Richtung Köln fahren.",
            MotorwayPhrases.phrase("In 1,5 Kilometern Auf die Auffahrt auf A 3 abfahren.", null, "A 3", listOf("Köln", "Oberhausen")))
        assertEquals("Rechts auf die Auffahrt A 40 fahren.", MotorwayPhrases.phrase("Auf die Auffahrt A 40 abbiegen.", "rechts", "A 40", listOf("A 40")))
    }

    @Test fun continueInstructions() {
        assertEquals("In 800 Metern rechts auf Hafenstraße abbiegen.", ContinueInstructions.rewrite("800 Meter weiter der Route folgen.", "Rechts auf Hafenstraße abbiegen."))
        assertEquals("In einem Kilometer rechts abbiegen.", ContinueInstructions.rewrite("einen Kilometer weiter auf L 140, dann rechts abbiegen.", "Rechts abbiegen."))
        assertEquals("In 1,5 Kilometern an der Ausfahrt abfahren.", ContinueInstructions.rewrite("1,5 Kilometer weiter der Route folgen.", "An der Ausfahrt abfahren."))
        assertEquals("In 8 Kilometern rechts auf Ruhrorter Straße abbiegen.",
            ContinueInstructions.rewrite("8 Kilometer weiter der Route folgen.", "Rechts auf Ruhrorter Straße abbiegen. Dann Rechts abbiegen."))
        assertNull(ContinueInstructions.rewrite("Rechts abbiegen.", "Rechts abbiegen."))
        assertNull(ContinueInstructions.rewrite("800 Meter weiter der Route folgen.", "In 100 Metern rechts abbiegen."))
    }

    @Test fun europeanCodes() {
        assertEquals("Auf A 3 fahren", RoadNames.dropEuropeanCodes("Auf A 3/E 35 fahren", emptyList()))
        assertEquals("Rechts halten auf A 3 Richtung Köln", RoadNames.dropEuropeanCodes("Rechts halten auf A 3, E 35 Richtung Köln", emptyList()))
        assertEquals("7 Kilometer weiter auf der A 3 fahren.", RoadNames.dropEuropeanCodes("7 Kilometer weiter auf der E 35 fahren.", listOf("A 3")))
        assertEquals("Auf E 45 fahren", RoadNames.dropEuropeanCodes("Auf E 45 fahren", emptyList()))
        assertEquals("A 3", RoadNames.preferredCode(listOf("E 35", "A 3")))
    }

    @Test fun finalTurn() {
        assertEquals("Jetzt rechts abbiegen.", FinalTurn.short("rechts", "An der nächsten Ampel rechts abbiegen auf Hafenstraße"))
        assertEquals("Jetzt rechts abbiegen, dann rechts abbiegen.", FinalTurn.short("rechts", "Am Ende der Straße rechts abbiegen auf Ruhrorter Straße, dann rechts abbiegen"))
        assertEquals("Jetzt links abbiegen, dann rechts abbiegen.", FinalTurn.short("links", "Links auf Bergiusstraße abbiegen. Dann Rechts abbiegen."))
    }

    @Test fun streetOnlyOnce() {
        assertEquals("Rechts abbiegen.", StepAnnouncements.withoutStreet("Rechts auf Friedensstraße abbiegen.", "Friedensstraße", null))
        assertEquals("An der nächsten Ampel links abbiegen", StepAnnouncements.withoutStreet("An der nächsten Ampel links abbiegen auf Parkstraße", "Parkstraße", null))
        assertEquals("In 400 Metern Links abbiegen.", StepAnnouncements.withoutStreet("In 400 Metern Links auf L 473 abbiegen.", "Charlottering", "L 473"))
        assertEquals("Links abbiegen.", StepAnnouncements.withoutStreet("Links auf L 473, Charlottering abbiegen.", "Charlottering", "L 473"))
        assertEquals("Rechts halten auf A 42.", StepAnnouncements.withoutStreet("Rechts halten auf A 42.", null, "A 42"))
    }

    @Test fun landmarkPhrases() {
        assertEquals("An der nächsten Ampel rechts abbiegen", LandmarkInstructions.phrase(LandmarkInstructions.Landmark.TRAFFIC_LIGHT, 1, "rechts", null))
        assertEquals("An der zweiten Ampel links abbiegen auf Hauptstraße", LandmarkInstructions.phrase(LandmarkInstructions.Landmark.TRAFFIC_LIGHT, 2, "links", "Hauptstraße"))
        assertEquals("Am zweiten Stoppschild links abbiegen", LandmarkInstructions.phrase(LandmarkInstructions.Landmark.STOP_SIGN, 2, "links", null))
        assertNull(LandmarkInstructions.phrase(LandmarkInstructions.Landmark.TRAFFIC_LIGHT, 4, "rechts", null))
    }

    // Ganzer Ablauf mit kleinen Routen

    private fun waldstrasse(): List<Step> = listOf(
        Step(ManeuverType.TURN, Direction.RIGHT, distance = 900.0, names = listOf("Grafschafter Straße"),
            voice = listOf(Voice(880.0, "800 Meter weiter der Route folgen."), Voice(400.0, "In 400 Metern Links auf Waldstraße abbiegen."), Voice(90.0, "Links auf Waldstraße abbiegen."))),
        Step(ManeuverType.TURN, Direction.LEFT, distance = 300.0, names = listOf("Waldstraße"), maneuverLat = 51.5, maneuverLng = 6.7),
        Step(ManeuverType.ARRIVE),
    )

    @Test fun shortStepSkipsMiddleAndShortensLast() {
        val steps = waldstrasse()
        val a = Announcer()
        val leg = { remaining: Double -> LegState(steps, 0, remaining) }
        assertEquals(Announcer.Result.Speak("In 800 Metern links auf Waldstraße abbiegen."), a.process(steps[0].voice[0], leg(880.0)))
        assertTrue(a.process(steps[0].voice[1], leg(400.0)) is Announcer.Result.Skip)
        assertEquals(Announcer.Result.Speak("Jetzt links abbiegen."), a.process(steps[0].voice[2], leg(90.0)))
    }

    @Test fun departIsNeverShortened() {
        val steps = listOf(
            Step(ManeuverType.DEPART, distance = 60.0, voice = listOf(Voice(55.0, "Auf Waldstraße Richtung Südwesten fahren. Dann Links abbiegen, um auf Waldstraße zu bleiben."))),
            Step(ManeuverType.CONTINUE, Direction.LEFT, distance = 200.0, names = listOf("Waldstraße")),
            Step(ManeuverType.ARRIVE),
        )
        val r = Announcer().process(steps[0].voice[0], LegState(steps, 0, 55.0))
        assertEquals(Announcer.Result.Speak("Auf Waldstraße Richtung Südwesten fahren. Dann Links abbiegen, um auf Waldstraße zu bleiben."), r)
    }

    @Test fun parsesSignDestinations() {
        val (codes, places) = Step.parseDestinations("A 42: Kamp-Lintfort, Venlo")
        assertEquals(listOf("A 42"), codes)
        assertEquals(listOf("Kamp-Lintfort", "Venlo"), places)
        assertEquals(listOf("Duisburg", "-Baerl"), Step.parseDestinations("Duisburg, -Baerl").second)
    }
}

class RouteSamplerTest {
    @Test fun sharePointsScaleToForecast() {
        // 2 km geradeaus, laut Route 120 s – Prognose sagt 240 s (Stau): Zeiten verdoppeln sich
        val piece = de.koeven.meeterz.nav.RouteSampler.Piece(listOf(6.70 to 51.40, 6.70 to 51.409, 6.70 to 51.418), 120.0)
        val samples = de.koeven.meeterz.nav.RouteSampler.samples(listOf(piece))
        val pts = de.koeven.meeterz.nav.RouteSampler.sharePoints(samples, 0.0, 240.0, 1000.0)
        assertEquals(3, pts.size)
        assertEquals(1240.0, pts.last()[2], 1.0)
    }
}

class RouteSamplerCornerTest {
    @Test fun keepsCorners() {
        val s = listOf(
            de.koeven.meeterz.nav.RouteSampler.Sample(6.7000, 51.4000, 0.0, 0.0),
            de.koeven.meeterz.nav.RouteSampler.Sample(6.7000, 51.4009, 100.0, 10.0),
            de.koeven.meeterz.nav.RouteSampler.Sample(6.7000, 51.4018, 200.0, 20.0),
            de.koeven.meeterz.nav.RouteSampler.Sample(6.7014, 51.4018, 300.0, 30.0),
            de.koeven.meeterz.nav.RouteSampler.Sample(6.7029, 51.4018, 400.0, 40.0),
        )
        val pts = de.koeven.meeterz.nav.RouteSampler.sharePoints(s, 0.0, 40.0, 1000.0)
        assertTrue(pts.toString(), pts.any { it[1] == 51.4018 && it[0] == 6.7000 })
        assertTrue(pts.none { it[1] == 51.4009 })
        assertEquals(1040.0, pts.last()[2], 0.5)
    }
}
