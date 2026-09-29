import SwiftUI

/// Command Line Tools에는 SwiftUI 매크로(@State)가 없어서 ObservableObject로 대신한다
final class SettingsUIState: ObservableObject {
    static let shared = SettingsUIState()
    @Published var tab: SettingsView.Tab = .rain
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var stats: RuntimeStats
    @ObservedObject var spaces: SpaceSync
    @ObservedObject private var ui = SettingsUIState.shared

    enum Tab: String, CaseIterable, Identifiable {
        case rain, water, drop, look, perf, desk
        var id: String { rawValue }
        var label: String {
            switch self {
            case .rain: return L("비", "Rain")
            case .water: return L("물", "Water")
            case .drop: return L("물방울", "Drops")
            case .look: return L("질감", "Look")
            case .perf: return L("성능", "Speed")
            case .desk: return L("데스크톱", "Desktops")
            }
        }
    }

    private var s: Binding<RainSettings> { $store.settings }

    var body: some View {
        VStack(spacing: 10) {
            header
            Picker("", selection: $ui.tab) {
                ForEach(Tab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch ui.tab {
                    case .rain: rainTab
                    case .water: waterTab
                    case .drop: dropTab
                    case .look: lookTab
                    case .perf: perfTab
                    case .desk: deskTab
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 8)
            }
            .frame(height: 430)

            if let msg = store.statusMessage {
                Text(msg).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: 머리/꼬리

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text(store.settings.enabled ? "💩" : "💀")
                    .font(.title2)
                Text("Rainpane").font(.headline)
                Spacer()
                // 언어 전환: 바꿀 언어 이름을 보여 준다
                Button(store.settings.language == .en ? "한국어" : "English") {
                    store.settings.language = store.settings.language == .en ? .ko : .en
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                Toggle("", isOn: s.enabled).toggleStyle(.switch).labelsHidden()
            }
            // 비만, 또는 마우스 물방울만 쓸 수 있게 따로 켜고 끈다
            HStack(spacing: 18) {
                Toggle(L("비", "Rain"), isOn: s.rainEnabled)
                Toggle(L("마우스 물방울", "Mouse drops"), isOn: s.pressEffect)
                Spacer()
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!store.settings.enabled)
            HStack(spacing: 6) {
                ForEach(RainPreset.allCases) { preset in
                    Button(preset.label) { preset.apply(to: &store.settings) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(stats.paused ? L("대기 중 (비 없음)", "Idle (no rain)") : String(format: L("%.0f fps · CPU %.0f%% · GPU %.1fms/프레임 · 창 %d", "%.0f fps · CPU %.0f%% · GPU %.1fms/frame · windows %d"), stats.fps, stats.cpuPercent, stats.gpuMs, stats.windows))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button(L("기본값", "Defaults")) {
                let enabled = store.settings.enabled
                store.settings = RainSettings()
                store.settings.enabled = enabled
            }
            .controlSize(.small)
            Button(L("종료", "Quit")) { NSApp.terminate(nil) }
                .controlSize(.small)
        }
    }

    // MARK: 탭들

    @ViewBuilder private var rainTab: some View {
        Group {
            section(L("빗줄기", "Rain streaks"))
            slider(L("양", "Amount"), s.intensity, 0...1, pct)
            slider(L("바람", "Wind"), s.wind, -0.8...0.8, signed)
            slider(L("돌풍", "Gusts"), s.gustiness, 0...1, pct)
            slider(L("낙하 속도", "Fall speed"), s.fallSpeed, 0.4...2, mult)
            slider(L("빗줄기 길이", "Streak length"), s.streakLength, 0.3...2.5, mult)
            slider(L("빗줄기 굵기", "Streak width"), s.streakWidth, 0.4...2.5, mult)
            slider(L("밝기", "Brightness"), s.rainOpacity, 0.05...1, pct)
        }
        Group {
            section(L("깊이", "Depth"))
            slider(L("창 한 겹당 비 가시도", "Rain visibility per window layer"), s.depthStep, 0...1, pct,
                   hint: L("맨 앞 창엔 비가 없고, 뒤 창일수록 이만큼씩 비가 더 보여요", "The front window gets no rain. Each window further back gets this much more"))
            slider(L("바탕화면 비", "Rain on desktop"), s.desktopRain, 0...1, pct)
            slider(L("가까운 빗방울 흐림", "Blur on close raindrops"), s.depthOfField, 0...1, pct)
            ColorPicker(L("빗줄기 색", "Streak color"), selection: rainColor, supportsOpacity: false)
                .font(.callout)
        }
    }

    @ViewBuilder private var waterTab: some View {
        Group {
            section(L("고이는 물", "Pooling water"))
            Toggle(L("창 윗변에 물 고이기", "Water pools on window tops"), isOn: s.pooling)
            slider(L("최대 높이", "Max height"), s.poolCapacity, 1...12, pt)
            slider(L("고이는 속도", "Pooling speed"), s.accumulation, 0.1...4, mult)
            slider(L("증발", "Evaporation"), s.evaporation, 0...1, pct)
            slider(L("창 끌 때 출렁임", "Slosh when dragging windows"), s.sloshing, 0...3, mult)
            Toggle(L("관성 (창을 확 내리면 물이 공중에 남음)", "Inertia (water stays in midair if a window moves down fast)"), isOn: s.poolInertia)
            slider(L("창 모서리 반경", "Window corner radius"), s.cornerRadius, 0...30, pt)
            slider(L("모서리 곡선 (원호 ↔ macOS 연속 곡률)", "Corner curve (arc ↔ macOS continuous curvature)"), s.cornerSmoothness, 0...1, pct)
            slider(L("위젯 모서리 반경", "Widget corner radius"), s.widgetCornerRadius, 0...40, pt)
        }
        Group {
            section(L("흐르는 물", "Running water"))
            Toggle(L("옆면 물줄기", "Streams down the sides"), isOn: s.streams)
            slider(L("물줄기 굵기", "Stream width"), s.streamWidth, 0.3...2.5, mult)
            Toggle(L("모서리 낙수", "Drips from corners"), isOn: s.drips)
            Toggle(L("빗방울 튀김", "Raindrop splashes"), isOn: s.splashes)
            slider(L("튀김 양", "Splash amount"), s.splashAmount, 0...2, mult)
        }
        Group {
            section(L("창 닫을 때", "When a window closes"))
            Toggle(L("수막이 화면을 타고 흘러내림", "Water sheet slides down the screen"), isOn: s.curtain)
            slider(L("수막 세기", "Water sheet strength"), s.curtainStrength, 0.2...2.5, mult)
        }
        Group {
            section(L("창 유리 위 물방울", "Drops on window glass"))
            Toggle(L("천장에서 물방울이 또르르", "Drops roll down from the top edge"), isOn: s.windowDroplets)
            slider(L("빈도", "Frequency"), s.dropletFrequency, 0.05...2, mult)
            // 둘은 함께 켤 수 없다 (둘 다 끄면 맨 앞 창에만)
            Toggle(L("맨 앞 창뿐 아니라 모든 창에", "On all windows, not just the front one"), isOn: Binding(
                get: { store.settings.dropletsOnAllWindows && !store.settings.dropletsExceptFront },
                set: { store.settings.dropletsOnAllWindows = $0; if $0 { store.settings.dropletsExceptFront = false } }))
            Toggle(L("맨 앞 창 빼고 모든 창에", "On all windows except the front one"), isOn: Binding(
                get: { store.settings.dropletsExceptFront },
                set: { store.settings.dropletsExceptFront = $0; if $0 { store.settings.dropletsOnAllWindows = false } }))
        }
    }

    /// 마우스로 누른 물방울 (PressEffect)
    @ViewBuilder private var dropTab: some View {
        Group {
            section(L("누르기", "Press"))
            if GlassPress.available {
                Toggle(L("리퀴드 글래스 재질", "Liquid Glass material"), isOn: s.pressGlass)
            }
            slider(L("톡 클릭 크기", "Quick click size"), s.pressTapRadius, 8...90, pt, hint: L("짧게 클릭했을 때 퍼지는 반경", "How far a drop spreads on a quick click"))
            slider(L("누르고 있을 때 최대 크기", "Max size while held"), s.pressMaxRadius, 16...120, pt)
            slider(L("퍼지는 속도", "Spread speed"), s.pressGrowSpeed, 0.3...3, mult)
            slider(L("사라지는 속도", "Fade speed"), s.pressShrinkSpeed, 0.3...3, mult)
        }
        Group {
            section(L("끌 때", "Dragging"))
            slider(L("늘어나는 정도", "Stretch"), s.pressStretch, 0...2.5, mult)
            slider(L("멈출 때 말랑하게 출렁임", "Soft wobble when it stops"), s.pressWobble, 0...3, mult)
        }
        Group {
            section(L("잔 물방울", "Small droplets"))
            Toggle(L("누르고 뗄 때 잔 물방울이 튐", "Small droplets fly off on press and release"), isOn: s.pressSatellites)
            slider(L("개수", "Count"), s.pressSatelliteCount, 0.3...2.5, mult)
            slider(L("크기", "Size"), s.pressSatelliteSize, 0.4...2.5, mult)
            slider(L("퍼지는 거리", "Spread distance"), s.pressSatelliteDistance, 0...3, mult)
            slider(L("이어지는 목 길이", "Neck length"), s.pressNeck, 0.2...3, mult, hint: L("본 방울과 잔 물방울이 이만큼 가까우면 목으로 이어져요", "Small droplets this close to the main drop join it with a neck"))
        }
        Group {
            section(L("그림자", "Shadow"))
            slider(L("진하기", "Darkness"), s.pressShadow, 0...0.5, pct)
            slider(L("퍼짐", "Spread"), s.pressShadowSpread, 0.3...3, mult)
        }
        if GlassPress.available {
            Group {
                section(L("리퀴드 글래스", "Liquid Glass"))
                slider(L("굴절 세기", "Refraction strength"), s.pressGlassRefraction, 0...3, mult)
                slider(L("흐림", "Blur"), s.pressGlassBlur, 0...12, pt, hint: L("0이면 완전히 맑아요", "At 0 the glass is fully clear"))
                slider(L("밝은 배경에서 보이기", "Visibility on light backgrounds"), s.pressGlassLightBG, 0...1, pct, hint: L("밝은 배경을 살짝 어둡게 비춰요. 0이면 완전히 투명해요", "The drop slightly darkens light backgrounds. At 0 it is fully transparent"))
                slider(L("어두운 배경에서 보이기", "Visibility on dark backgrounds"), s.pressGlassDarkBG, 0...2, pct, hint: L("어두운 배경을 살짝 밝게 비춰요", "The drop slightly brightens dark backgrounds"))
            }
        }
        Group {
            section(L("다른 입력", "Other input"))
            Toggle(L("스크롤할 때 잔 물방울이 흩날림", "Small droplets scatter when scrolling"), isOn: s.pressScrollDust)
            Toggle(L("키보드: Enter·Tab 때 커서 자리에도", "Keyboard: also at the cursor on Return and Tab"), isOn: s.keyboardPress)
            Text(L("켜면 손쉬운 사용 권한을 물어요. Enter·Tab 말고는 보지 않고, 입력한 내용은 읽지 않아요.", "Asks for Accessibility permission when turned on. Watches only Return and Tab. Never reads what you type."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var lookTab: some View {
        section(L("빛", "Light"))
        slider(L("빛 방향", "Light direction"), s.lightAngle, -90...90, deg)
        slider(L("반짝임", "Highlights"), s.specular, 0...2, mult)
        slider(L("가장자리 어둠", "Edge darkness"), s.rimDarkness, 0...1, pct)
        slider(L("물 색조", "Water tint"), s.waterTint, 0...0.5, pct)
    }

    /// 비 효과와 상관없는 편의 기능 (SpaceSync)
    @ViewBuilder private var deskTab: some View {
        section(L("모니터 데스크톱", "Desktops across displays"))
        Toggle(L("한 모니터에서 넘기면 다른 모니터도 같은 번호로", "Switch other displays to the same desktop number"), isOn: s.spaceSync)
        Text(L("시스템 설정 → 키보드 → 키보드 단축키 → Mission Control에서 \"데스크톱 N(으)로 전환\"을 켜 두어야 해요. 이 기능을 켜면 손쉬운 사용 권한을 물어요.", "Turn on \"Switch to Desktop N\" in System Settings → Keyboard → Keyboard Shortcuts → Mission Control. Turning this on asks for Accessibility permission."))
            .font(.caption).foregroundStyle(.secondary)
        Text(L("그 번호의 데스크톱이 없는 모니터와 전체 화면 앱이 떠 있는 모니터는 그대로 둬요.", "Skips displays that don't have that desktop or are showing a full-screen app."))
            .font(.caption).foregroundStyle(.secondary)
        if store.settings.spaceSync {
            Text(spaces.summaryText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .onAppear { spaces.refresh() }
            if let p = spaces.problemText {
                Text(p).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !spaces.missingHotkeys.isEmpty {
                Text(L("꺼진 단축키: 데스크톱 ", "Shortcuts off: Desktop ") + spaces.missingHotkeys.map(String.init).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.orange)
                Button(L("꺼진 단축키 켜기 (Ctrl+숫자)", "Turn on these shortcuts (Control+number)")) { spaces.enableMissingHotkeys() }
                    .controlSize(.small)
                Text(L("시스템 설정 → 키보드 → 키보드 단축키에서 직접 켜는 것과 같아요. 10번까지만 돼요.", "Same as turning them on in System Settings → Keyboard → Keyboard Shortcuts. Works only up to Desktop 10."))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var perfTab: some View {
        section(L("프레임", "Frame rate"))
        Picker(L("최대 FPS", "Max FPS"), selection: s.maxFPS) {
            Text("30").tag(30); Text("60").tag(60); Text("120").tag(120)
        }
        .pickerStyle(.segmented)
        Toggle(L("적응형 (평소 30fps, 창 움직일 때만 최대)", "Adaptive (30fps normally, max only while windows move)"), isOn: s.adaptiveFPS)
        Text(L("투명 전체 화면은 그림 내용과 상관없이 갱신 횟수만큼 WindowServer 부하가 생겨요. 가장 효과가 큰 절약 옵션이에요.", "A transparent full-screen overlay adds WindowServer load on every refresh, no matter what it draws. This option saves the most."))
            .font(.caption).foregroundStyle(.secondary)
        slider(L("렌더 해상도", "Render resolution"), s.renderScale, 0.5...1, pct, hint: L("낮추면 GPU 부담이 줄고 빗줄기가 약간 부드러워져요", "Lower values use less GPU and make streaks a bit softer"))
        Toggle(L("배터리·저전력·발열 시 30fps", "30fps on battery, in Low Power Mode, or when hot"), isOn: s.batterySaver)
        Toggle(L("전체 화면 앱이 덮고 있으면 그리지 않기", "Pause when a full-screen app covers the screen"), isOn: s.pauseWhenCovered)
        section(L("캡처", "Screenshots"))
        Toggle(L("화면을 녹화할 때 비 숨기기", "Hide rain while recording the screen"), isOn: s.hideWhileRecording)
        Text(L("스크린샷 영역이나 창을 고르는 동안에는 늘 숨겨요. 녹화는 macOS 스크린샷 도구로 할 때만 알아채요.",
               "Rain is always hidden while you pick a screenshot area or window. Only recordings made with the macOS Screenshot tool are detected."))
            .font(.caption).foregroundStyle(.secondary)
        section(L("기타", "Other"))
        Toggle(L("로그인 시 자동 실행", "Open at login"), isOn: s.launchAtLogin)
        Picker(L("메뉴바 아이콘", "Menu bar icon"), selection: s.iconStyle) {
            ForEach(StatusIconStyle.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        Text(L("비가 0이고 물이 잠잠해지면 렌더링을 완전히 멈춰요.", "Rendering stops completely when rain is at 0 and the water is still."))
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: 도우미

    private var rainColor: Binding<Color> {
        Binding(
            get: { Color(red: store.settings.rainR, green: store.settings.rainG, blue: store.settings.rainB) },
            set: { c in
                if let ns = NSColor(c).usingColorSpace(.sRGB) {
                    store.settings.rainR = ns.redComponent
                    store.settings.rainG = ns.greenComponent
                    store.settings.rainB = ns.blueComponent
                }
            })
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.subheadline.bold()).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ fmt: @escaping (Double) -> String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(fmt(value.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).controlSize(.small)
            if let hint { Text(hint).font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    private func mult(_ v: Double) -> String { String(format: "×%.2f", v) }
    private func pt(_ v: Double) -> String { String(format: "%.1f pt", v) }
    private func deg(_ v: Double) -> String { String(format: "%.0f°", v) }
    private func signed(_ v: Double) -> String { v == 0 ? "0" : String(format: v > 0 ? "→ %.2f" : "← %.2f", abs(v)) }
}
