import Foundation
import Combine

/// 화면 언어. 기본은 영어, 설정 창 맨 위 버튼으로 한국어와 바꾼다
enum AppLanguage: String, Codable {
    case en, ko
    static var current: AppLanguage = .en
}

/// 화면 문구: 한국어와 영어를 나란히 적고 지금 언어에 맞는 쪽을 쓴다 (문구가 많지 않아 번역 파일 없이)
func L(_ ko: String, _ en: String) -> String { AppLanguage.current == .ko ? ko : en }

/// 모든 사용자 설정. 새 필드를 추가해도 기존 저장값과 호환되도록 load()에서 기본값 위에 병합한다.
struct RainSettings: Codable, Equatable {
    // 일반
    var enabled = true                   // 전체 (메뉴바 아이콘 오른쪽 클릭으로도 켜고 끔)
    var language: AppLanguage = .en      // 화면 언어
    var rainEnabled = true               // 비와 창 위의 물 (끄면 마우스 물방울만)

    // 비
    var intensity: Double = 0.271          // 0..1 빗방울 양
    var wind: Double = 0.35              // -1..1 기울기 (dx/dy)
    var gustiness: Double = 0.448         // 돌풍
    var fallSpeed: Double = 1.0
    var streakLength: Double = 1.0
    var streakWidth: Double = 1.911
    var rainOpacity: Double = 0.774
    var depthStep: Double = 0.099          // 창 한 겹 뒤로 갈 때마다 비가 보이는 비율
    var desktopRain: Double = 1.0        // 바탕화면에서의 비 가시도
    var depthOfField: Double = 1.0       // 가까운 빗방울 흐림
    var rainR: Double = 0.72
    var rainG: Double = 0.762
    var rainB: Double = 0.843

    // 물
    var pooling = true
    var poolCapacity: Double = 2.533         // pt, 윗변에 고이는 최대 높이
    var accumulation: Double = 4.0
    var evaporation: Double = 0.15
    var streams = true
    var streamWidth: Double = 1.498
    var drips = true
    var sloshing: Double = 0.999
    var poolInertia = true               // 창을 아래로 빠르게 끌면 물이 공중에 남음
    var cornerRadius: Double = 19.961
    var cornerSmoothness: Double = 0.262   // 0 = 원호, 1 = macOS 연속 곡률(squircle)
    var widgetCornerRadius: Double = 30  // 바탕화면 위젯 모서리 반경 (창보다 둥글다)
    var curtain = true
    var curtainStrength: Double = 1.096
    var windowDroplets = true            // 창 천장에서 흘러내리는 물방울
    var dropletFrequency: Double = 2.0
    var dropletsOnAllWindows = true
    var dropletsExceptFront = false      // 맨 앞(포커스) 창만 빼고 모든 창에 (켜면 dropletsOnAllWindows는 꺼짐)
    var splashes = true
    var splashAmount: Double = 2.0

    // 물방울 (마우스로 누르기)
    var pressEffect = true               // 누른 자리에 물이 눌려 퍼졌다가 떼면 오므라듦
    var pressGlass = true                // macOS 리퀴드 글래스 재질로 그리기 (macOS 26+)
    var pressTapRadius: Double = 25      // pt, 톡 클릭 때 퍼지는 반경
    var pressMaxRadius: Double = 48      // pt, 누르고 있을 때 퍼지는 최대 반경
    var pressGrowSpeed: Double = 1.0
    var pressShrinkSpeed: Double = 1.0
    var pressStretch: Double = 1.0       // 끌 때 늘어나는 정도
    var pressWobble: Double = 1.0        // 멈출 때 말랑하게 출렁이는 정도
    var pressSatellites = true           // 누르고 뗄 때 잔 물방울이 튐
    var pressSatelliteCount: Double = 1.0
    var pressSatelliteSize: Double = 1.0
    var pressSatelliteDistance: Double = 1.0
    var pressNeck: Double = 1.0          // 잔 물방울과 이어지는 목 길이
    var pressShadow: Double = 0.15       // 그림자 진하기 (최대 알파)
    var pressShadowSpread: Double = 1.0
    var pressGlassRefraction: Double = 1.0
    var pressGlassBlur: Double = 0       // pt, 유리 흐림 (0 = 완전히 맑게)
    // 민무늬 배경에서도 보이게 (0 = 완전히 투명). 어두운 쪽은 같은 비율로는 잘 안 보여서 따로 둔다
    var pressGlassLightBG: Double = 0.25 // 밝은 배경을 어둡게 비추는 정도
    var pressGlassDarkBG: Double = 1.0   // 어두운 배경을 밝게 비추는 정도
    var pressScrollDust = false          // 스크롤할 때 커서 둘레에 잔 물방울이 흩날림
    var keyboardPress = false            // Enter·Tab 때 커서·포커스 자리에 톡 클릭 물방울 (손쉬운 사용 권한: 켤 때만 묻는다)

    // 데스크톱 (비 효과와 따로)
    var spaceSync = false                // 한 모니터에서 데스크톱을 넘기면 다른 모니터도 같은 번호로 (손쉬운 사용 권한: 켤 때만 묻는다)

    // 질감
    var lightAngle: Double = 40.341         // 도. 0 = 위, 음수 = 왼쪽 위
    var specular: Double = 1.398
    var rimDarkness: Double = 0.499
    var waterTint: Double = 0.198

    // 성능
    var maxFPS: Int = 60
    var adaptiveFPS = false              // 켜면 평소 30fps, 움직임이 있을 때만 maxFPS
    var renderScale: Double = 1.0
    var batterySaver = false
    var pauseWhenCovered = true
    var hideWhileRecording = true        // macOS 스크린샷 도구로 화면을 녹화하는 동안 비를 숨김 (고르는 동안은 늘 숨김)
    var launchAtLogin = false
    var iconStyle: StatusIconStyle = .fontAwesome   // 메뉴바 아이콘 스타일

    static let storageKey = "RainSettings.v1"

    static func load() -> RainSettings {
        let defaults = RainSettings()
        // 이름을 바꾸기 전(Raindrop, local.raindrop)에 저장한 설정이 있으면 가져온다
        let saved = UserDefaults.standard.data(forKey: storageKey)
            ?? UserDefaults(suiteName: "local.raindrop")?.data(forKey: storageKey)
        guard let saved,
              let savedDict = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
              let defData = try? JSONEncoder().encode(defaults),
              var dict = try? JSONSerialization.jsonObject(with: defData) as? [String: Any]
        else { return defaults }
        dict.merge(savedDict) { _, new in new }
        guard let merged = try? JSONSerialization.data(withJSONObject: dict),
              let result = try? JSONDecoder().decode(RainSettings.self, from: merged)
        else { return defaults }
        return result
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

enum RainPreset: String, CaseIterable, Identifiable {
    case drizzle, normal, shower, storm

    var id: String { rawValue }
    var label: String {
        switch self {
        case .drizzle: return L("이슬비", "Drizzle")
        case .normal: return L("보통 비", "Moderate rain")
        case .shower: return L("소나기", "Shower")
        case .storm: return L("폭풍우", "Storm")
        }
    }

    func apply(to s: inout RainSettings) {
        switch self {
        case .drizzle:
            s.intensity = 0.2; s.wind = 0.05; s.gustiness = 0.15; s.fallSpeed = 0.75
            s.streakLength = 0.7; s.streakWidth = 0.8; s.rainOpacity = 0.4; s.accumulation = 0.5
        case .normal:
            s.intensity = 0.5; s.wind = 0.12; s.gustiness = 0.35; s.fallSpeed = 1.0
            s.streakLength = 1.0; s.streakWidth = 1.0; s.rainOpacity = 0.5; s.accumulation = 1.0
        case .shower:
            s.intensity = 0.8; s.wind = 0.08; s.gustiness = 0.3; s.fallSpeed = 1.15
            s.streakLength = 1.15; s.streakWidth = 1.1; s.rainOpacity = 0.55; s.accumulation = 1.6
        case .storm:
            s.intensity = 1.0; s.wind = 0.35; s.gustiness = 0.8; s.fallSpeed = 1.3
            s.streakLength = 1.3; s.streakWidth = 1.15; s.rainOpacity = 0.6; s.accumulation = 2.2
        }
    }
}

final class SettingsStore: ObservableObject {
    @Published var settings: RainSettings {
        didSet {
            guard settings != oldValue else { return }
            AppLanguage.current = settings.language
            scheduleSave()
            onChange?(settings, oldValue)
        }
    }
    /// 굴절 등에서 발생한 오류를 설정 창에 보여주기 위함
    @Published var statusMessage: String?

    var onChange: ((RainSettings, RainSettings) -> Void)?
    private var saveWork: DispatchWorkItem?

    init() {
        settings = RainSettings.load()
        AppLanguage.current = settings.language
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settings.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

/// 설정 창에 표시할 실시간 통계
final class RuntimeStats: ObservableObject {
    @Published var fps: Double = 0
    @Published var windows: Int = 0
    @Published var frameMs: Double = 0      // 틱 한 번의 벽시계 시간 (화면 그림판 대기 포함). 디버그 로그용
    @Published var cpuPercent: Double = 0   // 앱 전체 CPU 사용률 (활성 상태 보기와 같은 단위: 100% = 코어 하나)
    @Published var gpuMs: Double = 0
    @Published var paused = false
}
