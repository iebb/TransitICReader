import "./styles.css";
import { BYTE_FIELDS, decodeRecord, fieldForByte } from "./decoder";

type FamilyCounts = Record<string, number>;

interface StationDisplayNames {
  ko: string;
  en: string | null;
  hanja: string | null;
  zhHans: string | null;
  zhHant: string | null;
  ja: string | null;
}

interface Summary {
  records: number;
  cards: number;
  families: FamilyCounts;
  locations: number;
  stationTokens: number;
  transportModeCodes: number;
  knownLocations: number;
  confirmedRows: number;
  confirmedCoverage: number;
  officialStationRows: number;
  officialStationCoverage: number;
  officialStationLocations: number;
  officialStationIDs: number;
  officialExactStationRows: number;
  officialExactStationLocations: number;
  officialTransformedStationRows: number;
  officialTransformedStationLocations: number;
  busanBIMSStationRows: number;
  busanBIMSStationLocations: number;
  busanMetroStationRows: number;
  busanMetroStationLocations: number;
  daeguStationRows: number;
  daeguStationLocations: number;
  capitalRailStationRows: number;
  capitalRailStationLocations: number;
  userConfirmedStationRows: number;
  userConfirmedStationLocations: number;
  coordinateRows: number;
  coordinateCoverage: number;
  coordinateLocations: number;
  coordinateAliases: number;
  multilingualNameRows: number;
  multilingualNameCoverage: number;
  multilingualNameLocations: number;
  englishNameRows: number;
  englishNameCoverage: number;
  englishNameLocations: number;
  hanjaNameRows: number;
  hanjaNameCoverage: number;
  hanjaNameLocations: number;
  chineseNameRows: number;
  chineseNameCoverage: number;
  chineseNameLocations: number;
  japaneseNameRows: number;
  japaneseNameCoverage: number;
  japaneseNameLocations: number;
  uniqueRawRecords: number;
  duplicateRawRows: number;
  decodedTimestamps: number;
  plausibleTimestamps: number;
  timestampCoverage: number;
  timestampLayouts: Record<"packed33" | "bcd14" | "operator_opaque" | "alternate_unknown", number>;
  futureTimestampCandidates: number;
  exactEvents: number;
  eventCoverage: number;
  officialSystemCodes: number;
  unmappedSystemCodes: number;
  associatedSystemCodes: number;
  institutionalReferenceSystemCodes: number;
  corpusInferenceSystemCodes: number;
  attributedSystemRows: number;
  layoutWarningSystemCodes: number;
  officialSystemRows: number;
  officialSystemCoverage: number;
  officialSystemLocations: number;
  officialSystemStationTokens: number;
  officialSystemCards: number;
  stationIdCandidateRows: number;
  pairedJourneys: number;
  journeyFlows: number;
  exitDistanceRows: number;
  entryDistanceZeroRows: number;
  medianExitDistanceMeters: number | null;
  p95ExitDistanceMeters: number | null;
  bitfieldExactCardScans: number;
  bitfieldWithinTwoDaysCardScans: number;
  dayCounterExactCardScans: number;
}

interface DataMeta {
  title: string;
  format: string;
  generatedAt: string;
  sourceFirstSeen: string;
  sourceLastSeen: string;
  recordBytes: number;
  method: string;
}

interface KnownLocation {
  aliasKey: string;
  code: string;
  eventRaw: number | null;
  name: string;
  identityName: string;
  displayNames: StationDisplayNames;
  nameEnglish: string | null;
  nameHanja: string | null;
  nameChineseSimplified: string | null;
  nameChineseTraditional: string | null;
  nameJapanese: string | null;
  mode: string;
  sampleIds: string[];
  provenance: "official_dataset_exact_match" | "official_dataset_transformed_exact_match" | "user_confirmed";
  sourceID: string;
  sourceTitle: string;
  sourceURL: string | null;
  sourceStationID: string | null;
  nameSourceID: string | null;
  nameSourceTitle: string | null;
  nameSourceURL: string | null;
  nameSourceStationID: string | null;
  nameMatchingMethod: string | null;
  hanjaSourceID: string | null;
  hanjaSourceTitle: string | null;
  hanjaSourceURL: string | null;
  coordinateSourceID: string | null;
  coordinateSourceTitle: string | null;
  coordinateSourceURL: string | null;
  coordinateSourceStationID: string | null;
  coordinateMatchingMethod: string | null;
  arsID: string | null;
  ctpvName: string | null;
  sggName: string | null;
  matchingMethod: string | null;
  sourceStopID: string | null;
  latitude: number | null;
  longitude: number | null;
  records: number;
  cards: number;
}

interface KnownEvidence {
  sampleId: string;
  locationCode: string;
  name: string;
  mode: string;
  event: string;
  trip: string;
  notes: string;
  duplicateOf: string | null;
  raw: string;
}

interface FieldStat {
  offset: number;
  distinct: number;
  entropy: number;
  top: Array<{ hex: string; count: number }>;
}

interface LocationRow {
  code: string;
  stationToken: string;
  transportModeCode: string;
  systemDecimal: number;
  systemOfficialNameKo: string | null;
  systemClass: string | null;
  systemClassName: string | null;
  systemArea: string | null;
  systemAssociationStatus: string | null;
  systemAssociationNote: string | null;
  stationIdCandidate: string | null;
  name: string | null;
  identityName: string | null;
  displayNames: StationDisplayNames | null;
  nameEnglish: string | null;
  nameHanja: string | null;
  nameChineseSimplified: string | null;
  nameChineseTraditional: string | null;
  nameJapanese: string | null;
  mode: string | null;
  provenance: "official_dataset_exact_match" | "official_dataset_transformed_exact_match" | "user_confirmed" | null;
  sourceID: string | null;
  sourceTitle: string | null;
  sourceURL: string | null;
  sourceStationID: string | null;
  nameSourceID: string | null;
  nameSourceTitle: string | null;
  nameSourceURL: string | null;
  nameSourceStationID: string | null;
  nameMatchingMethod: string | null;
  hanjaSourceID: string | null;
  hanjaSourceTitle: string | null;
  hanjaSourceURL: string | null;
  coordinateSourceID: string | null;
  coordinateSourceTitle: string | null;
  coordinateSourceURL: string | null;
  coordinateSourceStationID: string | null;
  coordinateMatchingMethod: string | null;
  arsID: string | null;
  ctpvName: string | null;
  sggName: string | null;
  matchingMethod: string | null;
  sourceStopID: string | null;
  latitude: number | null;
  longitude: number | null;
  records: number;
  cards: number;
  boarding: number;
  alighting: number;
  flagged: number;
  families: FamilyCounts;
  firstCollected: string;
  lastCollected: string;
  firstTrip: string | null;
  lastTrip: string | null;
}

interface NetworkRow {
  code: string;
  decimalCode: number;
  officialNameKo: string | null;
  transportClass: string | null;
  transportClassName: string | null;
  area: string | null;
  matchStatus:
    | "official_kotris"
    | "official_seoul"
    | "institutional_reference"
    | "corpus_geometry_inference"
    | "corpus_association"
    | "layout_warning"
    | "unmapped";
  sourceTitle: string | null;
  sourceURL: string | null;
  associationNote: string | null;
  records: number;
  cards: number;
  locations: number;
  knownLocations: string[];
  families: FamilyCounts;
  timestampLayouts: Record<string, number>;
}

interface CardRow {
  hash: string;
  records: number;
  families: FamilyCounts;
  locations: number;
  knownLocations: number;
  firstCollected: string;
  lastCollected: string;
  firstTrip: string | null;
  lastTrip: string | null;
}

interface JourneyRow {
  id: string;
  cardHash: string;
  family: string;
  tripCounter: number;
  fromCode: string;
  fromName: string | null;
  toCode: string;
  toName: string | null;
  boardedAt: string;
  alightedAt: string;
  durationMinutes: number;
  distanceMeters: number;
  fare: number | null;
  boardingRecord: string;
  alightingRecord: string;
}

interface FlowRow {
  fromCode: string;
  fromName: string | null;
  toCode: string;
  toName: string | null;
  journeys: number;
  cards: number;
  medianMinutes: number;
  medianDistanceMeters: number | null;
  families: FamilyCounts;
}

interface RecordRow {
  id: string;
  dedupHash: string;
  cardHash: string;
  family: string;
  createdAt: string;
  raw: string;
  event: "boarding" | "alighting" | "flagged";
  eventRaw: number;
  eventFlags: number;
  byte03: number;
  tripCounter: number;
  stationToken: string;
  transportModeCode: string;
  systemDecimal: number;
  systemOfficialNameKo: string | null;
  systemClass: string | null;
  systemClassName: string | null;
  systemArea: string | null;
  systemAssociationStatus: string | null;
  systemAssociationNote: string | null;
  stationIdCandidate: string | null;
  locationCode: string;
  knownEventRaw: number | null;
  knownName: string | null;
  knownDisplayNames: StationDisplayNames | null;
  knownNameEnglish: string | null;
  knownNameHanja: string | null;
  knownNameChineseSimplified: string | null;
  knownNameChineseTraditional: string | null;
  knownNameJapanese: string | null;
  knownMode: string | null;
  knownProvenance: "official_dataset_exact_match" | "official_dataset_transformed_exact_match" | "user_confirmed" | null;
  knownSourceID: string | null;
  knownSourceTitle: string | null;
  knownSourceURL: string | null;
  knownSourceStationID: string | null;
  knownNameSourceID: string | null;
  knownNameSourceTitle: string | null;
  knownNameSourceURL: string | null;
  knownNameMatchingMethod: string | null;
  knownCoordinateSourceID: string | null;
  knownCoordinateSourceTitle: string | null;
  knownCoordinateSourceURL: string | null;
  knownCoordinateSourceStationID: string | null;
  knownCoordinateMatchingMethod: string | null;
  knownARSID: string | null;
  knownCtpvName: string | null;
  knownSggName: string | null;
  knownMatchingMethod: string | null;
  knownSourceStopID: string | null;
  knownLatitude: number | null;
  knownLongitude: number | null;
  timestamp: string | null;
  timestampHex: string;
  dateFlags: number;
  timestampLayout: "packed33" | "bcd14" | "operator_opaque" | "alternate_unknown";
  timestampPlausible: boolean;
  distanceMeters: number;
  legacyDistanceMeters: number;
  fare22: number;
  fare36: number;
  fare40: number;
  fare50: number;
  selectedFare: number | null;
  fareLayout: "primary22" | "regional36" | "base40" | "unresolved";
  operatorFieldProfile: string;
  operatorClockA: number | null;
  operatorClockB: number | null;
  operatorClockFlag: number | null;
  terminalReference: string;
}

interface SourceRow {
  title: string;
  url: string | null;
  note: string;
}

interface Dataset {
  meta: DataMeta;
  summary: Summary;
  knownLocations: KnownLocation[];
  knownEvidence: KnownEvidence[];
  fieldStats: FieldStat[];
  locations: LocationRow[];
  networks: NetworkRow[];
  cards: CardRow[];
  journeys: JourneyRow[];
  flows: FlowRow[];
  records: RecordRow[];
  sources: SourceRow[];
}

type Panel = "map" | "locations" | "networks" | "journeys" | "cards" | "records" | "bytes";

const PAGE_SIZE = 50;
const appElement = document.querySelector<HTMLDivElement>("#app");
if (!appElement) throw new Error("App mount not found");
const app: HTMLDivElement = appElement;

const number = new Intl.NumberFormat("en-US");
const krw = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "KRW",
  maximumFractionDigits: 0,
});

function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function formatDate(value: string | null, includeTime = false): string {
  if (!value) return "Not decoded";
  const hasExplicitZone = /(?:Z|[+-]\d{2}:\d{2})$/.test(value);
  const normalized = hasExplicitZone ? value : `${value}Z`;
  const parsed = new Date(normalized);
  if (Number.isNaN(parsed.valueOf())) return value.replace("T", " ");
  return new Intl.DateTimeFormat("en-CA", {
    year: "numeric",
    month: "short",
    day: "2-digit",
    ...(includeTime ? { hour: "2-digit", minute: "2-digit", hour12: false } : {}),
    timeZone: includeTime && value.endsWith("Z") ? "Asia/Seoul" : "UTC",
  }).format(parsed);
}

function shortHash(value: string): string {
  return `${value.slice(0, 8)}…${value.slice(-6)}`;
}

function familyLabel(families: FamilyCounts): string {
  return Object.entries(families)
    .map(([name, count]) => `${name} ${number.format(count)}`)
    .join(" · ");
}

function eventPill(event: RecordRow["event"], raw?: number): string {
  const suffix = raw === undefined ? "" : ` · ${raw.toString(16).padStart(2, "0").toUpperCase()}`;
  return `<span class="pill pill-${event}">${escapeHtml(event)}${suffix}</span>`;
}

function locationLabel(code: string, name: string | null): string {
  return name
    ? `<strong>${escapeHtml(name)}</strong><code>${escapeHtml(code)}</code>`
    : `<strong class="unresolved">Unresolved</strong><code>${escapeHtml(code)}</code>`;
}

type StationNameLike = {
  nameEnglish: string | null;
  nameHanja: string | null;
  nameChineseSimplified: string | null;
  nameChineseTraditional: string | null;
  nameJapanese: string | null;
};

function chineseStationName(station: StationNameLike): string | null {
  const simplified = station.nameChineseSimplified;
  const traditional = station.nameChineseTraditional;
  if (simplified && traditional && simplified !== traditional) return `${simplified} / ${traditional}`;
  return simplified ?? traditional;
}

function stationSearchNames(station: StationNameLike): string[] {
  return [
    station.nameEnglish,
    station.nameHanja,
    station.nameChineseSimplified,
    station.nameChineseTraditional,
    station.nameJapanese,
  ].filter((value): value is string => Boolean(value));
}

function stationNameLabel(code: string, name: string | null, station: StationNameLike): string {
  if (!name) return locationLabel(code, name);
  const chinese = chineseStationName(station);
  const secondary = [
    station.nameEnglish ? `<span lang="en"><b>EN</b> ${escapeHtml(station.nameEnglish)}</span>` : "",
    chinese ? `<span lang="zh"><b>中文</b> ${escapeHtml(chinese)}</span>` : "",
    station.nameJapanese ? `<span lang="ja"><b>日本語</b> ${escapeHtml(station.nameJapanese)}</span>` : "",
  ].filter(Boolean);
  return `<strong lang="ko">${escapeHtml(name)}</strong>${
    secondary.length ? `<small class="station-languages">${secondary.join("")}</small>` : ""
  }<code>${escapeHtml(code)}</code>`;
}

function stationLanguageDetails(station: StationNameLike): string {
  const chinese = chineseStationName(station);
  const rows = [
    station.nameEnglish ? `<div><dt>Official English</dt><dd lang="en">${escapeHtml(station.nameEnglish)}</dd></div>` : "",
    station.nameHanja ? `<div><dt>Official Hanja</dt><dd lang="ko-Hani">${escapeHtml(station.nameHanja)}</dd></div>` : "",
    chinese ? `<div><dt>Official Chinese</dt><dd lang="zh">${escapeHtml(chinese)}</dd></div>` : "",
    station.nameJapanese ? `<div><dt>Official Japanese</dt><dd lang="ja">${escapeHtml(station.nameJapanese)}</dd></div>` : "",
  ].filter(Boolean);
  return rows.join("");
}

function sourceLink(title: string | null, url: string | null): string {
  if (!title) return "—";
  return url
    ? `<a href="${escapeHtml(url)}" target="_blank" rel="noreferrer">${escapeHtml(title)} ↗</a>`
    : escapeHtml(title);
}

function mapTooltip(station: KnownLocation): string {
  const lines = [
    station.name,
    station.nameEnglish ? `EN: ${station.nameEnglish}` : "",
    station.nameHanja ? `Hanja: ${station.nameHanja}` : "",
    chineseStationName(station) ? `ZH: ${chineseStationName(station)}` : "",
    station.nameJapanese ? `JA: ${station.nameJapanese}` : "",
    `${number.format(station.records)} records · ${number.format(station.cards)} cards`,
    `${station.latitude?.toFixed(6)}, ${station.longitude?.toFixed(6)}`,
    station.nameSourceTitle ? `Names: ${station.nameSourceTitle}` : "",
    station.nameSourceStationID ? `Name source ID: ${station.nameSourceStationID}` : "",
    station.hanjaSourceTitle && station.hanjaSourceID !== station.nameSourceID
      ? `Hanja: ${station.hanjaSourceTitle}`
      : "",
    station.nameMatchingMethod ? `Name match: ${station.nameMatchingMethod}` : "",
    station.coordinateSourceTitle ? `Coordinates: ${station.coordinateSourceTitle}` : "",
    station.coordinateMatchingMethod ? `Coordinate match: ${station.coordinateMatchingMethod}` : "",
  ].filter(Boolean);
  return lines.join("\n");
}

function renderStationMap(data: Dataset, query: string): string {
  const normalized = query.trim().toLowerCase();
  const stations = data.knownLocations.filter((station) => {
    if (station.latitude === null || station.longitude === null) return false;
    return [
      station.code,
      station.name,
      station.identityName,
      ...stationSearchNames(station),
      station.mode,
      station.ctpvName ?? "",
      station.sggName ?? "",
      station.coordinateSourceTitle ?? "",
      station.coordinateSourceStationID ?? "",
      station.coordinateMatchingMethod ?? "",
    ]
      .join(" ")
      .toLowerCase()
      .includes(normalized);
  });
  const longitudeMin = 125.5;
  const longitudeMax = 130.0;
  const latitudeMin = 33.0;
  const latitudeMax = 38.7;
  const plotLeft = 52;
  const plotTop = 32;
  const plotWidth = 896;
  const plotHeight = 546;
  const project = (station: KnownLocation) => ({
    x: plotLeft + (((station.longitude ?? longitudeMin) - longitudeMin) / (longitudeMax - longitudeMin)) * plotWidth,
    y: plotTop + ((latitudeMax - (station.latitude ?? latitudeMin)) / (latitudeMax - latitudeMin)) * plotHeight,
  });
  const longitudeGrid = [126, 127, 128, 129, 130];
  const latitudeGrid = [33, 34, 35, 36, 37, 38];
  const visibleRecords = stations.reduce((total, station) => total + station.records, 0);
  return `<div class="panel-note"><strong>Only exact sourced coordinates are plotted.</strong> Korean remains the primary station label. English, Chinese, and Japanese appear only when an operator or public agency supplied them; the atlas does not machine-translate missing names.</div>
    ${filterBar(query, "Korean, English, Chinese, Japanese, region, source, or station ID")}
    <div class="map-coverage" aria-label="Map and translation coverage">
      <span><strong>${number.format(stations.length)}</strong><small>visible coordinate aliases</small></span>
      <span><strong>${number.format(visibleRecords)}</strong><small>visible records</small></span>
      <span><strong>${data.summary.coordinateCoverage}%</strong><small>all rows with coordinates</small></span>
      <span><strong>${data.summary.multilingualNameCoverage}%</strong><small>all rows with EN, ZH, or JA</small></span>
    </div>
    <div class="station-map-layout">
      <div class="station-map-wrap">
        <svg class="station-map" viewBox="0 0 1000 620" role="img" aria-labelledby="station-map-title station-map-description">
          <title id="station-map-title">Coordinate-backed Korean transit records</title>
          <desc id="station-map-description">A longitude and latitude plot of exact official station coordinates. Select a point to view matching records.</desc>
          <rect class="map-field" x="${plotLeft}" y="${plotTop}" width="${plotWidth}" height="${plotHeight}" />
          ${longitudeGrid.map((longitude) => {
            const x = plotLeft + ((longitude - longitudeMin) / (longitudeMax - longitudeMin)) * plotWidth;
            return `<g class="map-grid"><line x1="${x}" y1="${plotTop}" x2="${x}" y2="${plotTop + plotHeight}"/><text x="${x + 5}" y="${plotTop + plotHeight - 7}">${longitude}°E</text></g>`;
          }).join("")}
          ${latitudeGrid.map((latitude) => {
            const y = plotTop + ((latitudeMax - latitude) / (latitudeMax - latitudeMin)) * plotHeight;
            return `<g class="map-grid"><line x1="${plotLeft}" y1="${y}" x2="${plotLeft + plotWidth}" y2="${y}"/><text x="${plotLeft + 6}" y="${y - 6}">${latitude}°N</text></g>`;
          }).join("")}
          ${stations.map((station) => {
            const point = project(station);
            const radius = Math.min(10, 3 + Math.log2(station.records + 1));
            const eventSuffix = station.eventRaw == null ? "" : ` · event ${station.eventRaw.toString(16).padStart(2, "0").toUpperCase()}`;
            return `<a href="#workbench" class="map-point ${station.mode.includes("rail") ? "map-point-rail" : "map-point-bus"}" data-filter-location="${escapeHtml(station.code)}" aria-label="${escapeHtml(`${station.name}, ${station.records} records${eventSuffix}`)}"><circle cx="${point.x.toFixed(2)}" cy="${point.y.toFixed(2)}" r="${radius.toFixed(2)}"><title>${escapeHtml(mapTooltip(station))}</title></circle></a>`;
          }).join("")}
        </svg>
        <div class="map-legend"><span><i class="rail"></i>Rail</span><span><i class="bus"></i>Bus</span><small>Circle size follows record count · hover or focus for official names and coordinate provenance</small></div>
      </div>
      <aside class="map-station-list">
        <p class="eyebrow">HIGHEST VOLUME / CURRENT FILTER</p>
        ${stations.slice().sort((left, right) => right.records - left.records).slice(0, 12).map((station) => `<button type="button" data-filter-location="${escapeHtml(station.code)}">
          <span>${stationNameLabel(station.code, station.name, station)}</span>
          <small>${number.format(station.records)} rows · ${escapeHtml(station.mode)}${station.eventRaw == null ? "" : ` · event ${station.eventRaw.toString(16).padStart(2, "0").toUpperCase()}`}</small>
          <small>Coords: ${escapeHtml(station.coordinateSourceTitle ?? "sourced")}${station.coordinateSourceStationID ? ` · ${escapeHtml(station.coordinateSourceStationID)}` : ""}</small>
        </button>`).join("") || `<p class="map-empty">No coordinate-backed station matches this filter.</p>`}
      </aside>
    </div>`;
}

function stationProvenanceLabel(
  provenance: KnownLocation["provenance"] | LocationRow["provenance"],
): string {
  if (provenance === "official_dataset_exact_match") return "official exact ID";
  if (provenance === "official_dataset_transformed_exact_match") return "official row + documented transform";
  if (provenance === "user_confirmed") return "user confirmed";
  return "unresolved";
}

function byteStrip(record: RecordRow, compact = false): string {
  const decoded = decodeRecord(record.raw);
  return `<div class="byte-strip ${compact ? "byte-strip-compact" : ""}" aria-label="52 byte record">
    ${decoded.bytes
      .map((value, offset) => {
        const field = fieldForByte(offset);
        const confidence = field?.confidence ?? "open";
        return `<button class="byte-cell confidence-${confidence}" type="button" data-byte-offset="${offset}"
          title="Byte ${offset.toString().padStart(2, "0")} · ${field?.label ?? "Unknown"} · ${value
            .toString(16)
            .padStart(2, "0")
            .toUpperCase()}">
          <span>${offset.toString().padStart(2, "0")}</span>${value.toString(16).padStart(2, "0").toUpperCase()}
        </button>`;
      })
      .join("")}
  </div>`;
}

function metric(label: string, value: string, detail: string): string {
  return `<article class="metric"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong><small>${escapeHtml(detail)}</small></article>`;
}

function insight(index: string, title: string, status: string, body: string): string {
  return `<article class="insight">
    <div class="insight-index">${escapeHtml(index)}</div>
    <div><span class="confidence-label">${escapeHtml(status)}</span><h3>${escapeHtml(title)}</h3><p>${body}</p></div>
  </article>`;
}

function renderShell(data: Dataset): void {
  const latestRecord = data.records.reduce((latest, record) =>
    record.createdAt > latest.createdAt ? record : latest,
  );
  const inflatedDistances = data.records.filter((record) => record.legacyDistanceMeters > 100_000).length;
  const stationSystems = new Map<string, Set<string>>();
  data.records.forEach((record) => {
    const systems = stationSystems.get(record.stationToken) ?? new Set<string>();
    systems.add(record.transportModeCode);
    stationSystems.set(record.stationToken, systems);
  });
  const ambiguousStationCodes = [...stationSystems.values()].filter((systems) => systems.size > 1).length;
  const topSystems = data.networks.slice(0, 12);
  const maxSystemRecords = Math.max(...topSystems.map((system) => system.records));
  const commonSeoulSystems = [201, 202, 203, 115, 120]
    .map((code) => data.networks.find((system) => system.decimalCode === code))
    .filter((system): system is NetworkRow => Boolean(system));
  const commonSeoulRows = commonSeoulSystems.reduce((total, system) => total + system.records, 0);
  const prioritySeoulBusRows = data.records.filter((record) =>
    [115, 120].includes(record.systemDecimal),
  );
  const prioritySeoulBusMatches = prioritySeoulBusRows.filter(
    (record) => record.knownProvenance === "official_dataset_exact_match",
  ).length;

  app.innerHTML = `
    <header class="site-header">
      <a class="wordmark" href="#top"><span>CB</span> Korean Trip Atlas</a>
      <nav aria-label="Primary navigation">
        <a href="#findings">Findings</a><a href="#systems">Systems</a><a href="#known">Stations</a><a href="#workbench" data-open-panel="map">Map</a>
      </nav>
      <div class="snapshot-chip"><i></i> Snapshot ${escapeHtml(formatDate(data.meta.sourceLastSeen))}</div>
    </header>
    <main id="main">
      <section class="hero" id="top">
        <div class="hero-copy">
          <p class="eyebrow">KS X 6924 · SFI 03 · FULL D1 SNAPSHOT</p>
          <h1>Korean<br><em>Trip Atlas</em></h1>
          <p class="lede">Every collected T-money and EZL/Cashbee trip record, linked across cards, counters, KOTRIS transport-mode matches, exact station coordinates, official multilingual names, and all 52 raw bytes.</p>
          <div class="hero-actions">
            <button type="button" class="primary-action" data-open-panel="records">Explore all ${number.format(data.summary.records)} rows</button>
            <a href="#findings">Read what matched ↓</a>
          </div>
        </div>
        <aside class="record-specimen" aria-label="Latest record specimen">
          <div class="specimen-head"><span>RECORD SPECIMEN / LATEST INGEST</span><code>${escapeHtml(latestRecord.id.slice(0, 12))}</code></div>
          ${byteStrip(latestRecord, true)}
          <div class="specimen-key">
            <span><i class="key-confirmed"></i> confirmed</span>
            <span><i class="key-inferred"></i> inferred</span>
            <span><i class="key-open"></i> unresolved</span>
          </div>
          <div class="specimen-caption">
            <span>${eventPill(latestRecord.event)}</span>
            <span>${escapeHtml(latestRecord.knownName ?? latestRecord.locationCode)}</span>
            <span>${escapeHtml(latestRecord.family)}</span>
          </div>
        </aside>
      </section>

      <section class="metrics-band" aria-label="Dataset summary">
        ${metric("Records", number.format(data.summary.records), `${number.format(data.summary.uniqueRawRecords)} unique payloads`)}
        ${metric("Hashed cards", number.format(data.summary.cards), familyLabel(data.summary.families))}
        ${metric("Sourced station matches", number.format(data.summary.officialStationLocations), `${number.format(data.summary.officialStationRows)} rows · ${data.summary.officialStationCoverage}% coverage`)}
        ${metric("Coordinate coverage", `${data.summary.coordinateCoverage}%`, `${number.format(data.summary.coordinateRows)} rows · ${number.format(data.summary.coordinateLocations)} aliases`)}
        ${metric("Official EN / ZH / JA", `${data.summary.multilingualNameCoverage}%`, `${number.format(data.summary.multilingualNameRows)} rows · ${number.format(data.summary.multilingualNameLocations)} aliases`)}
        ${metric("Official system match", `${data.summary.officialSystemCoverage}%`, `${number.format(data.summary.officialSystemRows)} rows · ${data.summary.officialSystemCodes} codes`)}
      </section>

      <section class="section findings-section" id="findings">
        <div class="section-heading">
          <div><p class="eyebrow">WHAT ACTUALLY MATCHES</p><h2>Six findings from the whole corpus</h2></div>
          <p>Confirmed samples are treated as anchors. Dataset-wide repetition raises confidence; conflicts stay visible.</p>
        </div>
        <div class="insight-grid">
          ${insight(
            "01",
            "Keep two location levels",
            "CONFIRMED",
            `<code>05–08</code> is a reusable station token; <code>05–10</code> is the collision-free recorded context. <strong>${number.format(
              ambiguousStationCodes,
            )}</strong> tokens occur under multiple systems, so exact row matching must retain all six bytes. Byte 08 is part of this token—not a train/bus flag.`,
          )}
          ${insight(
            "02",
            "Bytes 09–10 match transport-mode codes",
            "OFFICIAL MATCH",
            `<strong>${data.summary.officialSystemCodes} of ${data.summary.transportModeCodes}</strong> observed codes occur in the official KORAIL KOTRIS or Seoul Smart Card tables, resolving <strong>${data.summary.officialSystemCoverage}%</strong> of rows. Another <strong>${data.summary.institutionalReferenceSystemCodes + data.summary.corpusInferenceSystemCodes}</strong> codes have separately labeled institutional or geometry evidence. Applying any table to card bytes 09–10 is a CardBal corpus inference; a value describes a mode or service, not generally a company ID.`,
          )}
          ${insight(
            "03",
            "Official station rows map by two strict joins",
            "OFFICIAL + TRANSFORM",
            `<strong>${number.format(prioritySeoulBusMatches)} of ${number.format(
              prioritySeoulBusRows.length,
            )}</strong> records for common Seoul bus codes 115 and 120 match exact settlement IDs. Nationwide, that direct join resolves <strong>${number.format(data.summary.officialExactStationRows)}</strong> rows. Versioned, system-scoped transforms add <strong>${number.format(data.summary.officialTransformedStationRows)}</strong>: capital rail ${number.format(data.summary.capitalRailStationRows)}, Busan BIMS bus ${number.format(data.summary.busanBIMSStationRows)}, Busan Metro ${number.format(data.summary.busanMetroStationRows)}, and Daegu Line 2 ${number.format(data.summary.daeguStationRows)}. Every transformed row keeps its method and source; review candidates stay unnamed.`,
          )}
          ${insight(
            "04",
            "Trip-time parsing follows operator profiles",
            "CORROBORATED",
            `<strong>${number.format(data.summary.timestampLayouts.packed33 ?? 0)}</strong> rows use a 33-bit packed clock and <strong>${number.format(
              data.summary.timestampLayouts.bcd14 ?? 0,
            )}</strong> use seven-byte <code>YYYYMMDDhhmmss</code> BCD. <strong>${number.format(
              data.summary.timestampLayouts.operator_opaque ?? 0,
            )}</strong> Mybi-family rows expose two raw counters rather than a fabricated date; another <strong>${number.format(
              data.summary.timestampLayouts.alternate_unknown ?? 0,
            )}</strong> fail both documented profiles.`,
          )}
          ${insight(
            "05",
            "Distance is two bytes, not three",
            "CONFIRMED",
            `<code>19–20</code> matches the labelled trip distances. Pulling byte 18 into the value produces more than 100 km for <strong>${number.format(
              inflatedDistances,
            )}</strong> records.`,
          )}
          ${insight(
            "06",
            "Official multilingual names stay source-faithful",
            "OFFICIAL LABELS ONLY",
            `<strong>${number.format(data.summary.englishNameRows)}</strong> rows have an official English label, <strong>${number.format(data.summary.chineseNameRows)}</strong> have official Chinese, and <strong>${number.format(data.summary.japaneseNameRows)}</strong> have official Japanese. Korean remains the primary display name; missing translations remain blank rather than being machine-generated.`,
          )}
        </div>
      </section>

      <section class="section systems-section" id="systems">
        <div class="section-heading">
          <div><p class="eyebrow">SOURCED TRANSPORT-CODE CROSSWALK</p><h2>Transport systems, regions, and service classes</h2></div>
          <p>The hexadecimal value is the exact card field. Most labels come from KORAIL’s 319-row KOTRIS table; six observed gaps are shown with distinct Seoul, institutional, or corpus-inference provenance.</p>
        </div>
        <div class="system-overview">
          <div class="system-chart">
            ${topSystems
              .map(
                (system) => `<button type="button" class="system-chart-row" data-filter-network="${escapeHtml(system.code)}">
                  <code>${escapeHtml(system.code)}</code>
                  <span><i style="width:${Math.max(1, (system.records / maxSystemRecords) * 100)}%"></i></span>
                  <strong>${escapeHtml(system.officialNameKo ?? "Unmapped")}</strong>
                  <small>${escapeHtml(system.area ?? system.transportClassName ?? "Open")}</small>
                  <b>${number.format(system.records)}</b>
                </button>`,
              )
              .join("")}
          </div>
          <aside class="system-summary">
            <span>${data.summary.officialSystemCodes}<small>official codes</small></span>
            <span>${data.summary.unmappedSystemCodes}<small>still unmapped</small></span>
            <span>${data.summary.officialSystemCards}<small>cards covered</small></span>
            <p>For rail, a label may name an operator. For buses, a code usually identifies a city or fare/service class shared by multiple companies. Of the unmatched codes, ${data.summary.associatedSystemCodes} have a cautious corpus-only regional association.</p>
            <p><strong>Common Seoul-linked modes:</strong> ${commonSeoulSystems
              .map((system) => `${system.decimalCode} ${system.officialNameKo ?? "unmapped"} (${number.format(system.records)})`)
              .join(" · ")}. Together they cover ${number.format(commonSeoulRows)} rows (${(
                (commonSeoulRows / data.summary.records) *
                100
              ).toFixed(1)}% of the corpus).</p>
            <button type="button" class="primary-action" data-open-panel="networks">Inspect all ${data.summary.transportModeCodes} system codes</button>
          </aside>
        </div>
      </section>

      <section class="section known-section" id="known">
        <div class="section-heading">
          <div><p class="eyebrow">STATION GROUND TRUTH</p><h2>${number.format(data.summary.officialStationLocations)} sourced station fingerprints, ${number.format(data.summary.coordinateLocations)} placed aliases</h2></div>
          <p>Identity, official translations, and coordinates each retain their own source and matching method. A station appears on the map only when its alias has an exact, cited coordinate match.</p>
        </div>
        <div class="known-grid">
          ${data.knownLocations
            .slice(0, 12)
            .map(
              (item) => `<button class="known-card" type="button" data-filter-location="${escapeHtml(item.code)}">
                <span>${escapeHtml(stationProvenanceLabel(item.provenance))}</span>${stationNameLabel(item.code, item.name, item)}
                <small>${number.format(item.records)} records · ${number.format(item.cards)} cards${item.sggName ? ` · ${escapeHtml(item.sggName)}` : ""}</small>
              </button>`,
            )
            .join("")}
        </div>
        <div class="known-more"><button type="button" class="primary-action" data-open-panel="locations">Browse all ${number.format(data.summary.knownLocations)} matched fingerprints</button></div>
      </section>

      <section class="section workbench-section" id="workbench">
        <div class="section-heading workbench-heading">
          <div><p class="eyebrow">FULL DATASET WORKBENCH</p><h2>Follow the bytes, cards, and candidate journeys</h2></div>
          <p>All ${number.format(data.summary.records)} rows are retained. Card identifiers are full SHA-256 hashes; plaintext last-four fragments are omitted. Created-at is ingestion time; decoded trip time is shown separately.</p>
        </div>
        <div class="panel-tabs" aria-label="Dataset views">
          ${(["map", "locations", "networks", "journeys", "cards", "records", "bytes"] as Panel[])
            .map(
              (panel) => `<button type="button" data-panel="${panel}" aria-pressed="${
                panel === "map"
              }">${panel === "bytes" ? "52-byte map" : panel === "networks" ? "systems" : panel}</button>`,
            )
            .join("")}
        </div>
        <div id="panel-content" class="panel-content"></div>
      </section>

      <section class="section method-section" id="method">
        <div class="method-copy">
          <p class="eyebrow">METHOD & BOUNDARIES</p>
          <h2>Evidence first. Unknown means unknown.</h2>
          <p>The atlas joins exact six-byte fingerprints, never nearby-looking codes. Candidate journeys require the same hashed card, the same byte-04 counter, a plausible decoded timestamp in either proven encoding, and an entry followed by an exit within eight hours. Counter reuse and missing scan order mean these remain candidates.</p>
        </div>
        <div class="source-list">
          ${data.sources
            .map(
              (source, index) => `<article><span>${String(index + 1).padStart(2, "0")}</span><div>${
                source.url
                  ? `<a href="${escapeHtml(source.url)}" target="_blank" rel="noreferrer">${escapeHtml(source.title)} ↗</a>`
                  : `<strong>${escapeHtml(source.title)}</strong>`
              }<p>${escapeHtml(source.note)}</p></div></article>`,
            )
            .join("")}
        </div>
      </section>
    </main>
    <footer>
      <span>CardBal / Korean Trip Atlas</span>
      <span>Generated ${escapeHtml(formatDate(data.meta.generatedAt, true))}</span>
      <span>${escapeHtml(data.meta.method)}</span>
    </footer>
    <dialog id="record-dialog" aria-labelledby="record-dialog-title"><div id="record-dialog-content"></div></dialog>
    <div class="toast" id="toast" role="status" aria-live="polite"></div>
  `;
}

function tablePager(total: number, page: number): string {
  const pages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  return `<div class="pager">
    <span>${number.format(total)} results · page ${page + 1} / ${pages}</span>
    <div><button type="button" data-page="${page - 1}" ${page <= 0 ? "disabled" : ""}>← Previous</button>
    <button type="button" data-page="${page + 1}" ${page + 1 >= pages ? "disabled" : ""}>Next →</button></div>
  </div>`;
}

function filterBar(
  query: string,
  placeholder: string,
  extra = "",
): string {
  return `<div class="filter-bar">
    <label class="search-control"><span>Search</span><input id="panel-search" type="search" value="${escapeHtml(
      query,
    )}" placeholder="${escapeHtml(placeholder)}" autocomplete="off"></label>
    ${extra}
  </div>`;
}

function renderPanel(data: Dataset, panel: Panel, query: string, page: number, family: string, event: string): string {
  const normalized = query.trim().toLowerCase();
  if (panel === "map") return renderStationMap(data, query);

  if (panel === "locations") {
    const rows = data.locations.filter((row) =>
      [
        row.code,
        row.stationToken,
        row.transportModeCode,
        row.systemDecimal,
        row.systemOfficialNameKo ?? "",
        row.systemClassName ?? "",
        row.systemArea ?? "",
        row.systemAssociationNote ?? "",
        row.stationIdCandidate ?? "",
        row.name ?? "",
        row.identityName ?? "",
        ...stationSearchNames(row),
        row.mode ?? "",
        row.provenance ?? "",
        row.sourceTitle ?? "",
        row.sourceStationID ?? "",
        row.nameSourceTitle ?? "",
        row.nameSourceStationID ?? "",
        row.hanjaSourceTitle ?? "",
        row.coordinateSourceTitle ?? "",
        row.coordinateSourceStationID ?? "",
        row.coordinateMatchingMethod ?? "",
        row.arsID ?? "",
        row.ctpvName ?? "",
        row.sggName ?? "",
      ]
        .join(" ")
        .toLowerCase()
        .includes(normalized),
    );
    const visible = rows.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
    return `<div class="panel-note"><strong>Two levels are shown.</strong> The four-byte station token can recur across services; the six-byte fingerprint is the exact recorded context. Names require an exact cited official row. Legacy capital rail, Busan, Daegu, and Jeju transforms are system-scoped corpus inferences and remain labeled separately from the official station identity.</div>
      ${filterBar(query, "Korean or official translated name, station ID, source, region, or fingerprint")}
      <div class="table-wrap"><table><thead><tr><th>Location fingerprint</th><th>Station identity</th><th>Coordinates</th><th>Transport system</th><th>Records</th><th>Cards</th><th>Entry / exit / flagged</th><th>Families</th></tr></thead>
      <tbody>${visible
        .map(
          (row) => `<tr><td><button type="button" class="table-link" data-filter-location="${escapeHtml(
            row.code,
          )}" aria-label="Show all records for ${escapeHtml(row.name ?? row.code)}">${stationNameLabel(
            row.code,
            row.name,
            row,
          )}</button>${row.identityName && row.identityName !== row.name ? `<small>Card alias: ${escapeHtml(row.identityName)}</small>` : ""}${row.nameSourceTitle ? `<small>Name source: ${sourceLink(row.nameSourceTitle, row.nameSourceURL)}${row.nameSourceStationID ? ` · ${escapeHtml(row.nameSourceStationID)}` : ""}</small>` : ""}${row.nameHanja && row.hanjaSourceTitle && row.hanjaSourceID !== row.nameSourceID ? `<small>Hanja source: ${sourceLink(row.hanjaSourceTitle, row.hanjaSourceURL)}</small>` : ""}</td><td><code>${escapeHtml(row.stationToken)}</code>${
            row.provenance === "official_dataset_exact_match"
              ? `<small>official settlement ${escapeHtml(row.sourceStationID ?? "")}${row.sggName ? ` · ${escapeHtml(row.sggName)}` : ""}${row.arsID ? ` · ARS ${escapeHtml(row.arsID)}` : ""}</small>`
              : row.provenance === "official_dataset_transformed_exact_match"
                ? `<small>official station ${escapeHtml(row.sourceStationID ?? "")} · ${escapeHtml(
                    row.matchingMethod === "busan_bims_low16le_ars_exact"
                      ? "Busan BIMS low16LE → ARS"
                      : row.matchingMethod === "busan_mybi_station_byte"
                        ? "Busan Mybi station byte"
                        : row.matchingMethod === "daegu_event_split_station_id_v1"
                          ? "Daegu event-split station ID"
                          : row.matchingMethod === "jeju_station_variant_digit_exact"
                            ? "Jeju seven-digit selector join"
                            : row.matchingMethod === "seoul_code190_settlement_exact_unresolved_system"
                              ? "dated Seoul stop join · system unresolved"
                            : row.matchingMethod === "capital_rail_additional_high_exact_location"
                              ? "capital rail high-only crosswalk"
                          : row.matchingMethod ?? "documented transform",
                  )}${row.sggName ? ` · ${escapeHtml(row.sggName)}` : ""}</small>`
              : row.stationIdCandidate
                ? `<small>unmatched settlement candidate ${escapeHtml(row.stationIdCandidate)}</small>`
              : ""
          }${row.sourceTitle ? `<small>Identity source: ${sourceLink(row.sourceTitle, row.sourceURL)}</small>` : ""}</td><td>${
            row.latitude !== null && row.longitude !== null
              ? `<strong>${row.latitude.toFixed(6)}, ${row.longitude.toFixed(6)}</strong><small>${sourceLink(row.coordinateSourceTitle, row.coordinateSourceURL)}${row.coordinateSourceStationID ? ` · ${escapeHtml(row.coordinateSourceStationID)}` : ""}</small>${row.coordinateMatchingMethod ? `<small>${escapeHtml(row.coordinateMatchingMethod)}</small>` : ""}`
              : `<span class="unresolved">Not sourced</span>`
          }</td><td><strong>${escapeHtml(row.systemOfficialNameKo ?? "Unmapped")}</strong><code>${escapeHtml(
            row.transportModeCode,
          )} · ${row.systemDecimal}</code><small>${escapeHtml(
            [row.systemArea, row.systemClassName].filter(Boolean).join(" · ") || "No official match",
          )}</small></td><td><strong>${number.format(
            row.records,
          )}</strong></td><td>${number.format(row.cards)}</td><td><span class="event-counts"><i>${number.format(
            row.boarding,
          )}</i><i>${number.format(row.alighting)}</i><i>${number.format(row.flagged)}</i></span></td><td>${escapeHtml(
            familyLabel(row.families),
          )}</td></tr>`,
        )
        .join("")}</tbody></table></div>${tablePager(rows.length, page)}`;
  }

  if (panel === "networks") {
    const max = Math.max(...data.networks.map((row) => row.records));
    const rows = data.networks.filter((row) =>
      [
        row.code,
        row.decimalCode,
        row.officialNameKo ?? "",
        row.transportClassName ?? "",
        row.area ?? "",
        ...row.knownLocations,
      ]
        .join(" ")
        .toLowerCase()
        .includes(normalized),
    );
    return `<div class="panel-note"><strong>Transport-mode crosswalk.</strong> CardBal interprets bytes 09–10 as a big-endian code. Each row shows whether the label comes from official KORAIL KOTRIS, official Seoul data, an institutional table, a corpus geometry inference, or remains unmapped.</div>
      ${filterBar(query, "Hex, decimal, Korean label, region, class, or place")}
      <div class="network-list">${rows
        .map(
          (row) => `<button type="button" class="network-row" data-filter-network="${escapeHtml(row.code)}">
            <code>${escapeHtml(row.code)}<small>${row.decimalCode}</small></code><span class="network-bar"><i style="width:${Math.max(
              1,
              (row.records / max) * 100,
            )}%"></i></span><strong>${number.format(row.records)}</strong><small>${number.format(
              row.locations,
            )} fingerprints · ${number.format(row.cards)} cards</small><em><b>${escapeHtml(
              row.officialNameKo ?? "Unmapped code",
            )}</b>${escapeHtml(
              [row.area, row.transportClassName].filter(Boolean).join(" · ") || "Needs source match",
            )}<span class="match-${row.matchStatus}">${row.matchStatus.replaceAll("_", " ")}</span>${
              row.sourceTitle ? `<small>Source: ${escapeHtml(row.sourceTitle)}</small>` : ""
            }${
              row.associationNote ? `<small>${escapeHtml(row.associationNote)}</small>` : ""
            }</em>
          </button>`,
        )
        .join("")}</div>`;
  }

  if (panel === "journeys") {
    const rows = data.flows.filter((row) =>
      [row.fromCode, row.fromName ?? "", row.toCode, row.toName ?? ""]
        .join(" ")
        .toLowerCase()
        .includes(normalized),
    );
    const visible = rows.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
    return `<div class="panel-note"><strong>Candidate links, not certified itineraries.</strong> Same full card hash + counter, exact entry/exit bytes, plausible timestamp in either proven encoding, ≤8 h.</div>
      ${filterBar(query, "Origin, destination, or fingerprint")}
      <div class="table-wrap"><table><thead><tr><th>Origin</th><th></th><th>Destination</th><th>Journeys</th><th>Cards</th><th>Median time</th><th>Median distance</th></tr></thead>
      <tbody>${visible
        .map(
          (row) => `<tr><td>${locationLabel(row.fromCode, row.fromName)}</td><td class="flow-arrow">→</td><td>${locationLabel(
            row.toCode,
            row.toName,
          )}</td><td><strong>${number.format(row.journeys)}</strong></td><td>${number.format(
            row.cards,
          )}</td><td>${row.medianMinutes} min</td><td>${
            row.medianDistanceMeters ? `${(row.medianDistanceMeters / 1000).toFixed(1)} km` : "—"
          }</td></tr>`,
        )
        .join("")}</tbody></table></div>${tablePager(rows.length, page)}`;
  }

  if (panel === "cards") {
    const rows = data.cards.filter((row) =>
      [row.hash, ...Object.keys(row.families)].join(" ").toLowerCase().includes(normalized),
    );
    const visible = rows.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
    return `${filterBar(query, "Full pseudonymous hash or card family")}
      <div class="card-ledger">${visible
        .map(
          (row) => `<button type="button" class="card-ledger-row" data-filter-card="${escapeHtml(row.hash)}">
            <span class="card-family-dot ${Object.keys(row.families)[0]?.startsWith("T-") ? "tmoney" : "ezl"}"></span>
            <code title="${escapeHtml(row.hash)}">${escapeHtml(shortHash(row.hash))}</code>
            <strong>${number.format(row.records)} records</strong>
            <span>${number.format(row.locations)} location keys</span>
            <span>hashed card ID</span>
            <small>${escapeHtml(familyLabel(row.families))}</small>
          </button>`,
        )
        .join("")}</div>${tablePager(rows.length, page)}`;
  }

  if (panel === "records") {
    const familyControl = `<label><span>Family</span><select id="family-filter"><option value="">Both families</option><option value="T-money" ${
      family === "T-money" ? "selected" : ""
    }>T-money</option><option value="EZL / Cashbee" ${family === "EZL / Cashbee" ? "selected" : ""}>EZL / Cashbee</option></select></label>`;
    const eventControl = `<label><span>Event byte</span><select id="event-filter"><option value="">Every event</option><option value="boarding" ${
      event === "boarding" ? "selected" : ""
    }>00 Boarding</option><option value="alighting" ${event === "alighting" ? "selected" : ""}>01 Alighting</option><option value="flagged" ${
      event === "flagged" ? "selected" : ""
    }>Other / flagged</option></select></label>`;
    const rows = data.records.filter((row) => {
      if (family && row.family !== family) return false;
      if (event && row.event !== event) return false;
      return [
        row.dedupHash,
        row.cardHash,
        row.raw,
        row.locationCode,
        row.stationToken,
        row.transportModeCode,
        row.systemDecimal,
        row.systemOfficialNameKo ?? "",
        row.systemClassName ?? "",
        row.systemArea ?? "",
        row.systemAssociationNote ?? "",
        row.stationIdCandidate ?? "",
        row.knownName ?? "",
        row.knownNameEnglish ?? "",
        row.knownNameHanja ?? "",
        row.knownNameChineseSimplified ?? "",
        row.knownNameChineseTraditional ?? "",
        row.knownNameJapanese ?? "",
        row.knownSourceStationID ?? "",
        row.knownSourceTitle ?? "",
        row.knownNameSourceTitle ?? "",
        row.knownCoordinateSourceTitle ?? "",
        row.knownCoordinateSourceStationID ?? "",
        row.knownARSID ?? "",
        row.knownCtpvName ?? "",
        row.knownSggName ?? "",
        row.family,
        row.timestamp ?? "",
      ]
        .join(" ")
        .toLowerCase()
        .includes(normalized);
    });
    const visible = rows.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
    return `${filterBar(query, "Hash, Korean or official translated name, source, raw hex, or timestamp", familyControl + eventControl)}
      <div class="table-wrap"><table><thead><tr><th>Trip time</th><th>Event</th><th>Location</th><th>Fare hypothesis</th><th>Distance</th><th>Card</th><th>Family</th><th>Record</th></tr></thead>
      <tbody>${visible
        .map(
          (row) => `<tr><td>${
            row.timestamp && row.timestampPlausible
              ? formatDate(row.timestamp, true)
              : row.timestamp
                ? `<span class="invalid">Future / implausible candidate</span>`
                : `<span class="invalid">Not decoded</span>`
          }<small>${escapeHtml(row.timestampLayout)} · ingested ${escapeHtml(formatDate(row.createdAt))}</small></td><td>${eventPill(
            row.event,
            row.eventRaw,
          )}</td><td>${stationNameLabel(row.locationCode, row.knownName, {
            nameEnglish: row.knownNameEnglish,
            nameHanja: row.knownNameHanja,
            nameChineseSimplified: row.knownNameChineseSimplified,
            nameChineseTraditional: row.knownNameChineseTraditional,
            nameJapanese: row.knownNameJapanese,
          })}<small>${escapeHtml(
            row.systemOfficialNameKo ?? `Unmapped system ${row.transportModeCode}`,
          )}${row.knownSourceStationID ? ` · official stop ${escapeHtml(row.knownSourceStationID)}` : ""}${row.knownSggName ? ` · ${escapeHtml(row.knownSggName)}` : ""}</small></td><td>${
            row.selectedFare ? krw.format(row.selectedFare) : "—"
          }<small>${escapeHtml(row.fareLayout)}</small></td><td>${
            row.distanceMeters ? `${(row.distanceMeters / 1000).toFixed(2)} km` : "—"
          }</td><td><code title="${escapeHtml(row.cardHash)}">${escapeHtml(shortHash(row.cardHash))}</code><small>pseudonymous hash</small></td><td>${escapeHtml(row.family)}</td><td><button type="button" class="table-link" data-record-id="${escapeHtml(
            row.id,
          )}" aria-label="Open full raw record ${escapeHtml(row.id.slice(0, 12))}">Open ↗</button></td></tr>`,
        )
        .join("")}</tbody></table></div>${tablePager(rows.length, page)}`;
  }

  const selected = data.records.find((row) => row.id === query) ?? data.records[0];
  const maxEntropy = Math.max(...data.fieldStats.map((stat) => stat.entropy));
  return `<div class="byte-workbench">
    <div class="byte-record-head"><div><p class="eyebrow">SELECTED RECORD</p><h3>${escapeHtml(
      selected.knownName ?? selected.locationCode,
    )}</h3></div><button type="button" data-record-id="${escapeHtml(selected.id)}">Open full record ↗</button></div>
    ${byteStrip(selected)}
    <div class="field-legend">${BYTE_FIELDS.map(
      (field) => `<span class="confidence-${field.confidence}"><i></i>${field.start.toString().padStart(2, "0")}${
        field.end === field.start ? "" : `–${field.end.toString().padStart(2, "0")}`
      } ${escapeHtml(field.label)}</span>`,
    ).join("")}</div>
    <div class="entropy-block"><div><p class="eyebrow">BYTE ENTROPY / ALL ${number.format(
      data.summary.records,
    )} ROWS</p><p>Taller means more varied. Bytes 00 and 01 are fixed at <code>01 32</code>; the location block carries the richest identity signal.</p></div>
      <div class="entropy-chart">${data.fieldStats
        .map(
          (stat) => `<button type="button" title="Byte ${stat.offset}: ${stat.distinct} values, entropy ${stat.entropy}" data-byte-offset="${
            stat.offset
          }"><i style="height:${Math.max(2, (stat.entropy / maxEntropy) * 100)}%"></i><span>${stat.offset
            .toString()
            .padStart(2, "0")}</span></button>`,
        )
        .join("")}</div>
    </div>
    <div id="byte-detail" class="byte-detail"><strong>Choose a byte</strong><span>Its corpus-wide value distribution will appear here.</span></div>
  </div>`;
}

function renderRecordDialog(data: Dataset, record: RecordRow): string {
  const linkedJourneys = data.journeys.filter(
    (journey) => journey.boardingRecord === record.id || journey.alightingRecord === record.id,
  );
  return `<div class="dialog-head"><div><p class="eyebrow">RAW RECORD / ${escapeHtml(record.family)}</p><h2 id="record-dialog-title">${escapeHtml(
    record.knownName ?? record.locationCode,
  )}</h2></div><button type="button" class="dialog-close" aria-label="Close record">×</button></div>
    <div class="dialog-summary">
      <div><span>Event</span>${eventPill(record.event, record.eventRaw)}</div>
      <div><span>Trip time</span><strong>${escapeHtml(
        record.timestamp
          ? record.timestampPlausible
            ? record.timestamp.replace("T", " ")
            : "Future / implausible candidate"
          : "Not decoded",
      )}</strong></div>
      <div><span>Card</span><button class="text-button" type="button" data-copy="${escapeHtml(record.cardHash)}" title="Copy full hash">${escapeHtml(
        record.cardHash,
      )}</button><small>pseudonymous hash only</small></div>
      <div><span>Ingested</span><strong>${escapeHtml(record.createdAt.replace("T", " "))}</strong></div>
    </div>
    ${byteStrip(record)}
    <div class="dialog-grid">
      <section><h3>Decoded / inferred fields</h3>
        <dl>
          <div><dt>Location fingerprint</dt><dd><code>${escapeHtml(record.locationCode)}</code></dd></div>
          <div><dt>Station token 05–08</dt><dd><code>${escapeHtml(record.stationToken)}</code>${
            record.knownSourceStationID
              ? ` · source station ${escapeHtml(record.knownSourceStationID)}`
              : record.stationIdCandidate
                ? ` · unmatched settlement candidate ${escapeHtml(record.stationIdCandidate)}`
              : ""
          }</dd></div>
          ${
            record.knownName
              ? `<div><dt>Station match</dt><dd>${escapeHtml(record.knownName)} · ${escapeHtml(
                  stationProvenanceLabel(record.knownProvenance),
                )}${record.knownMatchingMethod ? ` · ${escapeHtml(record.knownMatchingMethod)}` : ""}${record.knownSggName ? ` · ${escapeHtml(record.knownCtpvName ?? "")} ${escapeHtml(record.knownSggName)}` : ""}${record.knownARSID ? ` · ARS ${escapeHtml(record.knownARSID)}` : ""}</dd></div>`
              : ""
          }
          ${stationLanguageDetails({
            nameEnglish: record.knownNameEnglish,
            nameHanja: record.knownNameHanja,
            nameChineseSimplified: record.knownNameChineseSimplified,
            nameChineseTraditional: record.knownNameChineseTraditional,
            nameJapanese: record.knownNameJapanese,
          })}
          ${
            record.knownLatitude !== null && record.knownLongitude !== null
              ? `<div><dt>Source coordinates</dt><dd>${record.knownLatitude.toFixed(6)}, ${record.knownLongitude.toFixed(6)}${record.knownCoordinateSourceStationID ? ` · station ${escapeHtml(record.knownCoordinateSourceStationID)}` : ""}${record.knownSourceStopID ? ` · stop ${escapeHtml(record.knownSourceStopID)}` : ""}${record.knownCoordinateMatchingMethod ? `<small>${escapeHtml(record.knownCoordinateMatchingMethod)}</small>` : ""}</dd></div>`
              : ""
          }
          ${
            record.knownSourceTitle
              ? `<div><dt>Identity source</dt><dd>${sourceLink(record.knownSourceTitle, record.knownSourceURL)}</dd></div>`
              : ""
          }
          ${
            record.knownNameSourceTitle
              ? `<div><dt>Name source</dt><dd>${sourceLink(record.knownNameSourceTitle, record.knownNameSourceURL)}${record.knownNameMatchingMethod ? `<small>${escapeHtml(record.knownNameMatchingMethod)}</small>` : ""}</dd></div>`
              : ""
          }
          ${
            record.knownCoordinateSourceTitle
              ? `<div><dt>Coordinate source</dt><dd>${sourceLink(record.knownCoordinateSourceTitle, record.knownCoordinateSourceURL)}</dd></div>`
              : ""
          }
          <div><dt>KOTRIS system 09–10</dt><dd><code>${escapeHtml(record.transportModeCode)}</code> · ${record.systemDecimal} · ${escapeHtml(
            record.systemOfficialNameKo ?? "unmapped",
          )}${record.systemArea ? ` · ${escapeHtml(record.systemArea)}` : ""}</dd></div>
          <div><dt>Trip counter 04</dt><dd>${record.tripCounter} / 0x${record.tripCounter
            .toString(16)
            .padStart(2, "0")
            .toUpperCase()}</dd></div>
          <div><dt>Timestamp block 11–17</dt><dd><code>${escapeHtml(record.timestampHex)}</code> · ${escapeHtml(
            record.timestampLayout,
          )}${record.timestamp && !record.timestampPlausible ? " · implausible after ingest" : ""}</dd></div>
          ${
            record.operatorClockA !== null && record.operatorClockB !== null
              ? `<div><dt>Operator counters 11–16</dt><dd>${number.format(record.operatorClockA)} · ${number.format(record.operatorClockB)} · flag 0x${(record.operatorClockFlag ?? 0).toString(16).padStart(2, "0").toUpperCase()} <small>${escapeHtml(record.operatorFieldProfile)}</small></dd></div>`
              : ""
          }
          <div><dt>Distance 19–20</dt><dd>${number.format(record.distanceMeters)} m</dd></div>
          <div><dt>Terminal reference 24–27</dt><dd><code>${escapeHtml(record.terminalReference)}</code></dd></div>
        </dl>
      </section>
      <section><h3>Fare candidates</h3>
        <dl>
          <div><dt>Bytes 22–23</dt><dd>${krw.format(record.fare22)}</dd></div>
          <div><dt>Bytes 36–37</dt><dd>${krw.format(record.fare36)}</dd></div>
          <div><dt>Bytes 40–41</dt><dd>${krw.format(record.fare40)}</dd></div>
          <div><dt>Bytes 50–51</dt><dd>${krw.format(record.fare50)}</dd></div>
          <div><dt>Selected hypothesis</dt><dd>${record.selectedFare ? krw.format(record.selectedFare) : "None"}</dd></div>
          <div><dt>Fare layout</dt><dd><span class="pill pill-${record.fareLayout !== "unresolved" ? "boarding" : "flagged"}">${escapeHtml(
            record.fareLayout,
          )}</span></dd></div>
        </dl>
      </section>
    </div>
    <section class="raw-section"><div><h3>All 52 bytes</h3><button type="button" data-copy="${escapeHtml(
      record.raw,
    )}">Copy raw hex</button></div><code>${escapeHtml(record.raw)}</code></section>
    <section class="raw-section"><div><h3>Identifiers</h3><button type="button" data-copy="${escapeHtml(
      record.dedupHash,
    )}">Copy dedup hash</button></div><code>${escapeHtml(record.dedupHash)}</code></section>
    ${
      linkedJourneys.length
        ? `<section class="linked-journeys"><h3>Candidate journey links</h3>${linkedJourneys
            .map(
              (journey) => `<article><span>${escapeHtml(journey.fromName ?? journey.fromCode)}</span><i>→</i><span>${escapeHtml(
                journey.toName ?? journey.toCode,
              )}</span><small>${journey.durationMinutes} min · ${number.format(journey.distanceMeters)} m</small></article>`,
            )
            .join("")}</section>`
        : ""
    }
    <div class="dialog-byte-readout">Byte <strong>—</strong><span>Choose a cell above.</span></div>`;
}

async function copyText(value: string, toast: HTMLElement): Promise<void> {
  await navigator.clipboard.writeText(value);
  toast.textContent = "Copied to clipboard";
  toast.classList.add("toast-visible");
  window.setTimeout(() => toast.classList.remove("toast-visible"), 1800);
}

function wireApp(data: Dataset): void {
  let panel: Panel = "map";
  let query = "";
  let page = 0;
  let family = "";
  let event = "";
  const panelElement = document.querySelector<HTMLDivElement>("#panel-content");
  const dialogElement = document.querySelector<HTMLDialogElement>("#record-dialog");
  const dialogContentElement = document.querySelector<HTMLDivElement>("#record-dialog-content");
  const toastElement = document.querySelector<HTMLDivElement>("#toast");
  if (!panelElement || !dialogElement || !dialogContentElement || !toastElement) {
    throw new Error("Workbench elements missing");
  }
  const panelContent: HTMLDivElement = panelElement;
  const dialog: HTMLDialogElement = dialogElement;
  const dialogContent: HTMLDivElement = dialogContentElement;
  const toast: HTMLDivElement = toastElement;

  const showPanel = (nextPanel: Panel, nextQuery = "") => {
    panel = nextPanel;
    query = nextQuery;
    page = 0;
    document.querySelectorAll<HTMLButtonElement>("[data-panel]").forEach((button) => {
      const selected = button.dataset.panel === panel;
      button.setAttribute("aria-pressed", String(selected));
    });
    panelContent.innerHTML = renderPanel(data, panel, query, page, family, event);
    wirePanel();
  };

  const showRecord = (recordId: string) => {
    const record = data.records.find((candidate) => candidate.id === recordId);
    if (!record) return;
    dialogContent.innerHTML = renderRecordDialog(data, record);
    if (!dialog.open) dialog.showModal();
    wireDialog();
  };

  const showByteDetail = (offset: number, root: ParentNode = panelContent) => {
    const stat = data.fieldStats[offset];
    const field = fieldForByte(offset);
    const target = root.querySelector<HTMLElement>("#byte-detail, .dialog-byte-readout");
    if (!target) return;
    target.innerHTML = `<strong>Byte ${offset.toString().padStart(2, "0")} · ${escapeHtml(
      field?.label ?? "Unknown",
    )}</strong><span>${number.format(stat.distinct)} distinct values · entropy ${stat.entropy} bits · ${stat.top
      .map((item) => `<code>${item.hex} ${number.format(item.count)}</code>`)
      .join(" ")}</span>`;
  };

  function wireDialog() {
    dialogContent.querySelector<HTMLButtonElement>(".dialog-close")?.addEventListener("click", () => dialog.close());
    dialogContent.querySelectorAll<HTMLElement>("[data-copy]").forEach((button) => {
      button.addEventListener("click", () => void copyText(button.dataset.copy ?? "", toast));
    });
    dialogContent.querySelectorAll<HTMLButtonElement>("[data-byte-offset]").forEach((button) => {
      button.addEventListener("click", () => showByteDetail(Number(button.dataset.byteOffset), dialogContent));
    });
  }

  function wirePanel() {
    const search = panelContent.querySelector<HTMLInputElement>("#panel-search");
    search?.addEventListener("input", () => {
      query = search.value;
      page = 0;
      panelContent.innerHTML = renderPanel(data, panel, query, page, family, event);
      wirePanel();
      panelContent.querySelector<HTMLInputElement>("#panel-search")?.focus();
    });
    panelContent.querySelector<HTMLSelectElement>("#family-filter")?.addEventListener("change", (change) => {
      family = (change.currentTarget as HTMLSelectElement).value;
      page = 0;
      panelContent.innerHTML = renderPanel(data, panel, query, page, family, event);
      wirePanel();
    });
    panelContent.querySelector<HTMLSelectElement>("#event-filter")?.addEventListener("change", (change) => {
      event = (change.currentTarget as HTMLSelectElement).value;
      page = 0;
      panelContent.innerHTML = renderPanel(data, panel, query, page, family, event);
      wirePanel();
    });
    panelContent.querySelectorAll<HTMLButtonElement>("[data-page]").forEach((button) => {
      button.addEventListener("click", () => {
        page = Number(button.dataset.page);
        panelContent.innerHTML = renderPanel(data, panel, query, page, family, event);
        wirePanel();
        document.querySelector("#workbench")?.scrollIntoView({ behavior: "smooth" });
      });
    });
    panelContent.querySelectorAll<HTMLElement>("[data-record-id]").forEach((row) => {
      row.addEventListener("click", () => showRecord(row.dataset.recordId ?? ""));
    });
    panelContent.querySelectorAll<HTMLElement>("[data-filter-location]").forEach((row) => {
      row.addEventListener("click", () => showPanel("records", row.dataset.filterLocation ?? ""));
    });
    panelContent.querySelectorAll<HTMLElement>("[data-filter-network]").forEach((row) => {
      row.addEventListener("click", () => showPanel("records", row.dataset.filterNetwork ?? ""));
    });
    panelContent.querySelectorAll<HTMLElement>("[data-filter-card]").forEach((row) => {
      row.addEventListener("click", () => showPanel("records", row.dataset.filterCard ?? ""));
    });
    panelContent.querySelectorAll<HTMLButtonElement>("[data-byte-offset]").forEach((button) => {
      button.addEventListener("click", () => showByteDetail(Number(button.dataset.byteOffset)));
    });
  }

  document.querySelectorAll<HTMLButtonElement>("[data-panel]").forEach((button) => {
    button.addEventListener("click", () => showPanel(button.dataset.panel as Panel));
  });
  document.querySelectorAll<HTMLElement>("[data-filter-location]").forEach((button) => {
    button.addEventListener("click", () => {
      showPanel("records", button.dataset.filterLocation ?? "");
      document.querySelector("#workbench")?.scrollIntoView({ behavior: "smooth" });
    });
  });
  document.querySelectorAll<HTMLElement>("#systems [data-filter-network]").forEach((button) => {
    button.addEventListener("click", () => {
      showPanel("records", button.dataset.filterNetwork ?? "");
      document.querySelector("#workbench")?.scrollIntoView({ behavior: "smooth" });
    });
  });
  document.querySelectorAll<HTMLButtonElement>("[data-open-panel]").forEach((button) => {
    button.addEventListener("click", () => {
      showPanel(button.dataset.openPanel as Panel);
      document.querySelector("#workbench")?.scrollIntoView({ behavior: "smooth" });
    });
  });
  dialog.addEventListener("click", (click) => {
    if (click.target === dialog) dialog.close();
  });
  document.addEventListener("keydown", (key) => {
    if (key.key === "Escape" && dialog.open) dialog.close();
  });
  showPanel("map");
}

async function start(): Promise<void> {
  try {
    const response = await fetch("/data/korean-trips.json");
    if (!response.ok) throw new Error(`Dataset request failed (${response.status})`);
    const data = (await response.json()) as Dataset;
    renderShell(data);
    wireApp(data);
  } catch (error) {
    app.innerHTML = `<main class="fatal-error"><span>01 32 / LOAD ERROR</span><h1>The trip archive could not be opened.</h1><p>${escapeHtml(
      error instanceof Error ? error.message : String(error),
    )}</p><button type="button" onclick="location.reload()">Try again</button></main>`;
  }
}

void start();
