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
    try await testChineseLocalBesideCityUnion(fixture: fixture, histories: histories)
    try await testLingnanPass(fixture: fixture, histories: histories)
    print("PASS: China local balances, histories, identities, persistence and APDU procedures")
}

/// City Union / T-Union are read first (as in 2.5.2); a local application is added afterwards.
@MainActor func testChineseLocalBesideCityUnion(fixture: [String: Any], histories: [[String: Any]]) async throws {
    let cu = CityUnionDecoder.applicationAID, tu = TUnionDecoder.applicationAID
    let cards = fixture["cards"] as! [[String: Any]]
    let localAIDs = Set(cards.map { $0["aid"] as! String } + ["50424F43"])
    // A City Union-only card on Core NFC: only the Info.plist names are tried, and nothing else is accepted.
    var names: [String] = []
    let none = await ChineseLocalProtocol.read(kinds: [.shenzhen, .wuhan]) { command in
        guard command[1] == 0xA4, command[2] == 4 else { return (Data(), 0x6A, 0x82) }
        let name = Data(command.dropFirst(5).prefix(Int(command[4]))).hexString
        names.append(name)
        return (Data(), name == cu ? 0x90 : 0x6A, name == cu ? 0 : 0x82)
    }
    check(none == nil && names == ["5041592E535A54", "4150312E5748435443"], "City Union-only card read as local")
    check(!names.contains("4F43") && !names.contains("50424F43"), "Core NFC selected an unlisted Beijing name")

    // Built-in reads never select OC/PBOC, so a Beijing card is for external readers only.
    let beijing = cards[2], beijingAID = beijing["aid"] as! String
    let builtIn = NFCISO7816Tag(); builtIn.selectsUnlistedApplications = false
    builtIn.available = [beijingAID]; builtIn.balances = [beijingAID: Data(hexString: "800004D2")]
    builtIn.binaryFiles = [beijingAID: [beijing["sfi"] as! Int: Data(hexString: beijing["info"] as! String)]]
    do { _ = try await ChineseLocalDecoder.decode(tag: .iso7816(builtIn), scannedAt: Date()); preconditionFailure("Core NFC read Beijing") }
    catch NFCTestError.unsupportedCard { }
    check(!builtIn.selectedAIDs.contains("4F43") && !builtIn.selectedAIDs.contains("50424F43"), "Core NFC selected an unlisted Beijing name")

    var infoCU = Data(repeating: 0, count: 30); infoCU.replaceSubrange(2..<4, with: Data(hexString: "2000")); infoCU[19] = 1
    var infoTU = infoCU; infoTU.replaceSubrange(2..<4, with: Data(hexString: "2900"))
    infoTU.replaceSubrange(10..<20, with: Data(hexString: "03100000000000000001"))

    // (a) City Union only: read by the City Union reader; the local reader afterwards changes nothing.
    let cityUnion = NFCISO7816Tag(); cityUnion.selectsUnlistedApplications = false
    cityUnion.available = [cu]; cityUnion.info = [cu: infoCU]
    let primary = try await ChineseTransitDecoder.decode(tag: .iso7816(cityUnion), scannedAt: Date())
    check(primary.applications?.count == 1 && primary.applications?[0].isCityUnion == true, "City Union-only card not read")
    check(!cityUnion.selectedAIDs.contains(where: { localAIDs.contains($0) }), "Local SELECT before the City Union read")
    let readCount = cityUnion.selectedAIDs.count
    let kept = await ChineseLocalDecoder.addingLocalApplication(to: primary, tag: .iso7816(cityUnion))
    check(kept.applications == primary.applications && kept.balanceText == primary.balanceText
          && kept.selectedAID == cu && kept.resultFields.map(\.title) == primary.resultFields.map(\.title), "Local reader changed a City Union result")
    check(Array(cityUnion.selectedAIDs.dropFirst(readCount)) == ["5041592E535A54", "4150312E5748435443", "5041592E41505059", "5041592E5449434C"],
          "Unexpected local SELECTs on Core NFC")

    // (b) Shenzhen Tong beside City Union and T-Union: all three views, T-Union stays primary.
    let shenzhen = cards[0], szt = shenzhen["aid"] as! String
    let dual = NFCISO7816Tag(); dual.selectsUnlistedApplications = false
    dual.available = [cu, tu, szt]; dual.info = [cu: infoCU, tu: infoTU]
    dual.balances = [szt: Data(hexString: "800004D2")]
    dual.binaryFiles = [szt: [shenzhen["sfi"] as! Int: Data(hexString: shenzhen["info"] as! String)]]
    dual.files = [szt: [24: histories.prefix(2).map { Data(hexString: $0["hex"] as! String) }]]
    let mainland = try await ChineseTransitDecoder.decode(tag: .iso7816(dual), scannedAt: Date())
    let both = await ChineseLocalDecoder.addingLocalApplication(to: mainland, tag: .iso7816(dual))
    let apps = both.applications ?? []
    check(apps.count == 3 && apps.filter(\.isCityUnion).count == 1 && apps.filter(\.isTUnion).count == 1, "City Union / T-Union view lost")
    check(apps.contains { $0.cardFamily == "Shenzhen Tong" && $0.selectedAID == szt && $0.records.count == 2 && $0.balanceText == "CNY 12.34" },
          "Local view lost beside City Union / T-Union")
    check(both.selectedAID == tu && both.cardFamily == mainland.cardFamily && both.realSerialNumber == mainland.realSerialNumber
          && both.balanceText == mainland.balanceText, "Local application replaced the T-Union primary")
    check(both.resultFields.filter { $0.title.hasPrefix("City Union · ") }.count == mainland.resultFields.filter { $0.title.hasPrefix("City Union · ") }.count,
          "City Union fields duplicated")
    check(both.resultFields.contains { $0.title == "Shenzhen Tong · Card Number" && $0.value == shenzhen["serial"] as! String }, "Local fields missing")
    check(!dual.selectedAIDs.contains("4F43") && !dual.selectedAIDs.contains("50424F43"), "Core NFC selected an unlisted Beijing name")
    let stored = try JSONDecoder().decode([TransitApplication].self, from: JSONEncoder().encode(apps))
    check(stored == apps, "Combined local application lost in storage")
    print("PASS: City Union read first; local application added beside City Union / T-Union")
}

/// Lingnan Pass: details in PAY.APPY, purse and history in PAY.TICL; pairs with Octopus like T-Union.
@MainActor func testLingnanPass(fixture: [String: Any], histories: [[String: Any]]) async throws {
    let ticl = "5041592E5449434C", appy = "5041592E41505059", tu = TUnionDecoder.applicationAID
    // A real PAY.TICL SELECT reply (flutter_nfc_kit issue #32). Its 9F0C is not the card details file.
    let ticlFCI = Data(hexString: "6f3484085041592e5449434ca5289f0801029f0c21ffffffffffffffff000000000000000000000000000000002019082400000186a0")
    let lingnan = (fixture["cards"] as! [[String: Any]])[3]
    let info = Data(hexString: lingnan["info"] as! String)
    let appyFCI = Data([0x6F, 0x2D, 0x84, 0x08]) + Data(hexString: appy) + Data([0xA5, 0x21, 0x9F, 0x0C, 0x1E]) + info
    let records = histories.prefix(3).map { Data(hexString: $0["hex"] as! String) }

    // (a) A Lingnan-only card on Core NFC: details from PAY.APPY's FCI, purse and history from PAY.TICL.
    let card = NFCISO7816Tag(); card.selectsUnlistedApplications = false; card.initialSelectedAID = appy
    card.available = [appy, ticl]; card.selectReplies = [appy: appyFCI, ticl: ticlFCI]
    card.balances = [ticl: Data(hexString: "00000BB8")]
    card.files = [ticl: [24: records]]
    let read = try await ChineseLocalDecoder.decode(tag: .iso7816(card), scannedAt: Date())
    check(read.cardFamily == "Lingnan Pass" && read.selectedAID == ticl && read.region == "Guangzhou", "Lingnan identity")
    check(read.balanceText == "CNY 30", "Lingnan balance \(read.balanceText ?? "nil")")
    check(read.realSerialNumber == "5123456789", "Lingnan card number")
    check(read.resultFields.contains { $0.title == "Issue Date" && $0.value == "2020-01-01" }
          && read.resultFields.contains { $0.title == "Expiry Date" && $0.value == "2030-12-31" }, "Lingnan dates")
    check(read.rawTransactions.count == 3 && read.applications?.count == 1 && read.applications![0].isLingnan
          && read.applications![0].records.allSatisfy { $0.sfi == 0x18 && $0.kind == .transaction }, "Lingnan history")
    check(Array(card.selectedAIDs.prefix(4)) == ["5041592E535A54", "4150312E5748435443", appy, ticl], "Lingnan SELECT order \(card.selectedAIDs)")
    check(!card.selectedAIDs.contains("4F43") && !card.selectedAIDs.contains("50424F43"), "Core NFC selected an unlisted Beijing name")
    check(read.rawSections.first?.fields.contains { $0.value == appy } == true
          && read.rawSections.first?.fields.contains { $0.value == appyFCI.hexString } == true, "PAY.APPY selection not kept for diagnostics")
    check(!card.commands.contains { $0.instructionCode == 0xA4 && $0.p1Parameter == 0 }, "Lingnan read selected the master file")
    check(card.commands.allSatisfy { [UInt8(0xA4), 0xB0, 0xB2, 0x5C].contains($0.instructionCode) }, "Unexpected APDU")
    let stored = try JSONDecoder().decode([TransitApplication].self, from: JSONEncoder().encode(read.applications!))
    check(stored == read.applications, "Lingnan backup lost source records")

    // (b) The real PAY.TICL reply alone: balance read, its FCI bytes are not taken as card number or dates.
    let ticlOnly = NFCISO7816Tag(); ticlOnly.selectsUnlistedApplications = false; ticlOnly.initialSelectedAID = ticl
    ticlOnly.available = [ticl]; ticlOnly.selectReplies = [ticl: ticlFCI]
    ticlOnly.balances = [ticl: Data(hexString: "000186A0")]
    let plain = try await ChineseLocalDecoder.decode(tag: .iso7816(ticlOnly), scannedAt: Date())
    check(plain.cardFamily == "Lingnan Pass" && plain.selectedAID == ticl && plain.balanceText == "CNY 1000", "PAY.TICL-only card")
    check(plain.realSerialNumber == nil && !plain.resultFields.contains { $0.title == "Issue Date" || $0.title == "Expiry Date" },
          "PAY.TICL FCI misread as card details")
    ticlOnly.failBalances = true
    do { _ = try await ChineseLocalDecoder.decode(tag: .iso7816(ticlOnly), scannedAt: Date()); preconditionFailure("Lingnan read without a balance") }
    catch NFCTestError.unsupportedCard { }

    // (c) T-Union with Lingnan Pass on one card: T-Union is read first and stays primary.
    var infoTU = Data(repeating: 0, count: 30); infoTU.replaceSubrange(2..<4, with: Data(hexString: "2900")); infoTU[19] = 1
    infoTU.replaceSubrange(10..<20, with: Data(hexString: "03100000000000000001"))
    let both = NFCISO7816Tag(); both.selectsUnlistedApplications = false; both.initialSelectedAID = tu
    both.available = [tu, appy, ticl]; both.info = [tu: infoTU]; both.selectReplies = [appy: appyFCI, ticl: ticlFCI]
    both.balances = [ticl: Data(hexString: "00000BB8")]; both.files = [ticl: [24: records]]
    let mainland = try await ChineseTransitDecoder.decode(tag: .iso7816(both), scannedAt: Date())
    check(!both.selectedAIDs.prefix(both.selectedAIDs.firstIndex(of: "5041592E535A54") ?? both.selectedAIDs.count).contains(appy),
          "Lingnan SELECT before the T-Union read")
    let withLocal = await ChineseLocalDecoder.addingLocalApplication(to: mainland, tag: .iso7816(both))
    check(withLocal.applications?.count == 2 && withLocal.applications!.contains(where: \.isTUnion)
          && withLocal.applications!.contains(where: \.isLingnan), "T-Union + Lingnan views")
    check(withLocal.selectedAID == tu && withLocal.balanceText == mainland.balanceText && withLocal.cardFamily == mainland.cardFamily,
          "Lingnan replaced the T-Union primary")

    // (d) 岭南通·八达通: Lingnan Pass beside Octopus becomes one card with two views, in either order.
    let octopus = snapshot(nil, serial: nil, balance: "HKD 50", records: [record(Data(repeating: 1, count: 16), sfi: 0)])
    var rated = octopus
    rated.exchangeRate = OctopusExchangeRate(rate: "0.839", validUntil: nil)
    rated.applications = [TransitApplication(snapshot: rated, records: octopus.applications![0].records)]
    for pair in [[read, octopus], [rated, read]] {
        let reader = NFCTransitReader(); reader.startScanning()
        let session = reader.session!
        reader.accept(pair[0], session: session)
        check(reader.isScanning && reader.latestSnapshot == nil, "Lingnan / Octopus did not check the other interface")
        check(session.pollingOption == (pair[0].technology == "FeliCa" ? [.iso14443] : [.iso18092]), "Wrong companion protocol polled")
        reader.accept(pair[1], session: session)
        let combined = reader.latestSnapshot
        check(!reader.isScanning && combined?.applications?.count == 2, "Octopus + Lingnan not combined")
        check(combined?.cardFamily == "Octopus + Lingnan Pass" && combined?.balanceText == "HKD 50", "Octopus + Lingnan family or HKD balance")
        check(combined?.balanceDetail?.contains("Lingnan Pass: CNY 30") == true, "Lingnan balance missing from the combined card")
        // The separate Lingnan purse is never shown as the CN¥ side of an Octopus – T-Union card.
        check(DualCurrencyBalance(applications: combined?.applications)?.yuanBalance == nil, "Lingnan purse shown as a CN¥ balance")
        let wallet = Wallet(); wallet.upsert(snapshot: combined!); wallet.upsert(snapshot: read)
        check(wallet.cards.count == 1 && wallet.cards[0].applications?.count == 2, "Lingnan rescan split the Octopus card")
    }
    // A Shenzhen Tong read does not pair with Octopus (unchanged).
    check(!TransitApplication(snapshot: snapshot("5041592E535A54", serial: "1")).isLingnan, "Shenzhen counted as Lingnan")
    print("PASS: Lingnan Pass only, PAY.TICL reply, beside T-Union and beside Octopus")
}
