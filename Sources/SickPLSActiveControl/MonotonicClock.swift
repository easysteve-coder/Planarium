import Darwin

/// Eine injizierbare, monotone Uhr -- entkoppelt die harte Gesamtfrist je
/// Probe-Frame (SICK-011a) von echten Sleeps, damit Tests deterministisch
/// bleiben, ohne reale Zeit verstreichen zu lassen. Nur die Differenz
/// zweier ``nowMilliseconds()``-Werte ist aussagekräftig, der absolute
/// Wert hat keine eigene Bedeutung (wie `CLOCK_MONOTONIC`).
public protocol MonotonicClock {
    func nowMilliseconds() -> Int64
}

/// Reale Implementierung über `clock_gettime(CLOCK_MONOTONIC, ...)` --
/// unbeeinflusst von Wanduhr-Sprüngen (NTP-Korrektur, manuelle
/// Zeitverstellung), anders als eine Wanduhr-/`Date`-basierte Messung.
public struct DarwinMonotonicClock: MonotonicClock {
    public init() {}

    public func nowMilliseconds() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
    }
}
