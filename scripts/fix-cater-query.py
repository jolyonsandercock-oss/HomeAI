import asyncio, asyncpg, json, os

async def fix():
    conn = await asyncpg.connect(os.environ["PG_DSN"])
    # Get the current workflow
    row = await conn.fetchrow(
        "SELECT nodes FROM workflow_entity WHERE id = $1",
        "caterbook-pipeline-v1")
    
    nodes = json.loads(row["nodes"])
    # Find the "find-emails" node and update query
    for node in nodes:
        if node["name"] == "Find unprocessed Caterbook emails":
            old = node["parameters"]["query"]
            new = old.replace(
                "WHERE e.from_address ILIKE '%@caterbook.%'",
                "WHERE e.from_address ILIKE '%@caterbook.%' AND e.subject ILIKE '%Arrivals and Departures%'"
            )
            node["parameters"]["query"] = new
            print(f"BEFORE: {old[:120]}...")
            print(f"AFTER:  {new[:120]}...")
            break
    
    # Save back
    await conn.execute(
        "UPDATE workflow_entity SET nodes = $1::jsonb WHERE id = $2",
        json.dumps(nodes), "caterbook-pipeline-v1")
    print("Updated caterbook workflow filter")
    await conn.close()

asyncio.run(fix())
