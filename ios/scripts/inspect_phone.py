#!/usr/bin/env python3
"""Reads a debug-server phone (ios/Icarus/Model/DebugServer.swift) and analyzes the store.

Usage:
  python3 scripts/inspect_phone.py                # find the phone on this Wi-Fi, print the summary
  python3 scripts/inspect_phone.py --ip 192.168.1.42
  python3 scripts/inspect_phone.py --historical   # pull the offload records and analyze them
  python3 scripts/inspect_phone.py --sleep --hr --frames

Stdlib only. The phone must run a DEBUG build with the app foregrounded (its socket server stops
when iOS suspends the app). JSON keys are the store's snake_case column names.
"""
import argparse
import concurrent.futures
import datetime
import json
import socket
import subprocess
import sys
import urllib.request

PORT = 8087


def ms(value):
    if value is None:
        return "-"
    return datetime.datetime.fromtimestamp(value / 1000).astimezone().strftime("%m-%d %H:%M:%S")


def fetch(ip, path):
    with urllib.request.urlopen(f"http://{ip}:{PORT}{path}", timeout=60) as response:
        return json.load(response)


def mac_ip():
    for iface in ("en0", "en1"):
        try:
            out = subprocess.check_output(["ipconfig", "getifaddr", iface], text=True).strip()
            if out:
                return out
        except subprocess.CalledProcessError:
            pass
    return None


def find_phone():
    local = mac_ip()
    if not local:
        sys.exit("Could not read this Mac's Wi-Fi address; pass --ip.")
    prefix = ".".join(local.split(".")[:3])
    hosts = [f"{prefix}.{n}" for n in range(1, 255)]

    def open_port(host):
        try:
            with socket.create_connection((host, PORT), timeout=0.4):
                return host
        except OSError:
            return None

    print(f"Scanning {prefix}.0/24 for port {PORT} ...")
    with concurrent.futures.ThreadPoolExecutor(max_workers=60) as pool:
        for host in pool.map(open_port, hosts):
            if host:
                print(f"  found {host}")
                return host
    return None


def print_summary(ip):
    db = fetch(ip, "/db")
    print("Bands:")
    for band in db["bands"]:
        print(f"  id={band['id'][:8]} uuid={band['peripheral_uuid'][:8]} name={band.get('name')!r} "
              f"firmware={band.get('firmware')} tierB={band.get('tier_b_enabled')} "
              f"created={ms(band.get('created_at'))}")
    print(f"Profile timezone: {db.get('profileTZ')}")
    print("Tables (count, oldest, newest):")
    for table in db["tables"]:
        print(f"  {table['name']:<18} {table['count']:>7}  {ms(table.get('min'))}  ->  {ms(table.get('max'))}")
    print("Sync cursors:", db["cursors"])
    print("Recent events:")
    for event in db["recentEvents"][:10]:
        print(f"  {ms(event.get('ts_ms'))}  {event['kind']}  {json.dumps(event.get('payload'))[:100]}")
    print("Recent sync batches:")
    for batch in db["recentBatches"][:10]:
        print(f"  {ms(batch.get('created_at'))}  rows={batch['rows']:<6} status={batch['status']}"
              + (f" http={batch.get('http_status')}" if batch.get("http_status") else "")
              + (f" error={batch.get('error')}" if batch.get("error") else ""))


def print_sleep(ip):
    data = fetch(ip, "/sleep")
    rows = data["rows"]
    print(f"\nSleep sessions ({data['count']}):")
    for row in rows:
        print(f"  {ms(row['start_ms'])} -> {ms(row['end_ms'])}  dur={row['duration_s']//60:>4}min  "
              f"quality={row['quality']:<4}  contact={row['contact_fraction']:.2f}  "
              f"records={row['record_count']:<6}  rhr={row.get('resting_hr')}  rmssd={row.get('rmssd_ms')}  "
              f"band={row['band_id'][:8]}")


def print_hr(ip, limit):
    data = fetch(ip, f"/hr?limit={limit}")
    rows = data["rows"]
    print(f"\nHR samples ({len(rows)} newest):")
    for row in rows[:10]:
        print(f"  {ms(row['ts_ms'])}  bpm={row['bpm']}  source={row['source']}  contact={row.get('contact')}")
    if len(rows) > 15:
        print("  ...")
    for row in rows[-5:]:
        print(f"  {ms(row['ts_ms'])}  bpm={row['bpm']}  source={row['source']}  contact={row.get('contact')}")


def print_frames(ip, limit):
    data = fetch(ip, f"/frames?limit={limit}")
    rows = data["rows"]
    by_char = {}
    for row in rows:
        info = by_char.setdefault(row["char"], {"n": 0, "first": row["ts_ms"], "last": row["ts_ms"]})
        info["n"] += 1
        info["first"] = min(info["first"], row["ts_ms"])
        info["last"] = max(info["last"], row["ts_ms"])
    print(f"\nRaw frames ({len(rows)} newest of the 72 h window):")
    for char, info in sorted(by_char.items()):
        print(f"  char={char}  n={info['n']}  {ms(info['first'])} -> {ms(info['last'])}")
    for row in rows[:10]:
        print(f"  {ms(row['ts_ms'])}  {row['char']}  {row['hex']}")


def print_historical(ip):
    data = fetch(ip, "/historical?limit=100000")
    rows = data["rows"]
    if not rows:
        print("\nNo historical records at all: the band never offloaded (Tier B off, no drain, or insert failed).")
        return
    print(f"\nHistorical records: {len(rows)} rows, {ms(rows[0]['ts_ms'])} -> {ms(rows[-1]['ts_ms'])}")

    hours = {}
    for row in rows:
        hour = row["ts_ms"] // 3_600_000
        bucket = hours.setdefault(hour, {"n": 0, "contact": 0, "rr": 0, "bpm": []})
        bucket["n"] += 1
        bucket["contact"] += 1 if row.get("contact") else 0
        bucket["rr"] += 1 if row.get("rr_ms") else 0
        if row.get("bpm"):
            bucket["bpm"].append(row["bpm"])
    print("Per hour (local): n, contact%, rr%, bpm range:")
    for hour in sorted(hours):
        b = hours[hour]
        label = datetime.datetime.fromtimestamp(hour * 3600).astimezone().strftime("%m-%d %H")
        bpm = f"{min(b['bpm'])}-{max(b['bpm'])}" if b["bpm"] else "--"
        print(f"  {label}  n={b['n']:<6} contact={b['contact'] / b['n'] * 100:>5.1f}%  "
              f"rr={b['rr'] / b['n'] * 100:>5.1f}%  bpm={bpm}")

    versions = {row["version"] for row in rows}
    print(f"Record versions: {sorted(versions)}")
    gaps = [(cur["ts_ms"] - prev["ts_ms"]) / 1000
            for prev, cur in zip(rows, rows[1:])]
    big = [(gap, prev["ts_ms"], cur["ts_ms"]) for prev, cur, gap in zip(rows, rows[1:], gaps) if gap > 1800]
    print("Gaps > 30 min:")
    for gap, a, b in big:
        print(f"  {gap / 60:.0f} min  {ms(a)} -> {ms(b)}")
    if not big:
        print("  none")

    contact = sum(1 for row in rows if row.get("contact")) / len(rows)
    print(f"Overall contact fraction: {contact:.2f} "
          "(a session needs >= 30 min, >= 0.50 contact, inside 21:00-06:00 local)")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ip")
    parser.add_argument("--historical", action="store_true")
    parser.add_argument("--sleep", action="store_true")
    parser.add_argument("--hr", action="store_true")
    parser.add_argument("--frames", action="store_true")
    parser.add_argument("--hr-limit", type=int, default=5000)
    parser.add_argument("--frames-limit", type=int, default=300)
    args = parser.parse_args()

    ip = args.ip or find_phone()
    if not ip:
        sys.exit("Phone not found. Make sure the app is open and on the same Wi-Fi, or pass --ip.")
    print(f"Phone: {ip}:{PORT}\n")
    print_summary(ip)
    if args.sleep:
        print_sleep(ip)
    if args.hr:
        print_hr(ip, args.hr_limit)
    if args.frames:
        print_frames(ip, args.frames_limit)
    if args.historical:
        print_historical(ip)
    if not (args.sleep or args.hr or args.frames or args.historical):
        print("\n(no --sleep/--hr/--frames/--historical given; pass them to pull and analyze the rows)")


if __name__ == "__main__":
    main()
