# claude-code-multi-account

Claude Code에서 **설정은 공유하고 계정(자격증명)만 분리**해서 쓰기 위한 세팅 스크립트 모음입니다.
회사용 / 개인용 계정을 오갈 때 매번 로그아웃·로그인하지 않고, `claude-work` / `claude-personal` 같은 명령으로 전환할 수 있게 해줍니다.

- 지원 OS: **macOS**, **Ubuntu/Linux**
- 지원 셸: **bash**, **zsh** (그 외 셸은 붙여넣을 alias를 출력)

---

## 왜 이렇게 해야 하나 (핵심 원리)

Claude Code는 설정 디렉토리를 `CLAUDE_CONFIG_DIR` 환경변수로 지정하며, 기본값은 `~/.claude` 입니다.
자격증명은 **이 디렉토리에 묶여** 저장됩니다.

- **Ubuntu/Linux**: 자격증명이 `$CLAUDE_CONFIG_DIR/.credentials.json` 에 저장됩니다.
- **macOS**: 자격증명이 키체인에 저장되며, 항목 이름이 경로 해시로 구분됩니다
  (`Claude Code-credentials-<SHA256(CLAUDE_CONFIG_DIR)[:8]>`).

자격증명만 따로 다른 위치로 빼는 옵션은 없습니다. 따라서 **계정을 나누려면 `CLAUDE_CONFIG_DIR` 경로 자체가 두 개**여야 합니다.
하나의 동일한 `~/.claude` 를 두 계정이 그대로 공유하는 것은 불가능합니다.

이 저장소의 스크립트는 이 제약을 다음과 같이 해결합니다.

- 계정마다 별도의 설정 디렉토리(`~/.claude-<이름>`)를 사용 → **자격증명 분리**
- `settings.json`, `CLAUDE.md`, `commands/`, `agents/` 등 공유 대상은 **한 곳의 원본을 심볼릭 링크로 공유** → **설정 공유**
- `.credentials.json`, `projects/`, `statsig/` 등 계정·기기별 상태는 링크하지 않음 → 계정 간 섞이지 않음

> macOS의 키체인 경로 해시 동작은 Claude Code 내부 구현에 의존하므로, 세팅 후 `auth status`로 계정 분리가 유지되는지 한 번 확인하세요.

---

## 어떤 스크립트를 쓸까

| 상황 | 스크립트 |
|---|---|
| 설정을 새로 공유 폴더에 두고 프로필을 나누고 싶다 (일반적인 경우) | `claude-multi-account-setup.sh` |
| **이미 `~/.claude` 를 git으로 관리 중**이고, 그 git 내용을 공유하면서 계정만 나누고 싶다 | `claude-shared-git-profiles.sh` |

---

## 1) claude-multi-account-setup.sh — 공유 폴더 방식

`~/.claude-shared/` 에 공유 설정 파일을 두고, 각 프로필 디렉토리에서 링크합니다.
기존 `~/.claude/` 에 있는 공유 대상 파일(`settings.json`, `CLAUDE.md` 등)은 그 **내용을 공유 원본으로 복사**한 뒤 링크합니다(빈 파일로 덮어쓰지 않음).

```bash
chmod +x claude-multi-account-setup.sh
./claude-multi-account-setup.sh
```

만들어지는 구조 (기본값 기준):

```
~/.claude-shared/
  settings.json          # 실제 파일 (공유 원본)
  CLAUDE.md
~/.claude-work/
  settings.json  -> ~/.claude-shared/settings.json
  CLAUDE.md      -> ~/.claude-shared/CLAUDE.md
  .credentials.json      # 계정별로 따로 (Linux) / 키체인 (macOS)
~/.claude-personal/
  settings.json  -> ~/.claude-shared/settings.json
  ...
```

커스터마이즈 (스크립트 상단):

- `PROFILES=("work" "personal")` — 만들 프로필 이름
- `SHARE_FILES=("settings.json" "CLAUDE.md")` — 공유할 파일 목록
- `SHARED_DIR` — 공유 파일 보관 위치

---

## 2) claude-shared-git-profiles.sh — 기존 git 저장소 공유 방식

이미 `~/.claude` 가 git으로 관리되고 있을 때 사용합니다.
`git ls-files` 로 **git이 추적하는 항목만** 자동 판별해 공유 대상으로 삼습니다(= git이 곧 "공유 목록").

- 기존 `~/.claude` 는 **계정 1(기본)로 그대로 유지** → 재로그인 불필요
  (`claude-work` alias는 `CLAUDE_CONFIG_DIR` 을 건드리지 않고 기본값을 씁니다)
- `~/.claude-personal` 을 계정 2로 만들어 git 추적 항목을 원본으로 링크
- `.credentials.json` 등 비밀·상태 파일은 공유에서 제외하며, 실수로 git에 추적 중이면 경고

```bash
chmod +x claude-shared-git-profiles.sh
./claude-shared-git-profiles.sh
```

커스터마이즈 (스크립트 상단):

- `SOURCE_DIR="$HOME/.claude"` — git으로 관리 중인 공유 원본
- `BASE_PROFILE_NAME="work"` — 기존 `~/.claude` 를 가리킬 alias 이름
- `EXTRA_PROFILES=("personal")` — 추가로 만들 계정 이름들
- `NEVER_SHARE=(...)` — 추적되더라도 절대 공유하지 않을 항목

> `commands/` 같은 디렉토리는 통째로 공유됩니다. 그 안에 계정별로 달라야 하는 파일이 있다면
> `settings.local.json`(공유되지 않는 로컬 설정)으로 분리하세요.

---

## 사용 순서 (공통)

1. 스크립트 실행
2. 셸 설정 다시 불러오기: `source ~/.zshrc` (또는 새 터미널)
3. 계정별 최초 1회 로그인:
   ```bash
   claude-work        # (git 방식) 기존 계정이면 재로그인 불필요
   claude-personal    # 실행 후 /login
   ```
4. 확인:
   ```bash
   claude-work auth status
   claude-personal auth status
   ```

---

## 검증 방법

**계정 분리 확인**

```bash
claude-work auth status
claude-personal auth status
# 서로 다른 계정 정보가 나오면 정상
```

**(macOS) 키체인 항목이 분리됐는지 확인**

```bash
security dump-keychain 2>/dev/null | grep "Claude Code-credentials"
# 서로 다른 이름의 항목이 여러 개 보이면 정상적으로 분리된 것
```

---

## 여러 기기에서 쓸 때 (macOS + Ubuntu 등)

- 스크립트는 **각 컴퓨터에서 한 번씩** 실행해야 합니다. git으로 공유되는 것은 설정 파일 내용이며,
  심링크·alias 는 각 기기의 로컬 구성입니다.
- **자격증명은 기기 간에 절대 동기화되지 않습니다**(키체인 / `.credentials.json` 은 커밋 대상 아님).
  따라서 새 계정은 각 기기에서 `/login` 을 한 번씩 해줘야 합니다.

---

## 주의사항

- 이 스크립트는 **로그인을 대신 수행하지 않습니다.** 자격증명 처리는 사용자가 직접 `/login` 으로 합니다.
- 키체인 해싱·설정 파일 위치 등 내부 동작은 Claude Code 버전에 따라 바뀔 수 있습니다.
  세팅 후 `auth status` 로 실제 분리 여부를 반드시 확인하세요.
- 비밀 파일(`.credentials.json`, `.claude.json`)은 절대 git에 커밋하지 마세요.
  `git 방식` 스크립트는 이런 파일이 추적 중이면 경고를 출력합니다.

---

## 참고

- Claude Code 문서: https://docs.claude.com/en/docs/claude-code/overview
- 유사 목적의 서드파티 도구: `diranged/claude-profile`, `lephudao/ccacct`

## 라이선스

MIT
