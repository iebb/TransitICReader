import assert from "node:assert/strict";
import test from "node:test";
import { parseStationReport, ValidationError } from "./validation.ts";

const base = {
  submissionId: "f4b9eac2-9a3f-4db8-b3b6-b84af90cd3e4",
  reportType: "missing",
  stationName: "Tokyo",
  cardIdHash: "a".repeat(64),
  appVersion: "2.2.0",
  deviceId: "0bb685eb-8c0f-4d3d-b2d5-e4748e984ab1",
  source: "ios",
};

test("accepts a missing station report with only a name and app identifiers", () => {
  const report = parseStationReport(base);
  assert.equal(report.stationName, "Tokyo");
  assert.equal(report.stationCode, null);
  assert.equal(report.location, null);
});

test("accepts a code correction with manually selected location and context", () => {
  const report = parseStationReport({
    ...base,
    reportType: "correction",
    stationName: "新宿",
    stationCode: "0A1B",
    suggestedCode: "0A1C",
    lines: "Yamanote, Chuo",
    operator: "JR East",
    city: "Tokyo",
    location: { latitude: 35.6896, longitude: 139.7006 },
  });
  assert.equal(report.location?.latitude, 35.6896);
  assert.equal(report.location?.accuracyMeters, null);
  assert.equal(report.suggestedCode, "0A1C");
});

test("requires code for a correction", () => {
  assert.throws(() => parseStationReport({ ...base, reportType: "correction" }),
    (error) => error instanceof ValidationError && error.field === "stationCode");
});

test("rejects malformed location and unknown fields", () => {
  assert.throws(() => parseStationReport({ ...base, location: { latitude: 100, longitude: 10 } }),
    (error) => error instanceof ValidationError && error.field === "location.latitude");
  assert.throws(() => parseStationReport({ ...base, rawCardId: "1234" }),
    (error) => error instanceof ValidationError && error.field === "rawCardId");
});

test("iOS card reports require a SHA-256 card hash", () => {
  const ios = { ...base, cardIdHash: null };
  assert.throws(() => parseStationReport(ios),
    (error) => error instanceof ValidationError && error.field === "cardIdHash");
  assert.equal(parseStationReport({ ...ios, cardIdHash: "a".repeat(64) }).cardIdHash, "a".repeat(64));
});

test("rejects browser submissions", () => {
  assert.throws(() => parseStationReport({ ...base, source: "web" }),
    (error) => error instanceof ValidationError && error.field === "source");
});
