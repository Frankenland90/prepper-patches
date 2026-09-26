#!/usr/bin/env python3
"""Backup versioning + safe restore UI/API.

Additive / force-capable /* bakRestore */ patcher.
- Guarantees flask `request`, `import re`, `import json`
- Upgrades OLD anchors when present
- Injects missing API/UI pieces when only partial/broken bakRestore remains
- Second run repairs a broken install (does not no-op on marker alone)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


def must_replace(text: str, old: str, new: str, label: str) -> str:
    n = text.count(old)
    if n != 1:
        raise SystemExit("STOP %s: Anker %sx (erwartet 1)." % (label, n))
    return text.replace(old, new, 1)


def ensure_imports(text: str, changes: list) -> str:
    """Ensure request in flask import, and top-level import re / import json."""
    m = re.search(r"^from flask import ([^\n]+)$", text, re.M)
    if m:
        items = [x.strip() for x in m.group(1).split(",")]
        if "request" not in items:
            items.append("request")
            new_line = "from flask import " + ", ".join(items)
            text = text[: m.start()] + new_line + text[m.end() :]
            changes.append("flask+request")
    elif "from flask import" not in text:
        text = "from flask import Flask, render_template_string, jsonify, request\n" + text
        changes.append("flask-import-added")

    def ensure_top_import(mod: str, t: str):
        if re.search(r"(?m)^import\s+([^\n]*\b" + re.escape(mod) + r"\b)", t):
            return t, False
        if re.search(r"(?m)^from\s+" + re.escape(mod) + r"\s+import\s+", t):
            return t, False
        fm = re.search(r"(?m)^from flask import [^\n]+\n", t)
        if fm:
            return t[: fm.end()] + ("import %s\n" % mod) + t[fm.end() :], True
        return ("import %s\n" % mod) + t, True

    text, added = ensure_top_import("re", text)
    if added:
        changes.append("import-re")
    text, added = ensure_top_import("json", text)
    if added:
        changes.append("import-json")
    return text
