#!/usr/bin/env bash
# Pick a project directory under $DEV_ROOT with an nvim fuzzy picker, then
# create (or switch to) a tmux session named after it.
#
# Bound to `prefix + f` in ~/.tmux.conf.local.

set -euo pipefail

DEV_ROOT="${TMUX_SESSIONIZER_ROOT:-$HOME/dev}"

LIST_FILE=
OUT_FILE=
cleanup() { rm -f "$LIST_FILE" "$OUT_FILE"; }
trap cleanup EXIT

usage() {
  cat <<'EOF'
usage: tmux-sessionizer [<dir> | -s <n> | --list]

  (no args)   open the nvim picker over $DEV_ROOT (default ~/dev)
  <dir>       skip the picker and use <dir>
  -s <n>      skip the picker and use the nth candidate (0-based)
  --list      print the candidate directories and exit
EOF
}

die() {
  printf 'tmux-sessionizer: %s\n' "$*" >&2
  # A display-popup vanishes the moment we exit, so hold it open to be read.
  if [[ -t 0 && -n ${TMUX:-} ]]; then
    read -rsn1 -p 'press any key...' _
  fi
  exit 1
}

# Every directory directly under the root, plus nested git repos one level
# deeper so monorepo containers (openclaw/, MonoAgentZero/) are reachable too.
candidates() {
  [[ -d $DEV_ROOT ]] || die "$DEV_ROOT does not exist"
  {
    find "$DEV_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*'
    find "$DEV_ROOT" -mindepth 3 -maxdepth 3 -name .git ! -path '*/.*/*' 2>/dev/null |
      while IFS= read -r gitdir; do printf '%s\n' "${gitdir%/.git}"; done
  } | sort -u
}

# ~/dev/openclaw        -> openclaw
# ~/dev/openclaw/sdk    -> openclaw-sdk   (so two nested `sdk` dirs can't collide)
# Dots and colons are separators in tmux target names, so they become _.
session_name() {
  local dir=${1%/} rel
  rel=${dir#"$DEV_ROOT"/}
  if [[ $rel == /* ]]; then
    rel=$(basename "$dir")
  fi
  rel=${rel//\//-}
  rel=${rel//./_}
  rel=${rel//:/_}
  printf '%s\n' "$rel"
}

switch_to() {
  local dir=$1 name
  name=$(session_name "$dir")
  if ! tmux has-session -t "=$name" 2>/dev/null; then
    tmux new-session -ds "$name" -c "$dir"
  fi
  if [[ -n ${TMUX:-} ]]; then
    tmux switch-client -t "=$name"
  else
    tmux attach-session -t "=$name"
  fi
}

# Hand the candidates to nvim through the environment rather than the -c
# command line, so no path ever needs shell/vim quoting.
#
# The result comes back in $PICKED rather than on stdout: nvim needs the real
# terminal on stdout to draw its UI, and a $(...) capture would hand it a pipe
# instead, which makes it exit immediately without ever showing the picker.
PICKED=
pick() {
  command -v nvim >/dev/null || die 'nvim not found in PATH'

  LIST_FILE=$(mktemp)
  OUT_FILE=$(mktemp)
  candidates >"$LIST_FILE"
  [[ -s $LIST_FILE ]] || die "no project directories under $DEV_ROOT"

  TMUX_SESSIONIZER_LIST="$LIST_FILE" \
    TMUX_SESSIONIZER_OUT="$OUT_FILE" \
    TMUX_SESSIONIZER_ROOT="$DEV_ROOT" \
    nvim -c 'lua require("tmux_sessionizer").pick()'

  # Empty means the picker was cancelled.
  PICKED=$(tr -d '\n' <"$OUT_FILE")
}

main() {
  local dir n

  case ${1:-} in
    -h | --help)
      usage
      ;;
    --list)
      candidates
      ;;
    -s)
      n=${2:-}
      [[ $n =~ ^[0-9]+$ ]] || die '-s needs a non-negative index'
      dir=$(candidates | sed -n "$((n + 1))p")
      [[ -n $dir ]] || die "no candidate at index $n"
      switch_to "$dir"
      ;;
    '')
      pick
      [[ -n $PICKED ]] || exit 0
      switch_to "$PICKED"
      ;;
    *)
      [[ -d $1 ]] || die "not a directory: $1"
      switch_to "$1"
      ;;
  esac
}

main "$@"
