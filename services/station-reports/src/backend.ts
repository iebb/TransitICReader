import { parseStationReport, ValidationError } from "./validation.ts";
import { renderPublicPage, type ReportFilter, type StationReportRow } from "./public-report.ts";

const MAX_BODY_BYTES = 8192;
const secretHeader = "X-CardBal-Proxy-Token";

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" },
  });
}

function publicHeaders(source: Headers): Headers {
  const headers = new Headers(source);
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
  headers.set("Permissions-Policy", "geolocation=()");
  headers.set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https://tile.openstreetmap.org; connect-src 'none'; font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
  return headers;
}

function isAuthorized(request: Request, secret: string | undefined): boolean {
  if (!secret) return false;
  const actual = new TextEncoder().encode(request.headers.get(secretHeader) ?? "");
  const expected = new TextEncoder().encode(secret);
  if (actual.byteLength !== expected.byteLength) return false;
  let difference = 0;
  for (let index = 0; index < expected.byteLength; index++) difference |= actual[index] ^ expected[index];
  return difference === 0;
}

async function readSmallJson(request: Request): Promise<unknown> {
  if (request.headers.get("Content-Type")?.split(";", 1)[0].trim().toLowerCase() !== "application/json") {
    throw new ValidationError("contentType", "Content-Type must be application/json.");
  }
  const declaredLength = Number(request.headers.get("Content-Length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) {
    throw new ValidationError("body", "The report is too large.");
  }
  if (!request.body) throw new ValidationError("body", "A JSON body is required.");
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > MAX_BODY_BYTES) {
      await reader.cancel();
      throw new ValidationError("body", "The report is too large.");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new ValidationError("body", "The body must be valid UTF-8 JSON.");
  }
}

export default {
  async fetch(request, env) {
    if (!isAuthorized(request, env.PROXY_TOKEN)) return json({ error: "not_found" }, 404);
    const url = new URL(request.url);
    const path = url.pathname;
    if (path === "/api/health") {
      return request.method === "GET"
        ? json({ ok: true, service: "cardbal-station-reports" })
        : json({ error: "method_not_allowed" }, 405);
    }
    if (path === "/api/v1/station-reports") {
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      try {
        const report = parseStationReport(await readSmallJson(request));
        const result = await env.DB.prepare(`
          INSERT INTO station_reports (
            id, report_type, station_name, station_code, suggested_code, lines,
            operator, city, country, notes, latitude, longitude, accuracy_meters,
            card_family, card_id_hash, app_version, device_id, source
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO NOTHING
        `).bind(
          report.submissionId, report.reportType, report.stationName,
          report.stationCode, report.suggestedCode, report.lines, report.operator,
          report.city, report.country, report.notes, report.location?.latitude ?? null,
          report.location?.longitude ?? null, report.location?.accuracyMeters ?? null,
          report.cardFamily, report.cardIdHash, report.appVersion, report.deviceId,
          report.source,
        ).run();
        const duplicate = result.meta.changes === 0;
        return json({ id: report.submissionId, status: "pending", duplicate }, duplicate ? 200 : 201);
      } catch (error) {
        if (error instanceof ValidationError) {
          return json({ error: "invalid_report", field: error.field, message: error.message }, 400);
        }
        console.error(JSON.stringify({ event: "station_report_insert_failed" }));
        return json({ error: "server_error" }, 500);
      }
    }
    if (path.startsWith("/api/")) return json({ error: "not_found" }, 404);
    if (request.method !== "GET" && request.method !== "HEAD") {
      return json({ error: "method_not_allowed" }, 405);
    }
    if (path === "/" || path === "/index.html") {
      const page = Number(url.searchParams.get("page") ?? "1");
      const type = url.searchParams.get("type") ?? "all";
      if (!Number.isSafeInteger(page) || page < 1 || page > 100000 ||
          (type !== "all" && type !== "missing" && type !== "correction")) {
        return new Response("Invalid request list filter.", { status: 400 });
      }
      try {
        const results = await env.DB.prepare(`
          SELECT created_at, report_type, station_name, station_code,
                 suggested_code, lines, operator, city, country,
                 ROUND(latitude, 3) AS latitude, ROUND(longitude, 3) AS longitude,
                 status
          FROM station_reports
          WHERE status != 'rejected' AND (? = 'all' OR report_type = ?)
          ORDER BY created_at DESC, id DESC
          LIMIT 21 OFFSET ?
        `).bind(type, type, (page - 1) * 20).all<StationReportRow>();
        const template = await env.ASSETS.fetch(new Request(new URL("/index.html", request.url)));
        if (!template.ok) throw new Error("Page template unavailable");
        const html = renderPublicPage(
          await template.text(), results.results.slice(0, 20), type as ReportFilter,
          page, results.results.length > 20,
        );
        const headers = publicHeaders(template.headers);
        headers.set("Content-Type", "text/html; charset=utf-8");
        headers.set("Cache-Control", "no-store");
        return new Response(request.method === "HEAD" ? null : html, { status: 200, headers });
      } catch {
        console.error(JSON.stringify({ event: "station_report_page_failed" }));
        return new Response("Station requests are temporarily unavailable.", { status: 500 });
      }
    }
    const response = await env.ASSETS.fetch(request);
    return new Response(response.body, { status: response.status, statusText: response.statusText, headers: publicHeaders(response.headers) });
  },
} satisfies ExportedHandler<BackendEnv>;
