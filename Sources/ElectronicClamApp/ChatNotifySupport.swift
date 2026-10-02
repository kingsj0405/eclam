// ChatNotifySupport.swift — 채팅 알림의 백엔드 공통 정책 계층.
//
// Telegram(ADR-0028)과 Slack 은 목적지 API 만 다르고 "언제 보낼지"는 같다.
// 그 공통분모(이벤트 게이팅·스로틀·정착 창·문안 조각 포맷)를 여기 한 곳에 두고,
// 백엔드별 파일(TelegramSupport / SlackSupport)에는 그 백엔드에만 있는 것
// (설정 타입·토큰 형식 검사·응답 파싱)만 남긴다.
//
// Foundation 만 사용 — AppKit·OSLog·URLSession 호출 금지. `scripts/test.sh`
// 가 백엔드별 순수 계층과 함께 단독 컴파일한다.

import Foundation

/// 게이팅이 읽는 설정의 최소 형태. 백엔드 설정 struct 가 채택한다.
protocol ChatNotifySettings {
    /// 보낼 수 있는 최소 조건 — 마스터 ON + 목적지 자격 정보 완비.
    var isConfigured: Bool { get }
    var notifyAwakeStart: Bool { get }
    var notifyAwakeEnd: Bool { get }
    var notifySafety: Bool { get }
    var digestIntervalMin: Int { get }
}

/// 백엔드 공통 게이팅 + 문안 조각. 순수 함수만.
enum ChatNotify {

    /// 종료 알림이 분류되는 채널. 설정 체크박스와 1:1.
    enum EndChannel: Equatable {
        case safety     // notifySafety 게이트
        case awakeEnd   // notifyAwakeEnd 게이트
        case never      // 절대 전송하지 않음
    }

    /// `awakeEnd` 채널 종료를 알릴 최소 세션 길이(초). 에이전트가 몇 초 일했다
    /// 멈춘 깜빡임은 원격 알림 가치가 없다. 안전 가드 해제에는 적용하지
    /// 않는다 — 5분 cooldown 이 곧 닥치므로 항상 의미가 있다.
    ///
    /// ★`RemoteWatcher.inactiveGrace`(60초)보다 길어야 한다. 원격 신호가 폴
    /// 한 번만 양성이어도 유예 때문에 60~65초짜리 에피소드가 생기는데, 이 값이
    /// 60초이던 시절엔 그 깜빡임이 전부 통과해 분 단위로 알림이 나갔다
    /// (2026-10-02, 한 시간 49건).
    static let minEndEpisodeSeconds: TimeInterval = 120

    /// 종료 알림 정착 창(초). `awakeEnd` 채널 종료는 바로 보내지 않고 이 시간을
    /// 기다린다. 그 안에 같은 원인(startCause + startDetail)으로 다시 깨어나면
    /// 종료·시작 알림을 모두 삼키고 한 세션으로 이어 본다. 정착 창을 넘기면
    /// 첫 시작부터의 누적 길이로 한 통 보낸다. 상태 변화는 늦어도 이 시간
    /// 안에 알게 된다.
    static let endSettleSeconds: TimeInterval = 180

    /// 삼킨 깜빡임(정착 창 안 재시작·너무 짧아 버린 종료)을 모아 알리는 간격(초).
    /// 깜빡임이 하나라도 생긴 시점부터 재서, 이 시간이 지나면 "지난 1시간 짧은
    /// 깨어있음 N회" 한 줄로 보낸다. 조용히 버리지 않는다 — 깜빡임이 늘어나는
    /// 것도 상태 변화다.
    static let flapSummaryIntervalSeconds: TimeInterval = 3600

    /// 깨어있음-시작 메시지 사이 최소 간격(초). 에이전트 flapping 이 시작
    /// 알림을 도배하지 않도록 notifier 가 이 값으로 스로틀한다.
    static let minStartGapSeconds: TimeInterval = 300

    /// 주기 다이제스트 간격 선택지(분). UI 팝업과 검증이 공유.
    static let digestIntervalChoices = [15, 30, 60]

    /// 다이제스트 1회 전송 여부 — 타이머 tick 시점의 가드.
    /// 에피소드 진행 중 + 마스터/간격 설정 충족일 때만.
    static func shouldSendDigest(settings: ChatNotifySettings,
                                 episodeOngoing: Bool) -> Bool {
        settings.isConfigured && settings.digestIntervalMin > 0 && episodeOngoing
    }

    /// 종료 사유 → 채널 분류. exhaustive switch — `AwakeEndReason` 케이스가
    /// 늘어나면 여기서 컴파일이 깨져 분류 누락을 막는다 (asEndReason 패턴).
    static func endChannel(for reason: AwakeEndReason) -> EndChannel {
        switch reason {
        case .batteryLow, .thermalSerious, .thermalCritical, .timer, .watchdog:
            return .safety
        case .agentCeased, .remoteEnded, .remoteNetworkLost, .unknown:
            return .awakeEnd
        case .manualOff, .forceSleep:
            // 사용자가 Mac 앞에서 직접 한 행동 — 원격 알림 불필요.
            return .never
        case .appQuit:
            // applicationWillTerminate 중에는 비동기 전송 완료를 보장할 수
            // 없다. 보낼 수 없는 것을 보내는 척하지 않는다 (ADR-0028).
            return .never
        }
    }

    /// 종료 이벤트 전송 여부 결정 (길이 기준). notifier 는 이 판정을 바로 쓰지
    /// 않고 `EndSettler` 를 거친다 — 정착 창에서 이어 붙인 누적 길이로 같은
    /// 기준을 적용하기 때문이다. 채널 게이트의 정본은 여기와 settler 가 공유하는
    /// `endGate(settings:reason:)` 다.
    static func shouldNotifyEnd(settings: ChatNotifySettings,
                                reason: AwakeEndReason,
                                durationSeconds: TimeInterval) -> Bool {
        switch endGate(settings: settings, reason: reason) {
        case .safety:
            return true
        case .awakeEnd:
            return durationSeconds >= minEndEpisodeSeconds
        case .never:
            return false
        }
    }

    /// 채널 게이트만 — 설정 체크박스로 열린 채널을 돌려주고, 닫혔으면 `.never`.
    static func endGate(settings: ChatNotifySettings,
                        reason: AwakeEndReason) -> EndChannel {
        guard settings.isConfigured else { return .never }
        switch endChannel(for: reason) {
        case .safety:
            return settings.notifySafety ? .safety : .never
        case .awakeEnd:
            return settings.notifyAwakeEnd ? .awakeEnd : .never
        case .never:
            return .never
        }
    }

    /// 시작 이벤트 전송 여부 결정. `lastStartAt` 은 notifier 가 들고 있는
    /// 직전 시작-알림 시각 (스로틀). manual 시작은 사용자가 Mac 앞에서 직접
    /// 한 행동이라 원격 알림 가치가 없다 (manualOff 종료와 대칭).
    static func shouldNotifyStart(settings: ChatNotifySettings,
                                  cause: AwakeStartCause,
                                  lastStartAt: Date?,
                                  now: Date = Date()) -> Bool {
        guard settings.isConfigured, settings.notifyAwakeStart else { return false }
        guard cause != .manual else { return false }
        if let last = lastStartAt, now.timeIntervalSince(last) < minStartGapSeconds {
            return false
        }
        return true
    }

    // MARK: - 종료 정착 창 (2026-10-02)

    /// 종료 알림의 정착 창과 깜빡임 집계를 맡는 상태 기계. 순수 값 타입 —
    /// 타이머는 notifier 가 들고, 여기서는 "지금 무엇을 해야 하는지"만 결정한다.
    ///
    /// 흐름:
    ///   episodeEnded  → `noteEnd`   : 안전 채널은 즉시, awakeEnd 채널은 보류(hold)
    ///   episodeStarted→ `noteStart` : 보류 중 같은 원인 재시작이면 둘 다 삼킴,
    ///                                 다른 원인이면 보류분을 즉시 흘려보내고 새 세션
    ///   정착 창 만료   → `settle`    : 누적 길이가 최소 길이 이상이면 전송, 아니면 깜빡임 집계
    ///   요약 타이머    → `takeFlapSummary`
    struct EndSettler {

        /// 정착 대기 중인 종료.
        struct Pending: Equatable {
            /// 마지막으로 끝난 에피소드 (종료 사유·디테일의 출처).
            var episode: AwakeEpisode
            /// 이어 본 세션의 첫 시작 시각.
            var chainStartedAt: Date
            /// 이 세션에 삼킨 재시작 수.
            var mergedCount: Int
        }

        /// 보낼 종료 한 건 — 누적 길이와 합친 재시작 수를 함께 준다.
        struct Emission: Equatable {
            var episode: AwakeEpisode
            var duration: TimeInterval
            var mergedCount: Int
        }

        /// 깜빡임 요약 — `count` 건, 원인 디테일별 집계.
        struct FlapSummary: Equatable {
            var count: Int
            var byDetail: [String: Int]
        }

        enum StartAction: Equatable {
            /// 새 세션 — 평소의 시작 게이팅으로 진행.
            case notify
            /// 정착 창 안의 같은 원인 재시작 — 시작 알림과 보류 종료를 모두 삼킴.
            case swallowed
            /// 다른 원인으로 재시작 — 보류 종료를 지금 보내고, 시작은 평소대로.
            case flushThenNotify(Pending)
        }

        enum EndAction: Equatable {
            /// 즉시 전송 (안전 채널).
            case sendNow(Emission)
            /// 정착 창 보류 — 이 시각에 `settle` 을 부른다.
            case hold(until: Date)
            /// 전송하지 않음 (게이트 닫힘·never).
            case drop
        }

        private(set) var pending: Pending?
        /// 진행 중 세션의 첫 시작 시각. 정착 창 안에서 이어졌으면 과거 값을 유지.
        private(set) var chainStartedAt: Date?
        private(set) var chainMergedCount: Int = 0

        /// 요약용 집계.
        private(set) var flapCount: Int = 0
        private(set) var flapByDetail: [String: Int] = [:]
        private(set) var flapWindowStartedAt: Date?

        init() {}

        /// 요약을 보낼 예정 시각. 집계가 비어 있으면 nil.
        var flapSummaryDueAt: Date? {
            flapWindowStartedAt?.addingTimeInterval(ChatNotify.flapSummaryIntervalSeconds)
        }

        mutating func noteStart(_ ep: AwakeEpisode, now: Date) -> StartAction {
            if let p = pending {
                pending = nil
                if Self.sameCause(p.episode, ep) {
                    chainStartedAt = p.chainStartedAt
                    chainMergedCount = p.mergedCount + 1
                    recordFlap(detail: Self.detailKey(ep), now: now)
                    return .swallowed
                }
                chainStartedAt = ep.startedAt
                chainMergedCount = 0
                return .flushThenNotify(p)
            }
            chainStartedAt = ep.startedAt
            chainMergedCount = 0
            return .notify
        }

        mutating func noteEnd(_ ep: AwakeEpisode,
                              settings: ChatNotifySettings,
                              now: Date) -> EndAction {
            let start = chainStartedAt ?? ep.startedAt
            let merged = chainMergedCount
            chainStartedAt = nil
            chainMergedCount = 0
            switch ChatNotify.endGate(settings: settings, reason: ep.endReason ?? .unknown) {
            case .never:
                return .drop
            case .safety:
                let end = ep.endedAt ?? now
                return .sendNow(Emission(episode: ep,
                                         duration: end.timeIntervalSince(start),
                                         mergedCount: merged))
            case .awakeEnd:
                pending = Pending(episode: ep, chainStartedAt: start, mergedCount: merged)
                return .hold(until: now.addingTimeInterval(ChatNotify.endSettleSeconds))
            }
        }

        /// 정착 창 만료. 보류 종료가 없으면 nil. 누적 길이가 최소 길이에 못 미치면
        /// 깜빡임으로 집계하고 nil.
        mutating func settle(now: Date) -> Emission? {
            guard let p = pending else { return nil }
            pending = nil
            let end = p.episode.endedAt ?? now
            let duration = end.timeIntervalSince(p.chainStartedAt)
            if duration >= ChatNotify.minEndEpisodeSeconds {
                return Emission(episode: p.episode, duration: duration, mergedCount: p.mergedCount)
            }
            recordFlap(detail: Self.detailKey(p.episode), now: now)
            return nil
        }

        /// 요약을 꺼내고 집계를 비운다. 비어 있으면 nil. 때를 재는 건 호출자의
        /// 타이머(`flapSummaryDueAt`)다.
        mutating func takeFlapSummary() -> FlapSummary? {
            guard flapCount > 0 else { return nil }
            let summary = FlapSummary(count: flapCount, byDetail: flapByDetail)
            flapCount = 0
            flapByDetail = [:]
            flapWindowStartedAt = nil
            return summary
        }

        // MARK: 내부

        private mutating func recordFlap(detail: String, now: Date) {
            if flapWindowStartedAt == nil { flapWindowStartedAt = now }
            flapCount += 1
            flapByDetail[detail, default: 0] += 1
        }

        /// 같은 원인 = 시작 원인과 디테일이 같다. 원격 `pmset:NetworkClient` ↔
        /// 에이전트 `claude` 는 다른 세션이다.
        static func sameCause(_ a: AwakeEpisode, _ b: AwakeEpisode) -> Bool {
            a.startCause == b.startCause && a.startDetail == b.startDetail
        }

        static func detailKey(_ ep: AwakeEpisode) -> String {
            ep.startDetail ?? ep.startCause.rawValue
        }
    }

    /// `EndSettler` 에 타이머를 붙인 운전자. Slack·Telegram notifier 가 하나씩
    /// 들고, 메시지 조립·전송은 두 콜백으로 되돌려 준다. 메인 스레드 전용.
    final class SettleDriver {
        private var settler = EndSettler()
        private var settleTimer: Timer?
        private var flapSummaryTimer: Timer?
        private let emitEnd: (EndSettler.Emission) -> Void
        private let emitFlapSummary: (EndSettler.FlapSummary) -> Void

        init(emitEnd: @escaping (EndSettler.Emission) -> Void,
             emitFlapSummary: @escaping (EndSettler.FlapSummary) -> Void) {
            self.emitEnd = emitEnd
            self.emitFlapSummary = emitFlapSummary
        }

        /// 이어 본 세션의 첫 시작 시각 (다이제스트 기준).
        var chainStartedAt: Date? { settler.chainStartedAt }

        /// 시작 이벤트. false ⇒ 정착 창 안의 같은 원인 재시작이라 시작 알림을 삼켰다.
        func episodeStarted(_ ep: AwakeEpisode) -> Bool {
            switch settler.noteStart(ep, now: Date()) {
            case .swallowed:
                settleTimer?.invalidate(); settleTimer = nil
                scheduleFlapSummaryIfNeeded()
                return false
            case .flushThenNotify(let pending):
                settleTimer?.invalidate(); settleTimer = nil
                let end = pending.episode.endedAt ?? Date()
                emitEnd(EndSettler.Emission(episode: pending.episode,
                                            duration: end.timeIntervalSince(pending.chainStartedAt),
                                            mergedCount: pending.mergedCount))
                return true
            case .notify:
                return true
            }
        }

        func episodeEnded(_ ep: AwakeEpisode, settings: ChatNotifySettings) {
            switch settler.noteEnd(ep, settings: settings, now: Date()) {
            case .drop:
                return
            case .sendNow(let emission):
                emitEnd(emission)
            case .hold(let until):
                settleTimer?.invalidate()
                settleTimer = schedule(at: until) { [weak self] in
                    guard let self else { return }
                    self.settleTimer = nil
                    if let emission = self.settler.settle(now: Date()) {
                        self.emitEnd(emission)
                    } else {
                        self.scheduleFlapSummaryIfNeeded()
                    }
                }
            }
        }

        private func scheduleFlapSummaryIfNeeded() {
            guard flapSummaryTimer == nil, let due = settler.flapSummaryDueAt else { return }
            flapSummaryTimer = schedule(at: due) { [weak self] in
                guard let self else { return }
                self.flapSummaryTimer = nil
                if let summary = self.settler.takeFlapSummary() { self.emitFlapSummary(summary) }
            }
        }

        private func schedule(at date: Date, _ body: @escaping () -> Void) -> Timer {
            let t = Timer(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false) { _ in body() }
            RunLoop.main.add(t, forMode: .common)
            return t
        }
    }

    /// 깜빡임 요약의 원인별 꼬리. 예: "pmset:NetworkClient ×12, claude ×1".
    /// 많은 것부터, 같은 수면 이름순.
    static func formatFlapBreakdown(_ byDetail: [String: Int]) -> String {
        byDetail.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
    }

    /// "2h 14m" / "45m" / "<1m" — 메시지 본문용 짧은 길이 표기.
    /// (HistoryPane 의 표기와 독립 — 영문 단위 고정. 메시지는 채팅으로 가는
    /// 한 줄이라 i18n 단위보다 안정적인 축약형을 우선한다.)
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "<1m" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    /// 메시지 꼬리에 붙는 현재 상태 한 줄. 모든 입력이 nil/빈 값이면 nil.
    /// 예: "🔋 78% ⚡️ · 🌡 62°C · 🤖 claude · 💻 MacBook Pro"
    /// host 는 멀티 Mac 사용자가 어느 기계의 알림인지 구분하는 용도.
    static func statusLine(batteryPercent: Int?,
                           charging: Bool,
                           socTempCelsius: Double?,
                           activeAgents: [String],
                           host: String? = nil) -> String? {
        var parts: [String] = []
        if let b = batteryPercent {
            parts.append(charging ? "🔋 \(b)% ⚡️" : "🔋 \(b)%")
        }
        if let t = socTempCelsius {
            parts.append(String(format: "🌡 %.0f°C", t))
        }
        if !activeAgents.isEmpty {
            parts.append("🤖 " + activeAgents.sorted().joined(separator: ", "))
        }
        if let h = host, !h.isEmpty {
            parts.append("💻 " + h)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
