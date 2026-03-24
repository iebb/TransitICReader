import Foundation
import SwiftUI

public enum ICCardRegion: String, Codable, CaseIterable {
    case japan, korea, hongkong, china, europe, other
    
    public var currencyCode: String {
        switch self {
        case .japan: return "JPY"
        case .korea: return "KRW"
        case .hongkong: return "HKD"
        case .china: return "CNY"
        default: return "USD"
        }
    }
}

public enum ICCardBrand: String, Codable, CaseIterable, Identifiable {
    public var id: String { rawValue }
    
    // Japan
    case suica, pasmo, icoca, manaca, sugoca, hayakaken, kitaca, nimoca, toica, pitapa
    
    // Korea
    case tmoney, ezl, namane, climateCard, moiba, kCash
    
    // Hong Kong
    case octopus
    
    // China
    case tUnion
    
    case other
    
    public var region: ICCardRegion {
        switch self {
        case .suica, .pasmo, .icoca, .manaca, .sugoca, .hayakaken, .kitaca, .nimoca, .toica, .pitapa: 
            return .japan
        case .tmoney, .ezl, .namane, .climateCard, .moiba, .kCash:
            return .korea
        case .octopus:
            return .hongkong
        case .tUnion:
            return .china
        case .other:
            return .other
        }
    }
    
    public var isKorean: Bool { region == .korea }
    public var isJapan: Bool { region == .japan }
    
    public static func from(family: String) -> ICCardBrand {
        let f = family.lowercased()
        if f.contains("suica") { return .suica }
        if f.contains("pasmo") { return .pasmo }
        if f.contains("icoca") { return .icoca }
        if f.contains("manaca") { return .manaca }
        if f.contains("sugoca") { return .sugoca }
        if f.contains("hayakaken") { return .hayakaken }
        if f.contains("kitaca") { return .kitaca }
        if f.contains("nimoca") { return .nimoca }
        if f.contains("toica") { return .toica }
        if f.contains("pitapa") { return .pitapa }
        if f.contains("t-money") || f.contains("tmoney") { return .tmoney }
        if f.contains("ezl") || f.contains("cashbee") { return .ezl }
        if f.contains("namane") { return .namane }
        if f.contains("climate") { return .climateCard }
        if f.contains("moiba") { return .moiba }
        if f.contains("k-cash") || f.contains("kcash") { return .kCash }
        if f.contains("octopus") { return .octopus }
        if f.contains("t-union") || f.contains("china") { return .tUnion }
        return .other
    }
}
