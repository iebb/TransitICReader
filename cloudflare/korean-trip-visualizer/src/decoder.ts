export const RECORD_BYTES = 52;

export type EventKind = "boarding" | "alighting" | "flagged";

export interface DecodedRecord {
  bytes: number[];
  event: EventKind;
  eventRaw: number;
  headerFlags: number;
  tripCounter: number;
  locationCode: string;
  stationToken: string;
  transportModeCode: string;
  systemDecimal: number;
  stationIdCandidate: string | null;
  timestamp: string | null;
  timestampHex: string;
  dateFlags: number;
  timestampLayout: "packed33" | "bcd14" | "operator_opaque" | "alternate_unknown";
  timestampPlausible: boolean | null;
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
}

function hexSlice(bytes: number[], start: number, end: number): string {
  return bytes
    .slice(start, end)
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("")
    .toUpperCase();
}

function uint16(bytes: number[], offset: number): number {
  return bytes[offset] * 256 + bytes[offset + 1];
}

function validTimestamp(
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number,
  second: number,
): string | null {
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59) {
    return null;
  }
  const date = new Date(Date.UTC(year, month - 1, day, hour, minute, second));
  if (
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day
  ) {
    return null;
  }
  return `${year.toString().padStart(4, "0")}-${month
    .toString()
    .padStart(2, "0")}-${day.toString().padStart(2, "0")}T${hour
    .toString()
    .padStart(2, "0")}:${minute.toString().padStart(2, "0")}:${second
    .toString()
    .padStart(2, "0")}`;
}

function operatorFieldProfile(code: number): string {
  if (code === 870) return "mybi_busan_subway";
  if (
    (code >= 600 && code < 619) ||
    (code >= 632 && code < 637) ||
    (code >= 641 && code < 661) ||
    (code >= 711 && code < 714) ||
    (code >= 776 && code < 800) ||
    [887, 936, 940].includes(code) ||
    (code >= 901 && code < 905) ||
    (code >= 913 && code < 917) ||
    (code >= 925 && code < 928)
  ) return "mybi_busan";
  if (
    (code >= 621 && code < 632) ||
    (code >= 637 && code < 641) ||
    (code >= 684 && code < 686) ||
    [729, 888].includes(code) ||
    (code >= 928 && code < 932)
  ) return "mybi_total";
  if (code === 691 || (code >= 770 && code < 776) || code === 871) return "mybi_gwangju";
  return "standard_or_bcd";
}

function decodeTimestamp(bytes: number[], systemDecimal: number): {
  value: string | null;
  flags: number;
  layout: DecodedRecord["timestampLayout"];
} {
  const bcd = hexSlice(bytes, 11, 18);
  if (/^\d{14}$/.test(bcd)) {
    const value = validTimestamp(
      Number(bcd.slice(0, 4)),
      Number(bcd.slice(4, 6)),
      Number(bcd.slice(6, 8)),
      Number(bcd.slice(8, 10)),
      Number(bcd.slice(10, 12)),
      Number(bcd.slice(12, 14)),
    );
    if (value) return { value, flags: 0, layout: "bcd14" };
  }

  if (operatorFieldProfile(systemDecimal).startsWith("mybi_")) {
    return { value: null, flags: 0, layout: "operator_opaque" };
  }

  const rawDate = uint16(bytes, 11);
  const timeWord = uint16(bytes, 13);
  const year = 2000 + (rawDate >>> 9);
  const month = (rawDate >>> 5) & 0x0f;
  const day = rawDate & 0x1f;
  const hour = timeWord >>> 11;
  const minute = (timeWord >>> 5) & 0x3f;
  const second = ((timeWord & 0x1f) << 1) | (bytes[15] >>> 7);

  const value = validTimestamp(year, month, day, hour, minute, second);
  return value
    ? { value, flags: 0, layout: "packed33" }
    : { value: null, flags: 0, layout: "alternate_unknown" };
}

export function decodeRecord(
  rawHex: string,
  collectedAt?: string,
  transportClass?: "B" | "R" | "T" | null,
): DecodedRecord {
  const normalized = rawHex.replace(/\s+/g, "").toUpperCase();
  if (!/^[0-9A-F]+$/.test(normalized) || normalized.length !== RECORD_BYTES * 2) {
    throw new Error(`Expected ${RECORD_BYTES} bytes of hexadecimal data`);
  }

  const bytes = Array.from({ length: RECORD_BYTES }, (_, index) =>
    Number.parseInt(normalized.slice(index * 2, index * 2 + 2), 16),
  );
  const eventRaw = bytes[2];
  const event: EventKind =
    eventRaw === 0 ? "boarding" : eventRaw === 1 ? "alighting" : "flagged";
  const systemDecimal = uint16(bytes, 9);
  const profile = operatorFieldProfile(systemDecimal);
  const timestamp = decodeTimestamp(bytes, systemDecimal);
  const fare22 = uint16(bytes, 22);
  const fare36 = uint16(bytes, 36);
  const fare40 = uint16(bytes, 40);
  const fare50 = uint16(bytes, 50);
  const fareCandidates: Array<[DecodedRecord["fareLayout"], number]> = profile.startsWith("mybi_")
    ? [["base40", fare40], ["regional36", fare36], ["primary22", fare22]]
    : [["primary22", fare22], ["base40", fare40], ["regional36", fare36]];
  const selectedFareItem = fareCandidates.find(([, value]) => value > 0 && value <= 10_000);
  const selectedFare = selectedFareItem?.[1] ?? null;
  const stationToken = hexSlice(bytes, 5, 9);
  const timestampPlausible = (() => {
    if (!timestamp.value) return false;
    if (!collectedAt) return null;
    const collectedNormalized = /(?:Z|[+-]\d{2}:\d{2})$/.test(collectedAt)
      ? collectedAt
      : `${collectedAt.replace(" ", "T")}Z`;
    const tripInstant = Date.parse(`${timestamp.value}+09:00`);
    const collectedInstant = Date.parse(collectedNormalized);
    return Number.isFinite(tripInstant) && Number.isFinite(collectedInstant)
      ? tripInstant <= collectedInstant
      : false;
  })();

  return {
    bytes,
    event,
    eventRaw,
    headerFlags: eventRaw & 0xfe,
    tripCounter: bytes[4],
    stationToken,
    transportModeCode: hexSlice(bytes, 9, 11),
    systemDecimal,
    stationIdCandidate:
      transportClass === "B" && /^\d{7}0$/.test(stationToken)
        ? stationToken.slice(0, -1)
        : null,
    locationCode: hexSlice(bytes, 5, 11),
    timestamp: timestamp.value,
    timestampHex: hexSlice(bytes, 11, 18),
    dateFlags: timestamp.flags,
    timestampLayout: timestamp.layout,
    timestampPlausible,
    distanceMeters: uint16(bytes, 19),
    legacyDistanceMeters: bytes[18] * 65_536 + uint16(bytes, 19),
    fare22,
    fare36,
    fare40,
    fare50,
    selectedFare,
    fareLayout: selectedFareItem?.[0] ?? "unresolved",
    operatorFieldProfile: profile,
    operatorClockA: profile.startsWith("mybi_")
      ? bytes[11] * 65_536 + bytes[12] * 256 + bytes[13]
      : null,
    operatorClockB: profile.startsWith("mybi_")
      ? bytes[14] * 65_536 + bytes[15] * 256 + bytes[16]
      : null,
    operatorClockFlag: profile.startsWith("mybi_") ? bytes[17] : null,
  };
}

export const BYTE_FIELDS = [
  { start: 0, end: 1, label: "Header", confidence: "confirmed" },
  { start: 2, end: 2, label: "Event", confidence: "confirmed" },
  { start: 3, end: 3, label: "Flags?", confidence: "open" },
  { start: 4, end: 4, label: "Trip counter", confidence: "inferred" },
  { start: 5, end: 8, label: "Station token", confidence: "confirmed" },
  { start: 9, end: 10, label: "KOTRIS mode match", confidence: "inferred" },
  { start: 11, end: 17, label: "Clock / operator counters", confidence: "confirmed" },
  { start: 18, end: 18, label: "Unknown", confidence: "open" },
  { start: 19, end: 20, label: "Distance", confidence: "confirmed" },
  { start: 21, end: 21, label: "Unknown", confidence: "open" },
  { start: 22, end: 23, label: "Fare A", confidence: "inferred" },
  { start: 24, end: 27, label: "Terminal ref?", confidence: "inferred" },
  { start: 28, end: 35, label: "Trip metadata", confidence: "open" },
  { start: 36, end: 37, label: "Fare B", confidence: "inferred" },
  { start: 38, end: 39, label: "Unknown", confidence: "open" },
  { start: 40, end: 41, label: "Base fare", confidence: "inferred" },
  { start: 42, end: 49, label: "Settlement", confidence: "open" },
  { start: 50, end: 51, label: "Surcharge?", confidence: "inferred" },
] as const;

export function fieldForByte(offset: number) {
  return BYTE_FIELDS.find((field) => offset >= field.start && offset <= field.end);
}
