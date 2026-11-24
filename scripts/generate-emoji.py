"""Regenerate the read-only Unicode 17.0 Emoji table from emoji-test.txt."""
import hashlib
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_bytes()
if hashlib.sha256(source).hexdigest() != "1d8a944f88d7952f7ef7c5167fef3c67995bcae24543949710231b03a201acda":
    raise SystemExit("Expected https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt")

children = {(): set()}
wide = set()
for line in source.decode().splitlines():
    record = line.split("#", 1)[0].strip()
    if not record:
        continue
    codes, status = record.split(";")
    seq = tuple(int(n, 16) for n in codes.split())
    if status.strip() == "fully-qualified" or len(seq) > 1:
        wide.add(seq)
    for i, code in enumerate(seq):
        children[seq[:i]].add(code)
        children.setdefault(seq[:i+1], set())

queue = [((), 0)]
rows = []
for index, (seq, parent) in enumerate(queue):
    rows.append((seq[-1] if seq else 0, parent | (0x8000 if seq in wide else 0), len(queue)))
    queue.extend((seq + (code,), index) for code in sorted(children[seq]))
rows.append((0, 0, len(queue)))
assert len(rows) < 0x8000 and max(map(len, children)) <= 16
print("// Generated from Unicode Emoji 17.0 by scripts/generate-emoji.py. See Resources/Unicode-LICENSE.txt.")
for i in range(0, len(rows), 5):
    print("    " + " ".join("{0x%x,%d,%d}," % row for row in rows[i:i+5]))
