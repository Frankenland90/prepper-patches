#!/usr/bin/env python3
"""ADSB-Seite: Militär-Kachel als dritte Kachel, direkt über Squawk/Notlage.

Nur das PAGE_ADSB-Literal. Marker adsbMilThird. Idempotent.
"""
from pathlib import Path
import ast
import re
import sys

MARKER = "adsbMilThird"


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
            if html.startswith("<div", j) and (j + 4 >= n or html[j + 4] in " \t\n>/"):
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


def page_assign(src):
    tree = ast.parse(src)
    found = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign):
            continue
        for t in node.targets:
            if isinstance(t, ast.Name) and t.id == "PAGE_ADSB":
                found.append(node)
    if len(found) != 1:
        die("PAGE_ADSB %dx (erwartet 1)" % len(found))
    node = found[0]
    if not isinstance(node.value, ast.Constant) or not isinstance(node.value.value, str):
        die("PAGE_ADSB ist kein einzelner String")
    lit = ast.get_source_segment(src, node.value)
    if not lit:
        die("PAGE_ADSB Literal nicht lesbar")
    if lit.startswith('"""') and lit.endswith('"""'):
        q = '"""'
    elif lit.startswith("'''") and lit.endswith("'''"):
        q = "'''"
    else:
        die("PAGE_ADSB Quotes unerwartet")
    body = lit[3:-3]
    if body != node.value.value:
        die("PAGE_ADSB Literal hat Escapes")
    if src.count(lit) != 1:
        die("PAGE_ADSB Literal nicht eindeutig")
    return lit, q, body


def reorder(body):
    cards = find_cards(body)
    if not cards:
        die("keine Kacheln in PAGE_ADSB")
    mil_i = []
    sq_i = []
    titles = []
    for i, (a, b) in enumerate(cards):
        frag = body[a:b]
        title = title_of(frag)
        titles.append(title)
        if is_mil(title, frag):
            mil_i.append(i)
        if is_sq(title):
            sq_i.append(i)
    if len(mil_i) != 1:
        die("Militär-Kachel %dx, Titel: %s" % (len(mil_i), " | ".join(titles)))
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
    cards2 = find_cards(html)
    titles2 = [title_of(html[a:b]) for a, b in cards2]
    if len(cards2) < 4:
        die("nach dem Verschieben zu wenig Kacheln: %s" % " | ".join(titles2))
    frag2 = html[cards2[2][0] : cards2[2][1]]
    if not is_mil(titles2[2], frag2):
        die("Kachel 3 ist nicht Militär: %s" % " | ".join(titles2))
    if not is_sq(titles2[3]):
        die("Kachel 4 ist nicht Squawk/Notlage: %s" % " | ".join(titles2))
    if html[cards2[2][1] : cards2[3][0]].strip() != "":
        die("Militär nicht direkt über Squawk/Notlage")
    if MARKER not in frag2:
        die("Marker fehlt")
    if sum(1 for i, (a, b) in enumerate(cards2) if is_mil(titles2[i], html[a:b])) != 1:
        die("Militär-Kachel nicht genau einmal")
    return html, True, titles2


def main():
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
    src = path.read_text(encoding="utf-8")
    lit, q, body = page_assign(src)
    new_body, changed, titles = reorder(body)
    if not changed:
        print("adsbMilThird schon drin — nichts geaendert.")
        print("OK adsbMilThird: Kachel 3 MILITÄR direkt über SQUAWK / NOTLAGE")
        return
    new_lit = q + new_body + q
    src2 = src.replace(lit, new_lit, 1)
    if src2 == src:
        die("keine Aenderung")
    # Nur das Literal darf sich aendern.
    if src2.count(new_lit) != 1:
        die("neues Literal nicht eindeutig")
    path.write_text(src2, encoding="utf-8")
    print("OK adsbMilThird: Kachel 3 MILITÄR direkt über SQUAWK / NOTLAGE")
    print("TITLES:", " | ".join(titles))


if __name__ == "__main__":
    main()
