"""Compare native VT cores on macOS. Run build.sh first, then run this file."""
import argparse
import os
import random
import statistics
import subprocess
import tempfile
import unicodedata
from pathlib import Path

COLS, ROWS = 100, 32
OUT = Path(__file__).resolve().parents[2] / "build" / "terminal-comparison"


def workloads():
    # Construct the expected visible text independently of the escape stream.
    cases = {}
    for name in ("ascii", "mixed", "progress", "tui"):
        chunks = []
        screen = [""] * ROWS
        for i in range(512):
            status = f"worker-{i % 16:02}  file-{i:04}.o  " + "=" * (10 + i % 35)
            if name in ("ascii", "mixed"):
                if name == "mixed" and i % 2:
                    status = "已完成 " + status
                chunks.append(("\x1b[32mINFO\x1b[0m " if name == "mixed" else "INFO ") + status + "\r\n")
                screen = screen[1:] + [""]
                screen[-2] = "INFO " + status
            else:
                row = 0 if name == "progress" else i % ROWS
                # Every overwrite has the same width, just like a fixed status column.
                status = status.ljust(68)
                prefix = "\r" if name == "progress" else f"\x1b[{row + 1};1H\x1b[3{i % 7 + 1}m"
                chunks.append(prefix + status)
                screen[row] = status
        expected = []
        for line in screen:
            cells = []
            for c in line:
                cells.append(ord(c))
                if unicodedata.east_asian_width(c) in ("F", "W"):
                    cells.append(32)
            expected.extend(cells + [32] * (COLS - len(cells)))
        cases[name] = ("".join(chunks).encode(), expected)
    return cases


def trial(binary, path, repeats, expected):
    # wait4 returns this child's peak RSS and CPU time, without sampling other processes.
    with tempfile.TemporaryFile() as output:
        proc = subprocess.Popen([binary, path, str(repeats)], stdout=output)
        _, status, usage = os.wait4(proc.pid, 0)
        proc.returncode = os.waitstatus_to_exitcode(status)
        if proc.returncode:
            raise RuntimeError(f"{binary.name} exited with {proc.returncode}")
        output.seek(0)
        seconds = float(output.readline())
        cells = [int(cell, 16) for cell in output.read().split()]
    if cells != expected:
        raise ValueError(f"{binary.name}: incorrect screen for {path.name}")
    return seconds, usage.ru_maxrss / (1024 ** 2), usage.ru_utime + usage.ru_stime


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engines", nargs="*", default=["yaaterm", "ghostty", "alacritty"])
    parser.add_argument("--rounds", type=int, default=7)
    parser.add_argument("--repeats", type=int, default=1024)
    args = parser.parse_args()
    if min(args.rounds, args.repeats) < 1:
        parser.error("rounds and repeats must be positive")
    randomizer = random.Random(42)
    print("case engine MiB/s peak_RSS_MiB process_CPU_ms", flush=True)
    for case, (data, expected) in workloads().items():
        path = OUT / (case + ".vt")
        path.write_bytes(data)
        results = {name: [] for name in args.engines}
        for n in range(args.rounds + 1):
            order = list(results)
            randomizer.shuffle(order)
            for name in order:
                seconds, rss, cpu = trial(OUT / name, path, args.repeats, expected)
                if n:
                    results[name].append((len(data) * args.repeats / (1024**2 * seconds), rss, cpu * 1000))
        for name, samples in results.items():
            medians = [statistics.median(metric) for metric in zip(*samples)]
            print(case, name, *(f"{m:.2f}" for m in medians), flush=True)


if __name__ == "__main__":
    main()
