import SwiftUI
import SwiftData
import UIKit

// MARK: - 机械圆盘仪表（拖拉机 / 装甲机械读数盘）

/// 240° 扫掠表盘：黑色盘面、黄铜刻度、红针、中心金色大读数。
public struct MechanicalGauge: View {
    let title: String
    let valueText: String
    let caption: String
    /// 0...1，映射到 -120°...120° 扫掠角
    let needleFraction: Double

    public init(title: String, valueText: String, caption: String, needleFraction: Double) {
        self.title = title
        self.valueText = valueText
        self.caption = caption
        self.needleFraction = needleFraction
    }

    private var needleAngle: Double {
        -120 + min(max(needleFraction, 0), 1) * 240
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(SovietPalette.steelDark)
            Circle()
                .stroke(SovietPalette.black, lineWidth: 4)
            Circle()
                .stroke(SovietPalette.brass, lineWidth: 1.5)
                .padding(10)

            // 刻度：25 根，每 6 根一根主刻度
            ForEach(0..<25, id: \.self) { i in
                Rectangle()
                    .fill(SovietPalette.brass)
                    .frame(width: i % 6 == 0 ? 3 : 1.5, height: i % 6 == 0 ? 12 : 7)
                    .offset(y: -72)
                    .rotationEffect(.degrees(-120 + Double(i) * 10))
            }

            // 红针
            Rectangle()
                .fill(SovietPalette.redBright)
                .frame(width: 4, height: 56)
                .offset(y: -28)
                .rotationEffect(.degrees(needleAngle))
                .animation(.easeOut(duration: 0.5), value: needleFraction)

            // 轴心
            Circle()
                .fill(SovietPalette.brass)
                .frame(width: 16, height: 16)
                .overlay { Circle().stroke(SovietPalette.black, lineWidth: 2) }

            // 中心读数
            VStack(spacing: 2) {
                Spacer()
                Text(valueText)
                    .font(.soviet(30))
                    .foregroundStyle(SovietPalette.brass)
                Text(caption)
                    .font(.soviet(11))
                    .tracking(2)
                    .foregroundStyle(SovietPalette.textMuted)
                    .padding(.bottom, 26)
            }

            // 表名
            VStack {
                Text(title)
                    .font(.soviet(10))
                    .tracking(3)
                    .foregroundStyle(SovietPalette.textMuted)
                    .padding(.top, 24)
                Spacer()
            }
        }
        .frame(width: 200, height: 200)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(valueText) \(caption)")
    }
}

// MARK: - 重工业输入框

private struct SovietField: View {
    let label: String
    let unit: String
    @Binding var text: String
    var placeholder: String = "0"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.soviet(11))
                .tracking(1)
                .foregroundStyle(SovietPalette.brass)
            HStack(alignment: .firstTextBaseline) {
                TextField(placeholder, text: $text)
                    .keyboardType(.decimalPad)
                    .font(.soviet(20))
                    .foregroundStyle(SovietPalette.brassPale)
                    .tint(SovietPalette.brass)
                Spacer()
                Text(unit)
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textFaint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .constructivistCard(cut: 8)
    }
}

// MARK: - 能耗仪表盘（统计 + 补给登记）

public struct FuelTrackerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FuelEntry.odometer, order: .reverse) private var entries: [FuelEntry]

    @State private var odometerText = ""
    @State private var litersText = ""
    @State private var costText = ""
    @State private var isFullTank = true
    @State private var isBreakpoint = false
    @State private var showValidation = false

    public init() {}

    private var stats: FuelStatistics {
        FuelCalculationEngine.statistics(for: entries)
    }

    public var body: some View {
        ZStack {
            SovietPalette.castIron.ignoresSafeArea()

            VStack(spacing: 0) {
                HazardStripes()
                SovietBanner("能耗仪表盘")

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        gaugeSection
                        costCards
                        formSection
                        archiveSection
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                }

                HazardStripes()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if odometerText.isEmpty, let latest = entries.first {
                odometerText = String(format: "%.1f", latest.odometer)
            }
        }
        .alert("参数校验失败", isPresented: $showValidation) {
            Button("明白", role: .cancel) {}
        } message: {
            Text("里程、升数、金额必须为有效数字，且里程与升数须大于 0。")
        }
    }

    // MARK: 仪表区

    private var gaugeSection: some View {
        VStack(spacing: 8) {
            MechanicalGauge(
                title: "百公里油耗",
                valueText: stats.averageLitersPer100km.map({ String(format: "%.2f", $0) }) ?? "--.--",
                caption: "L / 100KM",
                needleFraction: stats.averageLitersPer100km.map({ ($0 - 1.5) / (6.0 - 1.5) }) ?? 0
            )

            HStack(spacing: 6) {
                Circle()
                    .fill(trendColor)
                    .frame(width: 9, height: 9)
                    .overlay { Circle().stroke(SovietPalette.redDark, lineWidth: 1.5) }
                Text(trendText)
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.brassPale)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(SovietPalette.steelLight)
            .border(SovietPalette.black, width: 2)
        }
        .frame(maxWidth: .infinity)
    }

    private var trendText: String {
        switch stats.trend {
        case .improved(let d): return "较上段 ↓ \(String(format: "%.2f", d)) L"
        case .worsened(let d): return "较上段 ↑ \(String(format: "%.2f", d)) L"
        case .steady:          return "与上段持平"
        case nil:              return "数据积累中 · 需两段加满"
        }
    }

    private var trendColor: Color {
        switch stats.trend {
        case .improved: return SovietPalette.brass
        case .worsened: return SovietPalette.redBright
        case .steady, nil: return SovietPalette.leverGrey
        }
    }

    // MARK: 成本读数卡

    private var costCards: some View {
        HStack(spacing: 10) {
            costCard(
                label: "每公里战备消耗",
                value: stats.averageCostPerKm.map({ String(format: "¥%.3f", $0) }) ?? "¥--",
                unit: "/km"
            )
            costCard(
                label: "累计燃油支出",
                value: String(format: "¥%.2f", stats.totalCost),
                unit: "CNY"
            )
        }
    }

    private func costCard(label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.soviet(11))
                .tracking(1)
                .foregroundStyle(SovietPalette.textMuted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.soviet(20))
                    .foregroundStyle(SovietPalette.brass)
                Text(unit)
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .constructivistCard(cut: 10)
    }

    // MARK: 补给登记站

    private var formSection: some View {
        VStack(spacing: 10) {
            SovietSectionLabel("补给登记站")

            SovietField(label: "仪表总里程 / KM", unit: "KM", text: $odometerText)

            HStack(spacing: 10) {
                SovietField(label: "加注量 / L", unit: "L", text: $litersText)
                SovietField(label: "金额 / ¥", unit: "CNY", text: $costText)
            }

            Toggle(isOn: $isFullTank) {
                Text("加满 FULL TANK")
            }
            .toggleStyle(.industrial)

            Toggle(isOn: $isBreakpoint) {
                Text("断点重置 BREAK")
            }
            .toggleStyle(.industrial)

            Button {
                register()
            } label: {
                Text("登记入库")
            }
            .buttonStyle(.heavyMetal)

            HStack {
                Text("档案编号 № \(String(format: "%04d", entries.count + 1))")
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textFaint)
                Spacer()
                RedStarSeal()
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: 补给档案列表

    private var archiveSection: some View {
        VStack(spacing: 8) {
            SovietSectionLabel("补给档案")

            if entries.isEmpty {
                Text("尚无补给记录 · 等待首次登记")
                    .font(.soviet(12))
                    .foregroundStyle(SovietPalette.textFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(SovietPalette.steelLight)
                    .border(SovietPalette.black, width: 2)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.prefix(8).enumerated()), id: \.element.persistentModelID) { index, entry in
                        archiveRow(entry)
                            .background(index % 2 == 0 ? SovietPalette.steelLight : SovietPalette.castIron)
                        if index < min(entries.count, 8) - 1 {
                            Rectangle().fill(SovietPalette.black).frame(height: 1)
                        }
                    }
                }
                .border(SovietPalette.black, width: 2)
            }
        }
    }

    private func archiveRow(_ entry: FuelEntry) -> some View {
        HStack {
            Text(entry.date, format: .dateTime.month(.twoDigits).day(.twoDigits))
                .font(.soviet(12))
                .foregroundStyle(SovietPalette.brassPale)
            Text(entry.isBreakpoint ? "断点" : (entry.isFullTank ? "加满" : "补加"))
                .font(.soviet(11))
                .foregroundStyle(entry.isBreakpoint ? SovietPalette.textFaint : SovietPalette.brass)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay {
                    Rectangle().stroke(
                        entry.isBreakpoint ? SovietPalette.textFaint : SovietPalette.brass,
                        lineWidth: 1
                    )
                }
            Spacer()
            if entry.isBreakpoint {
                Text("-- 不计入 --")
                    .font(.soviet(12))
                    .foregroundStyle(SovietPalette.textFaint)
            } else {
                Text(String(format: "%.1fL · ¥%.1f", entry.liters, entry.cost))
                    .font(.soviet(12))
                    .foregroundStyle(SovietPalette.brass)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: 登记动作

    private func register() {
        guard let odo = Double(odometerText), odo > 0,
              let liters = Double(litersText), liters > 0,
              let cost = Double(costText), cost >= 0 else {
            showValidation = true
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }

        let entry = FuelEntry(
            odometer: odo,
            liters: liters,
            cost: cost,
            isFullTank: isFullTank,
            isBreakpoint: isBreakpoint
        )
        modelContext.insert(entry)

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        litersText = ""
        costText = ""
        isFullTank = true
        isBreakpoint = false
        // 里程保留：下一次加油大概率在同一块表上累加
    }
}

// MARK: - 预览

#Preview("苏维埃 · 完整档案") {
    FuelTrackerView()
        .modelContainer(FuelEntry.previewContainer)
}

#Preview("空档案") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: FuelEntry.self, configurations: config)
    return FuelTrackerView()
        .modelContainer(container)
}

#Preview("仅一条加满（无闭合段）") {
    FuelTrackerView()
        .modelContainer(FuelEntry.makePreviewContainer(entries: [
            FuelEntry(odometer: 1000.0, liters: 8.0, cost: 66.40, isFullTank: true)
        ]))
}
