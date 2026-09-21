#!/usr/bin/env python3
"""Node-Anzeigename aus Meshtastic nodes-Dict. /* pingName */"""


def _key(nid) -> str:
    if nid is None:
        return ""
    s = str(nid).strip()
    if not s:
        return ""
    if s.startswith("!"):
        return s.lower()
    if s.isdigit():
        try:
            return f"!{int(s):08x}"
        except Exception:
            return s.lower()
    return s.lower() if s.startswith("!") else f"!{s.lower()}"


def resolve_name(nodes, from_id) -> str:
    """longName/shortName aus nodes, sonst leer."""
    if not from_id:
        return ""
    want = _key(from_id)
    want_bare = want.lstrip("!")
    nodes = nodes or {}
    info = None
    for k, v in nodes.items():
        kk = _key(k)
        if kk == want or kk.lstrip("!") == want_bare:
            info = v
            break
    if not isinstance(info, dict):
        return ""
    user = info.get("user") or {}
    if not isinstance(user, dict):
        try:
            return str(getattr(user, "longName", None) or getattr(user, "shortName", None) or "")
        except Exception:
            return ""
    return str(user.get("longName") or user.get("shortName") or "").strip()


def format_from(from_id, name: str = "") -> str:
    """'Name (!id)' oder nur id."""
    fid = str(from_id or "").strip() or "?"
    nm = (name or "").strip()
    if nm and nm.lower() not in (fid.lower(), fid.lower().lstrip("!")):
        return f"{nm} ({fid})"
    return fid


def label_from_iface(iface, from_id) -> str:
    nodes = getattr(iface, "nodes", None) or {} if iface is not None else {}
    return format_from(from_id, resolve_name(nodes, from_id))
