import SwiftUI

/// 环形仪表（苏维埃版）：切角钢板卡 + 圆环读数。
/// 0...1 的比例映射，中心显示读数与单位。
public struct GaugeRing: View {
    let ratio: Double
    let display: String
    let unit: String
    let caption: String
    let tint: Color
    var size: CGFloat = 86
    var lineWidth: CGFloat = 8

    public init(
        ratio: Double,
        display: String,
        unit: String,
        caption: String,
        tint: Color,
        size: CGFloat = 86,
        lineWidth: CGFloat = 8
    ) {
        self.ratio = ratio
        self.display = display
        self.unit = unit
        self.caption = caption
        self.tint = tint
        self.size = size
        self.lineWidth = lineWidth
    }

    public var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(SovietPalette.track, lineWidth: lineWidth)

                Circle()
                    .trim(from: 0, to: min(max(ratio, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.45), value: ratio)

                VStack(spacing: 1) {
                    Text(display)
                        .font(.soviet(19))
                        .monospacedDigit()
                        .foregroundStyle(SovietPalette.brassPale)
                    Text(unit)
                        .font(.soviet(10))
                        .foregroundStyle(SovietPalette.textMuted)
                }
            }
            .frame(width: size, height: size)

            Text(caption)
                .font(.soviet(11))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .constructivistCard(cut: 10)
    }
}

// MARK: - 数据格（切角钢板）

public struct DataCell: View {
    let label: String
    let value: String
    let unit: String?
    var tint: Color = SovietPalette.brassPale

    public init(label: String, value: String, unit: String? = nil, tint: Color = SovietPalette.brassPale) {
        self.label = label
        self.value = value
        self.unit = unit
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.soviet(11))
                .foregroundStyle(SovietPalette.textMuted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.soviet(17))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                if let unit {
                    Text(unit)
                        .font(.soviet(11))
                        .foregroundStyle(SovietPalette.textFaint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .constructivistCard(cut: 8, borderColor: SovietPalette.black, borderWidth: 2)
    }
}

// MARK: - BLE 连接状态（工业指示灯牌）

public struct ConnectionBadge: View {
    public enum State: Sendable {
        case disconnected
        case scanning
        case connecting
        case connected(rssi: Int)

        var label: String {
            switch self {
            case .disconnected: return "未连接"
            case .scanning:     return "扫描中"
            case .connecting:   return "连接中"
            case .connected(let rssi): return "已连接 · \(rssi) dBm"
            }
        }

        var tint: Color {
            switch self {
            case .connected: return SovietPalette.brass
            case .scanning, .connecting: return SovietPalette.redBright
            case .disconnected: return SovietPalette.leverGrey
            }
        }
    }

    let state: State

    public init(state: State) { self.state = state }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.tint)
                .frame(width: 8, height: 8)
                .overlay {
                    Circle().stroke(SovietPalette.black, lineWidth: 1.5)
                }
            Text(state.label)
                .font(.soviet(11))
                .foregroundStyle(state.tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(SovietPalette.steelLight)
        .border(SovietPalette.black, width: 2)
    }
}
