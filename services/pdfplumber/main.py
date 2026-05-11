from fastapi import FastAPI, UploadFile, File, HTTPException
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

@app.get("/healthcheck")
async def healthcheck():
    return {"status": "ok"}
