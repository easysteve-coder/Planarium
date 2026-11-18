#!/usr/bin/env python3
"""Gerätetest „MMK 90 zurückschreiben“ (Owner-Freigabe 12.10.2026).

Aufruf:  python pls-geraetetest-mmk90.py /dev/cu.usbserial-XXXX LOGDATEI [--write]

Ohne --write: nur Zustand erkennen und Segmenttabelle lesen (45 01), kein
Schreibbefehl. Mit --write: zusätzlich Login, 43 5a + 91 x 23 80 (Bytes aus
PLSIBS-Mitschnitt 20.09.2026 17:02:02.871), 20 20 und Prüfung der Punktzahl.
Jedes gesendete und empfangene Telegramm steht vollständig mit Zeitstempel im
Log (Owner 12.10.2026: Scanner ohne Sicherheitsrelevanz, nichts schwärzen).
Benötigt pyserial. Port: 8E1, keine Flusssteuerung.
"""
import sys, time, serial

PW = list(b"SICK_PLS")


def crc16(data):
    crc = 0; prev = 0
    for b in data:
        crc = (((crc & 0x7FFF) << 1) ^ 0x8005) if crc & 0x8000 else (crc << 1) & 0xFFFF
        crc = (crc ^ (b | (prev << 8))) & 0xFFFF
        prev = b
    return crc


assert crc16(bytes.fromhex("0200010031")) == 0x1215


def frame(addr, payload):
    b = bytes([2, addr]) + len(payload).to_bytes(2, "little") + bytes(payload)
    return b + crc16(b).to_bytes(2, "little")


def hexs(b):
    return " ".join(f"{x:02x}" for x in b)


class Link:
    def __init__(self, path, baud, log):
        self.s = serial.Serial(path, baud, bytesize=8, parity="E", stopbits=1, timeout=0.05)
        self.buf = bytearray(); self.log = log; self.t0 = time.monotonic(); self.baud = baud
        self.note(f"OPEN {path} {baud} 8E1")

    def note(self, text):
        line = f"+{(time.monotonic() - self.t0) * 1000:9.1f} ms  {text}"
        print(line); self.log.write(line + "\n"); self.log.flush()

    def send(self, addr, payload, label):
        f = frame(addr, payload)
        self.note(f"TX {label}: {hexs(f)}")
        self.s.write(f); self.s.flush()

    def frames(self, seconds, stop=None):
        """Liest CRC-gültige Frames; stop(payload) beendet vorzeitig."""
        out = []; end = time.monotonic() + seconds; noise = 0
        while time.monotonic() < end:
            self.buf += self.s.read(4096)
            while True:
                i = self.buf.find(b"\x02")
                if i < 0: noise += len(self.buf); self.buf.clear(); break
                if i: noise += i; del self.buf[:i]
                if len(self.buf) < 4: break
                n = int.from_bytes(self.buf[2:4], "little")
                if n == 0 or n > 812: noise += 1; del self.buf[:1]; continue
                if len(self.buf) < n + 6: break
                f = bytes(self.buf[:n + 6])
                if crc16(f[:-2]) != int.from_bytes(f[-2:], "little"):
                    noise += 1; del self.buf[:1]; continue
                del self.buf[:n + 6]
                p = f[4:-2]; out.append(p)
                if p[0] == 0xB0:
                    count = int.from_bytes(p[1:3], "little") & 0x3FFF
                    self.note(f"RX B0 addr {f[1]:02x} points {count} (len {n})")
                else:
                    self.note(f"RX addr {f[1]:02x}: {hexs(p)}")
                if stop and stop(p):
                    if noise: self.note(f"noise bytes {noise}")
                    return out
        if noise: self.note(f"noise bytes {noise}")
        return out


def expect(link, addr, payload, label, ok, seconds=2.0, tries=3):
    for attempt in range(1, tries + 1):
        link.send(addr, payload, f"{label} (Versuch {attempt})")
        got = link.frames(seconds, stop=lambda p: p[0] != 0xB0 and p[0] != 0xB1)
        reply = [p for p in got if p[0] not in (0xB0,)]
        if any(ok(p) for p in reply):
            return reply
    return None


def main():
    path, logpath = sys.argv[1], sys.argv[2]; write = "--write" in sys.argv
    with open(logpath, "a") as log:
        log.write(f"\n=== Gerätetest MMK90 {time.strftime('%Y-%m-%d %H:%M:%S')} write={write} ===\n")
        link = None
        for baud in (9600, 38400, 500000):
            link = Link(path, baud, log)
            link.note("passiv 1,0 s")
            got = link.frames(1.0)
            if got:
                break
            link.send(0, [0x31], "Identität 31")
            got = link.frames(1.0, stop=lambda p: p[0] == 0xB1)
            if got:
                break
            link.s.close(); link = None
        if not link:
            print("Kein Scanner gefunden."); return 2
        streaming = any(p[0] == 0xB0 for p in got)
        link.note(f"Zustand: {link.baud} Baud, Strom {'läuft' if streaming else 'still'}")
        if streaming:
            link.note("Strom anhalten: 20 25")
            expect(link, 0, [0x20, 0x25], "Strom stoppen 20 25", lambda p: p[0] == 0xA0)
            link.frames(1.0)
        table = expect(link, 0, [0x45, 0x01], "Segmenttabelle lesen 45 01", lambda p: p[0] == 0xC5)
        if table:
            t = [p for p in table if p[0] == 0xC5][-1]
            link.note(f"SICHERUNG 45 01 Antwort ({len(t)} B): {hexs(t)}")
        if not write:
            link.note("Nur lesen (ohne --write) – Ende."); return 0
        if not expect(link, 0, [0x20, 0x00] + PW, "Login 20 00 SICK_PLS", lambda p: p[:2] == b"\xa0\x00", seconds=3.5):
            link.note("Login nicht bestätigt – Abbruch."); return 3
        if not expect(link, 0, [0x43, 0x5A] + [0x23, 0x80] * 91, "Segmenttabelle schreiben 43 5a", lambda p: p[:2] == b"\xc3\x01", seconds=3.0, tries=1):
            link.note("43 nicht bestätigt – Abbruch."); return 4
        expect(link, 0, [0x20, 0x20], "MMK 20 20", lambda p: p[0] == 0xA0, tries=2)
        got = link.frames(4.0)
        counts = sorted({int.from_bytes(p[1:3], "little") & 0x3FFF for p in got if p[0] == 0xB0})
        link.note(f"ERGEBNIS MMK-Punktzahlen: {counts}")
        link.send(0, [0x20, 0x25], "Strom stoppen 20 25")
        link.frames(1.0)
        table = expect(link, 0, [0x45, 0x01], "Segmenttabelle prüfen 45 01", lambda p: p[0] == 0xC5)
        return 0 if counts == [90] else 5


if __name__ == "__main__":
    sys.exit(main())
