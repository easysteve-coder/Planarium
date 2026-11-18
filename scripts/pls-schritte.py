#!/usr/bin/env python3
"""Schrittweiser PLS-Gerätetest mit vollständigem TX/RX-Log (Owner-Freigabe 12.10.2026).

Aufruf: python pls-schritte.py PORT LOGDATEI STARTBAUD SCHRITT [SCHRITT ...]
Schritte:
  settings@A       20 30 SICK_PLS an A (Einstellungsmodus)
  login@A          20 00 SICK_PLS an Adresse A
  baud:RATE@A      20 40/48/42 an A, danach Port mit RATE neu öffnen, 31 prüfen
  mode:XX[:S]@A    20 XX an A, danach S (Standard 4) s B0 zählen (z. B. mode:20:8@0)
  stop@A           20 25 an A
  read45:N@A       45 N an A
  reset@A          10 an A, 30 s warten, bei 9600 neu öffnen, 31
  raw:DATEI@A      Payload-Hex aus DATEI an A senden (Antwort = Kommando|0x80)
  repeat:XX:N[:G]@A  20 XX bis zu N-mal im Abstand G s (Std 0,2) bis ACK, dann 4 s B0 zählen
  listen:S         S Sekunden passiv
Nutzt Frame/CRC/Log aus pls-geraetetest-mmk90.py.
"""
import sys, time, importlib.util, os
spec = importlib.util.spec_from_file_location("t", os.path.join(os.path.dirname(__file__), "pls-geraetetest-mmk90.py"))
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
CODES = {38400: 0x40, 500000: 0x48, 9600: 0x42}

def counts(got):
    c = {}
    for p in got:
        if p[0] == 0xB0:
            n = int.from_bytes(p[1:3], "little") & 0x3FFF; c[n] = c.get(n, 0) + 1
    return c

def main():
    port, logpath, baud = sys.argv[1], sys.argv[2], int(sys.argv[3])
    with open(logpath, "a") as log:
        log.write(f"\n=== pls-schritte {time.strftime('%Y-%m-%d %H:%M:%S')} {' '.join(sys.argv[3:])} ===\n")
        link = t.Link(port, baud, log)
        for step in sys.argv[4:]:
            name, _, addr = step.partition("@"); a = int(addr or "0")
            if name == "settings":
                t.expect(link, a, [0x20, 0x30] + t.PW, f"Einstellungsmodus 20 30 @{a}", lambda p: p[0] == 0xA0, seconds=3.5)
            elif name == "login":
                t.expect(link, a, [0x20, 0x00] + t.PW, f"Login @{a}", lambda p: p[0] == 0xA0, seconds=3.5)
            elif name.startswith("baud:"):
                rate = int(name[5:])
                r = t.expect(link, a, [0x20, CODES[rate]], f"Baud {rate} @{a}", lambda p: p[0] == 0xA0, tries=1)
                link.s.close(); time.sleep(0.1)
                t0 = link.t0; link = t.Link(port, rate, log); link.t0 = t0
                link.send(0, [0x31], "Identität 31")
                link.frames(1.0, stop=lambda p: p[0] == 0xB1)
            elif name.startswith("mode:"):
                parts = name[5:].split(":"); b = int(parts[0], 16)
                secs = float(parts[1]) if len(parts) > 1 else 4.0
                t.expect(link, a, [0x20, b], f"Modus 20 {b:02x} @{a}", lambda p: p[0] == 0xA0, tries=1)
                got = link.frames(secs)
                link.note(f"ERGEBNIS 20 {b:02x}: B0-Punktzahlen {counts(got)}")
            elif name == "stop":
                t.expect(link, a, [0x20, 0x25], f"Stopp 20 25 @{a}", lambda p: p[0] == 0xA0, tries=1)
                link.frames(1.0)
            elif name.startswith("read45:"):
                t.expect(link, a, [0x45, int(name[7:])], f"45 {name[7:]} @{a}", lambda p: p[0] == 0xC5, tries=1)
            elif name == "reset":
                link.send(a, [0x10], f"Reset 10 @{a}")
                link.frames(3.0, stop=lambda p: p[0] == 0x91)
                link.s.close(); link.note("warte 30 s auf Neustart")
                time.sleep(30)
                t0 = link.t0; link = t.Link(port, 9600, log); link.t0 = t0
                link.send(0, [0x31], "Identität 31")
                link.frames(2.0, stop=lambda p: p[0] == 0xB1)
            elif name.startswith("raw:"):
                payload = list(bytes.fromhex(open(name[4:]).read()))
                t.expect(link, a, payload, f"raw {payload[0]:02x} ({len(payload)} B) @{a}", lambda p: p[0] == (payload[0] | 0x80), seconds=3.0, tries=1)
            elif name.startswith("repeat:"):
                parts = name[7:].split(":"); b = int(parts[0], 16); n = int(parts[1]); gap = float(parts[2]) if len(parts) > 2 else 0.2
                acked = False
                for i in range(1, n + 1):
                    link.send(a, [0x20, b], f"Wiederholung {i}/{n} 20 {b:02x} @{a}")
                    got = link.frames(gap, stop=lambda p: p[0] == 0xA0)
                    if any(p[0] == 0xA0 for p in got):
                        acked = True; break
                got = link.frames(4.0)
                link.note(f"ERGEBNIS repeat 20 {b:02x}: ACK={'ja nach ' + str(i) if acked else 'nein'}, danach B0 {counts(got)}")
            elif name.startswith("listen:"):
                got = link.frames(float(name[7:])); link.note(f"passiv: {counts(got)}")
        link.s.close()

if __name__ == "__main__":
    main()
