import Foundation
import SwiftData

// MARK: - 补给档案（加油记录）

/// 一条加油记录。
/// - `isFullTank`：本次是否加满。只有"加满 → 加满"才能构成有效油耗区间。
/// - `isBreakpoint`：断点标记。历史里程缺失 / 漏记时打此标记，
///   该记录之前的未闭合区间整体作废，统计器从下一锚点重新起算。
@Model
public final class FuelEntry {
    public var date: Date
    public var odometer: Double      // 本次仪表累计总里程 km
    public var liters: Double        // 加油升数
    public var cost: Double          // 加油金额 元
    public var isFullTank: Bool
    public var isBreakpoint: Bool

    public init(
        date: Date = .now,
        odometer: Double,
        liters: Double,
        cost: Double,
        isFullTank: Bool = false,
        isBreakpoint: Bool = false
    ) {
        self.date = date
        self.odometer = odometer
        self.liters = liters
        self.cost = cost
        self.isFullTank = isFullTank
        self.isBreakpoint = isBreakpoint
    }

    /// 本次单价 元/升
    public var unitPrice: Double? {
        liters > 0 ? cost / liters : nil
    }
}

// MARK: - 预览样本

public extension FuelEntry {
    /// 含一次断点的六条样本：覆盖「正常区间」「断点作废」「重新锚定」三种路径。
    /// 段1：240km / 7.2L = 3.00 L/100km；段2：250km / 7.9L = 3.16 L/100km。
    static var samples: [FuelEntry] {
        let day: TimeInterval = 86_400
        let base = Date().addingTimeInterval(-27 * day)
        return [
            FuelEntry(date: base,                 odometer: 1000.0, liters: 8.0, cost: 66.40, isFullTank: true),
            FuelEntry(date: base + 7  * day,      odometer: 1240.0, liters: 7.2, cost: 59.60, isFullTank: true),
            FuelEntry(date: base + 13 * day,      odometer: 1390.0, liters: 5.0, cost: 42.00, isBreakpoint: true),
            FuelEntry(date: base + 20 * day,      odometer: 1400.0, liters: 9.1, cost: 74.80, isFullTank: true),
            FuelEntry(date: base + 24 * day,      odometer: 1520.0, liters: 3.2, cost: 26.50),
            FuelEntry(date: base + 27 * day,      odometer: 1650.0, liters: 4.7, cost: 38.90, isFullTank: true),
        ]
    }

    @MainActor
    static var previewContainer: ModelContainer {
        makePreviewContainer(entries: samples)
    }

    @MainActor
    static func makePreviewContainer(entries: [FuelEntry]) -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: FuelEntry.self, configurations: config)
        entries.forEach { container.mainContext.insert($0) }
        return container
    }
}
