"""Independent reference for PLAN.md 8 golden cases. Writes shared/golden/metrics_v1.json.

Written from the PLAN.md formulas, not from the Swift code. Keeps the existing sections as they are.
"""
import json
import math
import statistics
import sys
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

GOLDEN = str(__import__("pathlib").Path(__file__).resolve().parent.parent / "metrics_v1.json")
MIN = 60_000
WIN = 300_000
CHI = "America/Chicago"
LON = "Europe/London"
D = date(2026, 10, 8)
PROFILE_M = {"sex": "male", "age_years": 40, "height_cm": 180, "weight_kg": 80}


def local_ms(d, hour, tz):
    return round(datetime(d.year, d.month, d.day, hour, tzinfo=ZoneInfo(tz)).timestamp() * 1000)


def night(d, tz):
    return local_ms(d, 0, tz), local_ms(d, 6, tz)


def down(ts, size):
    return ts - ts % size


def up(ts, size):
    d = down(ts, size)
    return d if d == ts else d + size


def median(xs):
    return statistics.median(xs) if xs else None


def mad(xs):
    if not xs:
        return None
    c = statistics.median(xs)
    return statistics.median([abs(x - c) for x in xs])


def phi(z):
    return 0.5 * math.erfc(-z / math.sqrt(2))


def rnd(x):
    return math.floor(x + 0.5)


def margin_ok(x):
    # Stress rounds 100*Phi; keep away from .5 so libm differences cannot flip the integer.
    frac = abs((x - math.floor(x)) - 0.5)
    return frac > 0.01


# ---- minute aggregation -------------------------------------------------------------

def minute_aggregates(samples):
    acc = {}
    for ts, bpm, contact in samples:
        if contact == "not_detected":
            continue
        m = down(ts, MIN)
        a = acc.setdefault(m, {"sum": 0, "min": bpm, "max": bpm, "n": 0})
        a["sum"] += bpm
        a["min"] = min(a["min"], bpm)
        a["max"] = max(a["max"], bpm)
        a["n"] += 1
    out = []
    for m in sorted(acc):
        a = acc[m]
        out.append({
            "minute_ms": m,
            "hr_avg": a["sum"] / a["n"],
            "hr_min": a["min"],
            "hr_max": a["max"],
            "hr_n": a["n"],
            "coverage": a["n"] / 60,
        })
    return out


# ---- resting HR -----------------------------------------------------------------------

def rhr_in_range(minutes, lo, hi):
    elig = {m[0]: m[1] for m in minutes if lo <= m[0] < hi and m[2] / 60 >= 0.8}
    best = None
    for s in elig:
        keys = [s + k * MIN for k in range(5)]
        if all(k in elig for k in keys):
            mean = sum(elig[k] for k in keys) / 5
            best = mean if best is None else min(best, mean)
    return best


# ---- HRmax, HRR, zones ----------------------------------------------------------------

def hrmax(age, user):
    return float(user) if user is not None else 208 - 0.7 * age


def hrr_fraction(hr, rhr, mx):
    reserve = mx - rhr
    if reserve <= 0:
        return None
    return (hr - rhr) / reserve


def zone_of(f):
    if f < 0.5:
        return "below"
    if f < 0.6:
        return "zone1"
    if f < 0.7:
        return "zone2"
    if f < 0.8:
        return "zone3"
    if f < 0.9:
        return "zone4"
    return "zone5"


def is_exertion(hr, rhr, mx):
    if hr is None or rhr is None:
        return False
    f = hrr_fraction(hr, rhr, mx)
    return f is not None and f > 0.40


# ---- R-R windows and Baevsky ----------------------------------------------------------

def baevsky(rr):
    if len(rr) < 2:
        return None, None
    lo, hi = min(rr), max(rr)
    if hi <= lo:
        return None, None
    bins = {}
    for r in rr:
        b = math.floor(r / 50.0)
        bins[b] = bins.get(b, 0) + 1
    amo = max(bins.values()) / len(rr) * 100
    mo = statistics.median(rr) / 1000
    mx = (hi - lo) / 1000
    si = amo / (2 * mo * mx)
    return si, math.sqrt(si)


def windows(samples, rr, lo, hi):
    hr = {}
    for ts, bpm, contact in samples:
        if contact == "not_detected":
            continue
        hr.setdefault(down(ts, WIN), []).append(bpm)
    rrb = {}
    for ts, r in rr:
        rrb.setdefault(down(ts, WIN), []).append(r)
    out = []
    for s in range(up(lo, WIN), hi, WIN):
        vals = rrb.get(s, [])
        total = sum(vals)
        valid = total >= 180000
        hrs = hr.get(s)
        w = {
            "start": s,
            "hr": (sum(hrs) / len(hrs)) if hrs else None,
            "rr_count": len(vals),
            "rr_sum_ms": total,
            "valid": valid,
            "rmssd": None, "sdnn": None, "ln": None, "baevsky": None,
        }
        if valid and len(vals) >= 2:
            n = len(vals)
            ss = sum((vals[i + 1] - vals[i]) ** 2 for i in range(n - 1))
            w["rmssd"] = math.sqrt(ss / (n - 1))
            mean = sum(vals) / n
            w["sdnn"] = math.sqrt(sum((x - mean) ** 2 for x in vals) / (n - 1))
            if w["rmssd"] > 0:
                w["ln"] = math.log(w["rmssd"])
            w["baevsky"] = baevsky(vals)[1]
        out.append(w)
    return out


# ---- stress ---------------------------------------------------------------------------

def is_night(start, lo, hi):
    return lo <= start < hi


def baseline(history, day, tz, rhr, mx):
    valid_days = 0
    hr_only_days = 0
    rr_hr, rr_ln, hro = [], [], []
    for k in range(1, 15):
        lo, hi = night(day - timedelta(days=k), tz)
        nights = [w for w in history if is_night(w["start"], lo, hi) and not is_exertion(w["hr"], rhr, mx)]
        valids = [w for w in nights if w["valid"]]
        if len(valids) >= 12:
            valid_days += 1
        hrn = [w for w in nights if w["hr"] is not None]
        if len(hrn) >= 12:
            hr_only_days += 1
        rr_hr += [w["hr"] for w in valids if w["hr"] is not None]
        rr_ln += [w["ln"] for w in valids if w["ln"] is not None]
        hro += [w["hr"] for w in hrn]
    return {
        "valid_days": valid_days,
        "hr_median": median(rr_hr), "hr_mad": mad(rr_hr),
        "ln_rmssd_median": median(rr_ln), "ln_rmssd_mad": mad(rr_ln),
        "hr_only_days": hr_only_days,
        "hr_only_median": median(hro), "hr_only_mad": mad(hro),
    }


def score(w, rhr, mx, b):
    if is_exertion(w["hr"], rhr, mx):
        return None, "exertion"
    if w["valid"]:
        if b["valid_days"] < 7:
            return None, "calibrating"
        ok = (w["hr"] is not None and w["ln"] is not None
              and b["hr_median"] is not None and b["hr_mad"] is not None and b["hr_mad"] > 0
              and b["ln_rmssd_median"] is not None and b["ln_rmssd_mad"] is not None and b["ln_rmssd_mad"] > 0)
        if not ok:
            return None, "insufficient"
        zhr = (w["hr"] - b["hr_median"]) / (1.4826 * b["hr_mad"])
        zhrv = (w["ln"] - b["ln_rmssd_median"]) / (1.4826 * b["ln_rmssd_mad"])
        s = 0.5 * zhr - 0.5 * zhrv
        assert margin_ok(100 * phi(s)), ("stress rounding margin", s)
        return rnd(100 * phi(s)), "value"
    if b["hr_only_days"] < 7:
        return None, "calibrating"
    if (w["hr"] is None or b["hr_only_median"] is None or b["hr_only_mad"] is None
            or b["hr_only_mad"] <= 0):
        return None, "insufficient"
    z = (w["hr"] - b["hr_only_median"]) / (1.4826 * b["hr_only_mad"])
    assert margin_ok(100 * phi(z)), ("hr_only rounding margin", z)
    return rnd(100 * phi(z)), "hr_only"


# ---- kcal -----------------------------------------------------------------------------

def minute_energy(hr, p, rhr, mx):
    male = p["sex"] == "male"
    w, h, a = p["weight_kg"], p["height_cm"], p["age_years"]
    bmr_day = 10 * w + 6.25 * h - 5 * a + (5 if male else -161)
    bmr = bmr_day / 1440
    if hr is None:
        return bmr, 0.0, True
    flex = max(90, rhr + 0.30 * (mx - rhr)) if rhr is not None else 90
    if hr >= flex:
        if male:
            kj = -55.0969 + 0.6309 * hr + 0.1988 * w + 0.2017 * a
        else:
            kj = -20.4022 + 0.4472 * hr - 0.1263 * w + 0.074 * a
        kcal = max(bmr, kj / 4.184)
    else:
        kcal = bmr
    return kcal, max(0.0, kcal - bmr), False


def minute_rows(lo, hi, samples, rr, profile, rhr, mx, history, day, tz):
    b = baseline(as_windows(history), day, tz, rhr, mx)
    mins = {m["minute_ms"]: m for m in minute_aggregates(samples)}
    wins = {w["start"]: w for w in windows(samples, rr, down(lo, WIN), up(hi, WIN))}
    scores = {s: score(w, rhr, mx, b) for s, w in wins.items()}
    rows = []
    for m in range(lo, hi, MIN):
        agg = mins.get(m)
        ws = down(m, WIN)
        w = wins[ws]
        st, state = scores[ws]
        kcal, active, est = minute_energy(agg["hr_avg"] if agg else None, profile, rhr, mx)
        rows.append({
            "minute_ms": m,
            "hr_avg": agg["hr_avg"] if agg else None,
            "hr_min": agg["hr_min"] if agg else None,
            "hr_max": agg["hr_max"] if agg else None,
            "hr_n": agg["hr_n"] if agg else 0,
            "rmssd_ms": w["rmssd"],
            "sdnn_ms": w["sdnn"],
            "baevsky_sqrt": w["baevsky"],
            "stress": st,
            "stress_state": state,
            "kcal": kcal,
            "active_kcal": active,
            "kcal_estimated": est,
        })
    return rows


# ---- case builders --------------------------------------------------------------------

def hist_default(k, j):
    hr = 58.0 + ((k * 7 + j * 3) % 9) * 0.5
    ln = 3.40 + 0.02 * ((k * 5 + j * 3) % 11 - 5)
    return hr, ln


def history_s1():
    """Days -1..-8 with 12 valid windows each, day -2 has one exertion window (excluded, leaving 11),
    day -15 is outside the lookback, and two windows on the scored day must be excluded."""
    rows = []
    for k in list(range(1, 9)):
        base = local_ms(D - timedelta(days=k), 0, CHI)
        for j in range(12):
            hr, ln = hist_default(k, j)
            if k == 2 and j == 0:
                hr = 130.0
            rows.append([base + j * WIN, hr, True, ln])
    base15 = local_ms(D - timedelta(days=15), 0, CHI)
    for j in range(12):
        rows.append([base15 + j * WIN, 150.0, True, 2.0])
    today = local_ms(D, 0, CHI)
    rows.append([today + 6 * WIN, 160.0, True, 2.0])      # 00:30 tonight, excluded
    rows.append([local_ms(D, 14, CHI), 90.0, True, 3.0])  # daytime, not a night window
    return rows


def history_wide():
    rows = []
    for k in range(1, 9):
        base = local_ms(D - timedelta(days=k), 0, CHI)
        for j in range(12):
            _, ln = hist_default(k, j)
            rows.append([base + j * WIN, 56.0 + 2.0 * ((k * 7 + j * 3) % 9), True, ln])
    return rows


def history_days(offsets, valid=True, constant=False):
    rows = []
    for k in offsets:
        base = local_ms(D - timedelta(days=k), 0, CHI)
        for j in range(12):
            if constant:
                hr, ln = 60.0, 3.40
            else:
                hr, ln = hist_default(k, j)
            rows.append([base + j * WIN, hr, valid, ln])
    return rows


def as_windows(rows):
    return [{"start": r[0], "hr": r[1], "valid": r[2], "ln": r[3]} for r in rows]


def stress_case(name, history, current, rhr, mx, expected_state=None):
    b = baseline(as_windows(history), D, CHI, rhr, mx)
    cur = as_windows([current])[0]
    st, state = score(cur, rhr, mx, b)
    expected = dict(b)
    expected["stress"] = st
    expected["state"] = state
    return {
        "name": name,
        "day": {"year": D.year, "month": D.month, "day": D.day},
        "tz": CHI,
        "resting_hr": rhr,
        "max_hr": mx,
        "history": history,
        "current": current,
        "expected": expected,
    }


def minute_samples(start, minute_hr, n=60, not_detected=(), none_contact=(4,)):
    """1 Hz samples for one minute. Indices in not_detected are notDetected, indices in none_contact are unknown."""
    out = []
    for i in range(n):
        ts = start + i * 1000
        if i in not_detected:
            c = "not_detected"
        elif i in none_contact:
            c = None
        else:
            c = "detected"
        out.append([ts, minute_hr(i), c])
    return out


def build():
    cases = {}

    # minute aggregation
    minute_cases = []
    base = local_ms(D, 0, CHI)
    s1 = [
        [base + 0, 60, "detected"],
        [base + 1000, 62, None],
        [base + 59999, 64, "detected"],
        [base + 60000, 70, "detected"],
        [base + 61000, 200, "not_detected"],
        [base + 62000, 72, None],
        [base + 120000, 90, "not_detected"],
        [base + 180000, 100, None],
    ]
    minute_cases.append({"name": "contact_rules_and_minute_boundaries", "samples": s1,
                         "expected": {"minutes": minute_aggregates(s1)}})
    s2 = [[base + i * 1000, 70 + (i % 7), ("not_detected" if i < 12 else "detected")] for i in range(60)]
    minute_cases.append({"name": "coverage_exactly_0_8_is_48_of_60", "samples": s2,
                         "expected": {"minutes": minute_aggregates(s2)}})
    s3 = [[base + i * 1000, 80, "not_detected"] for i in range(60)]
    minute_cases.append({"name": "all_not_detected_minute_is_absent", "samples": s3,
                         "expected": {"minutes": minute_aggregates(s3)}})
    cases["minute_cases"] = minute_cases

    # resting HR (minutes given sparsely; absent minutes have no samples)
    def run(start, hr, n=60, count=5):
        return [[start + k * MIN, float(hr), n] for k in range(count)]

    t3 = local_ms(D, 3, CHI)
    rhr_cases = []
    mins1 = [[t3 + k * MIN, float(v), 60] for k, v in enumerate([100, 100, 100, 50, 50, 50, 50, 50])]
    rhr_cases.append({"name": "rolling_window_not_block_aligned", "local_day": {"year": 2026, "month": 10, "day": 8},
                      "tz": CHI, "minutes": mins1,
                      "expected": {"rhr": rhr_in_range(mins1, *night(D, CHI))}})
    t2 = local_ms(D, 2, CHI)
    t4 = local_ms(D, 4, CHI)
    mins2 = (run(t2, 50, 47) + run(t3, 60, 48)
             + [[t4 + k * MIN, 55.0, 47 if k == 2 else 60] for k in range(5)])
    rhr_cases.append({"name": "coverage_048_included_047_excluded", "local_day": {"year": 2026, "month": 10, "day": 8},
                      "tz": CHI, "minutes": mins2,
                      "expected": {"rhr": rhr_in_range(mins2, *night(D, CHI))}})
    t555 = local_ms(D, 5, CHI) + 55 * MIN
    mins3 = run(t555, 66) + run(local_ms(D, 6, CHI), 45)
    rhr_cases.append({"name": "minutes_from_0600_are_outside_the_night", "local_day": {"year": 2026, "month": 10, "day": 8},
                      "tz": CHI, "minutes": mins3,
                      "expected": {"rhr": rhr_in_range(mins3, *night(D, CHI))}})
    mins4 = run(t3 - 2 * MIN, 58)[:0] + [[t3 + k * MIN, 58.0, 60] for k in range(4)]
    rhr_cases.append({"name": "four_minutes_is_no_window", "local_day": {"year": 2026, "month": 10, "day": 8},
                      "tz": CHI, "minutes": mins4,
                      "expected": {"rhr": rhr_in_range(mins4, *night(D, CHI))}})
    dst = date(2026, 3, 8)
    mins5 = run(local_ms(dst, 0, CHI), 58) + run(local_ms(dst, 6, CHI), 40)
    rhr_cases.append({"name": "dst_start_night_is_five_hours_chicago", "local_day": {"year": 2026, "month": 3, "day": 8},
                      "tz": CHI, "minutes": mins5,
                      "expected": {"rhr": rhr_in_range(mins5, *night(dst, CHI))}})
    mins6 = run(local_ms(D, 0, LON), 62) + run(local_ms(D, 6, LON), 40)
    rhr_cases.append({"name": "london_bst_night_offset", "local_day": {"year": 2026, "month": 10, "day": 8},
                      "tz": LON, "minutes": mins6,
                      "expected": {"rhr": rhr_in_range(mins6, *night(D, LON))}})
    cases["rhr_cases"] = rhr_cases

    # HRmax and zones
    hrmax_cases = [
        {"name": "tanaka_age_40", "age_years": 40, "user_hr_max": None, "expected": {"hr_max": hrmax(40, None)}},
        {"name": "tanaka_age_55", "age_years": 55, "user_hr_max": None, "expected": {"hr_max": hrmax(55, None)}},
        {"name": "user_entered_overrides_tanaka", "age_years": 30, "user_hr_max": 190,
         "expected": {"hr_max": hrmax(30, 190)}},
    ]
    cases["hrmax_cases"] = hrmax_cases
    hrr_cases = []
    for name, hr, rhr, mx in [
        ("at_resting", 60, 60, 180), ("below_50_percent", 96, 60, 180),
        ("exactly_40_percent_not_exertion", 108, 60, 180), ("exactly_50_percent_zone1", 120, 60, 180),
        ("exactly_60_percent_zone2", 132, 60, 180), ("zone3", 150, 60, 180),
        ("exactly_90_percent_zone5", 168, 60, 180), ("above_max", 190, 60, 180),
        ("no_reserve_is_null", 90, 60, 60),
    ]:
        f = hrr_fraction(hr, rhr, mx)
        hrr_cases.append({
            "name": name, "hr": hr, "resting_hr": rhr, "max_hr": mx,
            "expected": {
                "hrr_fraction": f,
                "zone": zone_of(f) if f is not None else None,
                "exertion": is_exertion(hr, rhr, mx),
            },
        })
    cases["hrr_cases"] = hrr_cases

    # 5-minute windows
    wsamples = [[0, 60, "detected"], [1000, 62, None], [2000, 200, "not_detected"], [3000, 64, "detected"],
                [300000, 70, None]]
    wrr = []
    for i in range(226):
        wrr.append([i * 1000, 790.0 if i % 2 == 0 else 810.0])
    for i in range(224):
        wrr.append([300000 + i * 1000, 800.0])
    for i in range(225):
        wrr.append([600000 + i * 1000, 800.0])
    wins = windows(wsamples, wrr, 0, 1200000)
    window_out = []
    for w in wins:
        window_out.append({
            "start_ms": w["start"], "hr_mean": w["hr"], "rr_count": w["rr_count"], "rr_sum_ms": w["rr_sum_ms"],
            "valid": w["valid"], "rmssd": w["rmssd"], "sdnn": w["sdnn"], "ln_rmssd": w["ln"],
            "baevsky_sqrt": w["baevsky"],
        })
    cases["window_cases"] = [{
        "name": "hr_mean_rr_validity_boundary_and_equal_intervals",
        "samples": wsamples, "rr": wrr,
        "range_start_ms": 0, "range_end_ms": 1200000,
        "expected": {"windows": window_out},
    }]

    # Baevsky
    bv = []
    gen = [800 + ((i * 37) % 101 - 50) for i in range(60)]
    for name, rr in [
        ("five_intervals_mode_two", [800.0, 850.0, 900.0, 850.0, 800.0]),
        ("mode_bin_holds_three_of_four", [800.0, 825.0, 849.0, 860.0]),
        ("generated_60_intervals", [float(x) for x in gen]),
        ("equal_intervals_is_null", [800.0, 800.0]),
        ("single_interval_is_null", [800.0]),
    ]:
        si, sq = baevsky(rr)
        bv.append({"name": name, "rr_ms": rr, "expected": {"si": si, "sqrt_si": sq}})
    cases["baevsky_cases"] = bv

    # stress
    hist_s1 = history_s1()
    stress_cases = [
        stress_case("value_seven_qualifying_days", hist_s1, [local_ms(D, 3, CHI) + 2 * WIN, 61.0, True, 3.45],
                    60.0, 180.0),
        stress_case("calibrating_six_qualifying_days", history_days(range(1, 7)),
                    [local_ms(D, 3, CHI) + 2 * WIN, 61.0, True, 3.45], 60.0, 180.0),
        stress_case("exertion_window", hist_s1, [local_ms(D, 3, CHI) + 2 * WIN, 140.0, True, 3.30], 60.0, 180.0),
        stress_case("hr_only_without_rr", hist_s1, [local_ms(D, 3, CHI) + 2 * WIN, 61.0, False, None], 60.0, 180.0),
        stress_case("mad_zero_is_insufficient", history_days(range(1, 9), constant=True),
                    [local_ms(D, 3, CHI) + 2 * WIN, 61.0, True, 3.45], 60.0, 180.0),
        stress_case("hr_only_calibrating_six_days", history_days(range(1, 7), valid=False),
                    [local_ms(D, 3, CHI) + 2 * WIN, 61.0, False, None], 60.0, 180.0),
    ]
    cases["stress_cases"] = stress_cases

    # minute pipeline
    pm = []
    dd = D
    lo = local_ms(dd, 0, CHI)
    sm = []
    for k in range(5):
        sm += minute_samples(lo + k * MIN, lambda i, k=k: 60 + (i + k) % 3,
                             not_detected=tuple(range(10)) if k == 2 else ())
    rr_pipe = [[lo + i * 1000, 785.0 if i % 2 == 0 else 815.0] for i in range(226)]
    rows1 = minute_rows(lo, lo + 5 * MIN, sm, rr_pipe, PROFILE_M, 60.0, 180.0, hist_s1, dd, CHI)
    pm.append({"name": "rest_window_with_rr_value_state", "tz": CHI,
               "day": {"year": 2026, "month": 10, "day": 8},
               "range_start_ms": lo, "range_end_ms": lo + 5 * MIN,
               "profile": PROFILE_M, "resting_hr": 60.0, "max_hr": 180.0,
               "history": hist_s1, "samples": sm, "rr": rr_pipe,
               "expected": {"rows": rows1}})

    lo2 = local_ms(dd, 0, CHI)
    sm2 = []
    sm2 += []  # minute 0: no samples, a gap
    sm2 += minute_samples(lo2 + MIN, lambda i: 150)
    sm2 += minute_samples(lo2 + 2 * MIN, lambda i: 150, not_detected=tuple(range(60)))
    rows2 = minute_rows(lo2, lo2 + 3 * MIN, sm2, [], PROFILE_M, 60.0, 180.0, hist_s1, dd, CHI)
    pm.append({"name": "gap_keytel_and_exertion_window", "tz": CHI,
               "day": {"year": 2026, "month": 10, "day": 8},
               "range_start_ms": lo2, "range_end_ms": lo2 + 3 * MIN,
               "profile": PROFILE_M, "resting_hr": 60.0, "max_hr": 180.0,
               "history": hist_s1, "samples": sm2, "rr": [],
               "expected": {"rows": rows2}})

    lo3 = local_ms(dd, 0, CHI) + 10 * MIN
    sm3 = minute_samples(lo3, lambda i: 95)
    for k in range(1, 5):
        sm3 += minute_samples(lo3 + k * MIN, lambda i: 60)
    rows3 = minute_rows(lo3, lo3 + 5 * MIN, sm3, [], PROFILE_M, None, 180.0, history_wide(), dd, CHI)
    pm.append({"name": "no_resting_hr_floor_and_hr_only", "tz": CHI,
               "day": {"year": 2026, "month": 10, "day": 8},
               "range_start_ms": lo3, "range_end_ms": lo3 + 5 * MIN,
               "profile": PROFILE_M, "resting_hr": None, "max_hr": 180.0,
               "history": history_wide(), "samples": sm3, "rr": [],
               "expected": {"rows": rows3}})
    cases["minute_metric_cases"] = pm
    return cases


def main():
    """Keep the existing text of the file as it is and append the new sections after it."""
    out_path = sys.argv[1] if len(sys.argv) > 1 else GOLDEN
    with open(GOLDEN) as f:
        original = f.read()
    existing = json.loads(original)
    new = build()
    assert existing["format_version"] == 1
    body = original.rstrip()
    assert body.endswith("}")
    body = body[:-1].rstrip()
    keys = ["minute_cases", "rhr_cases", "hrmax_cases", "hrr_cases", "window_cases",
            "baevsky_cases", "stress_cases", "minute_metric_cases"]
    if all(k in existing for k in keys):
        # Already generated: check that the file still matches the reference.
        differs = [k for k in keys if json.loads(json.dumps(new[k])) != existing[k]]
        if differs:
            sys.exit(f"golden file differs from the reference in: {', '.join(differs)}")
        print("metrics_v1.json matches the reference")
        return
    parts = []
    for key in ["minute_cases", "rhr_cases", "hrmax_cases", "hrr_cases", "window_cases",
                "baevsky_cases", "stress_cases", "minute_metric_cases"]:
        assert key not in existing
        parts.append(f'  "{key}": ' + dump(new[key], 1))
    with open(out_path, "w") as f:
        f.write(body + ",\n" + ",\n".join(parts) + "\n}\n")
    for key in new:
        print(key, len(new[key]))


def fmt_scalar(v):
    return json.dumps(v)


def is_scalar(v):
    return not isinstance(v, (dict, list))


def dump(obj, depth=0):
    pad = "  " * depth
    if isinstance(obj, dict):
        if not obj:
            return "{}"
        items = [f'{pad}  {json.dumps(k)}: {dump(v, depth + 1)}' for k, v in obj.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(obj, list):
        if not obj:
            return "[]"
        if all(is_scalar(x) for x in obj):
            return "[" + ", ".join(fmt_scalar(x) for x in obj) + "]"
        if all(isinstance(x, list) and all(is_scalar(y) for y in x) for x in obj):
            # Rows of scalars, one row per line, for the compact input series.
            rows = [pad + "  [" + ", ".join(fmt_scalar(y) for y in x) + "]" for x in obj]
            return "[\n" + ",\n".join(rows) + "\n" + pad + "]"
        items = [pad + "  " + dump(x, depth + 1) for x in obj]
        return "[\n" + ",\n".join(items) + "\n" + pad + "]"
    return fmt_scalar(obj)


if __name__ == "__main__":
    main()
