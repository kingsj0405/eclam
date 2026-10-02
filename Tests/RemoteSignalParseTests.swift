/// RemoteSignalParseTests.swift — `pmset -g assertions` 파서 검증 (2026-10-02).
///
/// 실사고 회귀: 요약 표의 "NetworkClientActive 0" 을 양성으로 읽어 네트워크
/// 클라이언트가 없어도 폴마다 `pmset:NetworkClient` 가 켜졌다. 보유 프로세스
/// 행(`pid …`)만 읽어야 한다.
///
/// 실행 (scripts/test.sh): RemoteSignalParse.swift 와 함께 단독 컴파일.

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

/// 2026-10-02 15:38 실측 출력 — 네트워크 클라이언트 0, 앱 자신의 디스플레이
/// assertion 과 Claude 의 Electron assertion 만 있다.
let idleOutput = """
2026-10-02 15:38:14 +0900
Assertion status system-wide:
   BackgroundTask                 0
   ApplePushServiceTask           0
   UserIsActive                   1
   PreventUserIdleDisplaySleep    1
   SoftwareUpdateTask             0
   PreventSystemSleep             0
   ExternalMedia                  0
   InternalPreventDisplaySleep    1
   PreventUserIdleSystemSleep     1
   NetworkClientActive            0
Listed by owning process:
   pid 34359(Claude): [0x000267e000018128] 09:12:48 NoIdleSleepAssertion named: "Electron"
   pid 419(WindowServer): [0x0002e7e3000991f8] 00:00:03 UserIsActive named: "com.apple.iohideventsystem.queue.tickle serviceID:10000103a service:AppleMultitouchDevice product:Apple Internal Keyboard / Trackpad eventType:11"
	Timeout will fire in 597 secs Action=TimeoutActionRelease
   pid 1388(ElectronicClam): [0x000293a80005862e] 06:06:00 PreventUserIdleDisplaySleep named: "Electronic Clam - keep display awake"
   pid 358(powerd): [0x0002a6d600018782] 04:44:10 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"
Kernel Assertions: 0x104=USB,MAGICWAKE
   id=596  level=255 0x100=MAGICWAKE creat=  mod= description=en0 owner=IOSkywalkNetworkBSDClient
   id=617  level=255 0x4=USB creat= description=com.apple.usb.externaldevice.00100000 owner=USB2.1 Hub
"""

/// 진짜 원격 세션 — 화면 공유 데몬이 NetworkClientActive 를 들고 있다.
let screenSharingOutput = """
Assertion status system-wide:
   NetworkClientActive            1
   PreventSystemSleep             1
Listed by owning process:
   pid 52655(screensharingd): [0x0000000100000123] 00:02:10 NetworkClientActive named: "com.apple.screensharing.client"
   pid 52655(screensharingd): [0x0000000100000124] 00:02:10 PreventSystemSleep named: "com.apple.screensharing.server"
"""

let ardOutput = """
Listed by owning process:
   pid 777(ARDAgent): [0x0000000100000777] 00:00:40 PreventSystemSleep named: "Apple Remote Desktop session"
"""

let networkSharingOutput = """
Listed by owning process:
   pid 789(launchd): [0x0000000100000789] 00:10:00 PreventUserIdleSystemSleep named: "com.apple.NetworkSharing"
"""

@main
enum RemoteSignalParseTestMain {
    static func main() {
        print("── 요약 표 오탐")
        assert(RemoteSignalParse.pmsetChannels(from: idleOutput).isEmpty,
               "보유 0 인 요약 행 'NetworkClientActive 0' 은 채널이 아니다")
        assert(RemoteSignalParse.pmsetChannels(from: "   NetworkClientActive            3\n").isEmpty,
               "요약 행은 개수가 0 이 아니어도 읽지 않는다 (보유 행이 정본)")
        assert(RemoteSignalParse.pmsetChannels(from: "").isEmpty, "빈 출력 ⇒ 빈 집합")

        print("── 보유 행 매칭")
        let ss = RemoteSignalParse.pmsetChannels(from: screenSharingOutput)
        assert(ss.contains("pmset:NetworkClient"), "screensharingd 의 NetworkClientActive ⇒ NetworkClient")
        assert(ss.contains("pmset:ScreenSharing"), "screensharingd 의 PreventSystemSleep ⇒ ScreenSharing")
        assert(ss.count == 2, "두 채널만")
        assert(RemoteSignalParse.pmsetChannels(from: ardOutput) == ["pmset:ARD"],
               "ARDAgent 의 PreventSystemSleep ⇒ ARD")
        assert(RemoteSignalParse.pmsetChannels(from: networkSharingOutput) == ["pmset:NetworkClient"],
               "com.apple.NetworkSharing 의 PreventUserIdleSystemSleep ⇒ NetworkClient")

        print("── 무관한 보유 행")
        let own = """
        Listed by owning process:
           pid 1388(ElectronicClam): [0x1] 00:01:00 PreventUserIdleDisplaySleep named: "Electronic Clam - keep display awake"
           pid 419(WindowServer): [0x2] 00:00:00 PreventSystemSleep named: "com.apple.WindowServer.PUIDS"
        """
        assert(RemoteSignalParse.pmsetChannels(from: own).isEmpty,
               "앱 자신의 디스플레이 assertion · WindowServer PUIDS 는 원격이 아니다")

        print("")
        print("RemoteSignalParse tests: \(passCount) passed, \(failCount) failed")
        if failCount > 0 { exit(1) }
    }
}
