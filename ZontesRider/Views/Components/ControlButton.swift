import SwiftUI
import UIKit

/// 控车按键（苏维埃版）：切角机械键 + 粗黑描边。
/// 按下时触感反馈 + 下沉，指令进行中显示旋转指示器并禁用重复点击。
public struct ControlButton: View {
    let title: String
    let systemImage: String
    var tint: Color = SovietPalette.brassPale
    var isBusy: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    public init(
        title: String,
        systemImage: String,
        tint: Color = SovietPalette.brassPale,
        isBusy: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.isBusy = isBusy
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button {
            // 高灵敏度按键：先给反馈再发指令，蓝牙往返通常 300~900ms
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            action()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Image(systemName: systemImage)
                        .font(.system(size: 20))
                        .foregroundStyle(isEnabled ? tint : SovietPalette.textFaint)
                        .opacity(isBusy ? 0 : 1)

                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(SovietPalette.brass)
                    }
                }
                .frame(height: 22)

                Text(title)
                    .font(.soviet(11))
                    .foregroundStyle(isEnabled ? SovietPalette.brassPale : SovietPalette.textFaint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(SovietPalette.steel)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(SovietPalette.steelDark)
                    .frame(height: 3)
            }
            .padding(2)
            .background(SovietPalette.black)
            .clipShape(BeveledShape(cut: 10))
        }
        .buttonStyle(TactileButtonStyle())
        .disabled(!isEnabled || isBusy)
    }
}

/// 机械键行程：按下下沉 2pt，无阴影无渐变
public struct TactileButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? 2 : 0)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - 命令语义

/// 控车指令。与协议层的 VehicleCommand 一一对应，UI 只认这个枚举。
public enum ControlAction: String, CaseIterable, Sendable, Identifiable {
    case unlock
    case lock
    case findVehicle
    case arm
    case openSeat
    case openTank

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .unlock:      return "解锁"
        case .lock:        return "上锁"
        case .findVehicle: return "寻车"
        case .arm:         return "设防"
        case .openSeat:    return "坐垫"
        case .openTank:    return "油箱"
        }
    }

    var systemImage: String {
        switch self {
        case .unlock:      return "lock.open.fill"
        case .lock:        return "lock.fill"
        case .findVehicle: return "location.circle.fill"
        case .arm:         return "shield.fill"
        case .openSeat:    return "chevron.up.circle.fill"
        case .openTank:    return "fuelpump.fill"
        }
    }

    var tint: Color {
        switch self {
        case .unlock:      return SovietPalette.brass
        case .findVehicle: return SovietPalette.redBright
        default:           return SovietPalette.brassPale
        }
    }

    /// 需要二次确认的破坏性操作
    var needsConfirmation: Bool { self == .openSeat || self == .openTank }
}
