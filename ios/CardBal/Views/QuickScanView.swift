import SwiftUI

/// Shared by the Clip and the containing app's invocation flow.
@MainActor
final class QuickScanRoute: ObservableObject {
    static let shared = QuickScanRoute()
    @Published var isPresented = false

    func receive(_ url: URL?) {
        // A delivered invocation always opens the explicit-scan screen, even if
        // its URL is missing or malformed. Never fall through to scan-on-launch.
        if let url { _ = ClipInvocation(url) }
        isPresented = true
    }
}

struct QuickScanView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var reader = NFCTransitReader(localOnly: true)
    @State private var showsUnavailable = false
    @State private var demoSnapshot: TransitCardSnapshot?
    @State private var previewMessage: String?
    @State private var isDemo = false

    private var snapshot: TransitCardSnapshot? { reader.latestSnapshot ?? demoSnapshot }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if isDemo {
                        Label("Demo — no card was scanned", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                            .accessibilityIdentifier("clip-demo")
                    }
                    if let snapshot { result(snapshot) } else { landing }
                    if let previewMessage {
                        Text(Localizer.localize(previewMessage)).foregroundStyle(.secondary)
                    }
                    if reader.isScanning {
                        ProgressView(Localizer.localize(reader.statusMessage))
                        Button("Cancel") { reader.cancelScanning() }
                            .accessibilityIdentifier("clip-cancel")
                    } else if reader.hasScanError {
                        Label("Couldn't Read Card", systemImage: "exclamationmark.triangle")
                            .font(.headline).accessibilityIdentifier("clip-read-error")
                        Text("Hold the card near the top of your iPhone and try again.")
                            .foregroundStyle(.secondary)
                    }
                    Button(action: scan) {
                        Label(Localizer.localize(snapshot == nil ? "Scan Card" : "Scan Another Card"),
                              systemImage: "sensor.tag.radiowaves.forward.fill")
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                            .background(colorScheme == .dark ? Color.white : Color.black,
                                        in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(reader.isScanning)
                    .accessibilityIdentifier("clip-scan")
                    #if APPCLIP
                    VStack(alignment: .leading, spacing: 12) {
                        Link(destination: URL(string: "https://apps.apple.com/app/id6760978958")!) {
                            Label("Download Full CardBal App", systemImage: "arrow.down.app")
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .foregroundStyle(Color.primary)
                                .background(Color(uiColor: .secondarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(Color.primary.opacity(0.3)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("clip-download")
                        Text("Download the full app to save your cards.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    #endif
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(snapshot == nil ? "CardBal" : String(localized: "Card Details"))
            .navigationBarTitleDisplayMode(.inline)
            .alert("Scanning Unavailable", isPresented: $showsUnavailable) {
                Button("Done", role: .cancel) {}
            } message: {
                Text("Card scanning isn't available right now. Try again later.")
            }
            .onDisappear { reader.cancelScanning() }
            .onAppear(perform: loadPreview)
        }
    }

    private var landing: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "wave.3.right.circle.fill")
                .font(.system(size: 64)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Check your transit card").font(.largeTitle.bold())
            Text("Scan a supported card to see the balance and recent transactions it can share.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Text("Supported Cards").font(.headline)
                // This deliberately lists a subset of the enabled local decoders.
                Text("Suica · PASMO · ICOCA · T-money · EZL · China T-Union · CEPAS · Macau Pass")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text("Hold the card near the top of your iPhone.").font(.callout)
        }
    }

    private func result(_ snapshot: TransitCardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(Localizer.localize(snapshot.cardFamily)).font(.title.bold())
                .accessibilityIdentifier("clip-card-type")
            if let balance = snapshot.balanceText, !balance.isEmpty, balance != "N/A" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On-card Balance").font(.subheadline).foregroundStyle(.secondary)
                    Text(balance).font(.system(.largeTitle, design: .rounded).bold())
                        .accessibilityIdentifier("clip-balance")
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            }
            if let detail = snapshot.balanceDetail,
               ["On-card stored-value purse only. SimplyGo account balances are not read.",
                "Stored-value balance excluding the MOP 10 reserve.",
                "Balance and last-event summary; not full history"].contains(detail) {
                Text(Localizer.localize(detail)).font(.footnote).foregroundStyle(.secondary)
            }
            let records = snapshot.transitHistory.isEmpty ? snapshot.unifiedRecentTransactions : snapshot.transitHistory
            let history = Array(records.filter { $0.date != nil && $0.category != .unknown }.prefix(10))
            if !history.isEmpty {
                Text("Recent Transactions").font(.headline)
                VStack(spacing: 16) {
                    ForEach(Array(history.enumerated()), id: \.offset) { _, transaction in
                        transactionRow(transaction, brand: snapshot.brand)
                    }
                }
            }
        }
    }

    private func transactionRow(_ transaction: TransitTransaction, brand: ICCardBrand) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: transaction.iconInfo.name).foregroundStyle(transaction.iconInfo.color)
                .frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(Localizer.localize(transaction.type)).font(.subheadline.weight(.medium))
                if let date = transaction.date {
                    Text(CardDateFormatting.formatDisplayDateTime(date, brand: brand,
                        resolution: CardDateFormatting.resolution(forTimeText: transaction.time),
                        issuerTimeZone: transaction.issuerTimeZone))
                        .font(.caption).foregroundStyle(.secondary)
                }
                let stations = [transaction.entryStation, transaction.exitStation].compactMap { $0 }
                if !stations.isEmpty {
                    Text(stations.joined(separator: " → ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if transaction.amountKnown && !transaction.hasUnresolvedKoreanTransitFare {
                let currency = transaction.currencyCode ?? brand.region.currencyCode
                Text(formatCurrency(amount: transaction.amount, code: currency,
                                    fractionDigits: defaultFractionDigits(for: currency)))
                    .font(.subheadline.monospacedDigit())
            }
        }
    }

    private func scan() {
        previewMessage = nil
        isDemo = false
        demoSnapshot = nil
        reader.clearResult()
        guard reader.isNFCAvailable else { showsUnavailable = true; return }
        reader.startScanning(options: [.iso14443, .iso18092])
    }

    private func loadPreview() {
        #if DEBUG && targetEnvironment(simulator)
        guard !isDemo, let mode = ProcessInfo.processInfo.environment["CARDBAL_CLIP_PREVIEW"] else { return }
        isDemo = true
        switch mode {
        case "result":
            demoSnapshot = TransitCardSnapshot(technology: "FeliCa", cardFamily: "Suica",
                identifierLabel: "", identifierValue: "", rawIdentifierValue: "", pmm: nil,
                systemCode: "0003", selectedAID: nil, balanceText: formatCurrency(amount: 1280, code: "JPY"),
                balanceDetail: nil, realSerialNumber: nil, region: nil, resultFields: [], rawSections: [],
                rawTransactions: [], rawTransitHistory: [], scannedAt: Date())
        case "cancelled": previewMessage = "Scan cancelled."
        case "failure": previewMessage = "Couldn't Read Card"
        default: showsUnavailable = true
        }
        #endif
    }
}
