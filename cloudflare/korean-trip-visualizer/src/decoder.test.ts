import { describe, expect, it } from "vitest";
import { decodeRecord, RECORD_BYTES } from "./decoder";

const SEOUL_STATION_IN =
  "01320000020000971000CF30EB72A7800000000000000578000001DD010100000000008CC0000000057800000C03057800000000";
const YEONGDEUNGPO_OUT =
  "01320100020000133000CA30EB75F58000000022C4000578000000180101000000000000C0000000057800000B04057800000000";
const HONGIK_OUT =
  "01320100030000048000C930EB85DD800000001C200005780000006F0101000000000000C0000000057800000B04057800000000";
const JEJU_BCD_IN =
  "01320000000001727103E32026020116454901007300047E0B7954CE0000000000000000C0000000000000000000000000001932";

describe("decodeRecord", () => {
  it("decodes a confirmed standard subway boarding without dropping location bytes", () => {
    const record = decodeRecord(SEOUL_STATION_IN);

    expect(record.bytes).toHaveLength(RECORD_BYTES);
    expect(record.event).toBe("boarding");
    expect(record.tripCounter).toBe(2);
    expect(record.stationToken).toBe("00009710");
    expect(record.transportModeCode).toBe("00CF");
    expect(record.systemDecimal).toBe(207);
    expect(record.locationCode).toBe("0000971000CF");
    // Byte 15's high bit is the low seconds bit in the 33-bit packed clock.
    expect(record.timestamp).toBe("2024-07-11T14:21:15");
    expect(record.timestampLayout).toBe("packed33");
    expect(record.timestampPlausible).toBeNull();
    expect(record.distanceMeters).toBe(0);
    expect(record.fare22).toBe(1400);
  });

  it("uses bytes 19-20 for the confirmed alighting distance", () => {
    const record = decodeRecord(YEONGDEUNGPO_OUT);

    expect(record.event).toBe("alighting");
    expect(record.locationCode).toBe("0000133000CA");
    expect(record.distanceMeters).toBe(8_900);
    expect(record.legacyDistanceMeters).toBe(8_900);
  });

  it("keeps byte 08 inside the station candidate", () => {
    const record = decodeRecord(HONGIK_OUT);

    expect(record.bytes[8]).toBe(0x80);
    expect(record.stationToken).toBe("00000480");
    expect(record.locationCode).toBe("0000048000C9");
    expect(record.stationIdCandidate).toBeNull();
  });

  it("only derives a settlement-stop candidate when KOTRIS classifies the mode as bus", () => {
    const bus = decodeRecord(
      "013200000685022300007330ED8DB90000000000000005DC003A9E4B0101000000000096C000000005DC0000000005DC00000000",
      undefined,
      "B",
    );

    expect(bus.stationIdCandidate).toBe("8502230");
    expect(decodeRecord(bus.bytes.map((byte) => byte.toString(16).padStart(2, "0")).join(""), undefined, "R").stationIdCandidate).toBeNull();
  });

  it("prefers a strict seven-byte BCD timestamp over an accidental packed parse", () => {
    const record = decodeRecord(JEJU_BCD_IN);

    expect(record.timestampHex).toBe("20260201164549");
    expect(record.timestamp).toBe("2026-02-01T16:45:49");
    expect(record.timestampLayout).toBe("bcd14");
    expect(record.transportModeCode).toBe("03E3");
    expect(decodeRecord(JEJU_BCD_IN, "2026-01-01T00:00:00Z").timestampPlausible).toBe(false);
    expect(decodeRecord(JEJU_BCD_IN, "2026-05-03T14:35:57Z").timestampPlausible).toBe(true);
  });

  it("labels a selected byte-40 fare as a base-fare layout", () => {
    const byte40Fare = `${SEOUL_STATION_IN.slice(0, 44)}0000${SEOUL_STATION_IN.slice(48)}`;
    const record = decodeRecord(byte40Fare);

    expect(record.fare22).toBe(0);
    expect(record.selectedFare).toBe(1400);
    expect(record.fareLayout).toBe("base40");
  });

  it("keeps Mybi operator counters opaque and prefers its byte-40 base fare", () => {
    const busan = decodeRecord(
      "01320100810013CE0003669ADBB69ADBE90A1000000071002C1B0011301200000000000000C8B000064000000000000000000000",
    );

    expect(busan.timestamp).toBeNull();
    expect(busan.timestampLayout).toBe("operator_opaque");
    expect(busan.operatorFieldProfile).toBe("mybi_busan_subway");
    expect(busan.operatorClockA).toBe(0x9ADBB6);
    expect(busan.operatorClockB).toBe(0x9ADBE9);
    expect(busan.operatorClockFlag).toBe(0x0A);
    expect(busan.selectedFare).toBe(1600);
    expect(busan.fareLayout).toBe("base40");
  });

  it("does not coerce unknown event values into boarding", () => {
    const flagged = `${SEOUL_STATION_IN.slice(0, 4)}02${SEOUL_STATION_IN.slice(6)}`;
    const record = decodeRecord(flagged);

    expect(record.event).toBe("flagged");
    expect(record.eventRaw).toBe(2);
    expect(record.headerFlags).toBe(2);
  });

  it("rejects malformed records", () => {
    expect(() => decodeRecord("0132")).toThrow(`Expected ${RECORD_BYTES} bytes`);
    expect(() => decodeRecord("GG".repeat(RECORD_BYTES))).toThrow(`Expected ${RECORD_BYTES} bytes`);
  });
});
