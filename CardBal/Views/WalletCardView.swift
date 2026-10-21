import SwiftUI

/// Sizes a card from its container, including sheets and resized windows.
/// Keeping previews bounded also leaves room for their surrounding information.
struct WalletCardLayout: Layout {
    static let aspectRatio: CGFloat = 27.0 / 17.0
    static let maximumWidth: CGFloat = 480

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(max(proposal.width ?? Self.maximumWidth, 1), Self.maximumWidth)
        return CGSize(width: width, height: width / Self.aspectRatio)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

struct WalletCardView: View {
    private let cardCornerRadius: CGFloat = 22
    let card: SavedCardRecord
    let isExpanded: Bool
    let cardHeight: CGFloat
    let visiblePartHeight: CGFloat
    let onVisibleTap: () -> Void
    let showDetails: () -> Void
    let showTransactions: () -> Void
    let showTransit: () -> Void
    @AppStorage("snDisplayMode") private var snDisplayMode = 0
    @State private var copied = false

    private var faceImage: UIImage? {
        card.faceImageFileName.flatMap(loadCardFaceImage)
    }

    private var isPhotoFace: Bool { faceImage != nil && card.finalIsUsingImage }
    private var shouldShowTitle: Bool {
        !(isPhotoFace && card.finalHideTitle)
    }

    private var shouldShowSerialNumber: Bool {
        !card.finalHideSN
    }

    private var titleTextColor: Color { .white }
    private var balanceTextColor: Color { .white }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let dynamicRadius = width / 27.0
            
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: dynamicRadius, style: .continuous)
                    .fill(card.colorFace())

                if let faceImage, card.finalIsUsingImage {
                    Image(uiImage: faceImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: proxy.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: dynamicRadius, style: .continuous))
                }

                if isPhotoFace && card.imageFaceEnhancer == .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.58), location: 0),
                            .init(color: .black.opacity(0.34), location: 0.2),
                            .init(color: .black.opacity(0.1), location: 0.38),
                            .init(color: .clear, location: 0.56),
                            .init(color: .clear, location: 0.72),
                            .init(color: .black.opacity(0.22), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: dynamicRadius, style: .continuous))
                    .allowsHitTesting(false)
                }

                RoundedRectangle(cornerRadius: dynamicRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)

                VStack(alignment: .leading, spacing: 0) {
                    // Two compact rows so a stacked card's visible strip shows
                    // name, balance, number and scan date without clipping.
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if card.markerSystemName != nil || card.markerText != nil {
                                markerBadge
                                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                            }
                            borderedCardText(
                                shouldShowTitle ? card.displayTitle : "",
                                font: .title3.weight(.semibold),
                                foregroundColor: titleTextColor,
                                lineLimit: 1,
                                minimumScaleFactor: 0.8
                            )
                            Spacer(minLength: 8)
                            borderedCardText(
                                card.visibleBalance,
                                font: card.hasNoStoredBalance
                                    ? .system(size: 20, weight: .semibold, design: .rounded)
                                    : .system(size: 26, weight: .bold, design: .rounded),
                                foregroundColor: balanceTextColor.opacity(card.hasNoStoredBalance ? 0.82 : 1),
                                lineLimit: 1,
                                minimumScaleFactor: 0.7
                            )
                            .monospacedDigit()
                            .layoutPriority(1)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if shouldShowSerialNumber {
                                let snText = card.privacyFormattedSerialNumber(mode: snDisplayMode)
                                if !snText.isEmpty {
                                    Button {
                                        UIPasteboard.general.string = card.identifierValue
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { copied = true }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
                                    } label: {
                                        HStack(spacing: 4) {
                                            borderedCardText(
                                                snText,
                                                font: .caption.weight(.medium).monospacedDigit(),
                                                foregroundColor: titleTextColor.opacity(0.82),
                                                lineLimit: 1,
                                                minimumScaleFactor: 0.75
                                            )
                                            if copied {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundStyle(.white)
                                                    .transition(.scale.combined(with: .opacity))
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(Text("Copy card number"))
                                }
                            }
                            Spacer(minLength: 8)
                            let dateText = KSX6924DateFormatting.formatRawDateForDisplay(card.scannedAt, includeTime: false)
                            if !dateText.isEmpty && dateText != "Unknown" {
                                borderedCardText(
                                    dateText,
                                    font: .caption2.weight(.semibold).monospacedDigit(),
                                    foregroundColor: titleTextColor.opacity(0.72),
                                    lineLimit: 1
                                )
                                .accessibilityLabel(Text("Scanned \(dateText)"))
                            }
                        }
                    }

                    Spacer()

                    let transactionCount = card.transactions.count
                    let transitCount = card.transitHistory.count

                    HStack(alignment: .bottom) {
                        HStack(spacing: 8) {
                            if transactionCount > 0 {
                                historyButton(
                                    systemImage: "list.bullet",
                                    count: transactionCount,
                                    label: transactionCount == 1 ? String(localized: "1 Transaction") : String(localized: "\(transactionCount) Transactions"),
                                    action: showTransactions
                                )
                            }
                            if transitCount > 0 {
                                historyButton(
                                    systemImage: "tram.fill",
                                    count: transitCount,
                                    label: transitCount == 1 ? String(localized: "1 Ride") : String(localized: "\(transitCount) Rides"),
                                    action: showTransit
                                )
                            }
                        }

                        Spacer()

                        Button(action: showDetails) {
                            Image(systemName: "chevron.right")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(titleTextColor)
                                .frame(width: 40, height: 40)
                                .background((isPhotoFace ? Color.black.opacity(0.28) : Color.white.opacity(0.14)), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show Details")
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal, 18)
                .padding(.bottom, 16)

                if visiblePartHeight > 0 && !isExpanded {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: visiblePartHeight)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onVisibleTap)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded {
                    // Tap on expanded card background should trigger onVisibleTap?
                    // Optional: onVisibleTap()
                } else {
                    onVisibleTap()
                }
            }
        }
        .frame(height: cardHeight)
    }

    private func historyButton(systemImage: String, count: Int, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(isExpanded ? label : "\(count)")
                    .monospacedDigit()
            }
            .font(.system(size: isExpanded ? 12 : 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, isExpanded ? 11 : 8).padding(.vertical, isExpanded ? 8 : 6)
            .foregroundStyle(.white)
            .background(.black.opacity(isPhotoFace ? 0.34 : 0.22), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var markerBadge: some View {
        ZStack {
            markerBackground(color: card.markerColor.color, size: 28)
            
            Group {
                if let markerSystemName = card.markerSystemName {
                    Image(systemName: markerSystemName)
                        .font(.system(size: 14, weight: .bold))
                } else if let markerText = card.markerText {
                    Text(markerText)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(card.markerOuterColor.color)
        }
        .frame(width: 28, height: 28)
    }

    @ViewBuilder
    private func markerBackground(color: Color, size: CGFloat) -> some View {
        if card.markerShape == .circle { Circle().fill(color).frame(width: size, height: size) }
        else { RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(color).frame(width: size, height: size) }
    }

    @ViewBuilder
    private func borderedCardText(_ text: String, font: Font, foregroundColor: Color, lineLimit: Int? = nil, minimumScaleFactor: CGFloat? = nil) -> some View {
        Text(text).font(font).foregroundStyle(foregroundColor).lineLimit(lineLimit).minimumScaleFactor(minimumScaleFactor ?? 1)
            .shadow(
                color: isPhotoFace && card.imageFaceEnhancer == .border ? .black.opacity(0.8) : .clear,
                radius: isPhotoFace && card.imageFaceEnhancer == .border ? 4 : 0,
                x: 0,
                y: 1.5
            )
    }
}

extension SavedCardRecord {
    /// The gradient a card shows when it has no photo face.
    func colorFace(design: SavedCardDesign? = nil) -> LinearGradient {
        switch design ?? self.design {
        case .classic:
            return LinearGradient(colors: [color.color, color.darkerColor, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .sunrise:
            return LinearGradient(stops: [.init(color: color.color, location: 0), .init(color: color.color.opacity(0.92), location: 0.28), .init(color: .orange.opacity(0.9), location: 0.72), .init(color: color.darkerColor, location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
