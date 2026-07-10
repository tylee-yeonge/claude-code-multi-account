#!/usr/bin/env bash
#
# claude-shared-git-profiles.sh
# ---------------------------------------------------------------------------
# 이미 git으로 관리 중인 ~/.claude 를 "공유 원본"으로 그대로 두고,
# 계정(자격증명)만 프로필별로 분리하는 스크립트.
#
#   - git이 추적하는 항목(settings.json, CLAUDE.md, commands/, agents/ 등)은
#     원본 저장소 하나를 심링크로 공유 → 어느 프로필에서 고쳐도 같은 저장소가 바뀜
#   - 자격증명/세션 상태(.credentials.json, projects/, statsig/ 등)는
#     프로필마다 독립적으로 유지 → 계정 분리
#
#   지원 OS : macOS, Ubuntu/Linux    지원 셸 : bash, zsh
#
# 핵심 전제(검증됨): 자격증명은 CLAUDE_CONFIG_DIR 경로에 묶여 있어 별도 위치로
# 뺄 수 없습니다. 그래서 계정을 나누려면 CLAUDE_CONFIG_DIR 경로가 두 개여야 합니다.
# 이 스크립트는 기존 ~/.claude 를 그대로 "계정 1(기본)"으로 두고, 새 디렉토리를
# "계정 2"로 만들어 git 추적 파일만 원본으로 링크합니다.
# ---------------------------------------------------------------------------

set -euo pipefail

# ============================================================
# 사용자 설정
# ============================================================
# git으로 관리 중인 공유 원본(기존 설정 디렉토리)
SOURCE_DIR="$HOME/.claude"

# 계정 1(= 기존 ~/.claude) 을 가리키는 alias 이름.
# 계정 1은 CLAUDE_CONFIG_DIR 을 건드리지 않고 기본값(~/.claude)을 그대로 씁니다.
# (이렇게 해야 지금 로그인돼 있는 기존 계정을 다시 로그인할 필요가 없습니다.)
BASE_PROFILE_NAME="personal"

# 추가로 만들 계정들. 각각 ~/.claude-<이름> 디렉토리를 CLAUDE_CONFIG_DIR 로 사용.
EXTRA_PROFILES=("work")

# alias 접두어 (claude-work, claude-personal ...)
ALIAS_PREFIX="claude-"

# 추적되더라도 절대 공유(심링크)하지 않을 항목 — 계정/기기별 상태 및 비밀정보
NEVER_SHARE=(".credentials.json" ".claude.json" "projects" "statsig" "todos" \
             "shell-snapshots" "history.jsonl" ".last_session_id" "logs" "sessions")
# ============================================================


# ---- 출력 헬퍼 ----
if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"; GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"; RED="$(printf '\033[31m')"; RESET="$(printf '\033[0m')"
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi
info() { printf '%s\n' "${GREEN}▶${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}⚠${RESET}  $*"; }
err()  { printf '%s\n' "${RED}✖${RESET} $*" >&2; }
step() { printf '\n%s\n' "${BOLD}$*${RESET}"; }

# 항목이 NEVER_SHARE 목록에 있는지 검사
is_never_share() {
  local x="$1" n
  for n in "${NEVER_SHARE[@]}"; do [ "$x" = "$n" ] && return 0; done
  return 1
}


# ---- 1. OS / 셸 감지 ----
OS="$(uname -s)"
case "$OS" in
  Darwin) PLATFORM="macOS" ;;
  Linux)  PLATFORM="Linux" ;;
  *) err "지원하지 않는 OS입니다: $OS"; exit 1 ;;
esac
info "환경: ${BOLD}${PLATFORM}${RESET}"

SHELL_NAME="$(basename "${SHELL:-bash}")"
case "$SHELL_NAME" in
  zsh)  RC_FILE="$HOME/.zshrc" ;;
  bash)
    if [ "$PLATFORM" = "macOS" ] && [ -f "$HOME/.bash_profile" ]; then
      RC_FILE="$HOME/.bash_profile"; else RC_FILE="$HOME/.bashrc"; fi ;;
  *)    RC_FILE="" ;;
esac


# ---- 2. 공유 원본이 git 저장소인지 확인 ----
step "1) 공유 원본 확인 → $SOURCE_DIR"
if ! command -v git >/dev/null 2>&1; then
  err "git 이 설치돼 있지 않습니다."; exit 1
fi
if [ ! -d "$SOURCE_DIR" ]; then
  err "$SOURCE_DIR 가 없습니다."; exit 1
fi
if ! git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  err "$SOURCE_DIR 는 git 저장소가 아닙니다. (이 스크립트는 git 관리 중인 설정을 전제로 합니다)"; exit 1
fi
info "git 저장소 확인됨."

# 비밀정보가 실수로 추적되고 있지 않은지 안전 점검
for secret in ".credentials.json" ".claude.json"; do
  if git -C "$SOURCE_DIR" ls-files --error-unmatch "$secret" >/dev/null 2>&1; then
    warn "${BOLD}$secret 가 git에 추적되고 있습니다!${RESET} 토큰/상태가 커밋에 노출될 수 있어요."
    warn "  → git rm --cached \"$secret\" 후 .gitignore 에 추가하는 것을 강력히 권합니다."
  fi
done


# ---- 3. 공유할 항목 목록 계산 (추적 파일의 최상위 경로 요소, denylist 제외) ----
step "2) git이 추적하는 공유 항목 수집"
SHARED_ITEMS=()
while IFS= read -r item; do
  [ -z "$item" ] && continue
  is_never_share "$item" && { warn "제외(계정/기기별 상태): $item"; continue; }
  SHARED_ITEMS+=("$item")
done < <(git -C "$SOURCE_DIR" ls-files | sed 's#/.*##' | LC_ALL=C sort -u)

if [ "${#SHARED_ITEMS[@]}" -eq 0 ]; then
  err "공유할 추적 항목이 없습니다. ($SOURCE_DIR 에서 git add/commit 이 되어 있나요?)"; exit 1
fi
info "공유 항목: ${BOLD}${SHARED_ITEMS[*]}${RESET}"


# ---- 4. 추가 프로필 디렉토리 생성 + 공유 항목 심링크 ----
step "3) 추가 계정 디렉토리 생성 및 링크"
for p in "${EXTRA_PROFILES[@]}"; do
  cfg="$HOME/.claude-$p"
  if [ "$cfg" = "$SOURCE_DIR" ]; then
    warn "프로필 '$p' 의 경로가 원본과 같아 건너뜁니다."; continue
  fi
  mkdir -p "$cfg"
  chmod 700 "$cfg" 2>/dev/null || true
  info "계정 '$p' → $cfg"

  for item in "${SHARED_ITEMS[@]}"; do
    link="$cfg/$item"
    src="$SOURCE_DIR/$item"
    # 부모 경로 확보 (item 이 중첩 경로는 아니지만 안전하게)
    mkdir -p "$(dirname "$link")"
    if [ -L "$link" ]; then
      rm -f "$link"; ln -s "$src" "$link"          # 심링크면 새로 연결
    elif [ -e "$link" ]; then
      bak="$link.bak.$(date +%Y%m%d%H%M%S)"
      mv "$link" "$bak"; ln -s "$src" "$link"
      warn "  기존 '$item' 백업 후 링크 교체 (→ $bak)"
    else
      ln -s "$src" "$link"
    fi
  done
  info "  링크 완료. (계정별 개별 설정은 $cfg/settings.local.json 에 두면 공유되지 않습니다)"
done


# ---- 5. alias 블록 구성 ----
MARK_BEGIN="# >>> claude-code shared-git profiles (managed by setup script) >>>"
MARK_END="# <<< claude-code shared-git profiles (managed by setup script) <<<"

ALIAS_BLOCK="$MARK_BEGIN"$'\n'
# 계정 1: 기존 ~/.claude 를 기본값으로 사용 (CLAUDE_CONFIG_DIR 설정하지 않음)
ALIAS_BLOCK+="alias ${ALIAS_PREFIX}${BASE_PROFILE_NAME}='claude'"$'\n'
# 계정 2+: 각자 CLAUDE_CONFIG_DIR 지정
for p in "${EXTRA_PROFILES[@]}"; do
  cfg="$HOME/.claude-$p"
  ALIAS_BLOCK+="alias ${ALIAS_PREFIX}${p}='CLAUDE_CONFIG_DIR=\"$cfg\" claude'"$'\n'
done
ALIAS_BLOCK+="$MARK_END"


# ---- 6. rc 파일에 등록 (기존 관리 블록 교체) ----
step "4) 셸 alias 등록"
if [ -n "$RC_FILE" ]; then
  touch "$RC_FILE"
  tmp="$(mktemp)"
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0==b {skip=1}
    skip!=1 {print}
    $0==e {skip=0}
  ' "$RC_FILE" > "$tmp"
  { printf '%s\n\n%s\n' "$(cat "$tmp")" "$ALIAS_BLOCK"; } > "$RC_FILE"
  rm -f "$tmp"
  info "등록 완료 → $RC_FILE"
  printf '     %s%s%s → 기존 ~/.claude (기본 계정, 재로그인 불필요)\n' \
    "$BOLD" "${ALIAS_PREFIX}${BASE_PROFILE_NAME}" "$RESET"
  for p in "${EXTRA_PROFILES[@]}"; do
    printf '     %s%s%s → %s (새 계정)\n' "$BOLD" "${ALIAS_PREFIX}${p}" "$RESET" "$HOME/.claude-$p"
  done
else
  warn "셸($SHELL_NAME) 자동 등록 미지원. 아래를 직접 추가하세요:"
  printf '\n%s\n\n' "$ALIAS_BLOCK"
fi


# ---- 7. 완료 안내 ----
step "완료! 다음 순서로 진행하세요"
cat <<EOF

  1) 셸 설정 다시 불러오기:
       source ${RC_FILE:-<셸 설정 파일>}

  2) 기존 계정은 그대로 사용 (재로그인 불필요):
       ${ALIAS_PREFIX}${BASE_PROFILE_NAME}

  3) 새 계정만 최초 1회 로그인:
EOF
for p in "${EXTRA_PROFILES[@]}"; do
  printf '       %s%s%s      # 실행 후 /login\n' "$BOLD" "${ALIAS_PREFIX}${p}" "$RESET"
done
cat <<EOF

  4) 계정 확인:
       ${ALIAS_PREFIX}${BASE_PROFILE_NAME} auth status
       ${ALIAS_PREFIX}${EXTRA_PROFILES[0]} auth status

  동작 방식:
    - git 추적 파일(${SHARED_ITEMS[*]})은 $SOURCE_DIR 원본을 링크로 공유합니다.
      어느 계정에서 수정하든 같은 저장소가 바뀌며, 커밋/푸시는 $SOURCE_DIR 에서 하면 됩니다.
    - 자격증명/세션 상태는 계정마다 독립적으로 유지됩니다.
    - 특정 계정에만 적용할 설정은 각 프로필의 settings.local.json 에 두세요(공유 안 됨).
EOF

if [ "$PLATFORM" = "macOS" ]; then
cat <<'EOF'

  (macOS 참고) 기존 계정은 CLAUDE_CONFIG_DIR 을 설정하지 않은 기본 상태를 유지하므로
  현재 키체인 로그인이 그대로 쓰입니다. 새 계정은 경로 해시가 다른 별도 키체인 항목을
  사용합니다. 분리 확인:
       security dump-keychain 2>/dev/null | grep "Claude Code-credentials"
EOF
fi
printf '\n'
