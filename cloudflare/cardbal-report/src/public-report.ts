export type ReportFilter = "all" | "missing" | "correction";

export interface StationReportRow {
  created_at: string;
  report_type: string;
  station_name: string;
  station_code: string | null;
  suggested_code: string | null;
  lines: string | null;
  operator: string | null;
  city: string | null;
  country: string | null;
  latitude: number | null;
  longitude: number | null;
  status: string;
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[character]!);
}

export function toPublicReport(row: StationReportRow) {
  return {
    createdAt: row.created_at,
    reportType: row.report_type,
    stationName: row.station_name,
    stationCode: row.station_code,
    suggestedCode: row.suggested_code,
    lines: row.lines,
    operator: row.operator,
    city: row.city,
    country: row.country,
    latitude: row.latitude,
    longitude: row.longitude,
    status: row.status,
  };
}

function detail(label: string, value: string | null): string {
  if (!value) return "";
  return `<div class="request-detail"><span class="request-detail-label">${label}</span><strong>${escapeHtml(value)}</strong></div>`;
}

function renderReport(row: StationReportRow): string {
  const report = toPublicReport(row);
  const correction = report.reportType === "correction";
  const parsedDate = new Date(report.createdAt);
  const dateLabel = Number.isNaN(parsedDate.getTime())
    ? "Date unavailable"
    : new Intl.DateTimeFormat("en", { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" }).format(parsedDate);
  const details = [
    detail("Code shown", report.stationCode), detail("Correct code", report.suggestedCode),
    detail("Line(s)", report.lines), detail("Operator", report.operator),
    detail("City", report.city), detail("Country / region", report.country),
  ].join("");
  const hasPin = Number.isFinite(report.latitude) && Number.isFinite(report.longitude);
  const pin = hasPin
    ? `<button class="pin-button" type="button" data-lat="${report.latitude}" data-lon="${report.longitude}">Show approximate pin ↗</button>`
    : "";
  return `<article class="request-card">
    <div class="request-card-top"><span class="request-kind ${correction ? "correction" : "missing"}">${correction ? "Code correction" : "Missing station"}</span><time class="request-date" datetime="${escapeHtml(report.createdAt)}">${dateLabel}</time></div>
    <h3 class="request-name">${escapeHtml(report.stationName)}</h3>
    ${details ? `<div class="request-details">${details}</div>` : ""}
    <div class="request-card-bottom"><span class="request-status">${report.status === "reviewed" ? "Reviewed" : "Pending review"}</span>${pin}</div>
  </article>`;
}

function pageUrl(type: ReportFilter, page: number): string {
  return `/?type=${type}&amp;page=${page}`;
}

export function renderPublicPage(
  template: string, rows: StationReportRow[], type: ReportFilter, page: number, hasMore: boolean,
): string {
  const filters: { type: ReportFilter; label: string }[] = [
    { type: "all", label: "All requests" },
    { type: "missing", label: "Missing stations" },
    { type: "correction", label: "Code corrections" },
  ];
  const tabs = filters.map((filter) =>
    `<a class="request-tab${type === filter.type ? " selected" : ""}" href="${pageUrl(filter.type, 1)}"${type === filter.type ? ' aria-current="page"' : ""}>${filter.label}</a>`,
  ).join("");
  const list = rows.length
    ? rows.map(renderReport).join("")
    : `<div class="empty-state"><span class="empty-symbol">◎</span><h3>No requests here yet</h3><p>Reports submitted from the CardBal app will appear here.</p></div>`;
  const previous = page > 1 ? `<a class="secondary-button" href="${pageUrl(type, page - 1)}">← Previous page</a>` : "";
  const next = hasMore ? `<a class="secondary-button" href="${pageUrl(type, page + 1)}">Next page →</a>` : "";
  const replacements: Record<string, string> = {
    "<!-- REQUEST_COUNT -->": `${rows.length} ${rows.length === 1 ? "request" : "requests"} on page ${page}`,
    "<!-- REQUEST_FILTERS -->": tabs,
    "<!-- REQUEST_LIST -->": list,
    "<!-- REQUEST_PAGINATION -->": previous || next ? `<nav class="pagination" aria-label="Request pages">${previous}${next}</nav>` : "",
  };
  for (const [placeholder, content] of Object.entries(replacements)) {
    if (!template.includes(placeholder)) throw new Error(`Missing page placeholder: ${placeholder}`);
    template = template.replace(placeholder, content);
  }
  return template;
}
