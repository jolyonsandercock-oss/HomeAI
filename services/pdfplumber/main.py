from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.responses import Response
import pdfplumber, pandas as pd, asyncio, io, hashlib, re

app = FastAPI()

# Perf pass 2026-07-03: parsing/rendering is CPU-bound; it used to run inline
# in the async handlers, stalling the event loop (healthcheck included) and
# serialising concurrent extractions. Each handler now does the blocking work
# via asyncio.to_thread — per-request pdfplumber/pandas objects are
# independent, so threaded calls don't share state.

def sanitise(text: str) -> str:
    text = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', text)
    return text[:8000]

def _extract_pdf_text(content: bytes) -> str:
    with pdfplumber.open(io.BytesIO(content)) as pdf:
        return '\n'.join(p.extract_text() or '' for p in pdf.pages)

@app.post("/extract-pdf")
async def extract_pdf(file: UploadFile = File(...)):
    content = await file.read()
    if len(content) > 10 * 1024 * 1024:
        raise HTTPException(413, "File too large")
    text = await asyncio.to_thread(_extract_pdf_text, content)
    return {"text": sanitise(text),
            "content_hash": hashlib.sha256(content).hexdigest()}

def _df_records(read_fn, content: bytes) -> dict:
    df = read_fn(io.BytesIO(content), nrows=1000)
    df = df.where(pd.notna(df), None)
    return {"data": df.to_dict(orient='records'), "row_count": len(df)}

@app.post("/parse-xlsx")
async def parse_xlsx(file: UploadFile = File(...)):
    content = await file.read()
    return await asyncio.to_thread(_df_records, pd.read_excel, content)

@app.post("/parse-csv")
async def parse_csv(file: UploadFile = File(...)):
    content = await file.read()
    return await asyncio.to_thread(_df_records, pd.read_csv, content)

def _repair_pdf(content: bytes) -> bytes:
    """Rewrite a structurally-quirky PDF via pikepdf/qpdf. Some real supplier
    invoices (Forest Produce daily invoices, found 2026-07-03) parse fine in
    pdfminer (text extraction) but hard-fail pdfium ('Data format error') —
    the renderer behind Page.to_image. qpdf normalises the xref/trailer so
    pdfium accepts it. Raises on genuinely-unreadable input."""
    import pikepdf
    buf = io.BytesIO()
    with pikepdf.open(io.BytesIO(content)) as p:
        p.save(buf)
    return buf.getvalue()

def _render_page_png(content: bytes, width: int, page: int) -> tuple[bytes, int]:
    try:
        return _render_page_png_inner(content, width, page)
    except HTTPException:
        raise
    except Exception:
        # pdfium rejected it — repair and retry once before giving up
        return _render_page_png_inner(_repair_pdf(content), width, page)

def _render_page_png_inner(content: bytes, width: int, page: int) -> tuple[bytes, int]:
    with pdfplumber.open(io.BytesIO(content)) as pdf:
        if not pdf.pages:
            raise HTTPException(400, "PDF has no pages")
        if page < 0 or page >= len(pdf.pages):
            raise HTTPException(416, f"page {page} out of range (0..{len(pdf.pages)-1})")
        # resolution=N maps to N DPI. 1200px wide at A4 portrait ≈ 144 DPI.
        pg = pdf.pages[page]
        target_dpi = max(72, int(width / (pg.width / 72)))
        img = pg.to_image(resolution=target_dpi)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return buf.getvalue(), len(pdf.pages)

@app.post("/render-page1-png")
async def render_page1_png(file: UploadFile = File(...), width: int = 1200, page: int = 0):
    """U61 T2 / U276 — render one page of a PDF as a PNG (pdfplumber
    Page.to_image). Used by the dashboard invoice side panel and the vision-OCR
    pipeline. `page` is 0-based (default 0 — back-compat with the original
    page-1-only behaviour); the X-Page-Count header reports the total so
    callers can iterate multi-page documents (invoice totals are often on the
    LAST page). Capped at 10MB input and 2000px width."""
    content = await file.read()
    if len(content) > 10 * 1024 * 1024:
        raise HTTPException(413, "File too large")
    width = max(400, min(int(width), 2000))
    png, n_pages = await asyncio.to_thread(_render_page_png, content, width, page)
    return Response(content=png, media_type="image/png",
                    headers={"X-Page-Count": str(n_pages)})


@app.get("/healthcheck")
async def healthcheck():
    return {"status": "ok"}
