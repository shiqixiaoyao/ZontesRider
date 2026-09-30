// 协议解析离线自检（不联网、不装模拟器，十几秒跑完）
//
// 为什么要有这个：
//   2026-09-30 车况页 100% 报 `KeyNotFound: Key 'code' ... Path: data`，
//   根因是 `getHomeData` 把泛型实参写成了 `Envelope<HomeDataPayload>`，
//   与 `perform` 内部的包膜叠加成「双层包膜」。这种错误编译器不会拦（两层都是 Decodable），
//   真机上才炸，而且要在手机上装包 → 登录 → 才发现，一轮就是十几分钟。
//
//   这里用真实抓取、脱敏后的响应接上 URLProtocol 打桩，把 **真实的客户端代码路径**
//   （perform → decodePayload → DTO）完整跑一遍并断言字段值。
//   于是同一类事故在 CI 上十几秒就能拦住。
//
// 编译运行（CI 里就是这么跑的）：
//   swiftc -swift-version 5 -parse-as-library \
//     ZontesRider/Model/VehicleTelemetry.swift \
//     ZontesRider/Model/TrackPoint.swift \
//     ZontesRider/Services/Net/IfinoAPI.swift \
//     ZontesRider/Services/Store/LocalStore.swift \
//     Tools/decode_check/main.swift -o /tmp/decode_check
//   /tmp/decode_check Tools/decode_check/Fixtures

import Foundation

// MARK: - 结果统计

final class Report {
    static let shared = Report()
    private(set) var passed = 0
    private(set) var failed = 0
    private var failures: [String] = []

    func ok(_ what: String, _ detail: String = "") {
        passed += 1
        print("  ✅ \(what)\(detail.isEmpty ? "" : " · \(detail)")")
    }

    func fail(_ what: String, _ detail: String = "") {
        failed += 1
        failures.append(what)
        print("  ❌ \(what)\(detail.isEmpty ? "" : " · \(detail)")")
    }

    func expect(_ condition: Bool, _ what: String, _ detail: String = "") {
        condition ? ok(what, detail) : fail(what, detail)
    }

    func expectEq<T: Equatable>(_ actual: T?, _ expected: T, _ what: String) {
        if let actual, actual == expected {
            ok(what, "= \(actual)")
        } else {
            fail(what, "得到 \(String(describing: actual))，期望 \(expected)")
        }
    }

    func summary() -> Int32 {
        print("")
        print(String(repeating: "=", count: 60))
        print("通过 \(passed) 项，失败 \(failed) 项")
        if !failures.isEmpty {
            print("失败清单：")
            for f in failures { print("  · \(f)") }
        }
        print(String(repeating: "=", count: 60))
        return failed == 0 ? 0 : 1
    }
}

// MARK: - URLProtocol 打桩（把真实抓取的响应喂给真实客户端）

final class FixtureProtocol: URLProtocol {
    static var responder: ((URLRequest) -> (Int, Data))?
    private(set) static var hitPaths: [String] = []

    static func reset() { hitPaths = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        FixtureProtocol.hitPaths.append(request.url?.path ?? "?")
        guard let responder = FixtureProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, body) = responder(request)
        guard let url = request.url,
              let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                         headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - 工具

let report = Report.shared

func json(_ text: String) -> Data { Data(text.utf8) }

func loadFixture(_ dir: String, _ name: String) -> Data {
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
    guard let data = try? Data(contentsOf: url), !data.isEmpty else {
        report.fail("读取 fixture \(name)", url.path)
        return Data("{}".utf8)
    }
    return data
}

func section(_ title: String) {
    print("")
    print("── \(title) ──")
}

func makeClient() -> IfinoAPIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureProtocol.self]
    return IfinoAPIClient(session: URLSession(configuration: config))
}

func failDetail(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
}

// MARK: - 主体

@main
struct DecodeCheck {
    static func main() async {
        // 别让自检往 ~/Documents 里写网络留档
        _ = setenv("ZR_TRACE_OFF", "1", 1)

        let dir = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : FileManager.default.currentDirectoryPath + "/Tools/decode_check/Fixtures"

        print("fixture 目录：\(dir)")
        let loginBody = loadFixture(dir, "login.json")
        let listBody = loadFixture(dir, "motorlist.json")
        let homeBody = loadFixture(dir, "homedata.json")
        let trackBody = loadFixture(dir, "track.json")

        let client = makeClient()

        // ── 1. 登录 ────────────────────────────────────────────────
        section("登录（data.user 里也有一个 code，用来确认包膜只解一层）")
        FixtureProtocol.responder = { _ in (200, loginBody) }
        do {
            let token = try await client.login(usercode: "15300000000", password: "x")
            report.expectEq(token.accessToken, "eyJhbGciOiJSUzI1NiJ9.SANITIZED.fake-signature-for-local-tests",
                            "accessToken")
            report.expect(token.refreshToken != nil, "refreshToken")
        } catch {
            report.fail("login", failDetail(error))
        }

        // ── 1b. refreshToken 续期（保持登录状态的关键路径）─────────
        section("refreshToken 续期（token 过期不掉登录）")
        let refreshBody = loadFixture(dir, "refresh.json")
        FixtureProtocol.responder = { _ in (200, refreshBody) }
        do {
            let p = try await client.refreshToken("SANITIZED-REFRESH-TOKEN")
            report.expectEq(p.accessToken, "eyJhbGciOiJSUzI1NiJ9.SANITIZED.fake-refreshed-token",
                            "新 accessToken")
            report.expect(p.refreshToken != nil, "轮换 refreshToken")
        } catch {
            report.fail("refreshToken", failDetail(error))
        }

        // ── 2. 车辆列表 ────────────────────────────────────────────
        section("车辆列表（pkecode 全小写 / 字符串型胎压额定值）")
        FixtureProtocol.responder = { _ in (200, listBody) }
        do {
            let list = try await client.getMyMotorList(token: "t")
            report.expectEq(list.count, 1, "车辆条数")
            report.expectEq(list.first?.pkeCode, "864918000000000", "pkecode 解析")
            report.expectEq(list.first?.motorName, "175V特黑（国Ⅳ）", "itemName")
            report.expectEq(list.first?.frameNumber, "LD3THL5B4T0000000", "cheJia")
            report.expect(list.first?.plateNumber == nil, "liencePlate（空串按无牌处理）")
            report.expectEq(list.first?.serviceEndTime, "2031-07-26 17:08:38", "serviceValidTime")
            report.expect(list.first?.isShowOilTankAndSeatCushion == true, "坐垫/油箱能力位")
        } catch {
            report.fail("getMyMotorList", failDetail(error))
        }

        // ── 3. 车况（本次线上事故的正主）────────────────────────────
        section("实时车况 getHomeData（回归：绝不能再出现 Key 'code' @ data）")
        FixtureProtocol.responder = { _ in (200, homeBody) }
        do {
            let t = try await client.getHomeData(pkeCode: "864918000000000", token: "t")
            report.ok("getHomeData 解包成功（双层包膜事故已修复）")
            report.expectEq(t.batteryVoltage, 13.4, "电压 134 → 13.4V")
            report.expectEq(t.fuelPercent, 100, "油量")
            report.expectEq(t.rangeKm, 453, "续航")
            report.expectEq(t.odometerKm, 1289.0, "总里程")
            report.expectEq(t.frontTireKpa, 93, "前胎压（服务端下发字符串 \"093\"）")
            report.expectEq(t.rearTireKpa, 112, "后胎压")
            report.expectEq(t.frontTireRated, 195, "前胎额定")
            report.expectEq(t.rearTireRated, 230, "后胎额定")
            report.expectEq(t.satelliteCount, 33, "卫星数")
            report.expectEq(t.tboxSignal, 5, "T-Box 信号")
            report.expect(t.lockState == .unlocked, "锁状态")
            report.expect(t.speedKmh == nil, "哨兵车速 1000000 必须被过滤")
            report.expect(t.location?.isValid == true, "定位有效",
                          t.location.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) } ?? "nil")
        } catch {
            report.fail("getHomeData", failDetail(error))
        }

        // ── 4. 轨迹 ────────────────────────────────────────────────
        section("历史轨迹（odomileages 是 0.1km、voltage 是 0.1V）")
        FixtureProtocol.responder = { _ in (200, trackBody) }
        do {
            let cal = Calendar.current
            let start = cal.startOfDay(for: Date())
            let end = start.addingTimeInterval(60 * 60 * 23)
            let pts = try await client.getTrack(carCode: "864918000000000",
                                                startTime: start, endTime: end, token: "t")
            report.expectEq(pts.count, 40, "点位数")
            report.expectEq(pts.first?.odometer, 1135.0, "里程 11350 → 1135.0km")
            report.expectEq(pts.first?.voltage, 14.9, "电压 149 → 14.9V")
            report.expectEq(pts.first?.speed, 23.0, "车速")
            report.expectEq(pts.first?.isLocked, true, "锁状态")
            report.expect(pts.first?.timestamp != nil, "时间戳解析")
            let stats = TrackStats(points: pts)
            report.expectEq(stats.pointCount, 40, "统计 · 点数")
            report.expect(stats.distanceKm > 0, "统计 · 里程累计", String(format: "%.3f km", stats.distanceKm))
        } catch {
            report.fail("getTrack", failDetail(error))
        }

        // ── 5. 包膜容错 ────────────────────────────────────────────
        section("包膜容错（网关形态漂移时不许整条链路打死）")
        let payload = #"{"myCarData":{"voltage":120,"oil":50},"carLocation":{"latitude":1.5,"longitude":2.5}}"#

        if let t = try? IfinoAPIClient.decodePayload(HomeDataPayload.self,
                                                     from: json(#"{"code":"200","msg":"ok","data":\#(payload)}"#)) {
            report.expectEq(t.myCarData?.voltage, 120, "code 是字符串 \"200\"")
        } else {
            report.fail("code 是字符串 \"200\"")
        }

        if let t = try? IfinoAPIClient.decodePayload(HomeDataPayload.self,
                                                     from: json(#"{"msg":"ok","data":\#(payload)}"#)) {
            report.expectEq(t.myCarData?.oil, 50, "缺 code 但有 data")
        } else {
            report.fail("缺 code 但有 data")
        }

        if let t = try? IfinoAPIClient.decodePayload(HomeDataPayload.self, from: json(payload)) {
            report.expectEq(t.carLocation?.longitude, 2.5, "完全没有包膜")
        } else {
            report.fail("完全没有包膜")
        }

        // ── 6. 报错信息必须是人话 ──────────────────────────────────
        section("报错信息可读性（下次排障不许再靠猜）")
        FixtureProtocol.responder = { _ in (200, json(#"{"code":200,"msg":"请求成功","data":{"istate":"1"}}"#)) }
        do {
            _ = try await client.getHomeData(pkeCode: "864918000000000", token: "t")
            report.fail("缺 myCarData 必须报错")
        } catch {
            let d = failDetail(error)
            report.expect(d.contains("myCarData"), "缺车况时报错指明字段", d)
        }

        FixtureProtocol.responder = { _ in (200, json(#"{"code":401,"msg":"token 已失效"}"#)) }
        do {
            _ = try await client.getMyMotorList(token: "t")
            report.fail("code 401 必须抛 unauthorized")
        } catch let e as IfinoError {
            if case .unauthorized = e { report.ok("code 401 → unauthorized（触发重新登录）") }
            else { report.fail("code 401 → unauthorized", "\(e)") }
        } catch {
            report.fail("code 401 → unauthorized", "\(error)")
        }

        FixtureProtocol.responder = { _ in (200, json("<html>502 Bad Gateway</html>")) }
        do {
            _ = try await client.getMyMotorList(token: "t")
            report.fail("非 JSON 必须给出可读错误")
        } catch {
            let d = failDetail(error)
            report.expect(d.contains("不是合法 JSON") && d.contains("原始响应"),
                          "非 JSON 报错带原文片段", d)
        }

        // ── 7. 请求路径核对 ────────────────────────────────────────
        section("请求路径")
        FixtureProtocol.reset()
        FixtureProtocol.responder = { _ in (200, homeBody) }
        _ = try? await client.getHomeData(pkeCode: "864918000000000", token: "t")
        report.expect(FixtureProtocol.hitPaths.contains { $0.hasSuffix("/pkeapp/gx/pke/carData/getHomeData") },
                      "getHomeData 路径", FixtureProtocol.hitPaths.last ?? "?")

        exit(report.summary())
    }
}
