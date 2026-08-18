# superviser

Claude/Codex를 **supervisor**로 두고, 넓고 반복적인 작업을 OpenCode headless 위의
DeepSeek worker에게 위임하는 스킬.

```
        ┌──────────────────────────┐
        │ Claude / Codex           │
        │ SUPERVISOR               │  분해 · 의사결정 · 최종 검증
        └────────────┬─────────────┘
                     │ ds-worker (Bash)
        ┌────────────▼─────────────┐
        │ opencode serve :4096     │  상주 백엔드 (cold boot 회피)
        │ (+ OmO Slim, 선택)        │
        └────────────┬─────────────┘
                     │ opencode run --attach --agent --model
       ┌─────────────┼─────────────┐
       ▼             ▼             ▼
  ds-explorer   ds-worker    ds-reviewer
   읽기 전용      쓰기 가능      읽기 전용
   flash         pro          pro
```

## 설치

```bash
./install.sh
```

- OpenCode 에이전트 3종 → `~/.config/opencode/agent/`
- `ds-worker` / `ds-serve` / `ds-doctor` → `~/.local/bin/`
- 스킬 → `~/.claude/skills/worker` · `~/.codex/skills/worker`

전제: `opencode`, `jq`, `curl`. 그리고 `opencode auth login` 이 되어 있어야 한다.

```bash
ds-doctor      # 진단
```

## 사용

```bash
ds-worker explorer "인증 미들웨어를 찾아라. 진입점과 실패 경로, file:line 필수."
ds-worker reviewer --file test.log "실패의 근본 원인 후보를 순위대로."
ds-worker worker "src/auth.ts:42 checkToken 이 만료 토큰에 500 반환. 401로. 검증: npm test -- auth"
```

```bash
ds-serve start|status|stop    # 상주 백엔드 (ds-worker가 필요 시 자동 기동)
```

## 설정

| 환경변수 | 기본값 |
|---|---|
| `DS_MODEL_EXPLORER` | `opencode-go/deepseek-v4-flash` |
| `DS_MODEL_WORKER` | `opencode-go/deepseek-v4-pro` |
| `DS_MODEL_REVIEWER` | `opencode-go/deepseek-v4-pro` |
| `DS_OPENCODE_HOST` / `DS_OPENCODE_PORT` | `127.0.0.1` / `4096` |
| `DS_TIMEOUT` | `900` (초) |
| `DS_SERVE` | `auto` (`off` 면 매번 새 프로세스) |
| `DS_AUTO` | `1` (`--auto` 전달) |
| `DS_STATE_DIR` | `~/.local/state/ds-worker` |

## 안전 모델

- `ds-explorer` / `ds-reviewer` 는 에이전트 정의에서 `edit: deny`, `bash: deny`.
  `--auto` 는 `deny` 를 뚫지 못한다 (실측 확인: bash 요청에 `NO_BASH`, 툴 호출 0건).
- **단, 이 보장은 에이전트가 실제로 적용됐을 때만 유효하다.** OpenCode는 에이전트를
  조용히 무시하고 제한 없는 기본 에이전트로 폴백하는 경로가 여럿 있다
  (심링크된 정의 파일, `mode: subagent`, 오타난 이름, 캐시된 백엔드).
  그래서 `ds-worker` 는 호출 전 에이전트를 검사하고, 호출 후 stderr에서
  `Falling back to default agent` 를 찾으면 **exit 3 으로 하드 실패**한다.
  자세한 내용: [references/opencode-cli.md](skills/worker/references/opencode-cli.md) 의 "함정".
- 세 role 모두 `task: deny`, `skill: deny` — 하위 에이전트를 띄워 permission
  경계를 우회하는 경로를 막는다. 작업 분해는 supervisor의 권한이다.
- `ds-worker` 만 쓰기 가능. 커밋/푸시/PR/의존성 변경은 프롬프트에서 금지되어 있고,
  최종 검증은 supervisor가 직접 한다.
- `--dir` 가 `$HOME` 이나 `/` 면 쓰기 role 실행을 거부한다.
- 백엔드는 `127.0.0.1` 바인드. 외부 바인드는 `OPENCODE_SERVER_PASSWORD` 없이는 거부한다.

## 에이전트 정의를 고쳤다면

```bash
./install.sh      # 실파일로 복사 + 상주 백엔드 정리
```

심링크로 걸면 `opencode agent list` 에는 보이지만 런타임에 무시된다.
상주 백엔드는 에이전트 파일 지문이 바뀌면 `ds-serve` 가 알아서 재시작한다.

## 실행 로그

`~/.local/state/ds-worker/runs/<timestamp>-<role>.ndjson` — 원본 이벤트 스트림과
stderr 가 호출마다 남는다.
