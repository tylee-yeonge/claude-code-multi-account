#!/usr/bin/env bash
#
# claude-multi-account-setup.sh
# ---------------------------------------------------------------------------
# Claude Code에서 여러 계정(예: 회사용/개인용)을
# "설정은 공유, 계정(자격증명)만 분리" 방식으로 쓰기 위한 자동 세팅 스크립트.
#
#   지원 OS   : macOS, Ubuntu/Linux
#   지원 셸   : bash, zsh  (그 외 셸은 수동 안내를 출력)
#
# 동작 원리:
#   - 프로필마다 별도의 CLAUDE_CONFIG_DIR (~/.claude-<이름>)을 사용 → 자격증명 분리
#     (macOS는 키체인 항목 이름이 config 디렉토리 경로 해시로 구분되어 서로 덮어쓰지 않음)
#   - settings.json / CLAUDE.md 등은 ~/.claude-shared/ 에 실제 파일 하나만 두고
#     각 프로필 디렉토리에서 심볼릭 링크로 연결 → 설정 공유
#   - 셸 설정 파일에 프로필별 alias 등록 (예: claude-work / claude-personal)
#
# 이 스크립트는 로그인을 대신 수행하지 않습니다. 계정 로그인은 안내대로
# 각 alias에서 직접 `/login` 하시면 됩니다. 여러 번 실행해도 안전합니다(idempotent).
# ---------------------------------------------------------------------------

set -euo pipefail

# ============================================================
# 사용자 설정 (보통 여기만 바꾸면 됩니다)
# ============================================================
# 만들 프로필(계정) 이름. 각 프로필은 ~/.claude-<이름> 디렉토리를 사용합니다.
PROFILES=("work" "personal")

# 프로필끼리 공유할 파일. ~/.claude-shared/ 아래 실제 파일을 두고
# 각 프로필 디렉토리에는 심볼릭 링크로 연결합니다.
SHARE_FILES=("settings.json" "CLAUDE.md")

# 공유 파일을 보관할 디렉토리
SHARED_DIR="$HOME/.claude-shared"

# alias 접두어. claude-work, claude-personal 처럼 만들어집니다.
ALIAS_PREFIX="claude-"
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


# ---- 1. OS 감지 ----
OS="$(uname -s)"
case "$OS" in
  Darwin) PLATFORM="macOS" ;;
  Linux)  PLATFORM="Linux" ;;
  *) err "지원하지 않는 OS입니다: $OS (macOS 또는 Linux만 지원합니다)"; exit 1 ;;
esac
info "감지된 환경: ${BOLD}${PLATFORM}${RESET}"


# ---- 2. 셸 rc 파일 결정 ----
SHELL_NAME="$(basename "${SHELL:-bash}")"
case "$SHELL_NAME" in
  zsh)  RC_FILE="$HOME/.zshrc" ;;
  bash)
    # Ubuntu는 ~/.bashrc, macOS 기본 bash 로그인 셸은 ~/.bash_profile 을 읽습니다.
    if [ "$PLATFORM" = "macOS" ] && [ -f "$HOME/.bash_profile" ]; then
      RC_FILE="$HOME/.bash_profile"
    else
      RC_FILE="$HOME/.bashrc"
    fi
    ;;
  *)    RC_FILE="" ;;  # fish 등 미지원 셸 → 수동 안내
esac
[ -n "$RC_FILE" ] && info "감지된 셸: ${BOLD}${SHELL_NAME}${RESET}  (설정 파일: ${RC_FILE})"


# ---- 3. 공유 디렉토리 및 공유 파일 준비 ----
step "1) 공유 설정 준비 → $SHARED_DIR"
mkdir -p "$SHARED_DIR"
chmod 700 "$SHARED_DIR" 2>/dev/null || true

for f in "${SHARE_FILES[@]}"; do
  target="$SHARED_DIR/$f"
  if [ -e "$target" ]; then
    info "이미 있음: $target (그대로 사용)"
    continue
  fi
  existing="$HOME/.claude/$f"
  if [ -f "$existing" ]; then
    # 기존 ~/.claude/<파일>이 있으면 내용을 그대로 공유 원본으로 가져옵니다.
    # (settings.json, CLAUDE.md 등 종류와 무관하게 기존 내용 보존)
    cp "$existing" "$target"
    info "기존 ~/.claude/$f 을(를) 공유 원본으로 복사했습니다."
  elif [ "$f" = "settings.json" ]; then
    printf '{\n}\n' > "$target"
    info "빈 settings.json 을 생성했습니다."
  else
    : > "$target"
    info "빈 $f 을 생성했습니다."
  fi
done


# ---- 4. 프로필별 config 디렉토리 생성 + 공유 파일 심링크 ----
step "2) 프로필 디렉토리 생성 및 공유 파일 링크"
for p in "${PROFILES[@]}"; do
  cfg="$HOME/.claude-$p"   # 예: ~/.claude-work
  mkdir -p "$cfg"
  chmod 700 "$cfg" 2>/dev/null || true
  info "프로필 '$p' → $cfg"

  for f in "${SHARE_FILES[@]}"; do
    link="$cfg/$f"
    src="$SHARED_DIR/$f"
    if [ -L "$link" ]; then
      ln -sfn "$src" "$link"          # 이미 심링크면 대상만 갱신
    elif [ -e "$link" ]; then
      bak="$link.bak.$(date +%Y%m%d%H%M%S)"
      mv "$link" "$bak"
      ln -s "$src" "$link"
      warn "기존 파일을 백업($bak)하고 공유 링크로 교체: $f"
    else
      ln -s "$src" "$link"
    fi
  done
done


# ---- 5. alias 블록 구성 ----
MARK_BEGIN="# >>> claude-code multi-account (managed by setup script) >>>"
MARK_END="# <<< claude-code multi-account (managed by setup script) <<<"

ALIAS_BLOCK="$MARK_BEGIN"$'\n'
for p in "${PROFILES[@]}"; do
  cfg="$HOME/.claude-$p"
  # CLAUDE_CONFIG_DIR 값은 항상 동일한 절대경로 문자열이어야
  # macOS 키체인 항목(경로 해시 기반)이 일관되게 유지됩니다.
  ALIAS_BLOCK+="alias ${ALIAS_PREFIX}${p}='CLAUDE_CONFIG_DIR=\"$cfg\" claude'"$'\n'
done
ALIAS_BLOCK+="$MARK_END"


# ---- 6. rc 파일에 alias 등록 (기존 관리 블록은 교체) ----
step "3) 셸 alias 등록"
if [ -n "$RC_FILE" ]; then
  touch "$RC_FILE"
  tmp="$(mktemp)"
  # 기존 관리 블록(마커 사이)을 제거
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0==b {skip=1}
    skip!=1 {print}
    $0==e {skip=0}
  ' "$RC_FILE" > "$tmp"
  # 끝의 빈 줄 정리 후 새 블록 추가
  { printf '%s\n\n%s\n' "$(cat "$tmp")" "$ALIAS_BLOCK"; } > "$RC_FILE"
  rm -f "$tmp"
  info "alias 를 $RC_FILE 에 등록했습니다."
  for p in "${PROFILES[@]}"; do
    printf '     %s%s%s → CLAUDE_CONFIG_DIR=%s\n' "$BOLD" "${ALIAS_PREFIX}${p}" "$RESET" "$HOME/.claude-$p"
  done
else
  warn "셸($SHELL_NAME)은 자동 등록을 지원하지 않습니다. 아래를 설정 파일에 직접 추가하세요."
  if [ "$SHELL_NAME" = "fish" ]; then
    printf '\n  # ~/.config/fish/config.fish\n'
    for p in "${PROFILES[@]}"; do
      printf "  alias %s%s 'env CLAUDE_CONFIG_DIR=\"%s\" claude'\n" \
        "$ALIAS_PREFIX" "$p" "$HOME/.claude-$p"
    done
    printf '\n'
  else
    printf '\n%s\n\n' "$ALIAS_BLOCK"
  fi
fi


# ---- 7. 완료 안내 ----
step "완료! 다음 순서로 각 계정에 로그인하세요"
cat <<EOF

  1) 셸 설정을 다시 불러오기:
       source ${RC_FILE:-<셸 설정 파일>}
     (또는 터미널을 새로 열기)

  2) 프로필별로 최초 1회만 로그인:
EOF
for p in "${PROFILES[@]}"; do
  printf '       %s%s%s      # 실행 후 /login 으로 해당 계정 로그인\n' "$BOLD" "${ALIAS_PREFIX}${p}" "$RESET"
done
cat <<EOF

  3) 로그인 상태 확인:
       ${ALIAS_PREFIX}${PROFILES[0]} auth status
       ${ALIAS_PREFIX}${PROFILES[1]:-${PROFILES[0]}} auth status
EOF

if [ "$PLATFORM" = "macOS" ]; then
cat <<'EOF'

  (macOS 참고) 두 계정의 키체인 항목이 실제로 분리됐는지 확인:
       security dump-keychain 2>/dev/null | grep "Claude Code-credentials"
     서로 다른 이름의 항목이 여러 개 보이면 정상적으로 분리된 것입니다.
EOF
fi

cat <<EOF

  이후에는 로그아웃/로그인 반복 없이 ${ALIAS_PREFIX}${PROFILES[0]} / ${ALIAS_PREFIX}${PROFILES[1]:-...} 로 계정을 오갈 수 있습니다.
  설정(${SHARE_FILES[*]})은 ${SHARED_DIR} 한 곳에서 공유됩니다.
  일반 'claude' 명령은 기존 기본 계정(~/.claude)을 그대로 사용합니다.

EOF
