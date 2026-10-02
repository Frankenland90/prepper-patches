#!/usr/bin/env python3
"""Zuhause-Seite: gleiche Nav-Swipe-Injection (# navEvenSwipe)."""
from pathlib import Path
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/zuhause.py")
MARKER = "navEvenSwipe"

if not PATH.is_file():
    print("skip: keine zuhause.py")
    raise SystemExit(0)

src = PATH.read_text(encoding="utf-8")
if MARKER in src and "touchstart" in src:
    print("already patched zuhause (navEvenSwipe) — nichts geändert.")
    raise SystemExit(0)

SWIPE = (
    '<script>/* navEvenSwipe */\n'
    "(function(){\n"
    "  if(window.__navEvenSwipe) return;\n"
    "  window.__navEvenSwipe=1;\n"
    '  var ORDER=["/","/energie","/lokale-energie","/speicher","/umwelt","/luft","/pegel","/adsb","/zuhause","/mesh","/mesh2","/news","/funk","/pi","/medizin"];\n'
    "  function norm(p){\n"
    '    if(!p) return "/";\n'
    '    try{ p=String(p).split("?")[0].split("#")[0]; }catch(e){}\n'
    '    if(p.length>1 && p.slice(-1)==="/") p=p.slice(0,-1);\n'
    '    return p || "/";\n'
    "  }\n"
    "  function pages(){\n"
    '    var have={}, nodes=document.querySelectorAll(".nav-top a[href],.navtop a[href],.nav a[href]");\n'
    "    for(var i=0;i<nodes.length;i++){\n"
    '      var h=nodes[i].getAttribute("href");\n'
    '      if(!h || h.charAt(0)!=="/") continue;\n'
    "      have[norm(h)]=1;\n"
    "    }\n"
    "    have[norm(location.pathname)]=1;\n"
    "    var out=[];\n"
    "    for(var j=0;j<ORDER.length;j++){\n"
    "      if(have[ORDER[j]]) out.push(ORDER[j]);\n"
    "    }\n"
    "    if(out.length<2){\n"
    "      var seen={}, dom=[];\n"
    "      for(var k=0;k<nodes.length;k++){\n"
    '        var href=nodes[k].getAttribute("href");\n'
    '        if(!href || href.charAt(0)!=="/") continue;\n'
    "        href=norm(href);\n"
    "        if(seen[href]) continue;\n"
    "        seen[href]=1;\n"
    "        dom.push(href);\n"
    "      }\n"
    "      return dom;\n"
    "    }\n"
    "    return out;\n"
    "  }\n"
    "  function ignoreTarget(el){\n"
    "    while(el && el!==document.body){\n"
    '      var t=(el.tagName||"").toLowerCase();\n'
    '      if(t==="input"||t==="textarea"||t==="select"||t==="button"||t==="option") return true;\n'
    "      if(el.isContentEditable) return true;\n"
    "      el=el.parentElement;\n"
    "    }\n"
    "    return false;\n"
    "  }\n"
    "  var x0=null,y0=null,t0=0,ign=false;\n"
    '  document.addEventListener("touchstart",function(e){\n'
    "    if(!e.touches || e.touches.length!==1){ x0=null; return; }\n"
    "    ign=ignoreTarget(e.target);\n"
    "    x0=e.touches[0].clientX; y0=e.touches[0].clientY; t0=Date.now();\n"
    "  },{passive:true});\n"
    '  document.addEventListener("touchend",function(e){\n'
    "    if(x0==null || ign){ x0=null; return; }\n"
    "    var t=e.changedTouches && e.changedTouches[0];\n"
    "    if(!t){ x0=null; return; }\n"
    "    var dx=t.clientX-x0, dy=t.clientY-y0;\n"
    "    x0=null;\n"
    "    if(Date.now()-t0>700) return;\n"
    "    if(Math.abs(dx)<64) return;\n"
    "    if(Math.abs(dx)<Math.abs(dy)*1.4) return;\n"
    "    var list=pages();\n"
    "    if(!list || list.length<2) return;\n"
    "    var cur=norm(location.pathname), idx=-1;\n"
    "    for(var i=0;i<list.length;i++){ if(list[i]===cur){ idx=i; break; } }\n"
    "    if(idx<0) return;\n"
    "    var next = dx<0 ? list[idx+1] : list[idx-1];\n"
    "    if(next && next!==cur) location.href=next;\n"
    "  },{passive:true});\n"
    "})();\n"
    "</script>"
)

if "</body></html>" not in src:
    raise SystemExit("STOP zuhause: kein </body></html>")
src = src.replace("</body></html>", SWIPE + "</body></html>")

PATH.write_text(src, encoding="utf-8")
print("OK zuhause navEvenSwipe injected")
