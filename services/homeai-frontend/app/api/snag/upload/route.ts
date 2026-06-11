import { realmFromRequest } from '@/lib/realm';
import { NextRequest, NextResponse } from "next/server";
import { withRealm } from "@/lib/db";
import { writeFile, mkdir } from "fs/promises";
import { join } from "path";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const realm = realmFromRequest(req);
  if (realm !== 'owner' && realm !== 'work') {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }
  let form: FormData;
  try { form = await req.formData(); }
  catch { return NextResponse.json({ error: "expected multipart form data" }, { status: 400 }); }

  const title = form.get("title")?.toString().trim();
  const description = form.get("description")?.toString() || null;
  const category = form.get("category")?.toString() || "ux";
  const priority = parseInt(form.get("priority")?.toString() || "3");
  const submitted_by = form.get("submitted_by")?.toString() || null;
  const source = form.get("source")?.toString() || "web";
  const image = form.get("image") as File | null;

  if (!title) {
    return NextResponse.json({ error: "title required" }, { status: 400 });
  }

  let imagePath: string | null = null;

  // Save image if provided
  if (image && image.size > 0) {
    const dir = "/data/snags";  // persistent bind mount (was /tmp — wiped on recreate)
    await mkdir(dir, { recursive: true });
    const ext = image.name.split(".").pop() || "png";
    const filename = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}.${ext}`;
    const filepath = join(dir, filename);
    const buffer = Buffer.from(await image.arrayBuffer());
    await writeFile(filepath, buffer);
    imagePath = `/snags/${filename}`;
  }

  try {
    // Wrap the SECURITY DEFINER insert so its body runs with realm/entity set.
    return await withRealm(realm, async (client) => {
      const result = await client.query(
        "SELECT home_ai.insert_snag($1, $2, $3, $4, $5, $6, $7)",
        [title, description, imagePath, category, priority, submitted_by, source]
      );
      return NextResponse.json({ ok: true, id: result.rows[0]?.insert_snag, image_path: imagePath });
    }, { entity: '1' });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 500 });
  }
}
