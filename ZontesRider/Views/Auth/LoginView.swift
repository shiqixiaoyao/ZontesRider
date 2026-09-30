import SwiftUI
import UIKit

// MARK: - 我的工段（未登录 → 登录门岗；已登录 → 车辆档案）

public struct ProfileView: View {
    @Environment(AuthStore.self) private var auth

    public init() {}

    public var body: some View {
        if auth.isLoggedIn {
            VehicleProfileView()
        } else {
            LoginView()
        }
    }
}

// MARK: - 登录门岗

public struct LoginView: View {
    @Environment(AuthStore.self) private var auth

    @State private var usercode = ""
    @State private var password = ""
    @State private var showPassword = false
    @FocusState private var focus: Field?

    private enum Field { case user, pass }

    public init() {}

    public var body: some View {
        ZStack {
            SovietPalette.castIron.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    SovietBanner("门岗登记")

                    VStack(spacing: 18) {
                        RedStarSeal(size: 64)
                            .padding(.top, 26)

                        Text("升仕云端 · ifino 接入")
                            .font(.soviet(12))
                            .foregroundStyle(SovietPalette.textMuted)
                            .tracking(2)

                        // 账号
                        SovietField(label: "军籍编号 / 账号") {
                            TextField("手机号", text: $usercode)
                                .keyboardType(.phonePad)
                                .textContentType(.username)
                                .focused($focus, equals: .user)
                                .submitLabel(.next)
                                .onSubmit { focus = .pass }
                        }

                        // 密码
                        SovietField(label: "通行密令 / 密码") {
                            HStack(spacing: 8) {
                                Group {
                                    if showPassword {
                                        TextField("密码", text: $password)
                                    } else {
                                        SecureField("密码", text: $password)
                                    }
                                }
                                .textContentType(.password)
                                .focused($focus, equals: .pass)
                                .submitLabel(.go)
                                .onSubmit { submit() }

                                Button {
                                    showPassword.toggle()
                                } label: {
                                    Image(systemName: showPassword ? "eye.slash" : "eye")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(SovietPalette.textMuted)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // 错误告示
                        if let err = auth.lastError, !err.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(SovietPalette.danger)
                                Text(err)
                                    .font(.soviet(11))
                                    .foregroundStyle(SovietPalette.danger)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(10)
                            .background(SovietPalette.danger.opacity(0.12))
                            .border(SovietPalette.danger, width: 2)
                        }

                        // 登录推杆
                        Button(action: submit) {
                            HStack(spacing: 8) {
                                if auth.state == .loggingIn {
                                    ProgressView().tint(SovietPalette.brass)
                                }
                                Text(auth.state == .loggingIn ? "核验中…" : "验 证 通 行")
                                    .font(.soviet(15))
                                    .tracking(4)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(HeavyMetalButtonStyle())
                        .disabled(usercode.isEmpty || password.isEmpty || auth.state == .loggingIn)
                        .opacity(usercode.isEmpty || password.isEmpty ? 0.5 : 1)

                        Text("凭证仅存于本机钥匙串\n直连 www.ifino.com:8081 官方网关")
                            .font(.soviet(10))
                            .foregroundStyle(SovietPalette.textFaint)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .padding(.bottom, 24)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
    }

    private func submit() {
        guard !usercode.isEmpty, !password.isEmpty, auth.state != .loggingIn else { return }
        focus = nil
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        Task { await auth.login(usercode: usercode, password: password) }
    }
}

// MARK: - 车辆档案（已登录）

public struct VehicleProfileView: View {
    @Environment(AuthStore.self) private var auth
    @State private var confirmLogout = false

    public init() {}

    public var body: some View {
        ZStack {
            SovietPalette.castIron.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    SovietBanner("车辆档案")

                    VStack(spacing: 16) {
                        // 账号牌
                        HStack(spacing: 12) {
                            RedStarSeal(size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(auth.usercode ?? "—")
                                    .font(.soviet(16))
                                    .foregroundStyle(SovietPalette.brass)
                                Text("已接入 ifino 云端")
                                    .font(.soviet(10))
                                    .foregroundStyle(SovietPalette.textMuted)
                            }
                            Spacer()
                            Circle()
                                .fill(SovietPalette.ok)
                                .frame(width: 10, height: 10)
                        }
                        .padding(14)
                        .constructivistCard()
                        .padding(.top, 20)

                        // 车辆列表
                        if auth.vehicles.isEmpty {
                            Text("名下暂无绑定车辆")
                                .font(.soviet(12))
                                .foregroundStyle(SovietPalette.textMuted)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(auth.vehicles) { v in
                                vehicleCard(v)
                            }
                        }

                        // 启动诊断（自签包没有控制台，靠它定位闪退）
                        DiagnosticsCard()

                        // 退出
                        Button {
                            confirmLogout = true
                        } label: {
                            Text("注 销 通 行 证")
                                .font(.soviet(13))
                                .tracking(3)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(HeavyMetalButtonStyle(faceColor: SovietPalette.steel,
                                                           edgeColor: SovietPalette.black))
                        .padding(.top, 8)
                        .padding(.bottom, 28)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .refreshable { await auth.refreshVehicles() }
        }
        .alert("注销通行证", isPresented: $confirmLogout) {
            Button("取消", role: .cancel) {}
            Button("注销", role: .destructive) { auth.logout() }
        } message: {
            Text("将清除本机保存的登录凭证")
        }
        .preferredColorScheme(.dark)
    }

    private func vehicleCard(_ v: MotorVehicle) -> some View {
        let selected = auth.selectedPKECode == v.pkeCode
        return Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            auth.selectedPKECode = v.pkeCode
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(v.displayName)
                        .font(.soviet(16))
                        .foregroundStyle(SovietPalette.brass)
                    Spacer()
                    if selected {
                        Text("现役")
                            .font(.soviet(10))
                            .tracking(2)
                            .foregroundStyle(SovietPalette.castIron)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(SovietPalette.brass)
                    }
                }

                VStack(spacing: 6) {
                    profileRow("PKE 编号", v.pkeCode)
                    if let f = v.frameNumber, !f.isEmpty { profileRow("车架号", f) }
                    if let p = v.plateNumber, !p.isEmpty { profileRow("号牌", p) }
                    if let m = v.mcuID, !m.isEmpty { profileRow("MCU", m) }
                    if let t = v.serviceEndTime, !t.isEmpty { profileRow("服务至", t) }
                }
            }
            .padding(14)
            .constructivistCard(borderColor: selected ? SovietPalette.brass : SovietPalette.textFaint)
        }
        .buttonStyle(.plain)
    }

    private func profileRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
                .font(.soviet(11))
                .foregroundStyle(SovietPalette.textMuted)
            Spacer()
            Text(v)
                .font(.soviet(11))
                .foregroundStyle(SovietPalette.textPrimary)
                .lineLimit(1)
        }
    }
}

// MARK: - 启动诊断卡

/// 显示「上次启动走到哪一步」+ 落盘的异常原因。
/// 闪退后重新打开 App，进「我的」工段即可看到，把内容截图发我就能定位。
private struct DiagnosticsCard: View {
    @State private var showDetail = false

    private var phase: String { LaunchTrace.phase ?? "（无记录）" }
    private var crash: String? { LaunchTrace.crash }

    /// 装的是哪一版（XcodeGen 之前没把版本号写进 Info.plist，一直显示 SDK 默认的 1.0/1，
    /// 出问题时根本分不清用户手里是哪个包）
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    /// 机型与系统版本：闪退排查第一问就是「iOS 多少」
    private var systemInfo: String {
        "iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SovietSectionLabel("启动诊断")

            HStack {
                Text("App 版本")
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textMuted)
                Spacer()
                Text(appVersion)
                    .font(.soviet(11))
                    .monospacedDigit()
                    .foregroundStyle(SovietPalette.brassPale)
                    .lineLimit(1)
            }

            HStack {
                Text("系统环境")
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textMuted)
                Spacer()
                Text(systemInfo)
                    .font(.soviet(11))
                    .monospacedDigit()
                    .foregroundStyle(SovietPalette.brassPale)
                    .lineLimit(1)
            }

            HStack {
                Text("上次止于")
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textMuted)
                Spacer()
                Text(phase)
                    .font(.soviet(11))
                    .monospacedDigit()
                    .foregroundStyle(LaunchTrace.lastLaunchSurvived ? SovietPalette.ok : SovietPalette.danger)
                    .lineLimit(1)
            }

            if crash == nil {
                Text("未捕获到 NSException（若是 Swift 致命错误，看上面的阶段即可定位）")
                    .font(.soviet(9))
                    .foregroundStyle(SovietPalette.textFaint)
            } else {
                Button {
                    showDetail.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(showDetail ? "收起异常详情" : "展开上次异常详情")
                            .font(.soviet(11))
                        Spacer()
                    }
                    .foregroundStyle(SovietPalette.danger)
                }
                .buttonStyle(.plain)

                if showDetail {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(crash ?? "")
                            .font(.soviet(9))
                            .foregroundStyle(SovietPalette.textSecondary)
                    }
                    .frame(maxHeight: 160)

                    Button("清除记录") { LaunchTrace.clearCrash() }
                        .font(.soviet(10))
                        .foregroundStyle(SovietPalette.textMuted)
                }
            }
        }
        .padding(14)
        .constructivistCard(borderColor: SovietPalette.black)
    }
}

// MARK: - 苏维埃输入框

private struct SovietField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.soviet(10))
                .tracking(2)
                .foregroundStyle(SovietPalette.textMuted)
            content
                .font(.soviet(15))
                .foregroundStyle(SovietPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(SovietPalette.steelDark)
                .overlay(
                    BeveledShape(cut: 8)
                        .stroke(SovietPalette.brass, lineWidth: 2)
                )
                .clipShape(BeveledShape(cut: 8))
        }
    }
}

// MARK: - 预览

#Preview("登录门岗") {
    LoginView()
        .environment(AuthStore())
}

#Preview("我的工段") {
    ProfileView()
        .environment(AuthStore())
}
