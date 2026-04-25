export interface Env {
  DB: D1Database;
}

type SeoCopy = {
  htmlLang: string;
  locale: string;
  title: string;
  description: string;
  keywords: string;
  headline: string;
  body: string;
};

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

const siteOrigin = "https://cardbal-korean-trip-crowdsourcing.workers.dev";

const seoCopy: Record<"en" | "ja" | "zh-Hans", SeoCopy> = {
  en: {
    htmlLang: "en",
    locale: "en_US",
    title: "CardBal Korean Trip Crowdsourcing",
    description:
      "CardBal collects anonymized Korean transit trip records to improve balance and trip parsing for supported transit IC cards.",
    keywords:
      "CardBal, transit card, Korean transit, trip history, crowdsourcing, NFC, T-money, EZL, Cashbee",
    headline: "CardBal Korean trip data collection",
    body:
      "This endpoint receives privacy-preserving trip records from CardBal so the app can improve support for Korean transit IC cards.",
  },
  ja: {
    htmlLang: "ja",
    locale: "ja_JP",
    title: "CardBal 韓国乗車データ収集",
    description:
      "CardBal は、対応する交通系 IC カードの残高表示と履歴解析を改善するため、匿名化された韓国の乗車記録を収集します。",
    keywords:
      "CardBal, 交通系ICカード, 韓国交通, 乗車履歴, クラウドソーシング, NFC, T-money, EZL, Cashbee",
    headline: "CardBal 韓国乗車データ収集",
    body:
      "このエンドポイントは CardBal から匿名化された乗車記録を受け取り、韓国の交通系 IC カード対応を改善するために使用されます。",
  },
  "zh-Hans": {
    htmlLang: "zh-CN",
    locale: "zh_CN",
    title: "CardBal 韩国乘车数据收集",
    description:
      "CardBal 会收集匿名化的韩国交通出行记录，用于改进对已支持交通 IC 卡的余额显示和行程解析。",
    keywords:
      "CardBal, 交通IC卡, 韩国交通, 行程记录, 众包, NFC, T-money, EZL, Cashbee",
    headline: "CardBal 韩国乘车数据收集",
    body:
      "该端点会接收来自 CardBal 的匿名化乘车记录，用于持续改进韩国交通 IC 卡的支持能力。",
  },
};

function getPreferredLocale(request: Request): "en" | "ja" | "zh-Hans" {
  const url = new URL(request.url);
  const requested = url.searchParams.get("hl")?.toLowerCase();
  if (requested === "ja") return "ja";
  if (requested === "zh" || requested === "zh-cn" || requested === "zh-hans") return "zh-Hans";

  const acceptLanguage = request.headers.get("accept-language")?.toLowerCase() ?? "";
  if (acceptLanguage.includes("ja")) return "ja";
  if (acceptLanguage.includes("zh")) return "zh-Hans";
  return "en";
}

function shouldServeHtml(request: Request): boolean {
  const accept = request.headers.get("accept")?.toLowerCase() ?? "";
  return accept.includes("text/html");
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function renderHtml(copy: SeoCopy): string {
  const pageUrl = `${siteOrigin}/`;
  const structuredData = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "CardBal",
    applicationCategory: "TravelApplication",
    operatingSystem: "iOS",
    inLanguage: [copy.htmlLang, "en", "ja", "zh-CN"],
    description: copy.description,
    url: pageUrl,
  };

  return `<!doctype html>
<html lang="${copy.htmlLang}">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${escapeHtml(copy.title)}</title>
    <meta name="description" content="${escapeHtml(copy.description)}">
    <meta name="keywords" content="${escapeHtml(copy.keywords)}">
    <meta name="robots" content="index,follow,max-image-preview:large">
    <meta name="application-name" content="CardBal">
    <meta name="apple-mobile-web-app-title" content="CardBal">
    <meta name="theme-color" content="#0b57d0">
    <link rel="canonical" href="${pageUrl}">
    <link rel="alternate" hreflang="en" href="${pageUrl}?hl=en">
    <link rel="alternate" hreflang="ja" href="${pageUrl}?hl=ja">
    <link rel="alternate" hreflang="zh-Hans" href="${pageUrl}?hl=zh-Hans">
    <link rel="alternate" hreflang="x-default" href="${pageUrl}">
    <meta property="og:type" content="website">
    <meta property="og:site_name" content="CardBal">
    <meta property="og:locale" content="${copy.locale}">
    <meta property="og:title" content="${escapeHtml(copy.title)}">
    <meta property="og:description" content="${escapeHtml(copy.description)}">
    <meta property="og:url" content="${pageUrl}">
    <meta name="twitter:card" content="summary">
    <meta name="twitter:title" content="${escapeHtml(copy.title)}">
    <meta name="twitter:description" content="${escapeHtml(copy.description)}">
    <script type="application/ld+json">${JSON.stringify(structuredData)}</script>
    <style>
      :root {
        color-scheme: light;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        background: #f7f8fb;
        color: #111827;
      }
      body {
        margin: 0;
        padding: 48px 20px;
      }
      main {
        max-width: 760px;
        margin: 0 auto;
        background: #fff;
        border: 1px solid #dbe3f0;
        border-radius: 20px;
        padding: 32px;
        box-shadow: 0 20px 60px rgba(15, 23, 42, 0.08);
      }
      h1 {
        margin: 0 0 12px;
        font-size: clamp(2rem, 5vw, 3rem);
        line-height: 1.05;
      }
      p {
        margin: 0 0 16px;
        line-height: 1.6;
      }
      code {
        padding: 0.15rem 0.35rem;
        border-radius: 6px;
        background: #eef3fb;
      }
    </style>
  </head>
  <body>
    <main>
      <h1>${escapeHtml(copy.headline)}</h1>
      <p>${escapeHtml(copy.body)}</p>
      <p><code>POST /ingest/korean-trip-records</code></p>
    </main>
  </body>
</html>`;
}

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
      if (shouldServeHtml(request)) {
        const locale = getPreferredLocale(request);
        return new Response(renderHtml(seoCopy[locale]), {
          headers: {
            "content-type": "text/html; charset=utf-8",
            "cache-control": "public, max-age=300",
          },
        });
      }

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
