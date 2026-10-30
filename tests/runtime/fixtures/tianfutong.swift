// Invented card number, timestamps and terminals. No personal card captures.
@MainActor func testTianfuTong() async throws {
    let aid = TianfuTongDecoder.applicationAID
    let monthly = TianfuTongDecoder.monthlyAID
    let info = Data(hexString: "544661001000000003001234560001234567890120260101203601010102000000")
    check(info.count == 33, "Tianfu fixture length")
    let metadata = TianfuTongDecoder.parseCardInfo(info)!
    check(metadata.serial == "12345600012345678901", "Tianfu BCD serial/leading digits")
    check(metadata.issueDate == "2026-01-01" && metadata.expiryDate == "2036-01-01", "Tianfu validity offsets")
    var invalid = info; invalid[0] = 0x86
    check(TianfuTongDecoder.parseCardInfo(invalid) == nil, "Unrelated issuer accepted")
    check(TianfuTongDecoder.parseCardInfo(Data(info.prefix(32))) == nil, "Truncated info accepted")
    invalid = info; invalid[10] = 0xFA; invalid[22] = 0x13
    check(TianfuTongDecoder.parseCardInfo(invalid)?.serial == nil && TianfuTongDecoder.parseCardInfo(invalid)?.issueDate == nil, "Invalid BCD/date was fabricated")
    check(TianfuTongDecoder.balanceMinor(Data(hexString: "000001D6")) == 470, "Tianfu balance endian/units")
    check(TianfuTongDecoder.balanceMinor(Data(repeating: 0, count: 4)) == 0, "Zero purse became unavailable")
    check(TianfuTongDecoder.balanceMinor(Data(hexString: "FFFFFFFF")) == nil, "Sentinel became a balance")
    check(TianfuTongDecoder.balanceMinor(Data(hexString: "000001")) == nil, "Short balance accepted")

    let purchase = Data(hexString: "00090000000000012C0900010099000120261020093000")
    var entry = purchase; entry[1] = 8; entry[7] = 0; entry[8] = 0
    var topup = purchase; topup[1] = 1; topup[8] = 0xF4; topup[9] = 2
    var table = Data(repeating: 0, count: 48)
    table.replaceSubrange(36..<40, with: Data(hexString: "20260014"))
    let credits = TianfuTongDecoder.monthlyCredits(table)
    check(credits.count == 1 && credits[0].month == "2026-10" && credits[0].rides == 20, "Monthly credits are rides, not fen")
    check(TianfuTongDecoder.monthlyCredits(Data(repeating: 0, count: 48)).isEmpty, "Empty monthly table fabricated rides")
    check(TianfuTongDecoder.monthlyCredits(Data(repeating: 0xFF, count: 48)).isEmpty, "Invalid monthly years accepted")
    check(TianfuTongDecoder.monthlyCredits(Data(table.prefix(47))).isEmpty, "Truncated monthly table accepted")
    let debit = TianfuTongDecoder.decodeRecord(data: purchase, index: 0)!
    check(debit.amount == -3 && debit.currencyCode == "CNY" && debit.issuerTimeZone == "Asia/Shanghai", "Cash history units/timezone/sign")
    check(debit.location == nil && debit.entryStation == nil && debit.exitStation == nil, "Local terminal used T-Union station inference")
    let zero = TianfuTongDecoder.decodeRecord(data: entry, index: 1)!
    check(zero.amount == 0 && zero.category == .payment, "Zero-fare purchase was lost or guessed to be entry")
    check(TianfuTongDecoder.decodeRecord(data: topup, index: 0)?.category == .topUp, "SFI 09 top-up type lost")
    check(TianfuTongDecoder.decodeRecord(data: topup, index: 0)?.amount == 5, "Top-up amount/sign")
    invalid = purchase; invalid[9] = 0x12
    check(TianfuTongDecoder.decodeRecord(data: invalid, index: 0)?.amountKnown == false, "Unknown type became a monetary debit")
    invalid = purchase; invalid[16] = 0xFA
    check(TianfuTongDecoder.decodeRecord(data: invalid, index: 0)?.date == nil, "Invalid timestamp fabricated a date")
    check(TianfuTongDecoder.decodeRecord(data: Data(purchase.prefix(22)), index: 0) == nil, "Truncated history accepted")
    check(TianfuTongDecoder.decodeRecord(data: Data(repeating: 0, count: 23), index: 0) == nil, "Empty circular slot became history")

    let card = NFCISO7816Tag()
    card.available = [aid, monthly]; card.info = [aid: info, monthly: info]
    card.binaryFiles = [monthly: [0x1A: table]]
    card.balances = [aid: Data(hexString: "000001D6"), monthly: Data(hexString: "00000014")]
    card.files = [aid: [0x18: [purchase, entry, Data(repeating: 0, count: 23)], 0x09: [topup]]]
    let snapshot = try await TianfuTongDecoder.decode(tag: .iso7816(card), scannedAt: Date())
    check(snapshot.cardFamily == "天府通" && snapshot.balanceText == "CNY 4.7", "Cash application or balance selected incorrectly")
    check(snapshot.selectedAID == aid && card.selected == aid, "Monthly application replaced cash purse")
    check(snapshot.applications?.count == 1 && snapshot.applications?[0].records.count == 3, "On-card records missing or empty slots included")
    check(snapshot.applications?[0].records.filter { $0.sfi == 9 }.count == 1, "Top-up SFI provenance lost")
    check(snapshot.resultFields.contains { $0.title == "Monthly Rides (2026-10)" && $0.value == "20" }, "Monthly allocation omitted")
    check(snapshot.rawTransitHistory.isEmpty, "PBOC records pretended to be T-Union travel")
    check(snapshot.transactions.count == 3 && snapshot.transactions.filter { $0.amount > 0 }.count == 1, "Application history lost credit/debit distinction")
    check(card.commands.allSatisfy { [UInt8(0xA4), 0xB0, 0xB2, 0x5C].contains($0.instructionCode) }, "Reader sent a non-read command")
    let reader = NFCTransitReader(); reader.startScanning()
    reader.tagReaderSession(reader.session!, didDetect: [.iso7816(card)])
    try await Task.sleep(for: .milliseconds(30))
    check(reader.latestSnapshot?.cardFamily == "天府通", "Native reader did not dispatch Tianfu Tong")
    var otherInfo = info; otherInfo[19] = 0x02
    card.info[monthly] = otherInfo
    let mismatched = try await TianfuTongDecoder.decode(tag: .iso7816(card), scannedAt: Date())
    check(!mismatched.resultFields.contains { $0.title.hasPrefix("Monthly Rides") }, "Different monthly card mixed with cash card")
    card.info[monthly] = info
    let persisted = try JSONDecoder().decode([TransitApplication].self, from: JSONEncoder().encode(snapshot.applications!))
    check(persisted == snapshot.applications, "Tianfu history/provenance failed persistence")
    card.available = [aid]; card.failBalances = true
    let partial = try await TianfuTongDecoder.decode(tag: .iso7816(card), scannedAt: Date())
    check(partial.balanceText == nil && partial.transactions.count == 3, "Unavailable purse became zero or history was lost")
    let merged = TransitApplication.merge(existing: snapshot.applications!, incoming: partial.applications!)
    check(merged.count == 1 && merged[0].balanceText == snapshot.balanceText, "Partial rescan lost cash balance")
    card.available = []
    let unsupported = await TianfuTongDecoder.canDecode(tag: .iso7816(card))
    check(!unsupported, "Unrelated card accepted")
    card.available = [aid]; card.info[aid] = Data(repeating: 0, count: 33)
    do { _ = try await TianfuTongDecoder.decode(tag: .iso7816(card), scannedAt: Date()); preconditionFailure("Wrong issuer accepted") }
    catch NFCTestError.unsupportedCard { }
    print("PASS: Tianfu Tong cash, top-ups, monthly rides, strict parsing, persistence and read-only APDUs")
}
