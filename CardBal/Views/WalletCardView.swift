import SwiftUI

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
                    .fill(cardBackground)

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
                            .init(color: .black.opacity(0.52), location: 0),
                            .init(color: .black.opacity(0.24), location: 0.18),
                            .init(color: .black.opacity(0.08), location: 0.34),
                            .init(color: .clear, location: 0.54)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: dynamicRadius, style: .continuous))
                    .allowsHitTesting(false)
                }

                RoundedRectangle(cornerRadius: dynamicRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if card.markerSystemName != nil || card.markerText != nil {
                                    markerBadge
                                }
                                borderedCardText(
                                    shouldShowTitle ? card.displayTitle : "",
                                    font: .title3.weight(.semibold),
                                    foregroundColor: titleTextColor
                                )
                            }
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
                                                font: .caption.weight(.medium),
                                                foregroundColor: titleTextColor.opacity(0.8),
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
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }

                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            borderedCardText(
                                card.visibleBalance,
                                font: .system(size: 28, weight: .bold, design: .rounded),
                                foregroundColor: balanceTextColor,
                                minimumScaleFactor: 0.75
                            )
                            
                            // Mini Last Scanned - Always visible top part
                            let dateText = KSX6924DateFormatting.formatRawDateForDisplay(card.scannedAt, includeTime: false)
                            if !dateText.isEmpty && dateText != "Unknown" {
                                Text(dateText)
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .foregroundStyle(titleTextColor)
                                    .background(.black.opacity(0.24), in: Capsule())
                            }
                        }
                    }

                    Spacer()

        let transactionCount = card.transactions.count
        let transitCount = card.transitHistory.count
        let showHistoryButtons = isExpanded && (transactionCount > 0 || transitCount > 0)
        
        HStack(alignment: .bottom) {
            if showHistoryButtons {
                HStack(spacing: 8) {
                    if transactionCount > 0 {
                        Button(action: showTransactions) {
                            HStack(spacing: 4) {
                                Image(systemName: "list.bullet")
                                Text("\(transactionCount) Tx")
                            }
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .foregroundStyle(isPhotoFace ? .white : .primary)
                            .background((isPhotoFace ? Color.black.opacity(0.3) : Color.white.opacity(0.18)), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if transitCount > 0 {
                        Button(action: showTransit) {
                            HStack(spacing: 4) {
                                Image(systemName: "map")
                                Text("\(transitCount) Trips")
                            }
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .foregroundStyle(isPhotoFace ? .white : .primary)
                            .background((isPhotoFace ? Color.black.opacity(0.3) : Color.white.opacity(0.18)), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()

            Button(action: showDetails) {
                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(titleTextColor)
                    .frame(width: 40, height: 40)
                    .background((isPhotoFace ? Color.black.opacity(0.22) : Color.white.opacity(0.14)), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show Details")
        }
                }
                .padding(.top, 11)
                .padding(.leading, 18)
                .padding(.trailing, 18)
                .padding(.bottom, 18)

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

    private var cardBackground: AnyShapeStyle {
        switch card.design {
        case .classic:
            return AnyShapeStyle(LinearGradient(colors: [card.color.color, card.color.darkerColor, .black], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .sunrise:
            return AnyShapeStyle(LinearGradient(stops: [.init(color: card.color.color, location: 0), .init(color: card.color.color.opacity(0.92), location: 0.28), .init(color: .orange.opacity(0.9), location: 0.72), .init(color: card.color.darkerColor, location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}
