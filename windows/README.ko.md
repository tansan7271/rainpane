# Rainpane 윈도우판 (실험)

[English](README.md)

Rainpane을 윈도우로 옮긴 버전입니다. 맥판보다 훨씬 더 실험적입니다.

- Claude Code가 맥판을 보고 한 번의 긴 세션에서 옮겼습니다. 물 시뮬레이션과 셰이더는 맥판 코드를 거의 그대로 따르고, 윈도우에 붙는 부분은 새로 짰습니다.
- Windows 11 ARM 가상 머신(Apple Silicon Mac의 VMware Fusion)에서만 돌려 봤습니다. 실제 윈도우 PC, x64, 모니터 여러 대에서는 한 번도 돌려 보지 않았습니다.
- 미리 빌드한 파일은 없습니다. 직접 빌드해야 합니다.
- 버그가 있을 겁니다. 가상 머신에서 잰 프레임과 CPU 수치는 의미가 적습니다.

## 되는 것

- 비는 창 뒤로 내립니다. 맨 앞 창은 젖지 않습니다.
- 창 윗변에 물이 고이고, 옆면으로 흘러내리고, 아래 모서리에서 떨어집니다. 창 유리 위로 물방울이 굴러 내려옵니다.
- 창을 닫거나 최소화하면 고여 있던 물이 화면을 타고 수막처럼 흘러내립니다. 가상 데스크톱을 바꾸면 물은 보관합니다.
- 작업 표시줄과 메뉴는 비를 가립니다. 작업 표시줄이 아래에 있으면 그 윗변에서 빗방울이 튑니다.
- 마우스 물방울. 선택: 스크롤 먼지, 키보드 물방울.
- 설정 창. 영어와 한국어를 지원합니다. 트레이 아이콘을 왼쪽 클릭하면 열립니다.
- 선택, 더 실험적: 유리 물방울. 윈도우에는 리퀴드 글래스가 없어서, 물방울 뒤 화면을 복사해 셰이더에서 휘어 그립니다.

윈도우판에 없는 것:

- 모니터 데스크톱 함께 넘기기. 윈도우는 원래 모든 모니터가 함께 넘어갑니다.
- 바탕화면 위젯.

## 빌드

필요한 것: Windows 10 2004 이상(Windows 11 권장), MSVC 툴체인의 [Rust](https://rustup.rs), C++ 워크로드를 설치한 Visual Studio Build Tools.

```sh
cd windows
cargo build --release
target\release\rainpane.exe
```

맥에서 빌드하려면 [cargo-xwin](https://github.com/rust-cross/cargo-xwin)을 씁니다. Microsoft CRT와 Windows SDK 파일을 내려받는데, 이는 그 파일에 대한 Microsoft 라이선스에 동의하는 것입니다.

```sh
cargo install cargo-xwin
rustup target add aarch64-pc-windows-msvc   # 또는 x86_64-pc-windows-msvc
cd windows
cargo xwin build --release --target aarch64-pc-windows-msvc
```

앱은 트레이에 있습니다. ^ 화살표 안에 숨어 있을 수 있습니다. 왼쪽 클릭하면 설정이 열리고, 오른쪽 클릭하면 끄기와 종료 메뉴가 나옵니다.

## 권한과 개인정보

윈도우는 아래 기능에 권한을 요청하지 않습니다. 앱이 읽는 것은 이렇습니다.

- 화면에 있는 창의 위치, 크기, 클래스 이름, 스타일. 창 제목은 읽지 않습니다.
- 마우스 버튼과 휠 (Raw Input).
- 키보드 물방울 (기본 꺼짐): Enter나 Tab을 눌렀는지만 봅니다. 다른 키는 무시합니다. 포커스된 요소의 종류, 위치, 크기, 텍스트 커서 위치를 UI Automation으로 읽습니다. 입력한 내용은 읽지 않고, 비밀번호 칸에서는 커서 위치도 묻지 않습니다.
- 유리 물방울 (기본 꺼짐): 물방울이 화면에 있는 동안 Desktop Duplication API로 화면을 복사합니다. 이미지는 GPU 안에서만 쓰고 저장하지 않습니다. 유리 물방울을 켜 두면 비 창은 늘 스크린샷과 녹화에서 빠집니다.

설정은 `%APPDATA%\Rainpane\settings.json`에 저장합니다. "로그인 시 자동 실행"은 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`에 값을 추가합니다. 네트워크에 연결하지 않습니다.

## 맥판과 다른 점

- 창이 사라진 이유(닫힘, 최소화, 다른 가상 데스크톱으로 이동)를 윈도우가 알려 줍니다. 맥판은 최소화 애니메이션과 미션 컨트롤을 보고 짐작해야 합니다.
- 비는 클릭이 통과하는 항상 위 창에 Direct3D 11로 그립니다 (DirectComposition). Metal 셰이더를 HLSL로 옮겼습니다.
- 스크린샷과 녹화: 스크린샷 도구를 감지하지 않고, 윈도우의 캡처 제외 기능(`SetWindowDisplayAffinity`)을 씁니다.
- 설정 창은 egui를 Direct3D 11로 그립니다. 윈도우 ARM 기기 중에는 OpenGL이 없는 경우가 있어서입니다.

시험용 옵션: `--debug`를 붙이면 exe 옆에 `rainpane.log`를 씁니다. `--quit-after N`, `--intensity X`, `--press "x,y,누름,뗌[,dx,dy]"`, `--glass`, `--settings`, `--tab 이름`은 마우스 없이 가상 머신에서 확인할 때 썼습니다.

## 라이선스

프로젝트의 나머지와 같은 MIT입니다. `assets/`의 아이콘은 Font Awesome Free(아이콘: CC BY 4.0)와 Microsoft Fluent Emoji(MIT)에서 가져왔습니다. 라이선스 파일은 `assets/`에 있습니다.
