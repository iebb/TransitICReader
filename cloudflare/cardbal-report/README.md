# CardBal station requests

CardBal submits missing-station reports and station-code corrections from the iOS app. The public site at <https://cardbal.ieb.app/> lists submitted station details and approximate location pins. It has no submission form and does not fetch reports from a public read API.

## API

`POST https://cardbal.ieb.app/api/v1/station-reports` accepts JSON from the app. Required fields are `submissionId` (UUID), `reportType` (`missing` or `correction`), `stationName`, `cardIdHash` (SHA-256 hex of the saved card ID), `appVersion`, `deviceId` (app-specific UUID), and `source` (`ios` or `android`). Corrections also require `stationCode`. Optional fields are `stationCode` for missing reports, `suggestedCode` for corrections, `lines`, `operator`, `city`, `country`, `notes`, `cardFamily`, and `location` (`latitude`, `longitude`, optional `accuracyMeters`). The server returns `201` and a submission ID, or `200` with `duplicate: true` for an already submitted ID. Input limits and ranges are enforced in [`src/validation.ts`](src/validation.ts). The API is IP rate limited at the public edge; `source` describes the client and is not proof of app origin.

`GET` on the station-report API returns `405 Method Not Allowed`. The website is rendered directly by the Worker from D1 at `/`, with ordinary links for the `all`, `missing`, and `correction` filters and 20 reports per page. Rejected reports are excluded. HTML contains station names, codes, lines, operator, city, country, review status, date, and optional coordinates rounded to three decimal places. It never contains card ID hashes, device IDs, app versions, card family, notes, exact coordinates, accuracy, or submission IDs. Public fields are selected explicitly in [`src/backend.ts`](src/backend.ts) and escaped in [`src/public-report.ts`](src/public-report.ts).

`GET /api/health` returns service health. API and rendered listing responses use `Cache-Control: no-store`.

## Cloudflare layout

The backend Worker and D1 database run in the **Kitta Labs** Cloudflare account on `cardbal.kitta.co`. A small edge Worker in the `ieb.app` account serves the requested public hostname `cardbal.ieb.app` and forwards requests to the backend. Both Workers use the same `PROXY_TOKEN` secret; the backend rejects requests without it. Keep that secret in Cloudflare, outside Git. The `ieb.app` Worker rate limits submissions before forwarding them. D1 migration files are in [`migrations/`](migrations/).

## Development and deployment

Use Node.js and run `npm ci`, `npm run build`, `npm run typecheck`, and `npm test` in this directory. The build copies Leaflet's distribution files into an ignored `public/vendor/` directory.

Use `CLOUDFLARE_ACCOUNT_ID=58c982b69079141dd49d99076dd845b1 npm run deploy:backend` for the Kitta Worker, and `CLOUDFLARE_ACCOUNT_ID=599ee1cd6c4d3dc453d290c4c0477e76 npm run deploy:edge` for the public hostname Worker. Apply D1 migrations with `wrangler d1 migrations apply cardbal-station-reports -c wrangler.backend.jsonc --remote` under the Kitta account before deploying schema changes. Configure the same `PROXY_TOKEN` as a Cloudflare secret on both Workers. Do not put it in a `wrangler` config file or commit local `.dev.vars` files.

The iOS submission UI is [`../../CardBal/Views/StationReportView.swift`](../../CardBal/Views/StationReportView.swift). A card's saved ID is SHA-256 hashed on device before upload; a per-install UUID is used for the device field. No trip history or raw card ID is sent. Only an explicitly chosen map pin or user-requested current location is uploaded.
