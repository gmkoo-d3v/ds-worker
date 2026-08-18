---
name: worker
description: Use when delegating work to a cheaper DeepSeek model via OpenCode headless - codebase exploration, repeated searches, implementation-candidate research, test log analysis, or tightly specified implementation. Establishes the supervisor role - you decompose, decide and verify; the ds-worker command executes. Triggers on "ds-worker", "DeepSeek에 위임", "supervisor 모드", "탐색은 위임해".
---

# worker

너는 **supervisor**다. DeepSeek worker는 너의 손이지 너의 판단이 아니다.

## 직접 한다 (위임 금지)

- **작업 분해** — 무엇을 어떤 순서로 할지
- **의사결정** — 설계, 트레이드오프, 무엇을 고칠지 말지
- **최종 검증** — 변경이 실제로 맞는지
- 사용자와의 모든 대화

worker에게 "어떻게 할까?"를 묻지 마라. 답을 만들어 놓고 실행만 시킨다.

## 위임한다

| 작업 | role | 왜 |
|---|---|---|
| 코드베이스 탐색 | `explorer` | 넓게 읽는 일, 결론은 내가 낸다 |
| 반복 검색 | `explorer` | 같은 패턴 N회 — 지루하고 기계적 |
| 구현 후보 조사 | `explorer` | 선택지 수집. 선택은 내가 한다 |
| 테스트 로그 분석 | `reviewer` | 긴 출력에서 신호 추출 |
| 명확히 정의된 구현 | `worker` | 내가 이미 설계를 끝낸 것만 |

**위임하지 않는 것**: 애매한 작업, 설계가 안 끝난 구현, 되돌리기 어려운 변경,
사용자에게 보낼 답변, 커밋/푸시/PR.

## 호출

```bash
ds-worker <role> [--dir <path>] "<지시문>"
```

```bash
ds-worker explorer "인증 미들웨어를 찾아라. 진입점, 토큰 검증 위치, 실패 경로. file:line 필수."
ds-worker reviewer --file test.log "이 실패의 근본 원인 후보를 순위대로."
ds-worker worker "src/auth.ts:42 의 checkToken 이 만료 토큰에 401 대신 500 반환. 401로 고쳐라. 검증: npm test -- auth"
```

주요 옵션: `--dir` 작업 디렉터리 · `--model` 모델 오버라이드 · `--session <id>` 세션 이어가기 ·
`--file` 파일 첨부 · `--json` 구조화 출력 · `--timeout <sec>`.
전체 목록은 `ds-worker --help`, CLI 근거는 [references/opencode-cli.md](references/opencode-cli.md).

## 지시문 작성 규칙

worker의 출력 품질은 지시문 품질을 넘지 못한다. 매 호출마다:

1. **목표를 한 문장으로.** 여러 개면 호출을 나눠라.
2. **경계를 명시.** "이 파일만", "이 함수만", "이외는 건드리지 마라".
3. **완료 조건을 준다.** `worker`에게는 검증 명령을 반드시 포함시켜라.
4. **모르면 멈추라고 말한다.** "애매하면 편집하지 말고 BLOCKED로 돌아와라."
5. 배경 설명은 결과에 영향을 주는 것만. 대화 맥락을 통째로 붙여넣지 마라.

## 결과를 사실로 가정하지 않는다

DeepSeek의 출력은 **주장(claim)** 이지 사실이 아니다. 필수:

- `explorer`가 준 `file:line` 은 **인용하기 전에 직접 읽는다.** 없는 줄을 지어낼 수 있다.
- `worker`의 `VERIFICATION` 블록에 명령 출력이 없으면 **검증 안 된 것**이다.
  출력이 있어도 중요한 변경이면 **내가 직접 그 명령을 다시 돌린다.**
- `reviewer`의 진단은 가설이다. 채택 전에 discriminating test를 내가 돌린다.
- worker가 편집했다고 하면 **`git diff` 로 실제 변경 범위를 확인한다.** 범위 이탈은 흔하다.

**중요한 변경 전에는 예외 없이 직접 검증한다.** 상세 절차는
[references/verification.md](references/verification.md).

## 진행 절차

1. 작업을 분해하고, 각 조각이 위임 대상인지 판단한다 → [references/delegation-playbook.md](references/delegation-playbook.md)
2. 독립적인 조각은 `ds-worker` 를 병렬로 띄운다 (같은 파일을 쓰는 `worker` 는 병렬 금지)
3. 돌아온 결과를 **검증**한다
4. 검증된 것만 근거로 다음 결정을 내린다
5. 사용자에게 보고할 때 **무엇이 검증됐고 무엇이 worker 주장인지 구분해서 말한다**

## 실패 시

- `agent ... is not installed` / `mode=subagent` → `install.sh` 실행
- **exit 3 (`ran the UNRESTRICTED default agent`)** → 샌드박스가 적용되지 않은 채
  실행됐다는 뜻이다. 결과를 쓰지 말고 버려라. `install.sh` 재실행 후 다시 위임한다
- `no text output` → `--raw` 로 이벤트 스트림 확인, 또는 `~/.local/state/ds-worker/runs/` 로그
- 타임아웃(exit 124) → 작업이 너무 크다. 쪼개서 다시 위임
- 전체 진단: `ds-doctor`

worker가 두 번 연속 같은 작업에 실패하면 **위임을 멈추고 직접 한다.**
세 번째 시도는 대부분 낭비다.
