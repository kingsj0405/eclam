// RemoteSignalParse.swift — 원격 세션 신호의 순수 파서.
//
// `RemoteWatcher` 가 폴링하는 `pmset -g assertions` 출력에서 채널 집합을 뽑는
// 함수만 둔다. Foundation 만 사용 — OSLog·Subprocess 호출 금지. `scripts/test.sh`
// 가 Tests/RemoteSignalParseTests.swift 와 함께 단독 컴파일한다.
//
// 분리한 이유 (2026-10-02 실사고): 예전 파서는 출력 전체를 줄 단위로 훑으며
// "networkclientactive" 가 들어간 줄을 전부 양성으로 봤다. 그런데 출력 머리의
// 요약 표는 보유 개수가 0 이어도 종류 이름을 찍는다 —
//
//     Assertion status system-wide:
//        NetworkClientActive            0
//
// 그래서 네트워크 클라이언트가 하나도 없어도 폴마다 `pmset:NetworkClient` 가
// 양성이었고, 그 깜빡임이 1분짜리 에피소드와 Slack 종료 알림을 분 단위로
// 만들어 냈다(한 시간에 49건). 이제는 "Listed by owning process:" 아래의
// `pid N(이름): [...] 종류 named: "..."` 행만 읽는다.

import Foundation

enum RemoteSignalParse {

    /// `pmset -g assertions` 출력 → 원격 세션 채널 라벨 집합.
    ///
    /// 보유 프로세스 행(`pid ` 로 시작)만 본다. 요약 표와 "Kernel Assertions:"
    /// 절(`id=` 로 시작)은 무시한다. 라벨은 기존 UI·history 와 같다 —
    /// `pmset:NetworkClient` · `pmset:ScreenSharing` · `pmset:ARD`.
    ///
    /// 보유 행 안에서는 예전처럼 느슨하게 매칭한다. 여기서의 오탐은 "깨어 있기"
    /// 쪽이라 원격 세션 감지기에는 안전한 방향이다.
    static func pmsetChannels(from text: String) -> Set<String> {
        var found: Set<String> = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // 보유 프로세스 행만:
            //   pid 123(screensharingd): [...] NetworkClientActive named: "..."
            //   pid 456(ARDAgent): [...] PreventSystemSleep named: "..."
            //   pid 789(launchd): [...] PreventUserIdleSystemSleep named: "com.apple.NetworkSharing"
            guard line.hasPrefix("pid ") else { continue }
            let lower = line.lowercased()
            if lower.contains("networkclient") || lower.contains("com.apple.networksharing") {
                found.insert("pmset:NetworkClient")
            }
            if lower.contains("preventsystemsleep") || lower.contains("preventuseridlesystemsleep") {
                if lower.contains("screensharing") {
                    found.insert("pmset:ScreenSharing")
                }
                if lower.contains("apple remote desktop") || lower.contains("ardagent") {
                    found.insert("pmset:ARD")
                }
            }
        }
        return found
    }
}
