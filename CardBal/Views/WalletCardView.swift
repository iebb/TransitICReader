import SwiftUI

struct WalletCardView: View {
    let card: SavedCardRecord
    let isExpanded: Bool
    let cardHeight: CGFloat
    let visiblePartHeight: CGFloat
    let onVisibleTap: () -> Void
    let showDetails: () -> Void

    var isPhotoFace: Bool { card.faceImageFileName != nil }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(cardBackground)
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)

            if let fileName = card.faceImageFileName,
               let faceImage = loadCardFaceImage(fileName: fileName) {
                Image(uiImage: faceImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: UIScreen.main.bounds.width - 32, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        if card.imageFaceEnhancer == .mask {
                            LinearGradient(colors: [.black.opacity(0.6), .clear, .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !card.hideTitleOnImage || !isPhotoFace {
                            borderedCardText(card.displayTitle, font: .system(size: 22, weight: .bold, design: .rounded), foregroundColor: card.autoTitleTextColor?.color ?? .white)
                        }
                        if !card.hideSerialNumber {
                            borderedCardText(card.displayedSerialNumber, font: .system(.caption, design: .monospaced).weight(.bold), foregroundColor: (card.autoTitleTextColor?.color ?? .white).opacity(0.86))
                        }
                    }
                    Spacer()
                    if let markerSymbolName = card.markerSymbolName {
                        markerBadge(symbol: markerSymbolName)
                    }
                }
                .padding(24)

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        borderedCardText(card.visibleBalance, font: .system(size: 34, weight: .black, design: .rounded), foregroundColor: card.autoBalanceTextColor?.color ?? .white, minimumScaleFactor: 0.5)
                        Text("Balance")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle((card.autoBalanceTextColor?.color ?? .white).opacity(0.65))
                    }
                    Spacer()
                    Button(action: showDetails) {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.system(size: 32, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(card.autoBalanceTextColor?.color ?? .white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(24)
            }
        }
        .frame(width: UIScreen.main.bounds.width - 32, height: isExpanded ? cardHeight : visiblePartHeight)
        .onTapGesture(perform: onVisibleTap)
    }

    @ViewBuilder
    private func markerBadge(symbol: String) -> some View {
        ZStack {
            markerBackground(color: card.markerColor.color, size: 28)
            if symbol.hasPrefix("sf:") {
                Image(systemName: String(symbol.dropFirst(3)))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(card.markerOuterColor.color)
            } else if symbol.hasPrefix("txt:") {
                Text(String(symbol.dropFirst(4)))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(card.markerOuterColor.color)
            }
        }
    }

    @ViewBuilder
    private func markerBackground(color: Color, size: CGFloat) -> some View {
        if card.markerShape == .circle { Circle().fill(color).frame(width: size, height: size) }
        else { RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(color).frame(width: size, height: size) }
    }

    @ViewBuilder
    private func borderedCardText(_ text: String, font: Font, foregroundColor: Color, lineLimit: Int? = nil, minimumScaleFactor: CGFloat? = nil) -> some View {
        Text(text).font(font).foregroundStyle(foregroundColor).lineLimit(lineLimit).minimumScaleFactor(minimumScaleFactor ?? 1)
            .shadow(color: isPhotoFace && card.imageFaceEnhancer == .border ? .black.opacity(0.8) : .clear, radius: 4, x: 0, y: 1.5)
    }

    private var cardBackground: AnyShapeStyle {
        switch card.design {
        case .classic:
            return AnyShapeStyle(LinearGradient(colors: [card.color.color, card.color.darkerColor, .black], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .sunrise:
            return AnyShapeStyle(LinearGradient(stops: [.init(color: card.color.color, location: 0), .init(color: card.color.color.opacity(0.92), location: 0.28), .init(color: .orange.opacity(0.9), location: 0.72), .init(color: card.color.darkerColor, location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .metro:
            return AnyShapeStyle(LinearGradient(stops: [.init(color: card.color.darkerColor, location: 0), .init(color: card.color.darkerColor, location: 0.46), .init(color: card.color.color, location: 0.46), .init(color: card.color.color, location: 0.64), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
        }
    }
}
