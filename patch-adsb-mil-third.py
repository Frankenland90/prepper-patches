#!/usr/bin/env python3
"""ADSB-Seite: Militaer-Kachel als dritte Kachel, direkt ueber Squawk/Notlage.

PAGE_ADSB darf ein einzelnes String-Literal sein oder per + zusammengehaengt
(auch in Klammern, mit Namen wie BASE_STYLE dazwischen). Geaendert werden nur
die String-Literale, per AST-Spanne. Marker adsbMilThird. Idempotent.
"""
from pathlib import Path
import ast
import re
import sys

MARKER = "adsbMilThird"
SENT = "\x00ADSB_MIL_GAP\x00"


def die(msg):
    raise SystemExit("STOP adsbMilThird: " + msg)


def find_cards(html):
    cards = []
    i = 0
    n = len(html)
    while True:
        m = re.search(r'<div class="card', html[i:])
        if not m:
            break
        start = i + m.start()
        j = start
        depth = 0
        while j < n:
            if html.startswith("<!--", j):
                end = html.find("-->", j + 4)
                if end < 0:
                    die("HTML-Kommentar nicht geschlossen")
                j = end + 3
                continue
            if html.startswith("<div", j) and (j + 4 >= n or html[j + 4] in " \t\n>/" ):
                depth += 1
                j += 4
                continue
            if html.startswith("</div>", j):
                depth -= 1
                j += 6
                if depth == 0:
                    cards.append((start, j))
                    break
                continue
            j += 1
        else:
            die("Kachel nicht geschlossen")
        i = j
    return cards


def title_of(fragment):
    m = re.search(r'<div class="title">\s*(.*?)\s*</div>', fragment, re.S)
    if not m:
        return ""
    return re.sub(r"\s+", " ", m.group(1)).strip()


def is_mil(title, fragment):
    if "milit" not in title.casefold():
        return False
    blob = (title + "\n" + fragment).casefold()
    return ("tar1090" in blob) or ("dbflag" in blob) or ("mil_list" in fragment)


def is_sq(title):
    t = title.casefold()
    return ("squawk" in t) and ("notlage" in t)


def ensure_marker(card):
    if MARKER in card:
        return card
    gt = card.find(">")
    if gt < 0:
        die("Kachel-Tag ohne >")
    return card[: gt + 1] + "<!-- " + MARKER + " -->" + card[gt + 1 :]


def reorder(body):
    cards = find_cards(body)
    if not cards:
        die("keine Kacheln in PAGE_ADSB")
    mil_i = []
    sq_i = []
    titles = []
    for i, (a, b) in enumerate(cards):
        frag = body[a:b]
        if SENT in frag:
            die("Kachel kreuzt ein Nicht-String-Stueck")
        title = title_of(frag)
        titles.append(title)
        if is_mil(title, frag):
            mil_i.append(i)
        if is_sq(title):
            sq_i.append(i)
    if len(mil_i) != 1:
        die("Militaer-Kachel %dx, Titel: %s" % (len(mil_i), " | ".join(titles)))
    if len(sq_i) != 1:
        die("Squawk/Notlage %dx, Titel: %s" % (len(sq_i), " | ".join(titles)))
    mi = mil_i[0]
    si = sq_i[0]
    mil_html = ensure_marker(body[cards[mi][0] : cards[mi][1]])
    already = (
        mi == 2
        and si == 3
        and mi + 1 == si
        and body[cards[mi][1] : cards[si][0]].strip() == ""
        and mil_html == body[cards[mi][0] : cards[mi][1]]
    )
    if already:
        return body, False, titles

    html = body[: cards[mi][0]] + body[cards[mi][1] :]
    sq_s = cards[si][0]
    if sq_s > cards[mi][0]:
        sq_s -= cards[mi][1] - cards[mi][0]
    html = html[:sq_s] + mil_html + "\n" + html[sq_s:]
    if html.count(SENT) != body.count(SENT):
        die("Nicht-String-Luecke beim Verschieben verloren")
    cards2 = find_cards(html)
    titles2 = [title_of(html[a:b]) for a, b in cards2]
    if len(cards2) < 4:
        die("nach dem Verschieben zu wenig Kacheln: %s" % " | ".join(titles2))
    frag2 = html[cards2[2][0] : cards2[2][1]]
    if SENT in frag2 or SENT in html[cards2[3][0] : cards2[3][1]]:
        die("Kachel kreuzt ein Nicht-String-Stueck")
    if not is_mil(titles2[2], frag2):
        die("Kachel 3 ist nicht Militaer: %s" % " | ".join(titles2))
    if not is_sq(titles2[3]):
        die("Kachel 4 ist nicht Squawk/Notlage: %s" % " | ".join(titles2))
    if html[cards2[2][1] : cards2[3][0]].strip() != "":
        die("Militaer nicht direkt ueber Squawk/Notlage")
    if MARKER not in frag2:
        die("Marker fehlt")
    if sum(1 for i, (a, b) in enumerate(cards2) if is_mil(titles2[i], html[a:b])) != 1:
        die("Militaer-Kachel nicht genau einmal")
    return html, True, titles2


def find_assign(tree):
    found = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == "PAGE_ADSB":
                    found.append(node)
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id == "PAGE_ADSB":
            found.append(node)
    if len(found) != 1:
        die("PAGE_ADSB %dx (erwartet 1)" % len(found))
    node = found[0]
    if not isinstance(node, ast.Assign):
        die("PAGE_ADSB ist keine einfache Zuweisung")
    return node


def flatten(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return [("str", node)]
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        return flatten(node.left) + flatten(node.right)
    if isinstance(node, ast.Name):
        return [("gap", node)]
    if isinstance(node, ast.JoinedStr):
        die("PAGE_ADSB enthaelt ein f-string")
    if isinstance(node, ast.Constant):
        die("PAGE_ADSB Teil ist %s, kein String" % type(node.value).__name__)
    die("PAGE_ADSB Teil nicht unterstuetzt: %s" % type(node).__name__)


_LINE = re.compile(r"(.*?(?:\r\n|\n|\r|$))")


def _byte_to_char(line, boff):
    # col_offset ist ein UTF-8-Byteoffset, nicht ein Zeichenindex.
    return len(line.encode()[:boff].decode())


def abs_span(src, node):
    if node.lineno is None or node.end_lineno is None or node.col_offset is None or node.end_col_offset is None:
        die("AST-Spanne fehlt")
    lines = []
    for lineno, match in enumerate(_LINE.finditer(src), 1):
        lines.append(match.group(0))
        if lineno >= node.end_lineno:
            break
    if len(lines) < node.end_lineno:
        die("AST-Zeile fehlt")
    start = sum(len(lines[i]) for i in range(node.lineno - 1)) + _byte_to_char(lines[node.lineno - 1], node.col_offset)
    end = sum(len(lines[i]) for i in range(node.end_lineno - 1)) + _byte_to_char(lines[node.end_lineno - 1], node.end_col_offset)
    if start < 0 or end < start or end > len(src):
        die("AST-Spanne ausserhalb der Datei")
    return start, end


def encode_literal(text):
    if "\x00" in text or SENT in text:
        die("HTML enthaelt ein reserviertes Zeichen")
    if '"""' not in text:
        return '"""' + text + '"""'
    if "'''" not in text:
        return "'''" + text + "'''"
    die("HTML enthaelt beide Triple-Quotes")


def group_parts(parts):
    groups = []
    for kind, node in parts:
        if kind == "gap":
            groups.append(("gap", node))
        elif groups and groups[-1][0] == "strs":
            groups[-1][1].append(node)
        else:
            groups.append(("strs", [node]))
    return groups


def build_html(groups):
    chunks = []
    for kind, payload in groups:
        if kind == "gap":
            chunks.append(SENT)
        else:
            chunks.append("".join(n.value for n in payload))
    return "".join(chunks)


def plan_segment(old_vals, new_text):
    old = "".join(old_vals)
    if new_text == old:
        return []
    if len(old_vals) == 1:
        return [(0, new_text)]
    pre = 0
    n = min(len(old), len(new_text))
    while pre < n and old[pre] == new_text[pre]:
        pre += 1
    suf = 0
    while (
        suf < (len(old) - pre)
        and suf < (len(new_text) - pre)
        and old[len(old) - 1 - suf] == new_text[len(new_text) - 1 - suf]
    ):
        suf += 1

    def idx_at(off):
        if off >= len(old):
            return len(old_vals) - 1
        acc = 0
        for i, val in enumerate(old_vals):
            if off < acc + len(val) or (off == acc and len(val) == 0):
                return i
            acc += len(val)
        return len(old_vals) - 1

    end_off = len(old) - suf
    i0 = idx_at(pre if pre < len(old) else len(old))
    i1 = idx_at(end_off - 1) if end_off > pre else i0
    if i0 != i1:
        return None
    acc = sum(len(v) for v in old_vals[:i0])
    acc_after = sum(len(v) for v in old_vals[i0 + 1 :])
    if new_text[:acc] != "".join(old_vals[:i0]):
        return None
    if acc_after and new_text[-acc_after:] != "".join(old_vals[i0 + 1 :]):
        return None
    mid = new_text[acc : len(new_text) - acc_after] if acc_after else new_text[acc:]
    vals = old_vals[:]
    vals[i0] = mid
    if "".join(vals) != new_text:
        return None
    return [(i0, mid)]


def take_groups(new_html, groups):
    pos = 0
    out = []
    for kind, payload in groups:
        if kind == "gap":
            if not new_html.startswith(SENT, pos):
                die("Kachel kreuzt ein Nicht-String-Stueck")
            pos += len(SENT)
        else:
            nxt = new_html.find(SENT, pos)
            if nxt < 0:
                text = new_html[pos:]
                pos = len(new_html)
            else:
                text = new_html[pos:nxt]
                pos = nxt
            out.append((payload, text))
    if pos != len(new_html):
        die("PAGE_ADSB Rest nach dem Zusammensetzen")
    return out


def apply_html(src, groups, new_html):
    repls = []
    for nodes, text in take_groups(new_html, groups):
        old_vals = [n.value for n in nodes]
        planned = plan_segment(old_vals, text)
        if planned is None:
            start, _ = abs_span(src, nodes[0])
            _, end = abs_span(src, nodes[-1])
            repls.append((start, end, encode_literal(text)))
            continue
        for idx, mid in planned:
            start, end = abs_span(src, nodes[idx])
            repls.append((start, end, encode_literal(mid)))
    if not repls:
        return src
    # Ueberlappende Spannen waeren ein Fehler.
    repls.sort()
    for (a1, b1, _), (a2, b2, _) in zip(repls, repls[1:]):
        if b1 > a2:
            die("ueberlappende Literale")
    out = src
    for start, end, lit in reversed(repls):
        out = out[:start] + lit + out[end:]
    return out


def page_html_from_src(src):
    tree = ast.parse(src)
    node = find_assign(tree)
    parts = flatten(node.value)
    if not any(k == "str" for k, _ in parts):
        die("PAGE_ADSB ohne String-Literal")
    for kind, n in parts:
        if kind != "str":
            continue
        start, end = abs_span(src, n)
        seg = src[start:end]
        if seg != ast.get_source_segment(src, n):
            die("AST-Spanne stimmt nicht")
        try:
            lit_val = ast.literal_eval(seg)
        except Exception:
            die("String-Literal nicht lesbar")
        if lit_val != n.value:
            die("String-Literal Wert weicht ab")
    groups = group_parts(parts)
    return groups, build_html(groups), parts


def confirm(src):
    groups, html, parts = page_html_from_src(src)
    html2, changed, titles = reorder(html)
    if changed or html2 != html:
        die("Ergebnis nicht stabil")
    if len(titles) < 4:
        die("zu wenig Kacheln")
    return titles


def shape_label(parts):
    nstr = sum(1 for k, _ in parts if k == "str")
    ngap = sum(1 for k, _ in parts if k == "gap")
    if ngap == 0 and nstr == 1:
        return "einzelner String"
    return "Verkettung %d Strings, %d Luecken" % (nstr, ngap)


def main():
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
    src = path.read_text(encoding="utf-8")
    groups, html, parts = page_html_from_src(src)
    new_html, changed, titles = reorder(html)
    label = shape_label(parts)
    if not changed:
        confirm(src)
        print("adsbMilThird schon drin \u2014 nichts geaendert. (%s)" % label)
        print("OK adsbMilThird: Kachel 3 MILIT\u00c4R direkt \u00fcber SQUAWK / NOTLAGE")
        return
    again, changed2, _ = reorder(new_html)
    if changed2 or again != new_html:
        die("zweiter Lauf waere nicht idempotent")
    src2 = apply_html(src, groups, new_html)
    if src2 == src:
        die("keine Aenderung")
    ast.parse(src2)
    titles2 = confirm(src2)
    path.write_text(src2, encoding="utf-8")
    print("OK adsbMilThird: Kachel 3 MILIT\u00c4R direkt \u00fcber SQUAWK / NOTLAGE (%s)" % label)
    print("TITLES:", " | ".join(titles2))


if __name__ == "__main__":
    main()
