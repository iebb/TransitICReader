export type ReportType = "missing" | "correction";
export type ReportSource = "ios" | "android";

export interface StationReportInput {
  submissionId: string;
  reportType: ReportType;
  stationName: string;
  stationCode: string | null;
  suggestedCode: string | null;
  lines: string | null;
  operator: string | null;
  city: string | null;
  country: string | null;
  notes: string | null;
  location: { latitude: number; longitude: number; accuracyMeters: number | null } | null;
  cardFamily: string | null;
  cardIdHash: string | null;
  appVersion: string;
  deviceId: string;
  source: ReportSource;
}

export class ValidationError extends Error {
  readonly field: string;

  constructor(field: string, message: string) {
    super(message);
    this.name = "ValidationError";
    this.field = field;
  }
}

const allowedFields = new Set([
  "submissionId", "reportType", "stationName", "stationCode", "suggestedCode",
  "lines", "operator", "city", "country", "notes", "location", "cardFamily",
  "cardIdHash", "appVersion", "deviceId", "source",
]);
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const sha256Pattern = /^[0-9a-f]{64}$/i;

function object(value: unknown, field: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new ValidationError(field, `${field} must be an object.`);
  }
  return value as Record<string, unknown>;
}

function string(value: unknown, field: string, maxLength: number, required = false): string | null {
  if (value === undefined || value === null || value === "") {
    if (required) throw new ValidationError(field, `${field} is required.`);
    return null;
  }
  if (typeof value !== "string") throw new ValidationError(field, `${field} must be text.`);
  const result = value.trim();
  if (!result) {
    if (required) throw new ValidationError(field, `${field} is required.`);
    return null;
  }
  if (result.length > maxLength || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(result)) {
    throw new ValidationError(field, `${field} is too long or contains invalid characters.`);
  }
  return result;
}

function number(value: unknown, field: string, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < min || value > max) {
    throw new ValidationError(field, `${field} must be a number between ${min} and ${max}.`);
  }
  return value;
}

export function parseStationReport(value: unknown): StationReportInput {
  const input = object(value, "body");
  for (const key of Object.keys(input)) {
    if (!allowedFields.has(key)) throw new ValidationError(key, `${key} is not an accepted field.`);
  }

  const submissionId = string(input.submissionId, "submissionId", 36, true)!;
  const reportType = string(input.reportType, "reportType", 10, true);
  const stationName = string(input.stationName, "stationName", 120, true)!;
  const stationCode = string(input.stationCode, "stationCode", 64);
  const suggestedCode = string(input.suggestedCode, "suggestedCode", 64);
  const lines = string(input.lines, "lines", 240);
  const operator = string(input.operator, "operator", 120);
  const city = string(input.city, "city", 120);
  const country = string(input.country, "country", 120);
  const notes = string(input.notes, "notes", 1200);
  const cardFamily = string(input.cardFamily, "cardFamily", 80);
  const cardIdHash = string(input.cardIdHash, "cardIdHash", 64);
  const appVersion = string(input.appVersion, "appVersion", 48, true)!;
  const deviceId = string(input.deviceId, "deviceId", 36, true)!;
  const source = string(input.source, "source", 7, true);

  if (!uuidPattern.test(submissionId)) throw new ValidationError("submissionId", "submissionId must be a UUID.");
  if (reportType !== "missing" && reportType !== "correction") {
    throw new ValidationError("reportType", "reportType must be missing or correction.");
  }
  if (reportType === "correction" && !stationCode) {
    throw new ValidationError("stationCode", "A station code is required for corrections.");
  }
  if (suggestedCode && reportType !== "correction") {
    throw new ValidationError("suggestedCode", "suggestedCode is only for corrections.");
  }
  if (cardIdHash && !sha256Pattern.test(cardIdHash)) {
    throw new ValidationError("cardIdHash", "cardIdHash must be a SHA-256 hex digest.");
  }
  if (!uuidPattern.test(deviceId)) throw new ValidationError("deviceId", "deviceId must be a UUID.");
  if (source !== "ios" && source !== "android") {
    throw new ValidationError("source", "source must be ios or android.");
  }
  if (!cardIdHash) {
    throw new ValidationError("cardIdHash", "App reports require a hashed card ID.");
  }

  let location: StationReportInput["location"] = null;
  if (input.location !== undefined && input.location !== null) {
    const supplied = object(input.location, "location");
    for (const key of Object.keys(supplied)) {
      if (!new Set(["latitude", "longitude", "accuracyMeters"]).has(key)) {
        throw new ValidationError(`location.${key}`, `location.${key} is not accepted.`);
      }
    }
    location = {
      latitude: number(supplied.latitude, "location.latitude", -90, 90),
      longitude: number(supplied.longitude, "location.longitude", -180, 180),
      accuracyMeters: supplied.accuracyMeters === undefined || supplied.accuracyMeters === null
        ? null
        : number(supplied.accuracyMeters, "location.accuracyMeters", 0, 100000),
    };
  }

  return {
    submissionId, reportType, stationName, stationCode, suggestedCode, lines,
    operator, city, country, notes, location, cardFamily,
    cardIdHash: cardIdHash?.toLowerCase() ?? null, appVersion, deviceId, source,
  };
}
