# worker

[English](README.md) · **한국어**

Claude나 Codex를 **감독자(supervisor)** 자리에 두고, 넓고 반복적인 작업을
직접 고른 모델에 맡기는 스킬입니다. 로컬 모델 서버든 OpenCode가 접근할 수 있는
호스팅 API든 쓸 수 있고, 그 모델은 샌드박스가 걸린 OpenCode 에이전트로 실행됩니다.
명령어는 `ds-worker`이고, *ds*는 **delegated subagent**(위임받은 하위 에이전트)의
줄임말입니다.

```
        ┌──────────────────────────┐
        │ Claude / Codex           │
        │ SUPERVISOR               │  분해 · 결정 · 검증
        └────────────┬─────────────┘
                     │ ds-worker (Bash)
        ┌────────────▼─────────────┐
        │ opencode run --standalone│  OpenCode v2: 호출마다 전용 서버
        │   (or --server: ds-serve)│  DS_SERVE=auto, 비밀번호 보호
        └────────────┬─────────────┘
                     │ --agent --model $DS_MODEL
       ┌─────────────┼─────────────┐
       ▼             ▼             ▼
  ds-explorer   ds-worker    ds-reviewer
   읽기 전용     쓰기 가능    읽기 전용

  ds-worker critic   doc-critic, 다른 모델의 검토
  ds-worker direct   OpenCode·도구 없이 채팅 요청 한 번
```

감독자가 작업을 나누고, 결정하고, 돌아온 결과를 모두 검증합니다. 워커는
샌드박스 안에서 읽고, 찾고, 고칩니다. 워커의 결과는 감독자가 확인하기 전까지는
주장일 뿐입니다. 자세한 내용은
[`references/verification.md`](skills/worker/references/verification.md)를 보세요.

## 준비물

- [OpenCode](https://opencode.ai) v2. 이 도구가 의존하는 CLI 형식은
  `tests/test_opencode_v2_contract.sh`가 확인합니다. 그 밖에 `jq`, `curl`,
  `perl`, `git`이 필요합니다.
- `opencode models` 목록에 나오는, OpenCode가 접근할 수 있는 모델 하나:
  - **로컬**: OpenAI 호환 서버(vLLM, llama.cpp, Ollama, LM Studio 등)를
    `~/.config/opencode/opencode.jsonc`에 provider로 추가합니다.
  - **호스팅**: `opencode auth login`으로 로그인한 provider면 됩니다.

## 설치

```bash
./install.sh --model <provider/model>              # e.g. the name `opencode models` prints
./install.sh --model <provider/model> --critic-model <another/model>
```

터미널에서 `--model` 없이 실행하면 쓸 수 있는 모델 목록을 보여 주고 물어봅니다.

- OpenCode 페르소나 4개(`ds-explorer`, `ds-reviewer`, `ds-worker`,
  `doc-critic`) → `~/.config/opencode/agent/`
- `ds-worker` / `ds-serve` / `ds-doctor` / `ds-worker-rr` / `sync-agents` → `~/.local/bin/`
- `/doc-review` 명령 → `~/.config/opencode/command/`
- 스킬 → `~/.claude/skills/worker` · `~/.codex/skills/worker`
- `DS_MODEL`(와 `DS_MODEL_CRITIC`) → `~/.config/ds-worker/config`. 설치기는
  OpenCode 자체 설정을 건드리지 않습니다.

```bash
ds-doctor      # diagnostics: tools, credentials, model, agents, endpoint
```

## 사용법

```bash
ds-worker explorer "Find every call site of checkToken in src/ — list all of them, not a sample. file:line required."
ds-worker reviewer --file test.log "Rank the root-cause candidates for this failure, reading the log to its end."
ds-worker worker "checkToken at src/auth.ts:42 returns 500 for an expired token. Make it 401. Verify: npm test -- auth"
ds-worker critic --file docs/plan/foo.md "Audit the supplied document before delivery."
ds-worker direct --file test.log "Rank the root-cause candidates."   # no OpenCode, no tools
sync-agents                 # check persona registry drift
sync-agents --install       # install managed persona updates
```

`direct`는 파일 내용을 프롬프트에 넣어, 모델의 OpenAI 호환 엔드포인트로 채팅
요청을 한 번 바로 보냅니다. `curl`과 `jq`만 있으면 되므로 OpenCode CLI가 바뀌어도
계속 동작합니다. 모델에게 도구가 없으니 필요한 자료는 모두 넘겨 주세요. 호스팅
API를 쓴다면 `DS_MODEL_API_KEY_ENV`에 API 키가 든 환경변수의 **이름**을 적습니다.

```bash
ds-serve start|status|stop    # resident v2 backend; password in ~/.local/state/ds-worker/serve.password (0600)
```

```bash
bash tests/test_opencode_v2_contract.sh                    # CLI shape vs. the installed opencode
DS_CONTRACT_LIVE=1 bash tests/test_opencode_v2_contract.sh # + real round trips to your model
for t in tests/test_*.sh; do bash "$t"; done               # unit tests (stubbed opencode)
```

## 설정

설정 파일은 `~/.config/ds-worker/config`이고,
[`config.example`](skills/worker/config.example)을 바탕으로 `install.sh`가
만듭니다. 우선순위는 **환경변수 > 설정 파일 > 기본값**입니다. 평소 설정은
파일에 두고, 한 번만 바꿀 때는 환경변수를 쓰면 됩니다.

```bash
ds-doctor --config        # every setting, its value, and where that value came from
```

설정 파일을 스킬 폴더 옆이 아니라 사용자 설정 폴더에 두는 데는 이유가 있습니다.
스킬 폴더는 여러 도구나 계정에 연결해 쓰는 git 체크아웃일 수 있어서, 거기 둔
설정 파일은 모든 사용자가 쓸 수 있는 것도 아니고, 고칠 때마다 작업 트리가
더러워집니다.

설정 파일은 실행(source)하지 않고 읽기만(parse) 합니다. 모르는 키는 줄 번호와
함께 알려 주고 무시하며, 파일 안의 어떤 것도 실행되지 않습니다.

| 설정 | 기본값 |
|---|---|
| `DS_MODEL` | 없음 — `install.sh --model`이 정함, 모든 역할이 사용 |
| `DS_MODEL_EXPLORER` / `DS_MODEL_REVIEWER` / `DS_MODEL_WORKER` | `DS_MODEL` |
| `DS_MODEL_EXPLORER_FALLBACK` / `DS_MODEL_REVIEWER_FALLBACK` / `DS_MODEL_WORKER_FALLBACK` | 비어 있음 |
| `DS_MODEL_CRITIC` | 비어 있음(OpenCode 기본 모델; `DS_MODEL`과 다른 모델 권장) |
| `DS_MODEL_RETRIES` | `2`(다음 모델로 넘어가기 전 모델당 시도 횟수) |
| `DS_MODEL_ENDPOINT` | 비어 있음(`opencode.jsonc`에 있는 provider의 `baseURL`) |
| `DS_MODEL_AUTODETECT` | `1`(모델 하나를 서빙하는 서버를 따라감) |
| `DS_MODEL_API_KEY_ENV` | 비어 있음(`direct`용 API 키가 든 환경변수 이름) |
| `DS_RR_MODELS` | 비어 있음(`ds-worker-rr`이 돌려 쓸 모델 목록) |
| `DS_IDLE_TIMEOUT` | NDJSON 출력 없이 `1200`초(`0`이면 끔) |
| `DS_MAX_RUNTIME` | `3600`초 |
| `DS_TIMEOUT` | `3600`초(`DS_MAX_RUNTIME`의 옛 이름) |
| `DS_PROGRESS_INTERVAL` | `15`초(`0`이면 진행 알림 끔) |
| `DS_AUTO_RECOVER_READONLY` | `1`(explorer/reviewer 복구 한 번) |
| `DS_RECOVERY_IDLE_TIMEOUT` / `DS_RECOVERY_MAX_RUNTIME` | `60` / `180`초 |
| `DS_OPENCODE_HOST` / `DS_OPENCODE_PORT` | `127.0.0.1` / `4096`(사용 중이면 위로 찾음) |
| `DS_PORT_SCAN` | `20`(`DS_OPENCODE_PORT`부터 시도할 포트 수) |
| `DS_SERVE` | `off`(`auto`면 `ds-serve` 백엔드 사용; 호출당 약 1.7초 절약, 복구는 계속 `--standalone`) |
| `DS_AUTO` | `1`(`--auto` 전달) |
| `DS_STATE_DIR` | `~/.local/state/ds-worker` |

### 모델 고르기

`opencode models`에 나오는 모델이면 무엇이든 됩니다. 도구가 미리 정해 둔 모델은
없습니다. `explorer`와 `reviewer`는 감독자가 어차피 결과를 검증하므로 작고 빠른
모델로 충분한 경우가 많습니다. `worker`는 코드를 쓰고, 그럴듯하지만 틀린 수정이
가장 비싼 실패이므로 더 강한 모델을 따로 줄 만합니다(`DS_MODEL_WORKER`).
`critic`은 교차 모델 검토이므로 `DS_MODEL`과 다른 모델을 주세요.

`ds-worker`는 역할의 모델을 `DS_MODEL_RETRIES`번까지 시도하고, 그다음 fallback
모델을 `DS_MODEL_RETRIES`번까지 시도하며, 처음 성공하면 멈춥니다.
`--model <provider/model>`을 주면 그 호출 한 번은 이 순서를 건너뜁니다. JSON
결과에는 실제로 쓴 모델이 남습니다(`model`, `attempts`, `fallback_used`).

한 번에 모델 하나만 올리는 로컬 서버에서는 다른 모델을 올리는 순간 설정해 둔
이름이 맞지 않게 됩니다. 자동 감지는 엔드포인트에 어떤 모델을 서빙하는지 묻고,
그것이 모델 하나일 때만 따라갑니다. 항목이 하나이거나, 같은 가중치의 별칭들
(vLLM이 `--served-model-name` 별칭을 같은 `root`로 보여 주는 경우)일 때입니다.
그리고 provider 카탈로그에 있는 모델로만 바꿉니다. 설정한 이름이 별칭 중 하나면
그대로 두고, 여러 모델을 내놓는 호스팅 API에서는 설정한 모델을 유지합니다.

- `explorer`는 읽고 찾기만 합니다.
- `reviewer`는 파일을 바꾸지 않고 로그, diff, 테스트 출력을 진단합니다.
- `worker`는 정확히 지정된 수정을 하고 검증 결과를 보고합니다. 시간 초과가
  수정 도중에 날 수 있으므로, `worker`는 `--dir`이 git 작업 트리이고 시작
  때와 달라진 것이 없다고 확인될 때만 다음 시도로 넘어갑니다. 그렇지 않으면
  바로 멈추고 중간 결과를 감독자에게 넘깁니다. 아래 "안전 모델"을 보세요.

느린 로컬 추론 모델이라면 OpenCode provider 설정에서 `chunkTimeout`과 전체
`timeout`을 정하세요. `ds-worker`는 이와 별도로 NDJSON 출력 활동을 지켜보고
`DS_MAX_RUNTIME`을 적용합니다.

## 안전 모델

- `ds-explorer`와 `ds-reviewer`는 `edit: deny`, `bash: deny`를 선언합니다.
  `--auto`로도 `deny`를 넘을 수 없습니다(측정: bash 요청에 `NO_BASH`, 도구
  호출 0건).
- 세 역할 모두 `task: deny`와 `skill: deny`도 둡니다. 에이전트가 하위
  에이전트를 띄워 자기 권한 경계를 벗어나는 길을 막기 위해서입니다. 작업 분해는
  감독자의 몫입니다.
- **이 보장은 에이전트가 실제로 적용될 때만 유효합니다.** OpenCode에는 에이전트를
  조용히 무시하고 제한 없는 기본 에이전트로 돌아가는 경우가 여럿 있습니다.
  심볼릭 링크로 된 정의 파일, `mode: subagent`, 오타 난 이름, 옛 내용을 들고 있는
  백엔드입니다. 그래서 `ds-worker`는 호출 전에 에이전트를 확인하고, 호출 뒤에는
  stderr에서 `Falling back to default agent`를 찾아 **exit 3으로 바로 실패**합니다.
  자세한 내용: [references/opencode-cli.md](skills/worker/references/opencode-cli.md)의 "Traps".
- 모든 페르소나는 권한 목록을 `"*": deny`로 시작하고, 필요한 도구만 이름으로
  다시 허용합니다. OpenCode v2는 모든 에이전트를 `"*": allow`에서 시작하므로,
  이 줄이 없으면 아무도 적지 않은 도구가 허용됩니다. 측정해 보니 코드 모드
  `execute` 도구, 그리고 그 안에서 `worktree_create`, `session_move`, 원격
  MCP 서버가 열려 있었습니다. 이 줄을 넣으면 `execute`가 아예 제공되지 않고
  읽기는 그대로 됩니다. 막아 둔 셸·편집 도구는 `execute` 안에서도 보이지
  않았습니다.
- MCP 도구는 기본 권한 키 밖에 있습니다. 그래서 `opencode.jsonc`에 선언된 MCP
  서버는 `bash: deny`와 상관없이 셸을 포함한 자기 도구를 모든 에이전트에게
  넘깁니다. 와일드카드 deny가 이것을 막고, 페르소나는 이름을 붙인 읽기 전용
  도구만 다시 허용합니다(`serena_find_symbol` 등).
- 파일을 쓸 수 있는 역할은 `worker` 하나뿐입니다. 커밋, push, PR, 의존성 변경은
  계속 감독자의 몫입니다.
- 쓰기 역할은 `--dir`이 `$HOME`이나 `/`이면 실행을 거부합니다.
- 쓰기 역할 `worker`의 primary/fallback 순서는 파일을 고쳤을 수 있는 시도를
  넘어서 진행하지 않습니다. 시작 전에 `--dir`의 `git status --porcelain`을 떠
  두고, 실패한 시도마다 다시 비교해서 하나라도 다르면 멈춥니다. `--dir`이 git
  작업 트리가 아니어도 확인할 방법이 없으므로 멈춥니다.
- 백엔드는 loopback에만 바인드합니다. 다른 주소는 `OPENCODE_SERVER_PASSWORD`
  없이는 거부합니다.

## 결과와 시간 초과 계약

`ds-worker --json`은 원본 NDJSON 스트림을 `DS_STATE_DIR` 아래에 저장한 뒤
구조화된 결과 하나를 내놓습니다. `outcome` 필드로 `CLEAN_RESULT`,
`FINAL_ARTIFACT_MISSING`, `TOOL_ONLY_NO_FINAL_ARTIFACT`, `IDLE_TIMEOUT`,
`MAX_RUNTIME`과 그 밖의 실패를 구분합니다. exit `124`는 항상 결과가 불확실한
작업입니다. 이어 가기 전에 `raw_log`, `stderr_log`, 세션을 확인하세요.
`ds-worker`가 git으로 지키는 primary/fallback 순서("안전 모델" 참고) 말고는,
감독자가 쓰기 역할을 자동으로 다시 부르면 안 됩니다.

JSON 결과에는 실제로 실행된 OpenCode 에이전트(`agent`)와 모델(`model`)도
들어 있습니다. `DS_MODEL_CRITIC` 없이 부른 critic은 OpenCode 기본 모델이 답하므로
`model: null`입니다.

래퍼의 유휴 타이머는 추론·도구 이벤트를 포함해 NDJSON이 쓰일 때마다 다시
시작되고, `DS_MAX_RUNTIME`은 이와 별개인 전체 상한입니다. 숫자로 된 진행 알림은
`DS_PROGRESS_INTERVAL`마다 stderr로 나가며 모델 원문은 담지 않습니다.

explorer나 reviewer가 세션은 있는데 요구된 최종 보고서가 없으면, 래퍼는 같은
세션에서 읽기 전용 복구 요청을 최대 한 번 보냅니다. 복구에 성공하면
`recovered: true`가 되고, 원래 결과는 `initial_outcome`, `initial_exit`,
`initial_timeout_reason`으로 계속 볼 수 있습니다. 끄려면
`DS_AUTO_RECOVER_READONLY=0`을 쓰세요.

## 에이전트 정의를 고친 뒤

```bash
./install.sh      # copies real files
```

심볼릭 링크로 된 정의는 `opencode debug agents`에는 보이지만 실행 때는 무시됩니다.
상주 백엔드는 에이전트 파일 지문이 바뀌면 스스로 다시 시작합니다.

## 실행 로그

`~/.local/state/ds-worker/runs/<timestamp>-<role>.ndjson`에 호출마다 원본 이벤트
스트림과 짝이 되는 `.stderr` 파일이 남습니다. 복구를 시도했다면
`-recovery.ndjson`과 `-recovery.stderr` 파일이 따로 생깁니다.

## 라이선스

[MIT](LICENSE)
