#!/usr/bin/env python3
"""Headless real-device check using the original SICK_PLS Python protocol.

This runner deliberately imports the frame, CRC, response classification and
serial I/O implementation directly from ``SICK Doku/SICK_PLS.zip``.  It adds
only orchestration for the documented mixed-address path and the capture-backed
MMK command.  Password-bearing TX is rendered through the original redactor.
"""

from __future__ import annotations

import argparse
import builtins
import sys
import time
from datetime import datetime
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
REFERENCE_ZIP = PROJECT_ROOT / "SICK Doku" / "SICK_PLS.zip"
sys.path.insert(0, f"{REFERENCE_ZIP}/SICK_PLS/src")

from pls_stream_analysis import pls_control as ctl  # noqa: E402
from pls_stream_analysis import pls_serial_cli as serial_cli  # noqa: E402
from pls_stream_analysis import sick_pls_protocol as proto  # noqa: E402


def timed_print(*args, **kwargs) -> None:
    timestamp = datetime.now().astimezone().isoformat(timespec="milliseconds")
    builtins.print(f"[{timestamp}]", *args, **kwargs)


# Keep a millisecond timestamp on both this runner's orchestration and the
# imported, byte-exact reference implementation's TX/RX diagnostics.
print = timed_print
serial_cli.print = timed_print

REFERENCE_SEND_AND_RECEIVE = serial_cli.send_and_receive


def send_and_receive_with_500k_pacing(
    ser,
    frame: bytes,
    read_window_s: float = serial_cli.READ_WINDOW_S,
    now_fn=time.monotonic,
) -> bytes:
    """Preserve reference I/O, adding SickPLS' 55 us TX pacing at 500 kbaud."""
    if getattr(ser, "baudrate", None) != 500000:
        return REFERENCE_SEND_AND_RECEIVE(ser, frame, read_window_s, now_fn)

    serial_cli.flush_rx(ser)
    for value in frame:
        ser.write(bytes([value]))
        ser.flush()
        time.sleep(55e-6)
    deadline = now_fn() + read_window_s
    buf = bytearray()
    while now_fn() < deadline:
        chunk = ser.read(4096)
        if chunk:
            buf.extend(chunk)
    return bytes(buf)


serial_cli.send_and_receive = send_and_receive_with_500k_pacing


ADDRESS_ZERO = ctl.ConfirmedTargetAddress(0x00)
ADDRESS_ONE = ctl.ConfirmedTargetAddress(0x01)
MMK_CONTINUOUS_MODE = 0x20
MONITOR_REQUEST_VALUES_MODE = 0x25
MONITOR_STREAM_VALUES_SUBRANGE_MODE = 0x27


def read_window(ser, seconds: float) -> bytes:
    old_timeout = ser.timeout
    ser.timeout = min(0.2, seconds)
    deadline = time.monotonic() + seconds
    data = bytearray()
    try:
        while time.monotonic() < deadline:
            chunk = ser.read(4096)
            if chunk:
                data.extend(chunk)
    finally:
        ser.timeout = old_timeout
    return bytes(data)


def describe_frames(raw: bytes, prefix: str) -> tuple[int, list[int]]:
    frames = proto.find_crc_valid_frames(raw)
    profiles = []
    for frame in proto.find_scan_profile_frames(frames):
        try:
            profiles.append(proto.parse_scan_profile_b0(frame.payload).num_measurements)
        except ValueError:
            continue
    commands = [frame.command_code for frame in frames]
    print(
        f"{prefix}: raw={len(raw)} bytes, crc_frames={len(frames)}, "
        f"commands={[f'0x{value:02x}' for value in commands]}, "
        f"B0_points={profiles}"
    )
    if raw:
        print(f"{prefix} RX raw: {raw.hex(' ')}")
    return len(frames), profiles


def rate_is_alive(port: str, baud: int) -> bool:
    preferred_address = ADDRESS_ZERO if baud == 38400 else ADDRESS_ONE
    probe_addresses = (preferred_address, ADDRESS_ONE if preferred_address == ADDRESS_ZERO else ADDRESS_ZERO)
    print(f"=== Ausgangslage: {baud} Baud passiv prüfen ===")
    ser = serial_cli.open_tx_capable_serial(port, baud, "E")
    try:
        passive = read_window(ser, 1.5)
        _, profiles = describe_frames(passive, f"{baud} passive")
        if profiles:
            print(f"{baud} ist durch CRC-gültigen B0-Messstrom belegt.")
            return True

        print("Kein B0-Strom; harmlose Identitätsproben 31 @00/@01 folgen.")
        for probe_address in probe_addresses:
            if serial_cli.run_status(ser, probe_address) == 0:
                return True
        return False
    finally:
        ser.close()


def detect_rate(port: str) -> int | None:
    # 9600/38400 sind der Produktkreis. Die übrigen drei Werte stammen
    # ausschließlich aus der originalen SICK-BAUD-Matrix und dienen nur
    # der harmlosen Wiederauffindung eines früher verstellten Geräts.
    for baud in (38400, 9600, 19200, 56000, 500000):
        if rate_is_alive(port, baud):
            print(f"Ausgangsbaudrate belegt: {baud}")
            return baud
    return None


def switch_rate(
    port: str,
    current_baud: int,
    target_baud: int,
    prelogin_delay: float,
    command_address: ctl.ConfirmedTargetAddress,
) -> bool:
    if current_baud == target_baud:
        print(f"ABORT: Umschaltung {current_baud} -> {target_baud} wäre wirkungslos.")
        return False

    print(f"=== Umschaltung {current_baud} -> {target_baud} ===")
    ser = serial_cli.open_tx_capable_serial(port, current_baud, "E")
    try:
        passive = read_window(ser, 0.5)
        _, active_profiles = describe_frames(passive, f"{current_baud} vor Einstellungszugang")

        if active_profiles:
            # Der originale SickToolbox-Treiber nutzt MonitorRequestValues
            # (0x25), um den Installationsmodus zu verlassen. Anders als der
            # nur zeitkorrelierte Kandidat 0x21 ist diese Bedeutung im
            # Quellcode belegt. Hier schafft er den ruhigen Anfragezustand,
            # in dem der aktiv reproduzierte R26-Weg gilt.
            print("--- Schritt 0a: aktiver B0-Start; MonitorRequestValues 20 25 @00 ---")
            frame = ctl.build_switch_operating_mode_frame(
                MONITOR_REQUEST_VALUES_MODE,
                b"",
                command_address.value,
            )
            print(
                f"TX MonitorRequestValues (20 25 @{command_address.value:02x}): "
                f"{frame.hex(' ')}"
            )
            stopped = False
            acknowledged = False
            for attempt in range(1, 4):
                if attempt > 1:
                    print(f"Stromstopp: identische Wiederholung {attempt}/3")
                raw = serial_cli.send_and_receive(ser, frame)
                describe_frames(raw, f"Antwort auf 20 25 @00, Versuch {attempt}")
                response = ctl.find_response_frame(raw, ctl.COMMAND_SWITCH_OPERATING_MODE)
                result = ctl.classify_response(ctl.COMMAND_SWITCH_OPERATING_MODE, response)
                if result.status == ctl.TransactionStatus.NACK:
                    print("ABORT: 20 25 @00 wurde ausdrücklich abgelehnt.")
                    return False
                acknowledged = (
                    result.status == ctl.TransactionStatus.ACK
                    and result.status_byte == 0x00
                )

                # Erst den bereits erreichten Zustand prüfen, bevor ein
                # idempotentes Kommando wiederholt wird. Gerade im dichten
                # 500-kBaud-B0-Strom kann die A0-Antwort zwischen Profilen
                # verloren gehen, obwohl der Scanner den Modus gewechselt hat.
                ser.reset_input_buffer()
                quiet_check = read_window(ser, 0.75)
                _, remaining_profiles = describe_frames(
                    quiet_check, f"Ruheprüfung nach 20 25, Versuch {attempt}"
                )
                if not remaining_profiles:
                    stopped = True
                    break

            if not stopped:
                print("ABORT: Nach drei Stoppversuchen läuft der B0-Dauerstrom weiter.")
                return False
            if not acknowledged:
                print(
                    "HINWEIS: keine isolierte A0/00-Antwort sichtbar; "
                    "Stromende wird vor jedem Folgeschritt per Identität abgesichert."
                )

        # Capture R26: Im ruhigen Zustand zuerst B1 @01 belegen; dort war
        # kein vorgeschaltetes 20 30 nötig.
        print(
            f"--- Schritt 0b: ruhiger Start; Identität 31 "
            f"@{command_address.value:02x} ---"
        )
        identity_confirmed = False
        for attempt in range(1, 3):
            print(f"Identitätsversuch {attempt}/2")
            if serial_cli.run_status(ser, command_address) == 0:
                identity_confirmed = True
                break
        if not identity_confirmed:
            print(f"ABORT: 31 @{command_address.value:02x} blieb unbestätigt.")
            return False

        print(
            f"--- Schritt 1: Installation 20 00 @{command_address.value:02x}, "
            "maximal zwei identische Wiederholungen ---"
        )
        if serial_cli.run_login(
            ser,
            command_address,
            mode=ctl.OP_MODE_INSTALLATION_ADDR01_VARIANT,
            retries=2,
        ) != 0:
            return False

        target_code = ctl.SICK_BAUD_RATE_CODES[target_baud]
        print(
            f"--- Schritt 2: Baudwechsel 20 {target_code:02x} "
            f"@{command_address.value:02x}; "
            f"ACK noch bei {current_baud} ---"
        )
        if serial_cli.run_set_baud(ser, command_address, target_baud) != 0:
            return False
    finally:
        ser.close()

    print(f"--- Schritt 3: Neuöffnung und Verifikation bei {target_baud} ---")
    ser = serial_cli.open_tx_capable_serial(port, target_baud, "E")
    try:
        # SickPLS waits roughly 2.5 ms after changing the host UART. Opening a
        # fresh macOS descriptor already takes longer, but retain the explicit
        # lower bound for the 500 kbaud special case.
        if target_baud == 500000:
            time.sleep(0.0025)
        passive = read_window(ser, 1.0)
        _, profiles = describe_frames(passive, f"{target_baud} nach Baudwechsel")
        if profiles:
            print("Zielbaudrate durch CRC-gültigen B0-Messstrom bestätigt.")
            return True
        print(
            f"Kein passiver B0-Strom; Identitätsverifikation 31 "
            f"@{command_address.value:02x} folgt."
        )
        return serial_cli.run_status(ser, command_address) == 0
    finally:
        ser.close()


def request_mmk_and_require_stream(
    port: str,
    baud: int,
    label: str,
    command_address: ctl.ConfirmedTargetAddress,
) -> bool:
    print(
        f"=== {label}: MMK 20 20 @{command_address.value:02x} "
        f"bei {baud} + B0 ==="
    )
    ser = serial_cli.open_tx_capable_serial(port, baud, "E")
    try:
        before = read_window(ser, 0.5)
        describe_frames(before, f"{label} vor TX")

        frame = ctl.build_switch_operating_mode_frame(
            MMK_CONTINUOUS_MODE,
            b"",
            command_address.value,
        )
        print(f"TX MMK (20 20 @{command_address.value:02x}): {frame.hex(' ')}")
        raw_parts: list[bytes] = []
        result = None
        for attempt in range(1, 4):
            if attempt > 1:
                print(f"MMK: identische Wiederholung {attempt}/3")
            raw = serial_cli.send_and_receive(ser, frame)
            raw_parts.append(raw)
            print(f"RX nach MMK, Versuch {attempt} ({len(raw)} bytes): {raw.hex(' ')}")
            response = ctl.find_response_frame(raw, ctl.COMMAND_SWITCH_OPERATING_MODE)
            result = ctl.classify_response(ctl.COMMAND_SWITCH_OPERATING_MODE, response)
            status = "--" if result.status_byte is None else f"0x{result.status_byte:02x}"
            print(f"MMK-Antwort: {result.status.value}, status={status}")
            if result.status == ctl.TransactionStatus.ACK and result.status_byte == 0x00:
                break
        if result is None or result.status != ctl.TransactionStatus.ACK or result.status_byte != 0x00:
            return False

        raw = b"".join(raw_parts)
        _, profiles = describe_frames(raw, f"{label} Antwortfenster")
        if not profiles:
            follow_up = read_window(ser, 3.0)
            _, profiles = describe_frames(follow_up, f"{label} Messfenster")
        if not profiles:
            print("ABORT: MMK wurde bestätigt, aber kein CRC-gültiges B0-Profil empfangen.")
            return False

        print(
            f"{label} POSITIV: MMK CRC-gültig bestätigt und "
            f"{len(profiles)} B0-Profil(e) mit Punktzahlen {profiles} empfangen."
        )
        return True
    finally:
        ser.close()


def test_output_subrange_and_restore_mmk(
    port: str,
    baud: int,
    start_index: int,
    stop_index: int,
    command_address: ctl.ConfirmedTargetAddress,
) -> bool:
    """Tests volatile measured-value output limiting; never writes fields/config."""
    print(
        f"=== Reversibler Ausgabeteilbereich 20 27: "
        f"Index {start_index}...{stop_index} bei {baud} ==="
    )
    ser = serial_cli.open_tx_capable_serial(port, baud, "E")
    subrange_ok = False
    try:
        passive = read_window(ser, 0.5)
        _, profiles = describe_frames(passive, "Teilbereich vor TX")
        if profiles:
            quiet_frame = ctl.build_switch_operating_mode_frame(
                MONITOR_REQUEST_VALUES_MODE, b"", command_address.value
            )
            print(f"TX Stromstopp 20 25: {quiet_frame.hex(' ')}")
            quiet_raw = serial_cli.send_and_receive(ser, quiet_frame)
            describe_frames(quiet_raw, "Antwort Stromstopp")
            quiet_response = ctl.find_response_frame(
                quiet_raw, ctl.COMMAND_SWITCH_OPERATING_MODE
            )
            quiet_result = ctl.classify_response(
                ctl.COMMAND_SWITCH_OPERATING_MODE, quiet_response
            )
            if quiet_result.status != ctl.TransactionStatus.ACK or quiet_result.status_byte != 0:
                print("ABORT: Messstrom konnte vor dem Teilbereichstest nicht gestoppt werden.")
                return False
            ser.reset_input_buffer()
            read_window(ser, 0.5)

        params = bytes(
            [
                start_index & 0xFF,
                (start_index >> 8) & 0xFF,
                stop_index & 0xFF,
                (stop_index >> 8) & 0xFF,
            ]
        )
        frame = ctl.build_switch_operating_mode_frame(
            MONITOR_STREAM_VALUES_SUBRANGE_MODE, params, command_address.value
        )
        print(f"TX Teilbereich 20 27: {frame.hex(' ')}")
        # Genau einmal senden. Ein einzelnes 0x06 ist die unmittelbare
        # Steuerquittung des PLS; bei einem Strommodus darf danach bereits
        # die Datenausgabe beginnen. Eine blinde Wiederholung während dieses
        # Übergangs war im ersten Versuch nicht robust und wird vermieden.
        raw = serial_cli.send_and_receive(ser, frame)
        received = bytearray(raw)
        print(f"RX Teilbereich einmalig: {raw.hex(' ')}")
        response = ctl.find_response_frame(raw, ctl.COMMAND_SWITCH_OPERATING_MODE)
        result = ctl.classify_response(ctl.COMMAND_SWITCH_OPERATING_MODE, response)
        has_control_ack = bool(raw) and raw[0] == 0x06
        print(
            f"Teilbereich Quittung: A0={result.status.value}, "
            f"Steuer-ACK-06={'ja' if has_control_ack else 'nein'}"
        )
        if result.status == ctl.TransactionStatus.NACK:
            print("Teilbereich NEGATIV: ausdrückliches A0-NACK.")
            return False

        received.extend(read_window(ser, 4.0))
        frames = proto.find_crc_valid_frames(bytes(received))
        data_frames = [frame for frame in frames if frame.command_code != 0xA0]
        profiles = []
        for candidate in proto.find_scan_profile_frames(data_frames):
            try:
                profiles.append(proto.parse_scan_profile_b0(candidate.payload).num_measurements)
            except ValueError:
                pass
        print(
            "Teilbereich RX-Auswertung: "
            f"CRC-Frames={len(frames)}, "
            f"Kommandos={[f'0x{frame.command_code:02x}' for frame in frames if frame.command_code is not None]}, "
            f"Payloadlaengen={[len(frame.payload) for frame in data_frames]}, "
            f"B0-Punktzahlen={profiles}"
        )
        if not profiles:
            print("Teilbereich NEGATIV: keine CRC-gültigen B0-Teilprofile empfangen.")
            return False
        if result.status != ctl.TransactionStatus.ACK and not has_control_ack:
            print("Teilbereich NEGATIV: Daten ohne zuordenbare Quittung.")
            return False
        subrange_ok = True
        print(
            "Teilbereich POSITIV: einmalige Umschaltung quittiert und "
            f"{len(profiles)} CRC-gültige B0-Profile empfangen."
        )
        return True
    finally:
        ser.close()
        # Always leave this diagnostic in the known product mode.
        restored = request_mmk_and_require_stream(
            port, baud, "Wiederherstellung nach Teilbereich", command_address
        )
        print(f"MMK-Wiederherstellung: {'POSITIV' if restored else 'NEGATIV'}")
        if subrange_ok and not restored:
            print("WARNUNG: Teilbereich war positiv, aber MMK konnte nicht wiederhergestellt werden.")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--cycles", type=int, default=2)
    parser.add_argument("--prelogin-delay", type=float, default=3.0)
    parser.add_argument("--final-baud", type=int, choices=(9600, 38400), default=38400)
    parser.add_argument(
        "--leg-target",
        type=int,
        choices=(9600, 38400, 500000),
        help=(
            "Nur genau eine belegte Teilstrecke zum Zielwert ausfuehren und dort "
            "MMK+B0 bestaetigen. Mehrere Aufrufe bilden einen unterbrechungsfesten Vollkreis."
        ),
    )
    parser.add_argument("--address", type=int, choices=(0, 1), required=True)
    parser.add_argument(
        "--test-subrange",
        metavar="START:STOP",
        help="Fluechtigen 20-27-Ausgabeteilbereich testen und danach MMK wiederherstellen.",
    )
    parser.add_argument(
        "--preflight-mmk",
        action="store_true",
        help="Vor dem ersten Vollkreis den erkannten Zustand mit MMK+B0 belegen.",
    )
    parser.add_argument(
        "--assume-current-baud",
        type=int,
        choices=(9600, 38400, 500000),
        help="Bekannte aktuelle Baudrate verwenden und die Ratensuche ueberspringen.",
    )
    parser.add_argument(
        "--measure-seconds",
        type=float,
        help="Nur passiv B0-Profile zaehlen und die Profilrate ausgeben.",
    )
    args = parser.parse_args()

    if not args.port.startswith("/dev/cu."):
        print("ABORT: nur /dev/cu.* ist zulässig.")
        return 2
    if args.cycles < 2:
        print("ABORT: mindestens zwei Vollkreise sind für den Positivbeleg nötig.")
        return 2
    if args.prelogin_delay < 0:
        print("ABORT: die Bedienpause darf nicht negativ sein.")
        return 2
    if args.measure_seconds is not None and args.measure_seconds <= 0:
        print("ABORT: die Messdauer muss positiv sein.")
        return 2

    print(f"Port: {args.port}; 8E1; keine Flusssteuerung")
    command_address = ctl.ConfirmedTargetAddress(args.address)
    print(f"Explizite Geräteadresse für den gesamten Kreis: 0x{args.address:02x}")
    print(f"Primärimplementierung: {serial_cli.__file__}")
    print("Kennworttragende TX-Ausgaben bleiben redigiert.")

    try:
        current_baud = args.assume_current_baud or detect_rate(args.port)
        if current_baud is None:
            print("GESAMTERGEBNIS: NEGATIV — weder 9600 noch 38400 belegt")
            return 1

        if args.measure_seconds is not None:
            ser = serial_cli.open_tx_capable_serial(args.port, current_baud, "E")
            try:
                started = time.monotonic()
                raw = read_window(ser, args.measure_seconds)
                elapsed = time.monotonic() - started
            finally:
                ser.close()
            _, profiles = describe_frames(raw, f"Ratenmessung {current_baud}")
            rate = len(profiles) / elapsed
            print(
                f"RATENERGEBNIS: {len(profiles)} CRC-gueltige B0-Profile in "
                f"{elapsed:.3f} s = {rate:.3f} Profile/s; "
                f"Punktzahlen={sorted(set(profiles))}"
            )
            return 0 if profiles else 1

        if args.test_subrange is not None:
            try:
                start_text, stop_text = args.test_subrange.split(":", 1)
                start_index, stop_index = int(start_text), int(stop_text)
            except ValueError:
                print("ABORT: --test-subrange erwartet START:STOP als Dezimalzahlen.")
                return 2
            if not (1 <= start_index <= stop_index <= 361):
                print("ABORT: Teilbereich muss innerhalb 1...361 liegen.")
                return 2
            return 0 if test_output_subrange_and_restore_mmk(
                args.port,
                current_baud,
                start_index,
                stop_index,
                command_address,
            ) else 1

        if args.leg_target is not None:
            if current_baud != args.leg_target:
                if not switch_rate(
                    args.port,
                    current_baud,
                    args.leg_target,
                    args.prelogin_delay,
                    command_address,
                ):
                    print(
                        f"GESAMTERGEBNIS: NEGATIV auf Teilstrecke "
                        f"{current_baud} -> {args.leg_target}"
                    )
                    return 1
            if not request_mmk_and_require_stream(
                args.port,
                args.leg_target,
                f"Teilstrecke / {args.leg_target}",
                command_address,
            ):
                print(
                    f"GESAMTERGEBNIS: NEGATIV beim MMK-Beleg "
                    f"bei {args.leg_target}"
                )
                return 1
            print(
                f"GESAMTERGEBNIS: POSITIV — Ziel {args.leg_target} Baud "
                "und MMK-Messstrom belegt."
            )
            return 0

        if args.preflight_mmk:
            if not request_mmk_and_require_stream(
                args.port, current_baud, "Vorab-Zustandsabschluss", command_address
            ):
                print("GESAMTERGEBNIS: NEGATIV beim Vorab-MMK-Beleg")
                return 1

        # Ein Vollkreis beginnt bei 9600. Ist das Gerät bereits bei 38400,
        # wird es mit derselben belegpflichtigen Folge zuerst normalisiert.
        if current_baud != 9600:
            if not switch_rate(
                args.port, current_baud, 9600, args.prelogin_delay, command_address
            ):
                print("GESAMTERGEBNIS: NEGATIV bei der Normalisierung auf 9600")
                return 1
            current_baud = 9600
            if not request_mmk_and_require_stream(
                args.port, 9600, "Normalisierung", command_address
            ):
                print("GESAMTERGEBNIS: NEGATIV beim MMK-Beleg der Normalisierung")
                return 1

        completed_cycles = 0
        for cycle in range(1, args.cycles + 1):
            if not switch_rate(
                args.port, 9600, 38400, args.prelogin_delay, command_address
            ):
                print(f"GESAMTERGEBNIS: NEGATIV in Kreis {cycle}, Wechsel auf 38400")
                return 1
            if not request_mmk_and_require_stream(
                args.port, 38400, f"Kreis {cycle} / 38400", command_address
            ):
                print(f"GESAMTERGEBNIS: NEGATIV in Kreis {cycle}, MMK bei 38400")
                return 1
            if not switch_rate(
                args.port, 38400, 9600, args.prelogin_delay, command_address
            ):
                print(f"GESAMTERGEBNIS: NEGATIV in Kreis {cycle}, Rückkehr auf 9600")
                return 1
            if not request_mmk_and_require_stream(
                args.port, 9600, f"Kreis {cycle} / 9600", command_address
            ):
                print(f"GESAMTERGEBNIS: NEGATIV in Kreis {cycle}, MMK bei 9600")
                return 1
            completed_cycles += 1

        current_baud = 9600
        if args.final_baud == 38400:
            if not switch_rate(
                args.port, 9600, 38400, args.prelogin_delay, command_address
            ):
                print("GESAMTERGEBNIS: NEGATIV beim abschließenden Wechsel auf 38400")
                return 1
            if not request_mmk_and_require_stream(
                args.port, 38400, "Endzustand / 38400", command_address
            ):
                print("GESAMTERGEBNIS: NEGATIV beim abschließenden MMK-Beleg")
                return 1
            current_baud = 38400

        print(
            f"GESAMTERGEBNIS: POSITIV — {completed_cycles} von {args.cycles} "
            f"Vollkreisen 9600 -> 38400 -> 9600 bestätigt; "
            f"Endzustand {current_baud} Baud + MMK-Messstrom."
        )
        return 0
    except Exception as exc:  # Hardwaregrenze: sichtbarer Stop mit Typ, keine Fortsetzung.
        print(f"GESAMTERGEBNIS: FEHLER — {type(exc).__name__}: {exc}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
