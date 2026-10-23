# 세션 허브 설계 (1·2단계)

여러 프로젝트·worktree 에서 동시에 띄운 emu 세션을 한 화면에서 보고 고르고 정리한다.
세션마다 서버 하나(`emu __serve`)라는 지금 구조는 그대로 둔다 — CLI·에이전트는 계속 세션 서버를 직접
부른다. 허브는 그 위에 얹는 **목록 + 껍데기**다.

- 1단계: 세션 레지스트리 + 포트 자동 배정 + `emu ls`
- 2단계: `emu hub` — 왼쪽 서랍(세션 목록·하단 버전 정보) + 오른쪽에 고른 세션의 기존 대시보드
- (3단계, 이 문서 밖) 허브 URL 을 감싸는 macOS 메뉴바 앱

## 지금 상태와 문제

| 항목 | 지금 | 문제 |
|---|---|---|
| 세션 위치 | 프로젝트별 `.emu/server.json`(port·pid·token) | 프로젝트를 모르면 어떤 세션이 떠 있는지 알 수 없다 |
| 포트 | 기본 4577 고정(`--port`·`emu.yaml port` 로 변경) | 두 번째 프로젝트는 포트를 손으로 바꿔야 한다 |
| 기기 점유 | `~/.emu/devices/<기기>.json`(lease) | 누가 잡고 있는지는 `emu devices` 로만 보인다 |
| 대시보드 | 세션마다 다른 포트·다른 탭 | 탭이 흩어지고, 잊힌 세션이 남는다 |
| 대시보드 보안 | 토큰이 `index.html` 에 들어 있고 `frame-ancestors 'none'` | 다른 페이지 안에 넣을 수 없다(허브에서 풀어야 함) |

## 1단계 — 레지스트리, 포트 자동 배정, `emu ls`

### 레지스트리 `~/.emu/sessions/<id>.json`
- `id` = 프로젝트 루트 절대경로의 sha1 앞 12자리. 한 프로젝트에 세션은 하나라는 지금 규칙과 맞는다
  (worktree 는 루트가 다르므로 다른 세션).
- 서버가 bind 에 성공한 직후 쓰고(`server.json` 과 같은 시점), 종료할 때 지운다. 내용:
  ```json
  { "id": "3f2a…", "project": "/…/app", "name": "app", "port": 4578, "pid": 123,
    "device": {"id": "emulator-5554", "name": "sdk gphone64", "platform": "android"},
    "flavor": null, "mockPort": 4591, "emuVersion": "0.13.0", "startedAt": "…" }
  ```
  `name` 은 pubspec `name:`. 기기는 기동 후 정해지므로 정해지면 한 번 더 쓴다.
- **토큰은 넣지 않는다.** 토큰은 지금처럼 프로젝트의 `.emu/server.json` 에만 있다.
- 쓰기는 임시 파일 → rename(반쯤 쓰인 파일이 없게). 읽는 쪽은 lease 와 같은 `serverAlive`
  (pid + `/api/status` 응답)로 살아 있는지 보고, 죽은 파일은 지운다. 강제 종료로 남은 찌꺼기도 이걸로 정리된다.
- `~/.emu/projects.json` — 최근 프로젝트(경로·이름·마지막 시작 시각, 최대 20개). 허브의 "다시 시작"에 쓴다.

### 포트 자동 배정
상한·범위는 두지 않는다. 순서:
1. `--port` 나 `emu.yaml port` 가 있으면 그 포트(쓰이고 있으면 기존처럼 근처 포트로).
2. 없으면 이 프로젝트가 지난번 쓴 포트(`~/.emu/projects.json`). 같은 프로젝트가 같은 origin 을 쓰면 브라우저에
   기억된 그 대시보드 설정(패널 크기·screen 폭 등)이 유지된다.
3. 그것도 안 되면 4577 부터 위로 첫 빈 포트. `mocks:` 가 켜진 프로젝트는 목 서버 포트(p+13, p+14)도 비어 있어야 한다.
4. 후보는 실제로 bind 해 보고 고른다. 그 사이 다른 세션이 잡으면 서버의 기존 fallback(다음 포트)이 받는다.

CLI 가 세션을 찾는 방식은 그대로(cwd → `.emu/server.json`)라 영향이 없다.

### `emu ls`
```
$ emu ls
  app          :4577  emulator-5554 (android)  running  2h   ~/work/app
  app-wt-fix   :4578  iPhone 16 (ios)          stopped  5m   ~/work/app-wt-fix
  sample       :4579  —                        starting 10s  ~/tmp/sample
```
- `--json`: 레지스트리 내용 + 살아 있는 상태(`/api/status` 의 state).
- `emu down --project <경로|이름|id>`: cwd 가 아닌 세션 종료. `emu down --all` 은 확인 후 전부.
- `emu devices` 의 `(in use: …)` 에 프로젝트 이름을 같이 보인다.

## 2단계 — `emu hub`

### 실행
- `emu hub [--no-open]`: 상주 서버. 이미 떠 있으면(`~/.emu/hub.json` 의 pid + 응답 확인) 브라우저만 연다.
- 포트는 지정받지 않는다. 4576 을 먼저 쓰고, 쓰이고 있으면 다음 빈 포트를 쓴 뒤 실제 포트를
  `~/.emu/hub.json`(port·pid·token)에 기록한다. 모든 쪽(세션의 프레임 허용, `emu hub`, `emu up` 안내)은 이 파일을 본다.
  평소 같은 포트를 쓰는 이유는 주소(origin)가 같아야 브라우저에 기억한 설정(서랍·테마·마지막 세션)과
  북마크·앱 창이 유지되기 때문이다.
- `emu up` 은 허브를 띄우지 않는다. 허브가 떠 있으면 대시보드 링크와 함께 허브 링크를, 없으면 `emu hub` 를 한 줄 안내한다.
- 세션이 없어도 뜬다(빈 상태 화면). 허브를 꺼도 세션에는 영향이 없다.

### 화면 구성
```
┌──────────────────────────┬──────────────────────────────────────────────┐
│ ☰ emu                    │                                              │
│ ────────────────────────│                                              │
│ 세션              [+ 시작]│                                              │
│ ● app            :4577 ⋮│      고른 세션의 기존 대시보드 (iframe)          │
│   emulator-5554 · 2h     │      (topbar · 탭 · screen 그대로)              │
│ ○ app-wt-fix     :4578   │                                              │
│   iPhone 16 · stopped    │                                              │
│ ◌ sample         :4579   │                                              │
│   starting…              │                                              │
│ ────────────────────────│                                              │
│ 기기                    ▾│                                              │
│   emulator-5554 → app    │                                              │
│   iPhone 16     → app-wt │                                              │
│   QA_AVD_2      (비어 있음)│                                             │
│ ────────────────────────│                                              │
│ 최근 프로젝트           ▸│                                              │
│ ────────────────────────│                                              │
│ ⚙  ◐  v0.13.0 · 새 버전 0.14.0 │                                       │
└──────────────────────────┴──────────────────────────────────────────────┘
```
- **서랍(왼쪽 240px)**: ☰ 로 접고 펼치며 이 브라우저에 기억한다. 좁은 폭(≤900px)에서는 화면 위에 덮어 열고,
  고르기·바깥 누르기·Esc 로 닫는다.
  - **세션 목록**: 상태 점(running · starting · stopped/crashed · 응답 없음) + 이름 + 포트,
    둘째 줄은 기기 · 상태 · 가동 시간. 활성 목 시나리오가 있으면 `mock: qa` 배지.
    정렬은 최근 시작 순서.
  - 줄마다 **⋮ 메뉴**: 새 창으로 열기 · 프로젝트 경로 복사 · Finder 에서 열기 · Hot restart · 종료(`emu down`,
    확인 후). ⋮ 는 줄을 고르지 않고 Esc·바깥 누르기로 닫는다.
  - **기기**(접을 수 있음): `emu devices` + lease. 어느 세션이 잡고 있는지, 비어 있는 기기.
  - **최근 프로젝트**(접을 수 있음): 지금 안 떠 있는 프로젝트. [시작] 은 그 프로젝트에서 `emu up` 을 실행하고
    출력을 보여 준다(기기는 그 프로젝트의 `emu.yaml` 기본값, 필요하면 기기 고르기).
  - **하단 바**: ⚙ 허브 설정 · 테마(라이트 → 다크 → 시스템) · 버전.
    - 버전: 허브 바이너리 버전 `v0.13.0`. GitHub 최신 태그(`latestReleaseVersion`, 1시간 캐시)가 더 높으면
      `· 새 버전 0.14.0` 을 강조해 표시한다. 누르면 그 사이 CHANGELOG 절과 `emu update` 명령을 보여 준다.
    - 세션의 `emuVersion` 이 허브와 다르면 그 세션 줄에 `v0.12.0` 흐린 배지(다시 띄우면 새 버전).
- **본문(오른쪽)**: 고른 세션의 대시보드 `http://127.0.0.1:<port>/` 를 iframe 으로 보인다. 지금 대시보드를 그대로
  쓰므로 UI 를 두 벌로 만들지 않는다.
  - 최근에 고른 세션 3개까지는 iframe 을 숨겨 둔 채 유지한다. 그래서 다시 고르면 바로 보이고, 로그 WebSocket 도
    끊기지 않는다.
  - 주소는 `#/s/<id>`. 새로고침해도 같은 세션이 열린다.
  - 세션이 없으면 빈 상태 화면(최근 프로젝트와 `emu up` 안내)을 보인다.

### 데이터 흐름
- 허브는 `~/.emu/sessions/` 를 감시(`Directory.watch`, 실패하면 2초 주기)하고, 세션마다 `/api/status` 를
  3초마다 조회한다. 변화는 허브의 WebSocket 으로 서랍에 밀어 준다.
- 세션 종료·restart 같은 동작은 허브 **서버**가 해당 프로젝트의 `.emu/server.json` 토큰으로 세션 API 를 부른다
  (CLI 와 같은 권한·같은 파일). 세션 토큰은 브라우저의 허브 페이지로 넘어가지 않는다.
- 세션 대시보드 → 허브 알림(선택): iframe 안의 대시보드가 `postMessage({type:'emu-state', state, errors})` 를
  허브 origin 으로만 보낸다. 서랍 줄에 에러 수 배지를 붙이는 용도다. 받는 쪽은 `event.origin` 이 등록된 세션 포트인지 확인한다.

### 보안
- **허브**: 세션 서버와 같은 가드(`api_guard.dart`)를 쓴다 — loopback Host, 자기 origin, 시작마다 새 토큰
  (`index.html` 에 주입). 허브 API 가 하는 일(세션 종료, `emu up` 실행)이 세션 API 수준이기 때문이다.
- **세션 대시보드의 프레임 허용**: 지금 `frame-ancestors 'none'` + `X-Frame-Options: DENY`.
  `index.html` 응답 시 `~/.emu/hub.json` 을 읽고, 살아 있는 허브가 있으면
  `frame-ancestors http://127.0.0.1:<허브포트> http://localhost:<허브포트>` 로 바꾸고 `X-Frame-Options` 를 뺀다.
  없으면 지금처럼 `'none'`.
  - 허브 페이지는 iframe 내용을 읽을 수 없다(다른 origin). 그래서 토큰은 여전히 그 세션 페이지 안에만 있다.
    열리는 위험은 허브 origin 의 클릭재킹뿐인데, 그 origin 은 emu 허브 자신이다.
  - 허브 포트에 다른 프로세스가 떠 있는 경우는 `hub.json` 의 pid + 허브 `/api/status` 의 `{hub:true}` 로 확인한다.
- **"시작"으로 실행하는 경로**: 최근 프로젝트 목록(`projects.json`)에 있거나 사용자가 허브에서 직접 입력한
  경로에서 `pubspec.yaml` 이 있는 곳만 허용한다. 실행은 `emu up` 과 같은 인자 규칙을 따른다(셸 해석 없음).

## 구현 순서(PR)
1. **레지스트리 + 포트 자동 배정 + `emu ls` / `emu down --project|--all`** — `lib/src/registry.dart`, 서버 시작·종료
   지점, cli. 테스트: 쓰기·정리(죽은 pid), 포트 고르기, ls 출력.
2. **허브 서버(4576 우선, 빈 포트 fallback) + 서랍 UI + iframe** — `lib/src/hub.dart`(shelf, 가드 재사용), `web/hub.html`·`hub.js`·`hub.css`
   (기존 토큰·테마 변수 공유), 세션 쪽 `frame-ancestors` 변경, 하단 버전 표시.
3. **허브 동작** — ⋮ 메뉴(종료·restart·경로), 기기 섹션, 최근 프로젝트 [시작], `postMessage` 배지.
