# Meeterz

- iOS-App (Swift, CarPlay) in `Meeterz/`, Android-App (Kotlin, Android Auto) in `android/`, gemeinsames
  Supabase-Backend in `supabase/`.
- **Jede Änderung an einer App wird in der anderen nachgezogen** (Ansagen, Ladeplanung, Oberfläche, Backend-Aufrufe).
  Plattformeigenes (Flyover, Live-Aktivität, Siri) bekommt das nächste Gegenstück der anderen Plattform.
- Beide Apps teilen Tabellen und Live-Kanäle: Feldnamen in Kanälen (z. B. `LivePosition`: userId, lat, lng,
  heading, speed, ts) dürfen sich nur gemeinsam ändern.
- Kommunikation auf Deutsch. Builds: iOS `build.yml`/`testflight.yml`, Android `android.yml`.
