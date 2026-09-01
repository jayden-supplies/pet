# connor-pet

Orca의 프로젝트/에이전트 상태에 반응하는 데스크톱 펫(리아코/Totodile). 자세한 배경·아키텍처·동작 방식은 `README.md`가 최신 소스이므로 거기를 먼저 읽을 것.

## 구조

- `ConnorPet/` — 실제 결과물인 독립 macOS 앱 (Swift Package, Xcode 불필요)
  - `Sources/ConnorPet/OrcaStatusWatcher.swift` — `last-status.json` 폴링 + 상태 집계
  - `Sources/ConnorPet/PetAnimationState.swift` — 우선순위 로직 포팅
  - `Sources/ConnorPet/SpriteSheet.swift`, `PetView.swift`, `PetWindow.swift` — 렌더링
  - `Sources/ConnorPet/AppDelegate.swift` — 앱 연결, 메뉴바 아이콘/메뉴
  - `Sources/ConnorPet/Resources/` — `spritesheet.png` + `pet.json` 번들 사본 (아래 두 파일과 동일 내용 유지)
- `totodile.codex-pet/` — Orca에 직접 임포트 가능한 번들 (`pet.json`, `spritesheet.png`)
- `scripts/build_sheet.py` — PokeAPI에서 스프라이트를 다시 받아 시트를 재생성
- `scripts/simulate_agent.py` — 실제 에이전트 없이 `last-status.json`에 가짜 상태 주입
- `preview/index.html` — 브라우저 전용 미리보기 (Orca 설치 불필요)

## 빌드 / 실행 / 테스트

```sh
cd ConnorPet
swift build          # 컴파일만 확인
swift run            # 실제 앱 실행
CONNORPET_DEBUG=1 swift run   # 상태 판정 로그를 stderr로 출력
```

에이전트 상태 없이 테스트:
```sh
python3 scripts/simulate_agent.py set web-app working
python3 scripts/simulate_agent.py clear-all
```

UI/동작을 변경했으면 반드시 `swift run`으로 실제 앱을 띄워서 확인할 것 (빌드 성공 ≠ 동작 확인).

## 작업 시 반드시 지킬 것

- **README.md ↔ GitHub repo description 항상 일치**: 이 저장소의 목적·구성을 바꾸는 작업(기능 추가/제거, 앱 이름 변경, 아이콘·동작 변경 등)을 하면 `README.md`를 갱신하고, repo description도 같은 내용으로 맞출 것. 확인/변경 명령:
  ```sh
  gh repo view --json description
  gh repo edit --description "<새 설명>"
  ```
  README와 실제 동작이 어긋나는 부분(예: 코드에서 바뀐 아이콘·플래그·경로가 README에 옛날 그대로 남아있는 경우)을 발견하면 관련 작업이 아니어도 그 자리에서 같이 고칠 것.
- **브랜치 전략 없음, 항상 main에 push**: 이 저장소는 기능 브랜치/PR 없이 `main` 하나로만 운영한다. 별도 요청이 없는 한 작업이 끝나면 변경사항을 커밋하고 `git push origin main`까지 완료한 뒤 마칠 것.
- **커밋 메시지는 항상 한글로 작성**: 제목/본문 모두 한글로 쓸 것 (`Co-Authored-By:` 트레일러 등 고정 형식 줄은 예외).
