# connor-pet

Orca 또는 Claude Code의 프로젝트/에이전트 상태에 반응하는 데스크톱 펫 (리아코/Totodile 등 8종, 메뉴바에서 전환). 자세한 배경·아키텍처·동작 방식은 `README.md`가 최신 소스이므로 거기를 먼저 읽을 것.

## 구조

- `ConnorPet/` — 실제 결과물인 독립 macOS 앱 (Swift Package, Xcode 불필요)
  - `Sources/ConnorPet/OrcaStatusWatcher.swift` — `last-status.json` 폴링(1s) + 상태 집계 (Orca 소스)
  - `Sources/ConnorPet/ClaudeCodeStatusWatcher.swift` — `~/.claude/sessions/*.json`(항상) + `~/.claude/connor-pet-status.json`(훅 설치 시)을 250ms마다 폴링해 병합 (Claude Code 소스, 기본값)
  - `Sources/ConnorPet/PetAnimationState.swift` — 우선순위 로직 포팅 + `AgentStatusWatching` 프로토콜 (`acknowledgeDone()`으로 헤롱헤롱 호버-해제) + 토큰/진화 필드
  - `Sources/ConnorPet/TokenUsage.swift` — 트랜스크립트 JSONL에서 실제 토큰 사용량 합산(`TranscriptTokenReader`, mtime 캐시) + 토큰→경험치%/진화단계 매핑(`XPModel`)
  - `Sources/ConnorPet/SpriteSheet.swift`, `PetView.swift`(펫 아래 경험치 바 포함), `PetWindow.swift` — 렌더링
  - `Sources/ConnorPet/AppDelegate.swift` — 앱 연결, 메뉴바 아이콘/펫 선택/소스 선택/경험치 바 토글/진화 사용 토글/진화 % 설정 메뉴 + 경험치%에 따른 진화 스프라이트 교체(`evolutionChains`, 임계치·on-off는 사용자 설정)
  - `Sources/ConnorPet/Resources/pets/<slug>/` — 펫별 `spritesheet.png` + `pet.json` 번들 사본
- `<slug>.codex-pet/` (totodile/ditto/charmander/squirtle/geodude/eevee/chikorita/torchic) — Orca에 직접 임포트 가능한 번들
- `scripts/build_sheet.py` — PokeAPI에서 스프라이트를 다시 받아 각 펫의 시트를 재생성 (`PETS` 리스트가 소스 오브 트루스)
- `scripts/simulate_agent.py` — 실제 에이전트 없이 `last-status.json`에 가짜 상태 주입 (Orca 소스 전용)
- `scripts/install_claude_hooks.py` — 위 훅 핸들러를 `~/.claude/settings.json`에 병합/제거(`--uninstall`)하는 설치 스크립트. 기존 훅(matcher 걸린 것 포함) 안 건드리고, 재실행해도 중복 안 됨
- `scripts/claude_hook_status.py` — Claude Code 훅 핸들러 (선택 설치, README "Claude Code 훅으로 얼음/헤롱헤롱까지 보기" 참고). `~/.claude/settings.json`은 전역 설정이라 **사용자 명시적 동의 없이 이 저장소가 대신 실행하지 않는다** — 스크립트/README로 안내만 하고, 사용자가 직접 돌리거나 명시적으로 요청해야 실행
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
- **`main` 브랜치는 보호 룰셋이 없음**: write 권한이 있는 협업자는 PR/승인 없이 `main`에 직접 push 가능하고, force-push/브랜치 삭제도 막혀있지 않다. 협업자 현황 확인 명령: `gh api repos/pet-egg/pet/collaborators --jq '.[] | {login, permissions}'`. 룰셋 현황 확인 명령: `gh api repos/pet-egg/pet/rulesets`.
