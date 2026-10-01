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
            // 胎压标定：服务端 "093"/"112" 单位是额定/区间单位的 1/2 → ×2 = 186 / 224
            report.expectEq(t.frontTireKpa, 186, "前胎压（\"093\" ×2 标定）")
            report.expectEq(t.rearTireKpa, 224, "后胎压（\"112\" ×2 标定）")
            report.expectEq(t.frontTireRated, 195, "前胎额定")
            report.expectEq(t.rearTireRated, 230, "后胎额定")
            // 服务端下发正常区间（前 155~255 / 后 190~290）—— 胎压告警的权威判据
            report.expectEq(t.frontTireRangeLow, 155, "前胎正常下限")
            report.expectEq(t.frontTireRangeHigh, 255, "前胎正常上限")
            report.expectEq(t.rearTireRangeLow, 190, "后胎正常下限")
            report.expectEq(t.rearTireRangeHigh, 290, "后胎正常上限")
            // 标定后 186/224 落在服务端区间内 → 不应误报「气压偏低」（这正是用户说的「不准」）
            report.expect(!t.isFrontTireLow, "前胎压 186 在区间内，不误报偏低")
            report.expect(!t.isRearTireLow, "后胎压 224 在区间内，不误报偏低")
            report.expect(t.frontTireRangeText == "155~255", "区间文本")
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

        // ── 8. 蓝牙帧语法（控车协议，2026-10-01 反汇编补挖后钉死） ────
        //
        // 这一段拦的是「编译器拦不住、只能装到手机才发现」的协议类 bug：
        // 帧前缀 / 握手帧 / 应答判定一旦被改错，App 在车上只会显示「车机无应答」，
        // 而真实原因藏在帧格式里。这里把反汇编得出的**硬格式**写成断言。
        section("蓝牙控车帧语法（Lmfa / Luk0 反汇编）")

        // ① prime 握手帧：StringBuilder("*BT,") + pke + ",10,001,7#"
        report.expectEq(ControlPrime.frame(pkeCode: "864918000000000"),
                        "*BT,864918000000000,10,001,7#",
                        "prime 帧格式")

        // ② 明文指令帧：前缀带逗号，pke 后接 `#`
        report.expectEq(PlaintextCommand.unlock.frame(pkeCode: "ABC"),
                        "*UClear,ABC#", "解锁帧")
        report.expectEq(PlaintextCommand.lock.frame(pkeCode: "ABC"),
                        "*ULoc,ABC#", "上锁帧")
        report.expectEq(PlaintextCommand.find.frame(pkeCode: "ABC"),
                        "*UF,ABC#", "寻车帧")
        report.expectEq(PlaintextCommand.freeze.frame(pkeCode: "ABC"),
                        "*UFreeze,ABC#", "设防帧")
        report.expectEq(PlaintextCommand.refresh.frame(pkeCode: "ABC"),
                        "*RE,ABC#", "刷新帧")
        // 9 条指令的前缀一个都不许改（Lmfa.a 的 9 个 case 逐一验算过 hashCode）
        let prefixes = PlaintextCommand.allCases.map(\.rawValue)
        report.expectEq(prefixes.count, 9, "指令表条数")
        report.expect(prefixes.allSatisfy { $0.hasPrefix("*") && !$0.hasSuffix(",") },
                      "前缀不带尾部逗号（组帧时自己加）", prefixes.joined(separator: " "))

        // ③ AT 参数通道：**换行**结尾，不是 `#`（最容易搞混的一条）
        report.expect(ATCommand.readParam.hasSuffix("\n") && !ATCommand.readParam.contains("#"),
                      "AT 帧用换行结尾", ATCommand.readParam.debugDescription)
        report.expectEq(ATCommand.setParam5("1"), "AT+SET_PARAM=5,1\n", "AT+SET_PARAM 组帧")
        report.expectEq(ATCommand.setRGB("FF0000"), "AT+SET_RGB=FF0000\n", "AT+SET_RGB 组帧")

        // ④ 应答判定：,OK# 成功；,FAIL# / 首段 0# 失败；*BR,1# 是主动上报不是应答
        if case .ok = FrameParser.verdict(of: "*UClear,ABC,OK#") {
            report.ok("应答 ,OK# → 成功")
        } else {
            report.fail("应答 ,OK# → 成功", "判定错成 \(FrameParser.verdict(of: "*UClear,ABC,OK#"))")
        }
        if case .fail = FrameParser.verdict(of: "*UClear,ABC,FAIL#") {
            report.ok("应答 ,FAIL# → 失败")
        } else {
            report.fail("应答 ,FAIL# → 失败")
        }
        if case .fail = FrameParser.verdict(of: "0#,0#") {
            report.ok("首段 0# → 失败")
        } else {
            report.fail("首段 0# → 失败")
        }
        if case .unsolicited = FrameParser.verdict(of: "*BR,1#") {
            report.ok("主动上报 *BR,1# 不当作应答")
        } else {
            report.fail("主动上报 *BR,1# 不当作应答")
        }
        // 关键**反向**断言：普通指令应答绝不能被判成 ready ack，
        // 否则「等 ready ack」会把指令的 ACK 吞掉，指令必然超时。
        report.expect(!FrameParser.isReadyAck(of: "*UClear,ABC,OK#"),
                      "指令 ACK 不会被误认成 ready ack")
        report.expect(FrameParser.isReadyAck(of: "*BT,ABC,10,001,7#"),
                      "带 7 字段的帧 = ready ack")
        // 第 5 段非空才算「安全响应」token；短帧不许瞎报
        let shortToken: String? = FrameParser.secureToken(of: "*BT,ABC,10,001,7#")
        report.expect(shortToken == nil, "4 段帧没有 token", String(describing: shortToken))
        report.expectEq(FrameParser.secureToken(of: "*BT,ABC,10,008,AB12CD#"), "AB12CD",
                        "第 5 段 = token（大写去 #）")

        exit(report.summary())
    }
}
