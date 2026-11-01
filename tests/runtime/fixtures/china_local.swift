// Invented protocol fixtures shared with Android. No personal card captures.
@MainActor func testChineseLocal() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("tests/runtime/fixtures/china_local_synthetic.json"))) as! [String: Any]
    for item in fixture["balances"] as! [[String: Any]] {
        check(ChineseLocalProtocol.balanceMinor(Data(hexString: item["hex"] as! String)) == (item["minor"] as? NSNumber)?.int64Value, "China balance flag/sign/length")
    }
    let histories = fixture["histories"] as! [[String: Any]]
    for item in histories {
        let bytes = Data(hexString: item["hex"] as! String)
        let history = ChineseLocalDecoder.decodeRecord(data: bytes)
        if item["invalid"] as? Bool == true { check(history == nil, "Invalid China record decoded") }
        else {
            check(history != nil && history!.currencyCode == "CNY" && history!.issuerTimeZone == "Asia/Shanghai", "China history currency/timezone")
            check(history!.amountKnown == (item["amount"] as? NSNumber != nil), "Unknown type acquired a fare")
            check(history!.amount == Decimal((item["amount"] as? NSNumber)?.int64Value ?? 0) / 100, "China amount sign/units")
            check(history!.entryStationCode == nil && history!.exitStationCode == nil, "China terminal became a station")
        }
    }
    for item in fixture["cards"] as! [[String: Any]] {
        let card = NFCISO7816Tag(); let aid = item["aid"] as! String
        card.available = [aid]; card.balances = [aid: Data(hexString: "800004D2")]
        card.binaryFiles = [aid: [item["sfi"] as! Int: Data(hexString: item["info"] as! String)]]
        if let serial = item["serialFile"] as? String { card.binaryFiles[aid]![10] = Data(hexString: serial) }
        card.files = [aid: [24: histories.prefix(4).map { Data(hexString: $0["hex"] as! String) }]]
        let snapshot = try await ChineseLocalDecoder.decode(tag: .iso7816(card), scannedAt: Date())
        check(snapshot.cardFamily == item["family"] as! String && snapshot.realSerialNumber == item["serial"] as? String, "China identity/serial")
        check(snapshot.balanceText == "CNY 12.34", "China cash units")
        check(snapshot.rawTransactions.count == 4 && snapshot.rawTransitHistory.isEmpty, "China histories lost or duplicated")
        let saved = try JSONDecoder().decode([TransitApplication].self, from: JSONEncoder().encode(snapshot.applications!))
        check(saved == snapshot.applications && saved[0].records.allSatisfy { $0.sfi == 24 }, "China backup lost source records")
        check(card.commands.allSatisfy { [UInt8(0xA4), 0xB0, 0xB2, 0x5C].contains($0.instructionCode) }, "Unexpected APDU")
        if item["kind"] as? String == "beijing" {
            card.binaryFiles = [:]
            do { _ = try await ChineseLocalDecoder.decode(tag: .iso7816(card), scannedAt: Date()); preconditionFailure("Generic PBOC named Beijing") }
            catch NFCTestError.unsupportedCard { }
        }
        card.failBalances = true
        do { _ = try await ChineseLocalDecoder.decode(tag: .iso7816(card), scannedAt: Date()); preconditionFailure("ID-only China read accepted") }
        catch NFCTestError.unsupportedCard { }
    }
    // Follow both ISO response procedures and keep commands strictly read-only.
    var correction = false; var continuation = false
    let shenzhen = (fixture["cards"] as! [[String: Any]])[0]
    let result = await ChineseLocalProtocol.read { command in
        if command[1] == 0xA4 {
            let name = Data(command.dropFirst(5).dropLast()).hexString
            return (Data(), name == shenzhen["aid"] as! String ? 0x90 : 0x6A, name == shenzhen["aid"] as! String ? 0 : 0x82)
        }
        if command[1] == 0x5C {
            if !correction { correction = true; return (Data(), 0x6C, 4) }
            continuation = true; return (Data([0, 0]), 0x61, 2)
        }
        if command[1] == 0xC0 && continuation { return (Data([4, 0xD2]), 0x90, 0) }
        if command[1] == 0xB0 { return (Data(hexString: shenzhen["info"] as! String), 0x90, 0) }
        return (Data(), 0x6A, 0x83)
    }
    check(result?.balanceMinor == 1234 && correction && continuation, "6C/61 balance response")
    let beijing = (fixture["cards"] as! [[String: Any]])[2]
    var selectedFile = ""
    let fallback = await ChineseLocalProtocol.read { command in
        if command[1] == 0xA4 {
            let name = Data(command.dropFirst(5).dropLast()).hexString
            if command[2] == 4 && name == "4F43" { selectedFile = "app"; return (Data(), 0x90, 0) }
            if command[2] == 0 && name == "1001" { selectedFile = "purse"; return (Data(), 0x90, 0) }
            if command[2] == 0 && name == "3F00" { selectedFile = "mf"; return (Data(), 0x90, 0) }
            if command[2] == 8 && name == "10010018" { selectedFile = "log"; return (Data(), 0x90, 0) }
        }
        if command[1] == 0x5C && selectedFile == "purse" { return (Data(hexString: "000004D2"), 0x90, 0) }
        if command[1] == 0xB0 && command[2] == 0x84 && selectedFile == "mf" { return (Data(hexString: beijing["info"] as! String), 0x90, 0) }
        if command[1] == 0xB2 && command[2] == 1 && command[3] == 4 && selectedFile == "log" { return (Data(hexString: histories[0]["hex"] as! String), 0x90, 0) }
        return (Data(), 0x6A, 0x82)
    }
    check(fallback?.serial == beijing["serial"] as? String && fallback?.balanceMinor == 1234 && fallback?.records.count == 1, "Beijing MF/purse DF/log path fallback")
    let invalidStatus = await ChineseLocalProtocol.read { _ in (Data(), 0x90, 1) }
    check(invalidStatus == nil, "Non-9000 success accepted")
    print("PASS: China local balances, histories, identities, persistence and APDU procedures")
}
