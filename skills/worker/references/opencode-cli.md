# OpenCode CLI — 검증된 사실

`opencode 1.18.18` 기준. 아래 항목은 **로컬에서 직접 실행해 확인**했다.
공식 문서: <https://opencode.ai/docs/cli/>, <https://opencode.ai/docs/agents/>

## headless 실행

```bash
opencode run "이 작업을 조사해라"
```

`opencode run --help` 로 확인한 실제 플래그:

| 플래그 | 의미 |
|---|---|
| `-m, --model <provider/model>` | 모델 지정 |
| `--agent <name>` | 에이전트 지정 |
| `--dir <path>` | 작업 디렉터리 (attach 시엔 서버 기준 경로) |
| `--format default\|json` | `json` 은 **raw JSON 이벤트 스트림** |
| `--attach <url>` | 이미 떠 있는 서버에 붙는다 |
| `-s, --session <id>` / `-c, --continue` / `--fork` | 세션 이어가기 |
| `-f, --file <path>` | 파일 첨부 (배열) |
| `--variant <name>` | provider별 reasoning effort (`high`, `max`, `minimal`) |
| `--auto` | 명시적으로 deny되지 않은 permission을 자동 승인 |
| `--pure` | 외부 플러그인 없이 실행 |
| `-p/--password`, `-u/--username` | 서버 basic auth |
| `--title`, `--share`, `--thinking`, `--print-logs`, `--log-level` | 부가 |

## 상주 백엔드

매 호출마다 새 프로세스를 띄우면 MCP/플러그인 cold boot 비용을 매번 낸다.
공식 문서도 이 이유로 서버 상주를 권한다.

```bash
opencode serve --hostname 127.0.0.1 --port 4096
```

`serve` 플래그: `--port`, `--hostname`, `--mdns`, `--mdns-domain`, `--cors`.

- **health check**: `GET http://127.0.0.1:4096/app` → `200` (실측)
- `OPENCODE_SERVER_PASSWORD` 미설정 시 서버는 unsecured 경고를 낸다.
  `ds-serve` 는 그래서 127.0.0.1 이외 바인드를 비밀번호 없이는 거부한다.

붙는 쪽:

```bash
opencode run --attach http://127.0.0.1:4096 --dir "$PWD" \
  --agent ds-explorer --model opencode-go/deepseek-v4-flash "..."
```

## `--format json` 출력 구조 (실측)

NDJSON이다. **한 줄에 이벤트 객체 하나.** 단일 JSON 문서가 아니다.

```json
{"type":"step_start","timestamp":...,"sessionID":"ses_...","part":{...}}
{"type":"text","timestamp":...,"sessionID":"ses_...","part":{"type":"text","text":"PROBE_OK",...}}
{"type":"step_finish",...,"part":{"reason":"stop","tokens":{"total":7665,"input":7661,"output":4,...},"cost":0.00168806}}
```

- 이벤트 타입: `step_start` · `text` · `tool_use` · `step_finish`
  (툴 이벤트는 `tool` 이 아니라 **`tool_use`** 다. `.part.tool` 에 툴 이름)
- 최종 답변 = 모든 `type=="text"` 이벤트의 `.part.text` 를 순서대로 이어붙인 것
- 비용/토큰 = `type=="step_finish"` 의 `.part.cost`, `.part.tokens`
- 세션 ID = 어느 이벤트든 `.sessionID`
- 경고 등 비-JSON 줄이 섞일 수 있으므로 파서는 `fromjson? // empty` 로 흘려보내야 한다

## 에이전트 정의

마크다운 파일 하나 = 에이전트 하나. **파일명이 에이전트 ID**.

경로는 `~/.config/opencode/agent/` 와 `~/.config/opencode/agents/` **둘 다 인식된다**
(프로브 파일로 실측). 이 스킬은 단수형 `agent/` 를 쓴다. 프로젝트 로컬은 `.opencode/agent/`.

```yaml
---
description: 필수
mode: subagent        # primary | subagent | all
model: provider/model
temperature: 0.1
permission:
  edit: deny
  bash: deny
---
시스템 프롬프트 본문
```

permission 키: `read` `edit` `glob` `grep` `list` `bash` `task` `external_directory`
`todowrite` `webfetch` `websearch` `lsp` `skill` `question` `doom_loop`.

**`--auto` 는 `deny` 를 뚫지 못한다.** explorer/reviewer 를 `edit: deny`, `bash: deny` 로
못박아 둔 것이 headless 자동승인 환경의 실제 안전장치다.

확인 명령: `opencode agent list`, `opencode models`, `opencode auth list`.

## 함정 — 전부 실측으로 데인 것들

이 넷은 **조용히** 실패한다. 에러가 안 뜨고 결과만 틀린다.

### 1. `mode: subagent` 는 `run --agent` 로 못 쓴다

```
! agent "ds-explorer" is a subagent, not a primary agent. Falling back to default agent
```

stderr에 경고 한 줄 남기고 **제한 없는 기본 에이전트로 실행된다.** 프롬프트도
permission도 통째로 사라진다. `--auto` 와 겹치면 무방비 에이전트가 도는 것이다.
→ 이 스킬의 에이전트는 전부 `mode: all`.

### 2. 심링크된 에이전트 파일은 런타임에 무시된다

`opencode agent list` 에는 **멀쩡히 보인다.** 그런데 실제 실행에는 프롬프트도
permission도 적용되지 않는다. 실파일로 복사해야 한다.
→ `install.sh` 는 `cp` 를 쓴다. `ln -s` 로 바꾸지 마라.

### 3. 없는 에이전트 이름을 줘도 에러가 아니다

`--agent no-such-agent-xyz` 는 그냥 기본 에이전트로 돈다. 오타가 조용히
샌드박스를 날린다.
→ `ds-worker` 는 호출 전 `agent list` 로 확인하고, 호출 후 stderr에서
`Falling back to default agent` 를 찾아 **exit 3 으로 하드 실패**시킨다.

### 4. 상주 백엔드는 부팅 시점의 에이전트 레지스트리를 캐시한다

에이전트 정의를 고쳐도 서버를 재시작하기 전까지는 옛 설정으로 돈다. 그리고 그
"옛 설정"이 `mode: subagent` 였다면 위 1번이 발동한다.
→ `ds-serve` 는 에이전트 파일 지문을 state에 기록하고, 달라지면 자동 재시작한다.

### 5. `--file` 은 배열 옵션이라 뒤따르는 프롬프트를 삼킨다

```
Error: File not found: [supervisor task | role=reviewer | cwd=...]  ← 프롬프트가 파일로 해석됨
```

→ 프롬프트 앞에 `--` 를 넣는다: `opencode run ... --file x.log -- "프롬프트"`

### 6. `task` / `skill` 은 permission 경계의 우회로다

`bash: deny` 인 에이전트도 `task` 도구가 살아 있으면 bash 권한을 가진 하위
에이전트를 띄워 우회할 수 있다. 실측 중 explorer가 스스로 이 경로를 지적했다.
→ 세 에이전트 모두 `task: deny`, `skill: deny`. 작업 분해는 supervisor의 권한이다.
차단 후 explorer의 도구는 `glob, grep, read, todowrite` 만 남는다 (실측).

### 검증된 안전장치

`mode: all` + 실파일 + `permission: {bash: deny}` 상태에서 `--auto` 를 줘도
bash는 실행되지 않는다 (실측: `NO_BASH`, tool 호출 0건).
**`--auto` 는 `deny` 를 뚫지 못한다.** 단, 위 1~4 중 하나라도 걸리면
에이전트 자체가 적용되지 않으므로 이 보장도 함께 사라진다.

## DeepSeek 모델 (이 머신에서 실제 사용 가능)

```
opencode/deepseek-v4-flash-free     # 무료 티어
opencode-go/deepseek-v4-flash       # 기본 explorer
opencode-go/deepseek-v4-pro         # 기본 worker / reviewer
```

바뀔 수 있다. 확인: `opencode models | grep deepseek`.

## OmO Slim (선택)

이 스킬은 OmO Slim 없이 동작한다. 함께 쓰면 에이전트별 모델을 따로 지정할 수 있다.

```bash
bunx oh-my-opencode-slim@latest install --preset=opencode-go
```

설정: `~/.config/opencode/oh-my-opencode-slim.json`.
