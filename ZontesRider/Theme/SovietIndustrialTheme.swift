import SwiftUI
import UIKit

// MARK: - 苏维埃构成主义配色（依赖 DesignTokens 的 Color(hex:)）

public enum SovietPalette {
    public static let revolutionRed = Color(hex: 0x9E1B1B)   // 旗帜深红（主强调）
    public static let redBright     = Color(hex: 0xC62F2F)   // 工业指示灯·亮
    public static let redDark       = Color(hex: 0x5E1010)   // 深红机械阴影边
    public static let castIron      = Color(hex: 0x18191B)   // 工业铸铁黑（底色）
    public static let steel         = Color(hex: 0x2B2C2F)   // 冷轧钢板灰
    public static let steelLight    = Color(hex: 0x222326)
    public static let steelDark     = Color(hex: 0x0F1012)   // 仪表盘面
    public static let track         = Color(hex: 0x3A3B3F)   // 圆环轨道 / 分隔
    public static let brass         = Color(hex: 0xD4AF37)   // 黄铜 / 麦穗金
    public static let brassPale     = Color(hex: 0xF5E9C8)   // 读数米金
    public static let leverGrey     = Color(hex: 0x5A5C62)   // 拨杆常态
    public static let textSecondary = Color(hex: 0xA8A293)   // 次级米灰
    public static let textMuted     = Color(hex: 0x8A8D92)
    public static let textFaint     = Color(hex: 0x5A5C62)
    public static let black         = Color(hex: 0x000000)

    // 语义色（指示灯 / 正文）
    public static let danger        = Color(hex: 0xC62F2F)   // 告警红 = 指示灯亮
    public static let ok            = Color(hex: 0x6B8E4E)   // 军绿（在线/正常）
    public static let textPrimary   = Color(hex: 0xE8E2D0)   // 米白正文
}

// MARK: - 字体

extension Font {
    /// 机械等宽字体：标题与读数统一使用
    public static func soviet(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - 45° 切角外形（左上 + 右下斜切，构成主义斜线语言）

public struct BeveledShape: Shape {
    public var cut: CGFloat

    public init(cut: CGFloat = 10) { self.cut = cut }

    public func path(in rect: CGRect) -> Path {
        let c = min(cut, min(rect.width, rect.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + c, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
        p.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + c))
        p.closeSubpath()
        return p
    }
}

// MARK: - 构成主义卡片：黄铜描边 + 钢板底 + 切角

public struct ConstructivistCardStyle: ViewModifier {
    public var cut: CGFloat
    public var borderColor: Color
    public var fill: Color
    public var borderWidth: CGFloat

    public init(
        cut: CGFloat = 10,
        borderColor: Color = SovietPalette.brass,
        fill: Color = SovietPalette.steel,
        borderWidth: CGFloat = 2
    ) {
        self.cut = cut
        self.borderColor = borderColor
        self.fill = fill
        self.borderWidth = borderWidth
    }

    public func body(content: Content) -> some View {
        content
            .background(fill)
            .padding(borderWidth)
            .background(borderColor)
            .clipShape(BeveledShape(cut: cut))
    }
}

extension View {
    public func constructivistCard(
        cut: CGFloat = 10,
        borderColor: Color = SovietPalette.brass,
        fill: Color = SovietPalette.steel,
        borderWidth: CGFloat = 2
    ) -> some View {
        modifier(ConstructivistCardStyle(cut: cut, borderColor: borderColor, fill: fill, borderWidth: borderWidth))
    }
}

// MARK: - 重型机械推杆按钮
//
// 底部深红厚边模拟推杆行程：按下时厚边压薄 + 整体下沉 2pt。

public struct HeavyMetalButtonStyle: ButtonStyle {
    public var cut: CGFloat
    public var faceColor: Color
    public var edgeColor: Color

    public init(
        cut: CGFloat = 14,
        faceColor: Color = SovietPalette.revolutionRed,
        edgeColor: Color = SovietPalette.redDark
    ) {
        self.cut = cut
        self.faceColor = faceColor
        self.edgeColor = edgeColor
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.soviet(16))
            .tracking(6)
            .foregroundStyle(SovietPalette.brass)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(faceColor)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(edgeColor)
                    .frame(height: configuration.isPressed ? 1 : 4)
            }
            .padding(3)
            .background(SovietPalette.black)
            .clipShape(BeveledShape(cut: cut))
            .offset(y: configuration.isPressed ? 2 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == HeavyMetalButtonStyle {
    public static var heavyMetal: HeavyMetalButtonStyle { HeavyMetalButtonStyle() }
}

// MARK: - 工业拨杆开关（红 / 灰双色指示灯 + 滑块槽）

public struct IndustrialToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(configuration.isOn ? SovietPalette.redBright : SovietPalette.steelDark)
                    .frame(width: 12, height: 12)
                    .overlay {
                        Circle().stroke(configuration.isOn ? SovietPalette.redDark : SovietPalette.black, lineWidth: 2)
                    }

                configuration.label
                    .font(.soviet(13))
                    .foregroundStyle(configuration.isOn ? SovietPalette.brassPale : SovietPalette.textMuted)

                Spacer(minLength: 8)

                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Rectangle()
                        .fill(configuration.isOn ? SovietPalette.revolutionRed : SovietPalette.steel)
                    Rectangle()
                        .fill(configuration.isOn ? SovietPalette.brass : SovietPalette.leverGrey)
                        .frame(width: 16, height: 14)
                        .padding(2)
                }
                .frame(width: 44, height: 22)
                .border(SovietPalette.black, width: 2)
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(SovietPalette.steelLight)
            .border(SovietPalette.black, width: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == IndustrialToggleStyle {
    public static var industrial: IndustrialToggleStyle { IndustrialToggleStyle() }
}

// MARK: - 斜纹警示带（黄黑 45° 条纹，Canvas 平铺）

public struct HazardStripes: View {
    public var height: CGFloat
    public var stripeWidth: CGFloat

    public init(height: CGFloat = 10, stripeWidth: CGFloat = 9) {
        self.height = height
        self.stripeWidth = stripeWidth
    }

    public var body: some View {
        Canvas { context, size in
            // 死循环防护：layout 若把 .infinity 传进来，裸 while 会跑满主线程
            // （表现为「点开即闪退」，本质是看门狗杀进程）。这里三重设限。
            guard size.width.isFinite, size.height.isFinite else { return }
            let w = max(stripeWidth, 1)
            let limit = min(size.width + size.height, 8192) / w + 8
            var x: CGFloat = -size.height
            var index = 0
            while x < size.width + size.height, CGFloat(index) < limit {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                path.addLine(to: CGPoint(x: x + size.height + w, y: 0))
                path.addLine(to: CGPoint(x: x + w, y: size.height))
                path.closeSubpath()
                context.fill(
                    path,
                    with: .color(index % 2 == 0 ? SovietPalette.brass : SovietPalette.castIron)
                )
                x += w
                index += 1
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

// MARK: - 红旗标题横幅（红星 + 革命红底 + 金色大字）

public struct SovietBanner: View {
    let title: String

    public init(_ title: String) { self.title = title }

    public var body: some View {
        HStack {
            Image(systemName: "star.fill")
                .font(.system(size: 14))
                .foregroundStyle(SovietPalette.brass)
            Spacer()
            Text(title)
                .font(.soviet(15))
                .tracking(4)
                .foregroundStyle(SovietPalette.brass)
            Spacer()
            Image(systemName: "star.fill")
                .font(.system(size: 14))
                .foregroundStyle(SovietPalette.brass)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(SovietPalette.revolutionRed)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SovietPalette.black).frame(height: 3)
        }
    }
}

// MARK: - 红星印章（档案戳记装饰）

public struct RedStarSeal: View {
    public var size: CGFloat

    public init(size: CGFloat = 34) { self.size = size }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(SovietPalette.revolutionRed, lineWidth: 2.5)
            Circle()
                .stroke(SovietPalette.revolutionRed, lineWidth: 1)
                .padding(5)
            Image(systemName: "star.fill")
                .font(.system(size: size * 0.42))
                .foregroundStyle(SovietPalette.revolutionRed)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - 面板小节标签（▸ 黄铜导引符）

public struct SovietSectionLabel: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(SovietPalette.revolutionRed)
                .frame(width: 4, height: 12)
            Text(text)
                .font(.soviet(11))
                .tracking(2)
                .foregroundStyle(SovietPalette.textMuted)
            Spacer()
        }
    }
}
