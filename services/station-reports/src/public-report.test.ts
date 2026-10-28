import assert from "node:assert/strict";
import test from "node:test";
import { renderPublicPage, toPublicReport } from "./public-report.ts";

const row = {
  id: "8c642645-9ce7-431d-b5fd-3f922ed3ce29",
  created_at: "2026-09-26T00:00:00.000Z",
  report_type: "correction",
  station_name: "<script>alert('bad')</script>",
  station_code: "A123",
  suggested_code: "A124",
  lines: "Yamanote",
  operator: "JR East",
  city: "Tokyo",
  country: "Japan",
  latitude: 35.69,
  longitude: 139.7,
  status: "pending",
  card_id_hash: "a".repeat(64),
  device_id: "private-device-id",
  app_version: "2.2.0",
  notes: "private note",
};

test("server-rendered list escapes station text and omits identifiers and notes", () => {
  const template = "<!-- REQUEST_COUNT --><!-- REQUEST_FILTERS --><!-- REQUEST_LIST --><!-- REQUEST_PAGINATION -->";
  const page = renderPublicPage(template, [row], "all", 1, false);
  assert.match(page, /&lt;script&gt;/);
  assert.doesNotMatch(page, /<script>|private-device-id|private note|a{64}|8c642645-9ce7/);
  assert.match(page, /data-lat="35.69" data-lon="139.7"/);
  assert.equal("id" in toPublicReport(row), false);
  assert.equal("cardIdHash" in toPublicReport(row), false);
  assert.equal("deviceId" in toPublicReport(row), false);
});

test("filters and pagination are ordinary page links", () => {
  const template = "<!-- REQUEST_COUNT --><!-- REQUEST_FILTERS --><!-- REQUEST_LIST --><!-- REQUEST_PAGINATION -->";
  const page = renderPublicPage(template, [row], "correction", 2, true);
  assert.match(page, /href="\/\?type=correction&amp;page=1"/);
  assert.match(page, /href="\/\?type=correction&amp;page=3"/);
  assert.doesNotMatch(page, /\/api\/v1\/station-reports/);
});
