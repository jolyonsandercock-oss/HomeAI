import { NextRequest, NextResponse } from "next/server";
import { readFile } from "fs/promises";
import { join } from "path";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET(req: NextRequest) {
  const file = req.nextUrl.searchParams.get("file");
  if (!file || file.includes("..")) {
    return NextResponse.json({ error: "invalid" }, { status: 400 });
  }
  try {
    const buf = await readFile(join("/tmp/snags", file));
    return new NextResponse(buf, { headers: { "Content-Type": "image/png", "Cache-Control": "max-age=3600" } });
  } catch {
    return NextResponse.json({ error: "not found" }, { status: 404 });
  }
}
