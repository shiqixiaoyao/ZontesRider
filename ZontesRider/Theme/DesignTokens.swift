import SwiftUI

// MARK: - 工农红旗 / 苏维埃构成主义 全局配色
//
// 视觉基因：革命红主强调 + 铸铁黑底 + 黄铜读数 + 冷轧钢板灰。
// 字段名与旧版保持一致（background/surface/accent/...），
// 既有视图（DashboardView 等）无需改动即可整体换肤。

public enum Palette {
    public static let background    = Color(hex: 0x18191B)   // 工业铸铁黑
    public static let surface       = Color(hex: 0x2B2C2F)   // 冷轧钢板灰
    public static let surfaceRaised = Color(hex: 0x222326)
    public static let stroke        = Color(hex: 0x000000)   // 粗黑描边
    public static let track         = Color(hex: 0x3A3B3F)

    public static let textPrimary   = Color(hex: 0xF5E9C8)   // 读数米金
    public static let textSecondary = Color(hex: 0xA8A293)
    public static let textTertiary  = Color(hex: 0x8A8D92)
    public static let textDisabled  = Color(hex: 0x5A5C62)

    public static let accent  = Color(hex: 0xD4AF37)   // 黄铜金属色（正常 / 高亮）
    public static let warning = Color(hex: 0xEF9F27)   // 偏低 / 告警
    public static let danger  = Color(hex: 0xC62F2F)   // 指示灯亮红（异常）
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red:     Double((hex >> 16) & 0xFF) / 255,
            green:   Double((hex >> 8) & 0xFF) / 255,
            blue:    Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - 读数排版（机械等宽，防止跳动）

public struct ReadingModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let color: Color

    public init(size: CGFloat, weight: Font.Weight = .medium, color: Color = Palette.textPrimary) {
        self.size = size
        self.weight = weight
        self.color = color
    }

    public func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: weight, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(color)
    }
}

extension View {
    public func reading(size: CGFloat, weight: Font.Weight = .medium, color: Color = Palette.textPrimary) -> some View {
        modifier(ReadingModifier(size: size, weight: weight, color: color))
    }
}

// MARK: - 基础卡片（直角钢板底；切角金框卡片见 SovietIndustrialTheme）

public struct SurfaceCard: ViewModifier {
    var cornerRadius: CGFloat = 4

    public func body(content: Content) -> some View {
        content
            .background(Palette.surface, in: .rect(cornerRadius: cornerRadius))
    }
}

extension View {
    public func surfaceCard(cornerRadius: CGFloat = 4) -> some View {
        modifier(SurfaceCard(cornerRadius: cornerRadius))
    }
}
