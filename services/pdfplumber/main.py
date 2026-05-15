from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.responses import Response
import pdfplumber, pandas as pd, io, hashlib, re

app = FastAPI()

def sanitise(text: str) -> str:
    text = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', text)
    return text[:8000]

@app.post("/extract-pdf")
async def extract_pdf(file: UploadFile = File(...)):
    content = await file.read()
    if len(content) > 10 * 1024 * 1024:
        raise HTTPException(413, "File too large")
    with pdfplumber.open(io.BytesIO(content)) as pdf:
        text = '\n'.join(p.extract_text() or '' for p in pdf.pages)
    return {"text": sanitise(text),
            "content_hash": hashlib.sha256(content).hexdigest()}

@app.post("/parse-xlsx")
async def parse_xlsx(file: UploadFile = File(...)):
    content = await file.read()
    df = pd.read_excel(io.BytesIO(content), nrows=1000)
    df = df.where(pd.notna(df), None)
    return {"data": df.to_dict(orient='records'), "row_count": len(df)}

@app.post("/parse-csv")
async def parse_csv(file: UploadFile = File(...)):
    content = await file.read()
    df = pd.read_csv(io.BytesIO(content), nrows=1000)
    df = df.where(pd.notna(df), None)
    return {"data": df.to_dict(orient='records'), "row_count": len(df)}

@app.post("/render-page1-png")
async def render_page1_png(file: UploadFile = File(...), width: int = 1200):
    """U61 T2 — render page 1 of a PDF as a PNG (Wand/ImageMagick under the
    hood via pdfplumber.Page.to_image). Used by the dashboard invoice side panel.
    Capped at 10MB input and 2000px width."""
    content = await file.read()
    if len(content) > 10 * 1024 * 1024:
        raise HTTPException(413, "File too large")
    width = max(400, min(int(width), 2000))
    with pdfplumber.open(io.BytesIO(content)) as pdf:
        if not pdf.pages:
            raise HTTPException(400, "PDF has no pages")
        # resolution=N maps to N DPI. 1200px wide at A4 portrait ≈ 144 DPI.
        page = pdf.pages[0]
        target_dpi = max(72, int(width / (page.width / 72)))
        img = page.to_image(resolution=target_dpi)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
    return Response(content=buf.getvalue(), media_type="image/png")


@app.get("/healthcheck")
async def healthcheck():
    return {"status": "ok"}
