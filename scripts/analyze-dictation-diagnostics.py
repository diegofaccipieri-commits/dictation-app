#!/usr/bin/env python3
import glob
import json
import os
import re
from collections import Counter

LOG_DIR = os.path.expanduser("~/Library/Logs/DictationApp")
FILES = sorted(glob.glob(os.path.join(LOG_DIR, "diagnostics-*.jsonl")))

SUFFIXES = (
    "ção", "ções", "são", "sões", "agem", "mente", "amento", "amentos",
    "imento", "imentos", "ário", "ária", "dade", "tura", "eiro", "eira",
    "ando", "endo", "indo", "inho", "inha", "ado", "ada", "ificado",
    "ificada", "quela", "quele", "tion", "tions", "ment", "ments",
    "e", "o",
)
UNSAFE = {
    "com o", "com a", "com os", "com as",
    "por o", "por a", "por os", "por as",
}
WORD = r"[^\W\d_]"
FRAGMENT_RE = re.compile(
    rf"\b({WORD}{{2,10}})\s+({'|'.join(map(re.escape, SUFFIXES))})\b",
    re.IGNORECASE,
)


def context(text, start, end, radius=55):
    left = max(0, start - radius)
    right = min(len(text), end + radius)
    return text[left:right].replace("\n", " ")


def load_events():
    for path in FILES:
        with open(path, "r", encoding="utf-8") as f:
            for line_no, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError as exc:
                    print(f"bad json: {path}:{line_no}: {exc}")
                    continue
                event["_file"] = path
                event["_line"] = line_no
                yield event


def main():
    if not FILES:
        print(f"No diagnostics files found in {LOG_DIR}")
        return

    events = list(load_events())
    counts = Counter(e.get("event", "unknown") for e in events)
    print(f"Diagnostics directory: {LOG_DIR}")
    print(f"Files: {len(FILES)}")
    print(f"Events: {len(events)}")
    for name, count in sorted(counts.items()):
        print(f"  {name}: {count}")

    findings = []
    for event in events:
        event_name = event.get("event")
        if event_name == "final_paste":
            text = event.get("text", "")
        elif event_name == "whisper_response":
            text = event.get("cleaned_text", "")
        else:
            continue

        for match in FRAGMENT_RE.finditer(text):
            pair = f"{match.group(1)} {match.group(2)}".lower()
            if pair in UNSAFE:
                continue
            findings.append((event, match.group(0), context(text, match.start(), match.end())))

    print(f"\nPossible word-fragment findings: {len(findings)}")
    for event, fragment, snippet in findings[:80]:
        print(
            f"- {event.get('timestamp', '?')} "
            f"{event.get('event', '?')} "
            f"{fragment!r}: {snippet}"
        )

    if len(findings) > 80:
        print(f"... {len(findings) - 80} more not shown")


if __name__ == "__main__":
    main()
