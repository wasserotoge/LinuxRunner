#!/usr/bin/env python3
"""Emit the tails of build logs as GitHub Actions error annotations.

Annotations are readable through the public check-run API, unlike job logs,
so a failed run can be diagnosed without repository admin rights.
Usage: annotate-logs.py TITLE=PATH [TITLE=PATH ...]
"""
import pathlib
import sys

MAX_ANNOTATIONS = 10  # GitHub keeps at most 10 error annotations per step
LINES_PER_FILE = 120
LINES_PER_CHUNK = 40
MAX_CHARS = 6000


def escape_data(text):
    return text.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')


def escape_property(text):
    return escape_data(text).replace(':', '%3A').replace(',', '%2C')


budget = MAX_ANNOTATIONS
for spec in sys.argv[1:]:
    title, _, name = spec.partition('=')
    path = pathlib.Path(name)
    if budget <= 0 or not path.is_file() or path.stat().st_size == 0:
        continue
    lines = path.read_text(errors='replace').splitlines()[-LINES_PER_FILE:]
    chunks = [lines[i:i + LINES_PER_CHUNK] for i in range(0, len(lines), LINES_PER_CHUNK)]
    for number, chunk in enumerate(chunks, 1):
        if budget <= 0:
            break
        message = '\n'.join(chunk)[-MAX_CHARS:]
        label = f'{title} ({number}/{len(chunks)})'
        print(f'::error title={escape_property(label)}::{escape_data(message)}')
        budget -= 1
