import Foundation

// MARK: - 油耗区间

/// 一段闭合的「加满 → 加满」统计区间。
/// 区间内消耗油量 = 区间中所有非加满加油 + 终点加满的升数
///（起点加满的升数不计——那是上一箱油的基准）。
public struct FuelSegment: Sendable, Equatable {
    public var startOdometer: Double
    public var endOdometer: Double
    public var liters: Double
    public var cost: Double
    public var endDate: Date

    public var distanceKm: Double { endOdometer - startOdometer }

    /// 百公里油耗 L/100km
    public var litersPer100km: Double {
        distanceKm > 0 ? liters / distanceKm * 100 : 0
    }

    /// 每公里燃油成本 元/km
    public var costPerKm: Double {
        distanceKm > 0 ? cost / distanceKm : 0
    }
}

// MARK: - 统计结果

public struct FuelStatistics: Sendable, Equatable {
    /// 已闭合的有效区间（时间升序）
    public var segments: [FuelSegment]

    /// 当前平均百公里油耗（按里程加权：Σ升数 / Σ里程 × 100）
    public var averageLitersPer100km: Double?

    /// 当前每公里燃油成本（Σ区间花费 / Σ区间里程）
    public var averageCostPerKm: Double?

    /// 累计燃油支出（含未闭合区间与断点记录——钱是真金白银花出去的）
    public var totalCost: Double

    /// 累计加注升数（口径同 totalCost）
    public var totalLiters: Double

    /// 最近一次闭合区间相对上一段的能耗趋势
    public var trend: Trend?

    /// 当前未闭合区间的中间态（锚点之后的累计，供 UI 展示"本箱油已计"）
    public var pendingLiters: Double
    public var pendingCost: Double
    public var pendingDistance: Double

    public enum Trend: Sendable, Equatable {
        /// 油耗下降（更省），delta 为下降量 L/100km
        case improved(delta: Double)
        /// 油耗上升（更费），delta 为上升量 L/100km
        case worsened(delta: Double)
        /// 变化小于 0.05 L/100km 视为持平
        case steady

        public static let steadyThreshold = 0.05
    }

    public static let empty = FuelStatistics(
        segments: [],
        averageLitersPer100km: nil,
        averageCostPerKm: nil,
        totalCost: 0,
        totalLiters: 0,
        trend: nil,
        pendingLiters: 0,
        pendingCost: 0,
        pendingDistance: 0
    )
}

// MARK: - 油耗统计器

/// 纯函数引擎：输入任意顺序的加油记录，输出统计结果。
/// 不依赖 SwiftData 上下文，可单测。
///
/// 锚定规则：
/// 1. 「加满」记录成为新锚点（满箱基准），其升数滚入**上一段**消耗，不滚入下一段。
/// 2. 「断点」记录作废此前未闭合的累计；若断点本身加满，则它直接成为新锚点。
/// 3. 无锚点时的非加满记录无法归属区间，只计入总支出，不进油耗。
/// 4. 里程倒挂（odometer 回退）视为脏数据：该段丢弃，但仍重新锚定。
public enum FuelCalculationEngine {

    public static func statistics(for entries: [FuelEntry]) -> FuelStatistics {
        // 按里程排序比按日期更稳：日期可改，仪表里程单调递增
        let sorted = entries
            .filter { $0.odometer > 0 && $0.liters >= 0 }
            .sorted { $0.odometer < $1.odometer }

        guard !sorted.isEmpty else { return .empty }

        var segments: [FuelSegment] = []
        var anchor: FuelEntry?
        var accLiters = 0.0
        var accCost = 0.0

        for entry in sorted {
            if entry.isBreakpoint {
                // 断点：此前未闭合的区间整体作废，重新锚定
                anchor = entry.isFullTank ? entry : nil
                accLiters = 0
                accCost = 0
                continue
            }

            if entry.isFullTank {
                if let a = anchor, entry.odometer > a.odometer {
                    segments.append(FuelSegment(
                        startOdometer: a.odometer,
                        endOdometer: entry.odometer,
                        liters: accLiters + entry.liters,
                        cost: accCost + entry.cost,
                        endDate: entry.date
                    ))
                }
                // 无论是否闭合成段，本次加满都成为新锚点
                anchor = entry
                accLiters = 0
                accCost = 0
            } else if anchor != nil {
                // 非加满：只有已锚定才计入区间累计
                accLiters += entry.liters
                accCost += entry.cost
            }
        }

        // 聚合（按里程加权，而非各段算术平均——长区间话语权更大）
        let totalSegLiters = segments.reduce(0) { $0 + $1.liters }
        let totalSegCost   = segments.reduce(0) { $0 + $1.cost }
        let totalSegDist   = segments.reduce(0) { $0 + $1.distanceKm }

        let trend: FuelStatistics.Trend? = {
            guard segments.count >= 2 else { return nil }
            let last = segments[segments.count - 1].litersPer100km
            let prev = segments[segments.count - 2].litersPer100km
            let delta = last - prev
            if abs(delta) < FuelStatistics.Trend.steadyThreshold { return .steady }
            return delta < 0 ? .improved(delta: -delta) : .worsened(delta: delta)
        }()

        return FuelStatistics(
            segments: segments,
            averageLitersPer100km: totalSegDist > 0 ? totalSegLiters / totalSegDist * 100 : nil,
            averageCostPerKm: totalSegDist > 0 ? totalSegCost / totalSegDist : nil,
            totalCost: sorted.reduce(0) { $0 + $1.cost },
            totalLiters: sorted.reduce(0) { $0 + $1.liters },
            trend: trend,
            pendingLiters: accLiters,
            pendingCost: accCost,
            pendingDistance: anchor.map { a in max(0, (sorted.last?.odometer ?? a.odometer) - a.odometer) } ?? 0
        )
    }
}
