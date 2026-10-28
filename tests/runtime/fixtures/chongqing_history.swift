// Entirely invented SFI 18/1E regression records. Dates, times, terminal IDs,
// fares, balances and station choices are test data, not a user's card history.
// Public Chongqing station keys exercise normal station-name resolution.
func testChongqingHistory() throws {
    let tu = TUnionDecoder.applicationAID, cu = CityUnionDecoder.applicationAID
    let events: [(date: String, ledger: String, gate: String, station: String,
                  kind: UInt8, cents: UInt32, balance: UInt32)] = [
        ("20200203094010", "990000000001", "8800000000000001", "0904", 4, 0, 4250),
        ("20200203093005", "990000000001", "8800000000000001", "0904", 3, 0, 4250),
        ("20200203082535", "990000000002", "8800000000000002", "0905", 4, 250, 4250),
        ("20200203081020", "990000000001", "8800000000000003", "0904", 3, 0, 4500),
    ]
    func bytes(_ number: UInt32) -> Data {
        withUnsafeBytes(of: number.bigEndian) { Data($0) }
    }
    var ledger: [TransitApplicationRecord] = [], travel: [TransitApplicationRecord] = []
    for (index, event) in events.enumerated() {
        var purchase = Data(repeating: 0, count: 23)
        purchase[1] = UInt8(index + 1); purchase[9] = 0x09
        purchase.replaceSubrange(5..<9, with: bytes(event.cents))
        purchase.replaceSubrange(10..<16, with: Data(hexString: event.ledger))
        purchase.replaceSubrange(16..<23, with: Data(hexString: event.date))
        ledger.append(record(purchase, index: index + 1))
        var trip = Data(repeating: 0, count: 48)
        trip[0] = event.kind; trip[9] = 1
        trip.replaceSubrange(1..<9, with: Data(hexString: event.gate))
        trip.replaceSubrange(10..<17, with: Data(hexString: event.station + "0000000000"))
        trip.replaceSubrange(17..<21, with: bytes(event.cents))
        trip.replaceSubrange(21..<25, with: bytes(event.balance))
        trip.replaceSubrange(25..<32, with: Data(hexString: event.date))
        trip.replaceSubrange(32..<34, with: Data(hexString: "6900"))
        travel.append(record(trip, sfi: 0x1E, index: index + 1, kind: .transit))
    }
    let scanned = snapshot(tu, serial: "CHONGQING-TEST", balance: "CNY 42.50", records: ledger + travel)
    let app = scanned.applications![0]
    func checkMerged(_ apps: [TransitApplication], evidenceCount: Int = 2) {
        for kind in [RawHistoryKind.transactions, .transit] {
            let rows = TransitApplicationHistory.decode(apps, kind: kind)
            check(rows.count == 4, "Chongqing payment and gate records still shown twice")
            check(rows.map(\.type) == ["Exit", "Entry", "Exit", "Entry"], "Entry/exit direction or order lost")
            check(rows.map(\.amount) == [0, 0, Decimal(string: "-2.50")!, 0], "Zero fare or paid fare changed")
            check(rows.map(\.balanceAfter) == [Decimal(string: "42.50"), Decimal(string: "42.50"), Decimal(string: "42.50"), Decimal(string: "45.00")], "Travel balances lost")
            check(rows[0].exitStation == "沙坪坝" && rows[1].entryStation == "沙坪坝"
                  && rows[2].exitStation == "小龙坎" && rows[3].entryStation == "沙坪坝", "Station enrichment lost")
            check(rows.allSatisfy { $0.sourceRecordIDs?.count == evidenceCount }, "Merged source records lost")
        }
    }
    check(scanned.transitHistory.count == 4, "Scan still shows duplicate Chongqing records")
    checkMerged([app])
    check(app.records == ledger + travel, "Correlation modified raw history")
    let saved = SavedCardRecord(snapshot: scanned)
    let restored = try JSONDecoder().decode(SavedCardRecord.self, from: JSONEncoder().encode(saved))
    checkMerged(restored.applicationSnapshots)
    var legacy = saved; legacy.applications = nil
    checkMerged(legacy.applicationSnapshots)

    // Mirrored CU/TU payments may keep CU as the representative. The matching
    // TU source must still be recognized after that first deduplication.
    let local = snapshot(cu, serial: "CHONGQING-TEST-CU", records: ledger).applications![0]
    checkMerged([local, app], evidenceCount: 3)
    checkMerged([app, local], evidenceCount: 3)
    var travelOnly = app; travelOnly.records = travel
    check(TransitApplicationHistory.decode([local, travelOnly], kind: .transit).count == 8,
          "Coincident timestamps from separate applications were guessed")

    func checkUnmatched(_ records: [TransitApplicationRecord], _ count: Int, _ message: String) {
        var candidate = app; candidate.records = records
        check(TransitApplicationHistory.decode([candidate], kind: .transit).count == count, message)
    }
    var wrongFare = travel[2].data; wrongFare[20] = 99
    checkUnmatched([ledger[2], record(wrongFare, sfi: 0x1E, kind: .transit)], 2, "Conflicting fares merged")
    var later = travel[0].data; later[31] = 0x11
    checkUnmatched([ledger[0], record(later, sfi: 0x1E, kind: .transit)], 2, "Different timestamps merged")
    var repeated = ledger[0].data; repeated[1] = 99
    checkUnmatched([ledger[0], record(repeated, index: 2), travel[0]], 3, "Ambiguous ledger match guessed")
    var otherGate = travel[0].data; otherGate[0] = 3
    checkUnmatched([ledger[0], travel[0], record(otherGate, sfi: 0x1E, index: 2, kind: .transit)], 3,
                   "Ambiguous entry/exit match guessed")
    var invalidPurchase = ledger[0].data, invalidTrip = travel[0].data
    invalidPurchase.replaceSubrange(16..<23, with: Data(repeating: 0, count: 7))
    invalidTrip.replaceSubrange(25..<32, with: Data(repeating: 0, count: 7))
    checkUnmatched([record(invalidPurchase), record(invalidTrip, sfi: 0x1E, kind: .transit)], 2,
                   "Missing timestamps treated as a match")
}
