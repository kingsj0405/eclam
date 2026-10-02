/// SlackSupportTests.swift — Slack 알림 순수 계층 검증.
///
/// 1) 게이팅: Slack 설정으로 ChatNotify의 마스터·체크박스·최소 길이·시작 스로틀 검증
/// 2) 자격 정보·채널 표기 검사 (봇 토큰 / webhook URL / 채널 ID)
/// 3) conversations.list 채널 ID 파싱 + 페이지 커서
/// 4) chat.postMessage 결과 파싱 + error 코드 분류
///
/// 실행 (scripts/test.sh): AwakeEpisode.swift + ChatNotifySupport.swift +
/// SlackSupport.swift 와 함께 단독 컴파일 — SlackNotifier(URLSession·NSL 결합)는
/// 끌고 오지 않는다.

import Foundation

var passCount = 0
var failCount = 0

func assert(_ cond: Bool, _ msg: String) {
    if cond {
        print("  ✓ \(msg)")
        passCount += 1
    } else {
        print("  ✗ FAIL: \(msg)")
        failCount += 1
    }
}

/// 설정 팩토리 — 모두 켜진 configured 상태에서 출발해 케이스별로 끈다.
func cfg(enabled: Bool = true, token: String = "xoxb-123456789012-abcdefghijkl",
         channel: String = "C0123ABCD", start: Bool = true, end: Bool = true,
         safety: Bool = true, digest: Int = 0) -> SlackSettings {
    SlackSettings(enabled: enabled, credential: token, channel: channel,
                  notifyAwakeStart: start, notifyAwakeEnd: end, notifySafety: safety,
                  digestIntervalMin: digest)
}

/// conversations.list 응답 한 페이지를 만든다.
func listPage(_ names: [(String, String)], cursor: String? = nil, ok: Bool = true) -> Data {
    let channels = names.map { ["id": $0.0, "name": $0.1] }
    var root: [String: Any] = ["ok": ok, "channels": channels]
    if let cursor = cursor {
        root["response_metadata"] = ["next_cursor": cursor]
    }
    return try! JSONSerialization.data(withJSONObject: root)
}

@main
enum SlackSupportTestMain {
    static func main() {
        print("── 게이팅: 종료 이벤트")
        assert(ChatNotify.shouldNotifyEnd(settings: cfg(), reason: .batteryLow,
                                            durationSeconds: 5),
               "안전 가드 해제는 길이와 무관하게 전송")
        assert(!ChatNotify.shouldNotifyEnd(settings: cfg(safety: false), reason: .batteryLow,
                                             durationSeconds: 5),
               "안전 체크박스 OFF ⇒ 미전송")
        assert(!ChatNotify.shouldNotifyEnd(settings: cfg(), reason: .agentCeased,
                                             durationSeconds: 30),
               "1분 미만 에이전트 종료는 소음 ⇒ 미전송")
        assert(!ChatNotify.shouldNotifyEnd(settings: cfg(), reason: .agentCeased,
                                             durationSeconds: 65),
               "원격 유예(60초)만큼의 깜빡임 ⇒ 미전송 — 최소 길이가 유예보다 길다")
        assert(ChatNotify.shouldNotifyEnd(settings: cfg(), reason: .agentCeased,
                                            durationSeconds: 120),
               "2분 이상 에이전트 종료 ⇒ 전송")
        assert(!ChatNotify.shouldNotifyEnd(settings: cfg(), reason: .manualOff,
                                             durationSeconds: 600),
               "사용자가 직접 끈 종료 ⇒ 절대 미전송")
        assert(!ChatNotify.shouldNotifyEnd(settings: cfg(enabled: false), reason: .batteryLow,
                                             durationSeconds: 600),
               "마스터 OFF ⇒ 미전송")
        assert(!ChatNotify.shouldNotifyEnd(settings: cfg(channel: ""), reason: .batteryLow,
                                             durationSeconds: 600),
               "채널 미입력 ⇒ 미전송")
        assert(ChatNotify.endChannel(for: .watchdog) == .safety, "watchdog → safety")
        assert(ChatNotify.endChannel(for: .remoteEnded) == .awakeEnd, "remoteEnded → awakeEnd")
        assert(ChatNotify.endChannel(for: .appQuit) == .never, "appQuit → never")

        print("── 게이팅: 시작 이벤트")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        assert(ChatNotify.shouldNotifyStart(settings: cfg(), cause: .agent,
                                              lastStartAt: nil, now: now),
               "첫 시작 ⇒ 전송")
        assert(!ChatNotify.shouldNotifyStart(settings: cfg(start: false), cause: .agent,
                                               lastStartAt: nil, now: now),
               "시작 체크박스 OFF ⇒ 미전송")
        assert(!ChatNotify.shouldNotifyStart(settings: cfg(), cause: .manual,
                                               lastStartAt: nil, now: now),
               "수동 시작 ⇒ 미전송")
        assert(!ChatNotify.shouldNotifyStart(settings: cfg(), cause: .agent,
                                               lastStartAt: now.addingTimeInterval(-60), now: now),
               "5분 이내 재시작 ⇒ 스로틀")
        assert(ChatNotify.shouldNotifyStart(settings: cfg(), cause: .agent,
                                              lastStartAt: now.addingTimeInterval(-600), now: now),
               "5분 지난 재시작 ⇒ 전송")

        print("── 게이팅: 다이제스트")
        assert(ChatNotify.shouldSendDigest(settings: cfg(digest: 30), episodeOngoing: true),
               "에피소드 중 + 간격 30 ⇒ 전송")
        assert(!ChatNotify.shouldSendDigest(settings: cfg(digest: 0), episodeOngoing: true),
               "간격 0(off, 기본) ⇒ 미전송")
        assert(!ChatNotify.shouldSendDigest(settings: cfg(digest: 30), episodeOngoing: false),
               "에피소드 없음(유휴) ⇒ 미전송")

        print("── 토큰 형식")
        assert(SlackSupport.looksLikeBotToken("xoxb-123456789012-abcdefghijkl"), "봇 토큰")
        assert(SlackSupport.looksLikeBotToken("  xoxb-123456789012-abcdefghijkl  "),
               "앞뒤 공백은 무시")
        assert(SlackSupport.looksLikeBotToken("xoxp-123456789012-abcdefghijkl"),
               "사용자 토큰도 허용")
        assert(!SlackSupport.looksLikeBotToken("123456:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw3"),
               "Telegram 토큰은 거부")
        assert(!SlackSupport.looksLikeBotToken("xoxb-short"), "너무 짧으면 거부")
        assert(!SlackSupport.looksLikeBotToken("xoxb-abc def ghij klm"), "공백 포함 거부")
        assert(!SlackSupport.looksLikeBotToken(""), "빈 문자열 거부")

        print("── 채널 표기")
        assert(SlackSupport.normalizeChannel("#general") == "general", "선행 # 제거")
        assert(SlackSupport.normalizeChannel("  #dev-alerts ") == "dev-alerts", "공백 + # 제거")
        assert(SlackSupport.normalizeChannel("general") == "general", "그대로")
        assert(SlackSupport.looksLikeChannelId("C0123ABCD"), "공개 채널 ID")
        assert(SlackSupport.looksLikeChannelId("#C0123ABCD"), "# 붙어도 ID 로 인식")
        assert(SlackSupport.looksLikeChannelId("G01234ABCDE"), "비공개 채널 ID")
        assert(!SlackSupport.looksLikeChannelId("general"), "이름은 ID 아님")
        assert(!SlackSupport.looksLikeChannelId("C0123abc"), "소문자 섞이면 ID 아님")
        assert(!SlackSupport.looksLikeChannelId("C012"), "너무 짧으면 ID 아님")

        print("── 자격 정보 갈래")
        assert(SlackSupport.credentialKind("xoxb-123456789012-abcdefghijkl") == .botToken,
               "xoxb- ⇒ 봇 토큰")
        assert(SlackSupport.credentialKind(
                "https://hooks.slack.com/services/T01ABCDEF/B02GHIJKL/xxxxxxxxxxxxxxxx") == .webhook,
               "hooks.slack.com URL ⇒ webhook")
        assert(SlackSupport.credentialKind("  https://hooks.slack.com/services/T0/B0/s  ") == .webhook,
               "앞뒤 공백은 무시")
        assert(SlackSupport.credentialKind("https://example.com/services/T0/B0/s") == .unknown,
               "다른 호스트는 거부 — 임의 URL 로 전송하지 않는다")
        assert(SlackSupport.credentialKind("https://hooks.slack.com/services/") == .unknown,
               "경로 없는 접두사만으로는 안 됨")
        assert(SlackSupport.credentialKind("not-a-credential") == .unknown, "오타는 unknown")

        print("── webhook 은 채널 없이도 보낼 수 있다")
        let hook = "https://hooks.slack.com/services/T01ABCDEF/B02GHIJKL/xxxxxxxxxxxxxxxx"
        assert(cfg(token: hook, channel: "").isConfigured,
               "webhook + 채널 없음 ⇒ 전송 가능")
        assert(!cfg(token: "xoxb-123456789012-abcdefghijkl", channel: "").isConfigured,
               "봇 토큰 + 채널 없음 ⇒ 전송 불가")
        assert(!cfg(enabled: false, token: hook, channel: "").isConfigured,
               "마스터 OFF ⇒ 전송 불가")
        assert(cfg(enabled: false, token: hook, channel: "").isConfiguredIgnoringMaster,
               "마스터 OFF 여도 테스트 전송 조건은 충족")

        print("── webhook 응답 파싱")
        assert(SlackSupport.parseWebhookResult(status: 200, body: Data("ok".utf8)).ok,
               "HTTP 200 + 평문 ok ⇒ 성공")
        assert(SlackSupport.parseWebhookResult(status: 200, body: Data("ok\n".utf8)).ok,
               "줄바꿈 붙어도 성공")
        let badPayload = SlackSupport.parseWebhookResult(
            status: 400, body: Data("invalid_payload".utf8))
        assert(!badPayload.ok && badPayload.error == "invalid_payload", "실패 본문 그대로 노출")
        assert(SlackSupport.parseWebhookResult(status: 500, body: Data()).error == "HTTP 500",
               "본문이 비면 상태 코드로 대체")
        assert(SlackSupport.parseWebhookResult(status: 200, body: Data("ok".utf8)).error == nil,
               "성공이면 에러 문구 없음")
        assert(SlackSupport.classify(error: "no_service") == .badToken,
               "삭제된 webhook ⇒ 자격 정보 문제")

        print("── conversations.list 파싱")
        let page1 = listPage([("C111AAAAA", "random"), ("C222BBBBB", "general")])
        assert(SlackSupport.parseChannelId(fromConversationsList: page1, name: "general").id
               == "C222BBBBB", "이름으로 ID 찾기")
        assert(SlackSupport.parseChannelId(fromConversationsList: page1, name: "#general").id
               == "C222BBBBB", "# 붙여 넣어도 찾기")
        assert(SlackSupport.parseChannelId(fromConversationsList: page1, name: "GENERAL").id
               == "C222BBBBB", "대소문자 무시")
        let miss = SlackSupport.parseChannelId(fromConversationsList: page1, name: "nope")
        assert(miss.id == nil && miss.nextCursor == nil, "못 찾고 커서도 없으면 끝")
        let paged = listPage([("C111AAAAA", "random")], cursor: "dXNlcjpV")
        let next = SlackSupport.parseChannelId(fromConversationsList: paged, name: "general")
        assert(next.id == nil && next.nextCursor == "dXNlcjpV", "다음 페이지 커서 전달")
        let empty = listPage([("C111AAAAA", "random")], cursor: "")
        assert(SlackSupport.parseChannelId(fromConversationsList: empty, name: "general").nextCursor
               == nil, "빈 커서는 끝으로 취급")
        let failed = listPage([], ok: false)
        assert(SlackSupport.parseChannelId(fromConversationsList: failed, name: "general").id == nil,
               "ok=false 응답에서는 찾지 않음")

        print("── chat.postMessage 결과 파싱")
        let posted = try! JSONSerialization.data(withJSONObject: ["ok": true, "ts": "1.2"])
        assert(SlackSupport.parsePostResult(posted).ok, "성공 응답")
        let refused = try! JSONSerialization.data(
            withJSONObject: ["ok": false, "error": "not_in_channel"])
        let parsed = SlackSupport.parsePostResult(refused)
        assert(!parsed.ok && parsed.error == "not_in_channel", "실패 응답 + error 코드")
        assert(!SlackSupport.parsePostResult(Data("nonsense".utf8)).ok, "파싱 불가 ⇒ 실패")

        print("── error 코드 분류")
        assert(SlackSupport.classify(error: "invalid_auth") == .badToken, "invalid_auth → badToken")
        assert(SlackSupport.classify(error: "missing_scope") == .missingScope,
               "missing_scope → missingScope")
        assert(SlackSupport.classify(error: "not_in_channel") == .botNotInChannel,
               "not_in_channel → botNotInChannel")
        assert(SlackSupport.classify(error: "channel_not_found") == .botNotInChannel,
               "channel_not_found → botNotInChannel")
        assert(SlackSupport.classify(error: "ratelimited") == .rateLimited,
               "ratelimited → rateLimited")
        assert(SlackSupport.classify(error: "weird_new_code") == .other("weird_new_code"),
               "모르는 코드는 그대로 노출")

        print("── 종료 정착 창 (EndSettler)")
        func ep(_ start: Date, _ len: TimeInterval, cause: AwakeStartCause = .remote,
                detail: String? = "pmset:NetworkClient",
                reason: AwakeEndReason = .remoteEnded) -> AwakeEpisode {
            var e = AwakeEpisode(startedAt: start, startCause: cause, startDetail: detail)
            e.endedAt = start.addingTimeInterval(len)
            e.endReason = reason
            e.endDetail = detail
            return e
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            // 1분 깜빡임 20연속(실사고 패턴: 62초 켜짐 + 5초 꺼짐) — 즉시 전송 0,
            // 정착 뒤 누적 길이로 한 통.
            var st = ChatNotify.EndSettler()
            var held = 0, swallowed = 0, notified = 0
            var t = t0
            for _ in 0..<20 {
                let e = ep(t, 62)
                switch st.noteStart(e, now: t) {
                case .notify: notified += 1
                case .swallowed: swallowed += 1
                case .flushThenNotify: assert(false, "같은 원인 재시작에 flush 가 나오면 안 된다")
                }
                t = t.addingTimeInterval(62)
                if case .hold = st.noteEnd(e, settings: cfg(), now: t) { held += 1 }
                t = t.addingTimeInterval(5)
            }
            assert(notified == 1 && swallowed == 19, "첫 시작만 notify, 나머지 19회는 swallowed (got \(notified)/\(swallowed))")
            assert(held == 20, "스무 번 모두 보류(hold) — 즉시 전송 0 (got \(held))")
            let em = st.settle(now: t.addingTimeInterval(ChatNotify.endSettleSeconds))
            assert(em != nil, "정착 뒤 종료 한 통")
            assert(em?.mergedCount == 19, "합친 재시작 19회 (got \(em?.mergedCount ?? -1))")
            assert((em?.duration ?? 0) > 20 * 60, "길이는 첫 시작부터 누적 (got \(em?.duration ?? 0))")
            assert(em?.episode.endReason == .remoteEnded, "사유는 마지막 에피소드의 것")
            assert(st.flapCount == 19 && st.flapByDetail["pmset:NetworkClient"] == 19,
                   "삼킨 재시작 19회는 요약 집계로 남는다")
        }
        do {
            // 한 번만 깜빡이고 끝 — 62초짜리는 너무 짧아 버리고 요약에만 집계.
            var st = ChatNotify.EndSettler()
            let e = ep(t0, 62)
            assert(st.noteStart(e, now: t0) == .notify, "새 세션 ⇒ notify")
            let endAt = t0.addingTimeInterval(62)
            let action = st.noteEnd(e, settings: cfg(), now: endAt)
            assert(action == .hold(until: endAt.addingTimeInterval(ChatNotify.endSettleSeconds)),
                   "awakeEnd 종료 ⇒ hold, 만료 = 종료 + 정착 창")
            let due = endAt.addingTimeInterval(ChatNotify.endSettleSeconds)
            assert(st.settle(now: due) == nil, "62초 단발은 전송하지 않는다")
            assert(st.flapCount == 1 && st.flapByDetail["pmset:NetworkClient"] == 1,
                   "대신 깜빡임 1회로 집계")
            assert(st.flapSummaryDueAt == due.addingTimeInterval(ChatNotify.flapSummaryIntervalSeconds),
                   "요약 예정 시각 = 첫 깜빡임 + 간격")
            let sum = st.takeFlapSummary()
            assert(sum?.count == 1 && sum?.byDetail == ["pmset:NetworkClient": 1], "요약 1건")
            assert(st.takeFlapSummary() == nil && st.flapSummaryDueAt == nil,
                   "요약을 꺼내면 집계가 비워진다")
        }
        do {
            // 진짜 종료: 10분 세션 → 정착 창 동안 재시작 없음 → 한 통.
            var st = ChatNotify.EndSettler()
            let e = ep(t0, 600, cause: .agent, detail: "claude", reason: .agentCeased)
            _ = st.noteStart(e, now: t0)
            let endAt = t0.addingTimeInterval(600)
            _ = st.noteEnd(e, settings: cfg(), now: endAt)
            let em = st.settle(now: endAt.addingTimeInterval(ChatNotify.endSettleSeconds))
            assert(em?.duration == 600 && em?.mergedCount == 0, "10분 세션 그대로 한 통")
            assert(st.flapCount == 0, "깜빡임 집계 없음")
        }
        do {
            // 원인이 바뀐 재시작: 원격 종료 보류 중 에이전트 시작 ⇒ 보류분 즉시 flush.
            var st = ChatNotify.EndSettler()
            let remote = ep(t0, 900)
            _ = st.noteStart(remote, now: t0)
            _ = st.noteEnd(remote, settings: cfg(), now: t0.addingTimeInterval(900))
            let agent = ep(t0.addingTimeInterval(910), 300, cause: .agent, detail: "claude", reason: .agentCeased)
            let a = st.noteStart(agent, now: t0.addingTimeInterval(910))
            if case .flushThenNotify(let p) = a {
                assert(p.episode == remote, "flush 되는 건 보류 중이던 원격 종료")
            } else {
                assert(false, "다른 원인 재시작 ⇒ flushThenNotify (got \(a))")
            }
            assert(st.pending == nil && st.chainStartedAt == agent.startedAt, "새 세션은 에이전트 시작부터")
        }
        do {
            // 안전 채널은 정착 창 없이 즉시, 길이 무관.
            var st = ChatNotify.EndSettler()
            let e = ep(t0, 5, cause: .agent, detail: "claude", reason: .batteryLow)
            _ = st.noteStart(e, now: t0)
            if case .sendNow(let em) = st.noteEnd(e, settings: cfg(), now: t0.addingTimeInterval(5)) {
                assert(em.duration == 5, "안전 해제는 5초라도 즉시 전송")
            } else {
                assert(false, "안전 채널 ⇒ sendNow")
            }
            // 게이트 OFF ⇒ drop
            var st2 = ChatNotify.EndSettler()
            let long = ep(t0, 600)
            _ = st2.noteStart(long, now: t0)
            assert(st2.noteEnd(long, settings: cfg(end: false), now: t0.addingTimeInterval(600)) == .drop,
                   "notifyAwakeEnd OFF ⇒ drop")
            assert(ChatNotify.formatFlapBreakdown(["claude": 1, "pmset:NetworkClient": 12]) == "pmset:NetworkClient ×12, claude ×1",
                   "요약 꼬리는 많은 것부터")
        }

        print("── 설정 back-compat")
        let legacy = Data("""
        {"enabled":true,"credential":"xoxb-123456789012-abcdefghijkl","channel":"C0123ABCD"}
        """.utf8)
        let decoded = try! JSONDecoder().decode(SlackSettings.self, from: legacy)
        assert(decoded.digestIntervalMin == 0, "없는 키는 off 로 디코드")
        assert(decoded.notifyAwakeEnd && decoded.notifySafety && !decoded.notifyAwakeStart,
               "체크박스 기본값 유지")
        assert(decoded.isConfigured, "토큰·채널 있으면 configured")

        print("")
        print("SlackSupport tests: \(passCount) passed, \(failCount) failed")
        if failCount > 0 { exit(1) }
    }
}
