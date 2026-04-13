export interface Env {
  DB: D1Database;
}

type IncomingRecord = {
  dedupHash: string;
  hashedCardID: string;
  cardIDLast4: string;
  bytes0508: string;
  bytes090A: string;
  allBytes: string;
  cardFamily: string;
};

type IncomingPayload = {
  records?: IncomingRecord[];
  source?: string;
  appVersion?: string;
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "POST, OPTIONS",
      "access-control-allow-headers": "content-type",
    },
  });

function isHex(value: string) {
  return /^[0-9A-F]+$/i.test(value);
}

function isValidRecord(record: IncomingRecord): boolean {
  if (!record.dedupHash || !/^[0-9a-f]{64}$/i.test(record.dedupHash)) return false;
  if (!record.hashedCardID || !/^[0-9a-f]{64}$/i.test(record.hashedCardID)) return false;
  if (!record.cardIDLast4 || record.cardIDLast4.length > 4) return false;
  if (!isHex(record.allBytes) || record.allBytes.length % 2 !== 0) return false;
  if (record.bytes0508 && (!isHex(record.bytes0508) || record.bytes0508.length !== 8)) return false;
  if (record.bytes090A && (!isHex(record.bytes090A) || record.bytes090A.length !== 4)) return false;
  if (!record.cardFamily) return false;
  return true;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return json({ ok: true });
    }

    if (request.method === "GET" && url.pathname === "/") {
      return json({ service: "cardbal-korean-trip-crowdsourcing", ok: true });
    }

    if (request.method !== "POST" || url.pathname !== "/ingest/korean-trip-records") {
      return json({ error: "Not found" }, 404);
    }

    let payload: IncomingPayload;
    try {
      payload = (await request.json()) as IncomingPayload;
    } catch {
      return json({ error: "Invalid JSON body" }, 400);
    }

    const records = payload.records ?? [];
    if (!Array.isArray(records) || records.length === 0) {
      return json({ error: "records must be a non-empty array" }, 400);
    }

    let accepted = 0;
    let duplicates = 0;

    const statement = env.DB.prepare(
      `INSERT OR IGNORE INTO korean_trip_records
        (dedup_hash, hashed_card_id, card_id_last4, bytes_05_08, bytes_09_0a, all_bytes, card_family)
       VALUES (?, ?, ?, ?, ?, ?, ?)`
    );

    for (const record of records) {
      if (!isValidRecord(record)) {
        return json({ error: "Invalid record payload" }, 400);
      }

      const result = await statement
        .bind(
          record.dedupHash.toLowerCase(),
          record.hashedCardID.toLowerCase(),
          record.cardIDLast4,
          record.bytes0508.toUpperCase(),
          record.bytes090A.toUpperCase(),
          record.allBytes.toUpperCase(),
          record.cardFamily
        )
        .run();

      if ((result.meta.changes ?? 0) > 0) {
        accepted += 1;
      } else {
        duplicates += 1;
      }
    }

    return json({
      ok: true,
      accepted,
      duplicates,
      received: records.length,
      source: payload.source ?? null,
      appVersion: payload.appVersion ?? null,
    });
  },
};
