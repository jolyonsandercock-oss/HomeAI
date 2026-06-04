#!/usr/bin/env python3
"""gen-capabilities.py — derive a capability index from the live system.

Writes /home_ai/CAPABILITIES.md so a session can answer "does an X already exist?"
WITHOUT grepping at build time. Derive-don't-maintain: re-run on /retro (like STATUS.md).

Sources: FastAPI routes (services/*/main.py), home_ai.* functions + v_* views + slugs
(Postgres), and script header comments (scripts/*).
"""
import os, re, glob, subprocess, datetime, textwrap

ROOT = "/home_ai"
OUT  = f"{ROOT}/CAPABILITIES.md"


def psql(q, ncols):
    """Run a query; return rows each padded/truncated to exactly ncols fields.
    Collapses accidental newlines inside a field by requiring ncols-1 tabs."""
    r = subprocess.run(
        ["docker", "exec", "-i", "homeai-postgres", "psql", "-U", "postgres",
         "-d", "homeai", "-tA", "-F\t", "-R\x1e"],   # record sep = RS, avoids newline splits
        input=("SET app.current_realm='owner'; SET app.current_entity='all';\n" + q).encode(),
        capture_output=True)
    raw = r.stdout.decode()
    raw = re.sub(r'^(SET\s*\n)+', '', raw)   # drop the two SET status lines
    rows = []
    for rec in raw.split("\x1e"):
        rec = rec.strip("\n")
        if not rec.strip() or rec.strip() == "SET":
            continue
        parts = rec.split("\t")
        parts = [p.replace("\n", " ").strip() for p in parts]
        parts = (parts + [""] * ncols)[:ncols]
        rows.append(parts)
    return rows


def first_doc(lines, i):
    """First docstring line after a def at/after index i."""
    for j in range(i, min(i + 6, len(lines))):
        m = re.search(r'"""(.*)', lines[j])
        if m:
            doc = m.group(1).strip()
            return doc if doc else (lines[j + 1].strip() if j + 1 < len(lines) else "")
    return ""


def routes():
    out = {}
    for f in sorted(glob.glob(f"{ROOT}/services/*/main.py")):
        svc = f.split("/")[-2]
        lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
        rows = []
        for i, ln in enumerate(lines):
            m = re.search(r'@app\.(get|post|put|delete|patch)\(\s*["\']([^"\']+)["\']', ln)
            if not m:
                continue
            method, path = m.group(1).upper(), m.group(2)
            # find the def line that follows
            doc = ""
            for j in range(i + 1, min(i + 4, len(lines))):
                if re.search(r'\b(async\s+)?def\s', lines[j]):
                    doc = first_doc(lines, j + 1)
                    break
            rows.append((method, path, doc))
        if rows:
            out[svc] = rows
    return out


def sql_functions():
    return psql("""
      SELECT p.proname, pg_get_function_arguments(p.oid),
             COALESCE(obj_description(p.oid), '')
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='home_ai' ORDER BY p.proname;""", 3)


def views():
    return psql("""
      SELECT table_name, COALESCE(obj_description((quote_ident(table_name))::regclass), '')
      FROM information_schema.views
      WHERE table_schema='public' AND table_name LIKE 'v\\_%' ORDER BY 1;""", 2)


def slugs():
    return psql("""
      SELECT slug, realm, COALESCE(display_name,''), COALESCE(description,'')
      FROM query_whitelist WHERE active AND approved_at IS NOT NULL ORDER BY slug;""", 4)


def scripts_index():
    out = []
    for f in sorted(glob.glob(f"{ROOT}/scripts/*.sh") + glob.glob(f"{ROOT}/scripts/*.py")):
        name = f.split("/")[-1]
        desc = ""
        try:
            head = open(f, encoding="utf-8", errors="replace").read().splitlines()[:12]
        except OSError:
            out.append((name, "(unreadable)")); continue
        for ln in head:
            s = ln.strip()
            if s.startswith("#!") or not s:
                continue
            m = re.match(r'#\s?(.*)', s) or re.match(r'"""(.*)', s)
            if m and m.group(1).strip():
                desc = m.group(1).strip()
                break
        out.append((name, desc))
    return out


def main():
    now = datetime.date.today().isoformat()
    L = []
    L.append("# CAPABILITIES — generated index of what exists where")
    L.append("")
    L.append(f"Auto-generated {now} by `scripts/gen-capabilities.py`. **Do not hand-edit.**")
    L.append("Regenerate on `/retro`. Check this BEFORE designing or building anything — "
             "the codebase is large and parallel implementations have been built by mistake.")
    L.append("")

    rt = routes()
    nroutes = sum(len(v) for v in rt.values())
    L.append(f"## HTTP endpoints ({nroutes} across {len(rt)} services)")
    for svc in sorted(rt):
        L.append(f"\n### {svc}")
        for method, path, doc in rt[svc]:
            doc = (doc[:90] + "…") if len(doc) > 90 else doc
            L.append(f"- `{method:6s} {path}` — {doc}" if doc else f"- `{method:6s} {path}`")

    fns = sql_functions()
    L.append(f"\n## SQL functions — home_ai.* ({len(fns)})")
    for name, args, doc in fns:
        args = (args[:50] + "…") if len(args) > 50 else args
        L.append(f"- `home_ai.{name}({args})` — {doc}" if doc else f"- `home_ai.{name}({args})`")

    vw = views()
    L.append(f"\n## Views — v_* ({len(vw)})")
    for name, doc in vw:
        L.append(f"- `{name}` — {doc}" if doc else f"- `{name}`")

    sl = slugs()
    L.append(f"\n## Whitelisted slugs ({len(sl)}) — frontend reads via /api/slug/<slug>")
    for slug, realm, dn, desc in sl:
        d = desc or dn
        d = (d[:80] + "…") if len(d) > 80 else d
        L.append(f"- `{slug}` ({realm}) — {d}" if d else f"- `{slug}` ({realm})")

    sc = scripts_index()
    L.append(f"\n## Scripts ({len(sc)})")
    for name, desc in sc:
        desc = (desc[:90] + "…") if len(desc) > 90 else desc
        L.append(f"- `scripts/{name}` — {desc}" if desc else f"- `scripts/{name}`")

    open(OUT, "w").write("\n".join(L) + "\n")
    print(f"wrote {OUT}: {nroutes} routes, {len(fns)} fns, {len(vw)} views, "
          f"{len(sl)} slugs, {len(sc)} scripts")


if __name__ == "__main__":
    main()
