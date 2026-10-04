import AppKit

enum SelfTest {
    static func run() -> Int {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        do {
            let claude = try ClaudeProvider.parse(
                Data("""
                {
                  "five_hour": {"utilization": 33, "resets_at": "2026-04-11T07:00:00Z"},
                  "seven_day": {"utilization": 13, "resets_at": "2026-04-17T00:59:59Z"},
                  "seven_day_opus": null
                }
                """.utf8),
                plan: "Pro"
            )
            check(claude.windows.map(\.label) == ["5 小时", "每周"], "claude labels")
            check(claude.tightest?.label == "5 小时", "claude tightest")
            check(Int(claude.windows[0].remainingPercent.rounded()) == 67, "claude remaining")

            let codex = try CodexProvider.parse(Data("""
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {"used_percent": 4, "limit_window_seconds": 604800, "reset_at": 1791599736},
                "secondary_window": null
              },
              "credits": {"has_credits": true, "balance": "62500"},
              "rate_limit_reset_credits": {"available_count": 2}
            }
            """.utf8))
            check(codex.plan == "Pro 200", "codex plan")
            check(codex.windows.map(\.label) == ["每周"], "codex window")
            check(codex.note == "点数 62,500 · 重置次数 2", "codex note \(codex.note ?? "nil")")

            let cursor = try CursorProvider.parse(Data("""
            {
              "membershipType": "ultra",
              "billingCycleEnd": "2026-10-16T14:48:02.000Z",
              "individualUsage": {"plan": {"autoPercentUsed": 19.9, "apiPercentUsed": 86.5, "totalPercentUsed": 22.1}}
            }
            """.utf8), membership: nil)
            check(cursor.plan == "Ultra", "cursor plan")
            check(cursor.tightest?.label == "API", "cursor tightest")
            check(Int(cursor.tightest?.remainingPercent.rounded() ?? 0) == 14, "cursor remaining")
            let cycle = JSONValue.date("2026-10-16T14:48:02.000Z")
            check(cursor.billing?.at == cycle && cursor.billing?.manual == false, "cursor billing")
            check(cursor.windows.allSatisfy { $0.resetsAt == cycle }, "cursor cycle stays on windows")

            let grok = try GrokProvider.parse(Data("""
            {
              "config": {
                "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-10-03T15:41:13.720963+00:00"},
                "creditUsagePercent": 71,
                "onDemandCap": {"val": 0},
                "productUsage": [{"product": "GrokBuild", "usagePercent": 71}, {"product": "GrokTasks"}]
              }
            }
            """.utf8), plan: nil)
            check(grok.windows.map(\.label) == ["每周"], "grok window")
            check(grok.note == nil, "grok note")
            check(grok.billing == nil, "grok weekly is not a bill")
            let grokBill = try GrokProvider.parse(Data("""
            {
              "config": {
                "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-10-03T15:41:13Z"},
                "creditUsagePercent": 71,
                "billingPeriodEnd": "2026-11-01T00:00:00Z"
              }
            }
            """.utf8), plan: nil)
            check(grokBill.windows[0].resetsAt == JSONValue.date("2026-10-03T15:41:13Z"), "grok reset stays weekly")
            check(grokBill.billing?.at == JSONValue.date("2026-11-01T00:00:00Z"), "grok billing period")
        } catch {
            failures.append("parse threw \(error)")
        }

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let hour = now.addingTimeInterval(3_600)
        let day = now.addingTimeInterval(86_400)
        let past = now.addingTimeInterval(-3_600)
        let soonest = [
            sample("claude", "Claude", used: 10, resetsAt: day),
            sample("codex", "Codex", used: 4, resetsAt: hour),
            sample("cursor", "Cursor", used: 86, resetsAt: day.addingTimeInterval(3_600)),
            sample("grok", "Grok", used: 71, resetsAt: day),
        ]
        let menu = MenuTitle.text(for: soonest, now: now)
        check(menu == "Codex 96%", "soonest menu \(menu)")
        check(MenuTitle.item(for: soonest, now: now)?.kind == .codex, "soonest mark")
        let bar = MenuBarTitle.attributed(soonest, now: now).string
        check(bar.contains("96%") && !bar.contains("90%"), "menu bar \(bar)")

        let undated = MenuTitle.text(for: [
            sample("claude", "Claude", used: 10),
            sample("codex", "Codex", used: 4),
            sample("cursor", "Cursor", used: 86),
            sample("grok", "Grok", used: 71),
        ], now: now)
        check(undated == "Cursor 14%", "undated menu \(undated)")

        let split = ProviderSnapshot(
            id: "codex", name: "Codex", shortName: "Codex", plan: nil,
            windows: [
                QuotaWindow(id: "5h", label: "5 小时", usedPercent: 80, resetsAt: hour),
                QuotaWindow(id: "week", label: "每周", usedPercent: 4, resetsAt: day),
            ],
            note: nil, error: nil, isStale: false
        )
        let splitMenu = MenuTitle.text(for: [split], now: now)
        check(splitMenu == "Codex 20%", "soonest window \(splitMenu)")

        let onlyPast = MenuTitle.text(for: [
            sample("claude", "Claude", used: 10, resetsAt: past),
            sample("cursor", "Cursor", used: 86, resetsAt: past),
        ], now: now)
        check(onlyPast == "Cursor 14%", "past falls back \(onlyPast)")

        let futureWins = MenuTitle.text(for: [
            sample("cursor", "Cursor", used: 86, resetsAt: past),
            sample("grok", "Grok", used: 71, resetsAt: hour),
        ], now: now)
        check(futureWins == "Grok 29%", "future beats past \(futureWins)")

        let tied = MenuTitle.text(for: [
            sample("claude", "Claude", used: 40, resetsAt: hour),
            sample("codex", "Codex", used: 10, resetsAt: hour),
        ], now: now)
        check(tied == "Claude 60%", "tied reset \(tied)")

        check(MenuTitle.text(for: [], now: now) == "读取中", "empty menu")
        check(MenuTitle.text(for: [ProviderSnapshot(
            id: "x", name: "X", shortName: "X", plan: nil, windows: [],
            note: nil, error: "失败", isStale: false
        )], now: now) == "额度不可用", "error menu")

        check(Mark.icon(.board, side: 16).size == NSSize(width: 16, height: 16), "board icon")
        for name in ["claude", "codex", "cursor", "cursor-dark", "grok"] {
            check(Bundle.module.url(forResource: name, withExtension: "png") != nil, "icon \(name)")
        }
        for kind in [Mark.Kind.claude, .codex, .cursor, .grok] {
            let icon = Mark.icon(kind, side: 16)
            check(icon.size == NSSize(width: 16, height: 16), "icon size \(kind)")
            check((icon.tiffRepresentation?.count ?? 0) > 1000, "icon pixels \(kind)")
        }
        let darkCursor = Mark.icon(.cursor, side: 16, appearance: NSAppearance(named: .darkAqua))
        let lightCursor = Mark.icon(.cursor, side: 16, appearance: NSAppearance(named: .aqua))
        check(darkCursor.tiffRepresentation != lightCursor.tiffRepresentation, "cursor appearance")

        let healthy = MenuTitle.text(for: [sample("codex", "Codex", used: 4)], now: now)
        check(healthy == "Codex 96%", "healthy menu \(healthy)")

        let merged = mergeSnapshots(
            previous: [sample("cursor", "Cursor", used: 80)],
            fresh: [ProviderSnapshot(
                id: "cursor", name: "Cursor", shortName: "Cursor",
                plan: nil, windows: [], note: nil,
                error: "Cursor 用量请求失败（HTTP 500）", isStale: false
            )]
        )
        check(merged[0].windows.count == 1 && merged[0].isStale, "stale merge")
        let keptBill = mergeSnapshots(
            previous: [sample("claude", "Claude", used: 10).replacing(
                billing: BillingAnchor(at: JSONValue.date("2026-09-16T00:00:00Z")!, renews: nil, manual: false)
            )],
            fresh: [ProviderSnapshot(
                id: "claude", name: "Claude", shortName: "Claude",
                plan: nil, windows: [], note: nil, error: "Claude 用量请求失败", isStale: false
            )]
        )
        check(keptBill[0].isStale && keptBill[0].billing != nil, "stale keeps billing")

        let local = reading(
            id: "local",
            used: 4,
            accountID: "acct-a",
            userID: "user-a",
            email: "same@example.com",
            freshness: 3,
            note: "点数 62,500"
        )
        let sub2 = reading(
            id: "sub2",
            used: 80,
            accountID: "acct-a",
            freshness: 2,
            label: "work"
        )
        let other = reading(
            id: "other",
            used: 50,
            accountID: "acct-b",
            freshness: 2,
            label: "personal@example.com"
        )
        let remote = reading(id: "new", used: 90, userID: "user-a", freshness: 3, label: "Codex")
        let deduped = AccountDeduper.merge([local, sub2, other, remote, unsigned()])
        check(deduped.count == 2, "deduped count \(deduped.count)")
        check(Set(deduped.map(\.name)) == ["work", "Codex"], "deduped names \(deduped.map(\.name))")
        let primary = deduped.first { $0.note?.contains("62,500") == true }
        check(primary?.name == "work", "named from safe label \(primary?.name ?? "nil")")
        check(Int(primary?.tightest?.usedPercent.rounded() ?? 0) == 4, "kept local percent")
        check(deduped.allSatisfy { !$0.dumpLine.contains("example.com") && !$0.dumpLine.contains("acct-") }, "redacted dump")

        do {
        let cpa = try CPACodex.readings(from: Data("""
        {"files":[
          {"provider":"codex","disabled":false,"label":"work.json","email":"same@example.com",
           "id_token":{"chatgpt_account_id":"acct-a","plan_type":"pro","chatgpt_subscription_active_until":"2026-12-01T00:00:00Z"},
           "quota":{"observed_at":"2026-10-03T14:00:00Z","signals":{
             "X-Codex-Primary-Used-Percent":"51",
             "X-Codex-Primary-Window-Minutes":"10080",
             "X-Codex-Primary-Reset-At":"1787588999",
             "X-Codex-Bengalfox-Secondary-Used-Percent":"35"
           }}},
          {"provider":"claude","name":"skip"}
        ]}
        """.utf8), source: "cpa")
        check(cpa.count == 1, "cpa count")
        check(cpa[0].snapshot.plan == "Pro 200", "cpa plan")
        check(cpa[0].snapshot.billing?.at == JSONValue.date("2026-12-01T00:00:00Z"), "cpa billing")
        check(cpa[0].snapshot.windows.map(\.label) == ["每周"], "cpa skips spark")
        check(Int(cpa[0].snapshot.windows[0].usedPercent.rounded()) == 51, "cpa used")
        let withCPA = AccountDeduper.merge([local, cpa[0]])
        check(withCPA.count == 1 && withCPA[0].name == "Codex", "cpa joins local \(withCPA.count)")
        check(withCPA[0].note == "点数 62,500", "live reading wins over cpa")

        let listed = try Sub2APICodex.parsePage(Data("""
        {"code":0,"data":{"total":2,"items":[
          {"id":7,"name":"work","platform":"openai","type":"oauth","status":"active",
           "credentials":{"chatgpt_account_id":"acct-a","access_token":"secret","subscription_expires_at":"2026-11-03T00:00:00Z"}},
          {"id":8,"name":"shadow","platform":"openai","type":"oauth","status":"active","parent_account_id":7,
           "credentials":{"chatgpt_account_id":"acct-a"}}
        ]}}
        """.utf8))
        check(listed.accounts.count == 1 && listed.accounts[0].accountID == "acct-a", "sub2api skips shadow")
        let usageReadings = Sub2APICodex.readings(accounts: listed.accounts, usage: Data("""
        {"code":0,"data":{"usage":{"7":{"five_hour":{"utilization":12,"resets_at":"2026-10-03T18:00:00Z"},"seven_day":{"utilization":40,"resets_at":"2026-10-09T00:00:00Z"}}},"errors":{}}}
        """.utf8), source: "sub2api")
        check(usageReadings[0].snapshot.windows.map(\.label) == ["5 小时", "每周"], "sub2api windows")
        check(usageReadings[0].snapshot.billing?.at == JSONValue.date("2026-11-03T00:00:00Z"), "sub2api billing")
        check(usageReadings[0].snapshot.dumpLine.contains("secret") == false, "sub2api token dropped")
        let proListed = try Sub2APICodex.parsePage(Data("""
        {"code":0,"data":{"total":3,"items":[
          {"id":9,"name":"pro","platform":"openai","type":"oauth","status":"active",
           "credentials":{"plan_type":"pro","chatgpt_account_id":"acct-p"},
           "extra":{"codex_5h_window_minutes":300}},
          {"id":10,"name":"zero","platform":"openai","type":"oauth","status":"active",
           "credentials":{"plan_type":"plus"},
           "extra":{"codex_5h_window_minutes":0}},
          {"id":11,"name":"plus","platform":"openai","type":"oauth","status":"active",
           "credentials":{"plan_type":"plus"},
           "extra":{"codex_5h_window_minutes":300}}
        ]}}
        """.utf8))
        let proUsage = Sub2APICodex.readings(accounts: proListed.accounts, usage: Data("""
        {"code":0,"data":{"usage":{
          "9":{"five_hour":{"utilization":12,"resets_at":"2026-10-03T18:00:00Z"},"seven_day":{"utilization":4,"resets_at":"2026-10-09T00:00:00Z"}},
          "10":{"five_hour":{"utilization":8,"resets_at":"2026-10-03T18:00:00Z"},"seven_day":{"utilization":20,"resets_at":"2026-10-09T00:00:00Z"}},
          "11":{"five_hour":{"utilization":15,"resets_at":"2026-10-03T18:00:00Z"},"seven_day":{"utilization":30,"resets_at":"2026-10-09T00:00:00Z"}}
        },"errors":{}}}
        """.utf8), source: "sub2api")
        check(proUsage.count == 3, "pro page count")
        check(proUsage[0].snapshot.plan == "Pro 200" && proUsage[0].snapshot.windows.map(\.label) == ["每周"], "pro 200 drops 5h")
        check(proUsage[1].snapshot.windows.map(\.label) == ["每周"], "zero-length 5h dropped")
        check(proUsage[2].snapshot.windows.map(\.label) == ["5 小时", "每周"], "real 5h kept")

        let channels = try NewAPICodex.parsePage(Data("""
        {"success":true,"data":{"total":1,"items":[{"id":3,"name":"desk","type":57,"status":1,"key":"secret-key"}]}}
        """.utf8))
        check(channels.channels.count == 1 && channels.channels[0].name == "desk", "new-api channel")
        let wham = NewAPICodex.reading(channel: channels.channels[0], body: Data("""
        {"success":true,"data":{"plan_type":"pro","user_id":"user-a","email":"same@example.com","rate_limit":{"primary_window":{"used_percent":9,"limit_window_seconds":604800,"reset_at":1791599736}}}}
        """.utf8), source: "new-api")
        check(wham.userID == "user-a" && wham.snapshot.dumpLine.contains("same@") == false, "new-api identity hidden")
        let joined = AccountDeduper.merge([local, wham])
        check(joined.count == 1, "new-api joins on user id")

        let configs = try UpstreamConfig.parse(Data("""
        {"upstreams":[{"kind":"sub2api","baseURL":"https://example.test","keychainAccount":"sub2api"}]}
        """.utf8))
        check(configs.count == 1 && configs[0].keychainService == "quota-board", "config defaults")
        } catch {
            failures.append("upstream parse threw \(error)")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let october = JSONValue.date("2026-10-04T12:00:00Z")!
        let september = BillingCalendar.date(year: 2026, month: 9, day: 16, calendar: calendar)!
        let rolled = BillingCalendar.next(anchor: september, renews: nil, now: october, calendar: calendar)
        check(calendar.component(.month, from: rolled) == 10 && calendar.component(.day, from: rolled) == 16, "roll to next month")
        let future = JSONValue.date("2026-11-03T00:00:00Z")!
        let kept = BillingCalendar.next(anchor: future, renews: nil, now: october, calendar: calendar)
        check(kept == future, "future anchor stays")
        let january = BillingCalendar.date(year: 2026, month: 1, day: 31, calendar: calendar)!
        let march = JSONValue.date("2026-03-02T00:00:00Z")!
        let clamped = BillingCalendar.next(anchor: january, renews: nil, now: march, calendar: calendar)
        check(calendar.component(.month, from: clamped) == 3 && calendar.component(.day, from: clamped) == 31, "clamp short month \(clamped)")
        let lapsed = BillingAnchor(at: september, renews: false, manual: false)
        check(BillingCalendar.next(anchor: lapsed.at, renews: false, now: october, calendar: calendar) == september, "lapsed does not roll")
        check(Format.billing(lapsed, now: october, calendar: calendar) == "账单已过", "lapsed label")
        let monthly = BillingAnchor(at: september, renews: nil, manual: false)
        check(Format.billing(monthly, now: october, calendar: calendar) == "账单 10月16日", "monthly label")
        let soon = BillingAnchor(at: BillingCalendar.date(year: 2026, month: 10, day: 8, calendar: calendar)!, renews: true, manual: false)
        check(Format.billing(soon, now: october, calendar: calendar) == "4天后续费", "renew label")
        let nextYear = BillingAnchor(at: BillingCalendar.date(year: 2027, month: 1, day: 16, calendar: calendar)!, renews: nil, manual: false)
        check(Format.billing(nextYear, now: october, calendar: calendar) == "账单 2027年1月16日", "next year label")

        let payload = #"{"https://api.openai.com/auth":{"chatgpt_subscription_active_until":"2026-11-03T00:00:00Z"}}"#
        let body = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = OpenAISubscription.anchor(in: "e30.\(body).sig")
        check(token?.at == future, "id token billing")

        let localDated = reading(
            id: "local",
            used: 4,
            accountID: "acct-a",
            freshness: 3,
            billing: BillingAnchor(at: future, renews: nil, manual: false)
        )
        let remoteDated = reading(
            id: "sub2",
            used: 80,
            accountID: "acct-a",
            freshness: 2,
            billing: BillingAnchor(at: september, renews: nil, manual: false)
        )
        let picked = AccountDeduper.merge([localDated, remoteDated])
        check(picked.count == 1 && picked[0].billing?.at == future, "fresher billing wins")
        check(picked[0].billingIdentity == "acct:acct-a", "billing key \(picked[0].billingIdentity)")
        let onlyRemote = AccountDeduper.merge([
            reading(id: "local", used: 4, accountID: "acct-a", freshness: 3),
            remoteDated,
        ])
        check(onlyRemote[0].billing?.at == september, "keeps the only billing date")

        let manualDay = BillingCalendar.date(year: 2026, month: 10, day: 20, calendar: calendar)!
        let overridden = BillingOverrides.apply(
            [sample("claude", "Claude", used: 10).replacing(billing: monthly)],
            manual: ["claude": manualDay]
        )
        check(overridden[0].billing?.manual == true && overridden[0].billing?.at == manualDay, "manual replaces auto")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("quota-board-billing-\(UUID().uuidString).json")
        do {
            try BillingStore.save(["claude": manualDay], to: file, calendar: calendar)
            let loaded = BillingStore.load(from: file, calendar: calendar)
            check(loaded["claude"] == manualDay, "billing file roundtrip")
        } catch {
            failures.append("billing file threw \(error)")
        }
        try? FileManager.default.removeItem(at: file)

        let namedAccount = sample("codex-a", "work", used: 4).replacing(billing: nil, billingKey: "acct:acct-a")
        let droppedAccount = sample("codex-b", "Codex 2", used: 80).replacing(billing: nil, billingKey: "acct:acct-b")
        let directory = AccountDirectory(names: ["acct:acct-a": "公司号"], hidden: ["acct:acct-b"])
        let listed = directory.apply([namedAccount, droppedAccount])
        check(listed.visible.map(\.name) == ["公司号"] && listed.visible[0].nameIsManual, "renamed account")
        check(listed.visible[0].shortName == "公司号", "menu uses the saved name")
        check(listed.hidden.map(\.billingIdentity) == ["acct:acct-b"], "hidden account")
        check(MenuTitle.text(for: listed.visible, now: now) == "公司号 96%", "hidden leaves the menu \(MenuTitle.text(for: listed.visible, now: now))")
        let accountsFile = FileManager.default.temporaryDirectory.appendingPathComponent("quota-board-accounts-\(UUID().uuidString).json")
        do {
            try AccountStore.save(directory, to: accountsFile)
            let loaded = AccountStore.load(from: accountsFile)
            check(loaded == directory, "account file roundtrip")
        } catch {
            failures.append("account file threw \(error)")
        }
        try? FileManager.default.removeItem(at: accountsFile)
        let parsed = AccountStore.parse(Data("""
        {"names":{"acct:a":"  公司号  ","acct:b":"","acct:c":"123456789012345678901234567890123"},"hidden":["acct:z", 4]}
        """.utf8))
        check(parsed.names == ["acct:a": "公司号"], "account names \(parsed.names)")
        check(parsed.hidden == ["acct:z"], "account hidden \(parsed.hidden)")
        check(parsed.sort == .expiry, "missing sort defaults to expiry")
        check(AccountDirectory.normalize("   ") == nil && AccountDirectory.normalize(String(repeating: "名", count: 33)) == nil, "name limits")

        let resetHour = october.addingTimeInterval(3_600)
        let resetDay = october.addingTimeInterval(86_400)
        let resetPast = october.addingTimeInterval(-3_600)
        let near = sample("near", "near", used: 10, resetsAt: resetHour)
        let far = sample("far", "far", used: 20, resetsAt: resetDay)
        let tiedAlpha = sample("alpha", "alpha", used: 1, resetsAt: resetHour)
        let tiedBeta = sample("beta", "beta", used: 2, resetsAt: resetHour)
        let staleCard = sample("stale", "zeta", used: 30, resetsAt: resetPast)
        let blank = sample("blank", "mid", used: 40)
        let exact = sample("exact", "exact", used: 5, resetsAt: october)
        let multi = ProviderSnapshot(
            id: "multi",
            name: "multi",
            shortName: "multi",
            plan: nil,
            windows: [
                QuotaWindow(id: "week", label: "每周", usedPercent: 4, resetsAt: resetDay.addingTimeInterval(86_400)),
                QuotaWindow(id: "5h", label: "5 小时", usedPercent: 80, resetsAt: resetHour.addingTimeInterval(-1_800)),
            ],
            note: nil,
            error: nil,
            isStale: false
        )
        let expiryOrder = BoardOrder.arrange(
            [far, blank, staleCard, near, tiedAlpha, tiedBeta, exact, multi],
            sort: .expiry,
            now: october
        )
        check(
            expiryOrder.map(\.id) == ["multi", "alpha", "beta", "near", "far", "exact", "blank", "stale"],
            "expiry order \(expiryOrder.map(\.id))"
        )
        let nameOrder = BoardOrder.arrange([far, near, blank], sort: .name, now: october)
        check(nameOrder.map(\.id) == ["far", "blank", "near"], "name order \(nameOrder.map(\.id))")
        let byName = AccountDirectory(sort: .name).apply([far, near], now: october)
        check(byName.visible.map(\.id) == ["far", "near"], "directory name sort")
        check(AccountDirectory().apply([far, near], now: october).visible.map(\.id) == ["near", "far"], "directory expiry sort")
        let namedSort = AccountStore.parse(Data(#"{"sort":"name"}"#.utf8))
        check(namedSort.sort == .name, "saved name sort")
        let unknownSort = AccountStore.parse(Data(#"{"sort":"plan"}"#.utf8))
        check(unknownSort.sort == .expiry, "unknown sort falls back")

        let unsetFace = Format.billingFace(nil, now: october, calendar: calendar)
        check(unsetFace.text == "未设置" && unsetFace.emphasized == false, "unset billing face")
        let distantFace = Format.billingFace(monthly, now: october, calendar: calendar)
        check(distantFace.text == "10月16日" && distantFace.emphasized == false, "distant billing face \(distantFace)")
        let closeFace = Format.billingFace(soon, now: october, calendar: calendar)
        check(closeFace.text == "10月8日" && closeFace.emphasized, "close billing face \(closeFace)")
        let todayFace = Format.billingFace(BillingAnchor(at: october, renews: nil, manual: false), now: october, calendar: calendar)
        check(todayFace.text == "10月4日" && todayFace.emphasized, "today billing face \(todayFace)")
        let lapsedFace = Format.billingFace(lapsed, now: october, calendar: calendar)
        check(lapsedFace.text == "9月16日" && lapsedFace.emphasized, "lapsed billing face \(lapsedFace)")
        let yearFace = Format.billingFace(nextYear, now: october, calendar: calendar)
        check(yearFace.text == "2027年1月16日" && yearFace.emphasized == false, "year billing face \(yearFace)")

        if failures.isEmpty {
            print("self-test ok")
            return 0
        }
        for failure in failures {
            print("FAIL \(failure)")
        }
        return 1
    }

    private static func reading(
        id: String,
        used: Double,
        accountID: String? = nil,
        userID: String? = nil,
        email: String? = nil,
        freshness: Int,
        label: String? = nil,
        note: String? = nil,
        billing: BillingAnchor? = nil
    ) -> AccountReading {
        AccountReading(
            snapshot: ProviderSnapshot(
                id: id,
                name: "Codex",
                shortName: "Codex",
                plan: "Pro 200",
                windows: [QuotaWindow(id: "\(id)-week", label: "每周", usedPercent: used, resetsAt: nil)],
                note: note,
                error: nil,
                isStale: false,
                billing: billing
            ),
            accountID: accountID,
            userID: userID,
            email: email,
            freshness: freshness,
            label: label,
            source: id
        )
    }

    private static func unsigned() -> AccountReading {
        AccountReading(
            snapshot: failed("codex", "Codex", "Codex", plan: nil, .notSignedIn("Codex")),
            accountID: nil,
            userID: nil,
            email: nil,
            freshness: 3,
            label: nil,
            source: "local"
        )
    }

    private static func sample(_ id: String, _ name: String, used: Double, resetsAt: Date? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id,
            name: name,
            shortName: name,
            plan: nil,
            windows: [QuotaWindow(id: "\(id)-main", label: "每周", usedPercent: used, resetsAt: resetsAt)],
            note: nil,
            error: nil,
            isStale: false
        )
    }
}
