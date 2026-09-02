# connor-pet

실제 [Orca](https://github.com/stablyai/orca)의 프로젝트/에이전트 상태에 반응하는 데스크톱 펫 — 리아코 (Totodile), 메타몽 (Ditto), 파이리 (Charmander), 꼬부기 (Squirtle), 꼬마돌 (Geodude), 이브이 (Eevee), 치코리타 (Chikorita), 아차모 (Torchic) 중 메뉴바 아이콘에서 언제든 전환 가능합니다. Orca에 임포트하는 `.codex-pet` 번들이 아니라, **완전히 별개의 macOS 앱**으로 만들었습니다. Orca와 다른 프로세스로 떠 있으면서, 바깥에서 Orca의 상태를 읽어옵니다.

![펫 목록](docs/pet-gallery.png)

## 어떻게 가능한가

Orca의 훅 서버는 열려있는 모든 에이전트 패널의 상태를 250ms 디바운스로 디스크에 계속 저장합니다 (`src/main/agent-hooks/server/server-persistence.ts`):

```
~/Library/Application Support/Orca/agent-hooks/last-status.json
```

이 파일은 Orca 자신도 재시작 후 상태를 복구할 때 쓰는 파일이라, 바깥에서 읽어도 안전한 정식 대상입니다(해킹이 아님). 대략적인 모양:

```json
{
  "version": 2,
  "entries": {
    "<paneKey>": {
      "state": "working" | "blocked" | "waiting" | "done",
      "worktreeId": "...",
      "receivedAt": 1735000000000
    }
  }
}
```

> **주의 (실제로 부딪힌 문제)**: 실제 파일을 열어보면 항목마다 모양이 다릅니다. 예를 들어 `SubagentStop` 훅에서 온 항목은 `state`/`prompt`/`agentType`이 최상위가 아니라 `payload` 안에 중첩되어 있었습니다. 처음엔 엄격한 Codable 구조체로 파싱했는데, 이 경우 항목 하나가 예상과 다른 모양이면 **파일 전체 파싱이 실패**해서 모든 패널의 상태가 조용히 사라지는 버그가 있었습니다. 지금은 `JSONSerialization`으로 느슨하게 파싱하면서 항목마다 최상위/`payload` 둘 다 확인하도록 고쳤습니다 (`OrcaStatusWatcher.swift`).

`ConnorPet`은 이 파일을 1초마다 폴링(Orca 자신의 쓰기 주기보다 넉넉함)해서, Orca 펫이 쓰는 것과 같은 우선순위 로직(`pet-agent-state.ts`의 `agentStateAnimation`)을 열려있는 **모든** 프로젝트/패널에 대해 그대로 돌립니다:

1. 하나라도 `blocked`/`waiting` → **waiting** (최우선, 즉시 확정)
2. 없고 하나라도 `working` → **running**
3. 없고 하나라도 `done` → **review**
4. 아무것도 없음 → **idle**

우선순위 로직 자체는 Orca 펫과 동일하게 포팅한 것이고, 여기에 각 상태를 포켓몬 상태이상
컨셉으로 다시 스킨했습니다: `waiting`=**얼음(Freeze)**, `review`=**헤롱헤롱(Infatuation)**,
`idle`=**잠듦(Sleep)**. `running`은 원래 그대로입니다.

여기에 Orca 에는 없는 `failed` 상태를 하나 더 두었습니다 — 도구가 에러를 반환했을 때
붉게 떨리는 모션입니다. 우선순위는 `waiting` 바로 아래로, 다른 패널이 돌고 있어도
실패가 묻히지 않습니다.

마우스를 올리면 **jumping**, 드래그하면 마우스를 따라 **running-left**/**running-right**.

### 클릭 / 우클릭

- **좌클릭** — 최근 작업을 브리핑합니다 (아래 "클릭하면 브리핑" 참고). 말하는 동안에는
  **waving** 모션이 재생되고, 말풍선이 떠 있을 때 한 번 더 누르면 닫힙니다.
- **우클릭** — 모션 메뉴. 9개 모션을 직접 골라 고정 재생할 수 있어 에이전트 상태를
  기다리지 않고 확인할 수 있습니다. `자동`을 고르면 다시 실시간 상태를 따릅니다.
- 드래그와 클릭은 이동 거리로 구분합니다(움직였으면 드래그, 아니면 클릭).

### 상태별로 실제 어떻게 보이는지

리아코 기준 예시입니다 (다른 펫도 스프라이트만 다를 뿐 동일한 리스킨 로직을 그대로 씁니다):

![idle / running / waiting / review](docs/pet-states.png)

- **idle → 잠듦**: 채도/밝기를 크게 낮추고 위로 떠오르며 사라지는 "Zzz"를 얹었습니다. 할 일이
  없을 때는 그냥 자고 있는 걸로.
- **running**: 색 변화 없이 빠른 바운스 루프 그대로 — 변경 없음.
- **waiting → 얼음**: 한 포즈에 고정(=멈춰있음)하고 각진 얼음 결정 오버레이(모서리에 삐죽
  튀어나온 조각 포함)를 씌웠습니다. 채도만 낮췄던 이전 버전보다 "완전히 멈췄음"이 훨씬 명확하게
  전달됩니다.
- **review → 헤롱헤롱**: 골드 톤 대신 핑크 톤 + 떠오르는 하트 이펙트로, "일 끝났다"는 긍정적인
  뉘앙스를 상태이상 컨셉 안에서 표현했습니다.

전부 `scripts/build_sheet.py`의 `tint()`/`desaturate()`에 더해 `draw_ice_crystal()`/
`draw_hearts()`/`draw_zzz()`로 PNG에 직접 구운 것이라, Swift 쪽 코드는 건드리지 않았습니다
(애니메이션 우선순위/재생 로직은 그대로, 스프라이트 픽셀만 다시 구운 것).

## 폴더 구조

```
totodile.codex-pet/     리아코(Totodile) Orca 임포트용 번들 (Settings → Experimental → Pet → Import)
  pet.json                 매니페스트: 9행 스프라이트 레이아웃, 프레임별 타이밍
  spritesheet.png            2400x1800, 최대 12열 x 9행, 프레임 200x200
                               (행마다 프레임 수가 다릅니다 — 남는 칸은 투명)

ditto.codex-pet/         메타몽(Ditto) Orca 임포트용 번들 — 위와 동일한 구조
charmander.codex-pet/    파이리(Charmander) Orca 임포트용 번들 — 위와 동일한 구조
squirtle.codex-pet/      꼬부기(Squirtle) Orca 임포트용 번들 — 위와 동일한 구조
geodude.codex-pet/       꼬마돌(Geodude) Orca 임포트용 번들 — 위와 동일한 구조
eevee.codex-pet/         이브이(Eevee) Orca 임포트용 번들 — 위와 동일한 구조
chikorita.codex-pet/     치코리타(Chikorita) Orca 임포트용 번들 — 위와 동일한 구조
torchic.codex-pet/       아차모(Torchic) Orca 임포트용 번들 — 위와 동일한 구조

scripts/build_sheet.py   재현 가능한 생성 스크립트 — `PETS` 리스트에 등록된 각 포켓몬마다
                          PokeAPI의 5세대 배틀 스프라이트를 받아서 `<slug>.codex-pet/`과
                          ConnorPet 앱의 번들 리소스를 함께 재생성합니다 (`python3 scripts/build_sheet.py`)

scripts/simulate_agent.py  실제 에이전트 없이 테스트하기 위한 도구. last-status.json에
                             가짜 패널 상태를 주입/삭제합니다 (아래 "테스트하기" 참고)

preview/index.html        브라우저 전용 미리보기: 실제 spritesheet.png + pet.json을 그대로
                            불러와서 Orca의 실제 CSS 스텝핑 알고리즘(buildSpriteAnimationCss)으로
                            재생. 여러 프로젝트/에이전트를 흉내내는 컨트롤 패널 포함. Orca 설치 불필요.

ConnorPet/                 진짜 결과물: 독립 실행형 macOS 앱
  Package.swift              (Swift Package, `swift run`만 있으면 됨 — Xcode 불필요)
  Sources/ConnorPet/
    OrcaStatusWatcher.swift    last-status.json 폴링 + 전체 상태 집계
    PetAnimationState.swift    포팅한 우선순위 로직 + 드래그 방향 판정
    SpriteSheet.swift           spritesheet.png를 애니메이션별 프레임 배열로 자름
    PetView.swift                프레임 렌더링, 호버/드래그/클릭/우클릭 모션 메뉴
    PetWindow.swift               테두리 없는 투명, 항상 위에 뜨는 NSWindow
    SessionBrief.swift             ~/.claude/projects 트랜스크립트에서 최근 세션 브리핑 추출
    SpeechBubbleWindow.swift        말풍선 패널 (펫 위에 뜨고, 화면 밖으로 안 나가게 보정)
    AppDelegate.swift              전체 연결 + 메뉴바 포켓몬 선택/Quit 메뉴
    Resources/pets/<slug>/          펫별 spritesheet.png + pet.json 번들 사본 (totodile, ditto, charmander, squirtle, geodude, eevee, chikorita, torchic)
```

## 실행 방법

```sh
cd ConnorPet
swift run
```

메뉴바에 작은 포켓볼 아이콘이 생깁니다. 클릭하면 리아코(Totodile)/메타몽(Ditto)/파이리(Charmander)/꼬부기(Squirtle)/꼬마돌(Geodude)/이브이(Eevee)/치코리타(Chikorita)/아차모(Torchic) 중 원하는 펫을 고를 수 있고(체크 표시가 현재 선택), 맨 아래 Quit으로 종료합니다. 선택한 펫은 다음 실행 때도 그대로 복원됩니다. 펫 자체는 화면 우측 하단 근처에 떠서 다른 창들 위에, 모든 Space에서 보입니다. Orca가 안 깔려있거나 활동 중인 패널이 없으면 그냥 idle 상태로 가만히 있습니다.

크기는 Orca 자체 기본값(`PET_SIZE_DEFAULT=180`)보다 작게, `90pt`로 맞춰뒀습니다 (`AppDelegate.swift`의 `petSize`). 더 키우거나 줄이고 싶으면 이 값만 바꾸면 됩니다.

## 클릭하면 브리핑

펫을 좌클릭하면 **최근 6시간 안에 쓴 세션 5개**를, 최근 이용 순으로, 세션당 100자·합계
500자 이내로 말풍선에 띄웁니다. 각 줄은 `· [프로젝트] 그 세션을 시작할 때 요청한 내용`
형태입니다.

출처는 Claude Code 자신의 트랜스크립트 디렉터리입니다.

```
~/.claude/projects/<슬러그화된-cwd>/<sessionId>.jsonl
```

**`claude` CLI 와 Claude Code 데스크톱 앱이 모두 여기에 기록**하고, 레코드마다 `entrypoint`
필드(`cli` / `claude-desktop`)로 구분되기 때문에 리더 하나로 양쪽을 다 커버합니다. 둘 중
아무것도 실행 중이 아니어도 읽힙니다.

트랜스크립트는 큽니다(실측 31MB 세션 존재). 클릭에 즉시 반응해야 하므로 파일을 통째로
읽지 않고 **앞부분 128KB 만** 읽습니다 — 필요한 건 그 세션을 무엇 때문에 시작했는지이고,
확인해 본 모든 최근 트랜스크립트에서 첫 사용자 메시지가 앞 8KB 안에 있었습니다.
슬래시 커맨드 껍데기·스킬 본문·주입된 리마인더처럼 사람이 쓴 요청이 아닌 레코드와,
12자 미만의 한 마디짜리 세션은 걸러냅니다 (`SessionBrief.swift`).

## 테스트하기 (실제 에이전트 없이)

```sh
python3 scripts/simulate_agent.py set web-app working
python3 scripts/simulate_agent.py set api-server blocked   # 펫이 즉시 "waiting"으로
python3 scripts/simulate_agent.py clear api-server         # "running"으로 복귀
python3 scripts/simulate_agent.py clear-all                # "idle"로 복귀
```

`connor-pet-test:` 접두어가 붙은 키로만 기록해서, 실제 Orca 패널(UUID 형태)과 절대 충돌하지 않습니다. `clear-all`도 이 접두어가 붙은 항목만 지웁니다.

**한 가지 알아둘 점**: Orca가 실제로 돌고 있고 실제 에이전트 활동이 생기면, Orca 자신이 다음 상태를 저장할 때 파일 전체를 자기 메모리 상태로 덮어써서 주입해둔 테스트 항목이 사라질 수 있습니다(실제로 테스트하다가 이렇게 됐습니다). 그럴 땐 그냥 `set` 명령을 다시 실행하면 됩니다 — 실제 데이터를 건드리는 게 아니라서 안전합니다.

동작 확인 로그를 보고 싶으면:
```sh
CONNORPET_DEBUG=1 swift run
```
어떤 패널이 어떤 규칙으로 최종 애니메이션을 결정했는지 stderr에 한 줄씩 찍힙니다.

## Orca 안에서 직접 쓰고 싶다면

Orca 자체 펫으로 쓰고 싶으면(Settings → Experimental → Pet → Import), 원하는 펫의 `<slug>.codex-pet/` 폴더(`totodile`/`ditto`/`charmander`/`squirtle`/`geodude`/`eevee`/`chikorita`/`torchic`)를 그대로 임포터에 지정하면 됩니다.

## 스프라이트 시트 다시 만들기

```sh
pip install pillow
python3 scripts/build_sheet.py
```

### 프레임 수와 확대 배율

원본 gen5 배틀 스프라이트는 **55프레임짜리 애니메이션 GIF** 입니다. 예전에는 행마다 4장만
뽑아 써서 재생이 슬라이드쇼처럼 끊겼고, 지금은 행마다 8~12장을 뽑습니다(`FRAME_SPEC`).

같이 고친 것 세 가지입니다.

- **프레임별 `autocrop` 제거** — 프레임마다 따로 잘라 중앙에 놓으면 원본 GIF 안에 들어 있던
  호흡·바운스가 전부 지워집니다. 전 프레임 **공통 bbox** 로 잘라야 프레임 간 상대 움직임이
  남습니다. 이어져 보이는 실제 이유가 이것입니다.
- **정수배 확대** — 41x42 도트를 3.571배로 NEAREST 확대하면 한 도트가 3px 이 되기도 4px 이
  되기도 해서 픽셀 격자가 무너집니다. 반올림한 정수 배율만 씁니다(내림으로 하면 꼬마돌이
  2.79배 → 2배로 28% 작아집니다).
- **오프셋 클램프** — `paste_centered` 가 dx/dy 를 프레임 안으로 잘라 냅니다. 예전에는
  점프 최고점에서 머리 위가 실제로 프레임 밖으로 나가 잘리고 있었습니다.

재생 속도는 원본의 자연 속도(55프레임 x 100ms = 5.5초 루프)를 기준으로 잡습니다.
`FRAME_SPEC` 의 주석에 모션마다 자연 속도의 몇 배인지 적어 두었습니다.

`scripts/build_sheet.py`의 `PETS` 리스트에 등록된 각 포켓몬(현재 리아코 #158, 메타몽 #132, 파이리 #4, 꼬부기 #7, 꼬마돌 #74, 이브이 #133, 치코리타 #152, 아차모 #255)마다 PokeAPI에서 5세대 애니메이션 배틀 스프라이트를 다시 받아서 `<slug>.codex-pet/{spritesheet.png,pet.json}`과 `ConnorPet/Sources/ConnorPet/Resources/pets/<slug>/`의 앱 번들 사본을 동시에 처음부터 재생성합니다 — 완전히 재현 가능하고, 바이너리 원본 에셋은 저장소에 커밋하지 않습니다. 새 포켓몬을 펫 선택 메뉴에 추가하려면 `PETS`에 항목을 하나 더 넣고 스크립트를 다시 돌린 뒤, `AppDelegate.swift`의 `availablePetSlugs`에 슬러그를 추가하면 됩니다.

## 크레딧 / 라이선스

캐릭터 스프라이트는 Nintendo/Game Freak/Creatures Inc.의 포켓몬 에셋을 [PokeAPI](https://pokeapi.co/) 경유로 가져온 것으로, 개인/데모 용도로만 사용하고 독립된 에셋으로 재배포하지 않습니다. 그 외 이 저장소의 모든 코드(빌드 스크립트, Swift 앱, 미리보기 페이지)는 자유롭게 재사용해도 됩니다.
