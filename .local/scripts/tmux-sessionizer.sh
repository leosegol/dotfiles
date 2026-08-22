#!/usr/bin/env bash
# Pick a project directory under $DEV_ROOT with an nvim fuzzy picker, then
# create (or switch to) a tmux session named after it.
#
# Bound to `prefix + f` in ~/.tmux.conf.local.

set -euo pipefail

DEV_ROOT="${TMUX_SESSIONIZER_ROOT:-$HOME/dev}"
# Resolve symlinks once. git prints physical worktree paths, and the dedupe in
# candidates() compares them textually against the paths find produces.
if [[ -d $DEV_ROOT ]]; then
  DEV_ROOT=$(cd -P "$DEV_ROOT" && pwd)
fi

SELF=${BASH_SOURCE[0]}

LIST_FILE=
OUT_FILE=
cleanup() { rm -f "$LIST_FILE" "$OUT_FILE"; }
trap cleanup EXIT

usage() {
  cat <<'EOF'
usage: tmux-sessionizer [<dir> | -s <n> | --list | --children <dir>]

  (no args)         open the nvim picker over $DEV_ROOT (default ~/dev)
  <dir>             skip the picker and use <dir>
  -s <n>            skip the picker and use the nth candidate (0-based)
  --list            print the candidates and exit
  --children <dir>  print what the picker shows after <Tab> on <dir>

--list and --children print "<label><TAB><path>" per line; the picker shows
the label and switches to the path.
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

# The ~/dev/ prefix is noise on every line, so labels are relative to the root.
# Anything outside the root (a worktree parked elsewhere) keeps its full path.
rel_label() {
  local dir=${1%/} rel
  rel=${dir#"$DEV_ROOT"/}
  if [[ $rel == "$dir" ]]; then
    printf '%s\n' "$dir"
  else
    printf '%s\n' "$rel"
  fi
}

# The linked worktrees of a repo, one absolute path per line, main one included.
worktree_paths() {
  git -C "$1" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' || true
}

# Every directory directly under the root, plus nested git repos one level
# deeper so monorepo containers (openclaw/, MonoAgentZero/) are reachable, plus
# every repo's git worktrees -- those can live anywhere, and AgentZeroApp keeps
# its under .claude/worktrees/, which the scan below deliberately never enters.
candidates() {
  [[ -d $DEV_ROOT ]] || die "$DEV_ROOT does not exist"

  local dirs seen dir wtlist main label wt

  dirs=$(
    {
      find "$DEV_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*'
      find "$DEV_ROOT" -mindepth 3 -maxdepth 3 -name .git ! -path '*/.*/*' 2>/dev/null |
        while IFS= read -r gitdir; do printf '%s\n' "${gitdir%/.git}"; done
    } | LC_ALL=C sort -u
  )

  {
    while IFS= read -r dir; do
      [[ -n $dir ]] || continue
      printf '%s\t%s\n' "$(rel_label "$dir")" "$dir"
    done <<<"$dirs"

    # A worktree is reachable from every worktree of the same repo, so dedupe
    # against everything already listed: without it, asking AgentZeroApp and
    # AgentZeroApp-wireless in turn would list the same 5 directories twice.
    seen=$'\n'$dirs$'\n'
    while IFS= read -r dir; do
      # A linked worktree's .git is a file, not a directory, hence -e.
      [[ -n $dir && -e $dir/.git ]] || continue
      wtlist=$(worktree_paths "$dir")
      [[ -n $wtlist ]] || continue
      # Label by the repo's main worktree (git lists it first) rather than by
      # whichever worktree we happened to ask, so the prefix is stable.
      main=$(printf '%s\n' "$wtlist" | sed -n 1p)
      label=$(rel_label "$main")
      while IFS= read -r wt; do
        # -d also drops prunable entries whose directory is already gone.
        [[ -n $wt && -d $wt ]] || continue
        [[ $seen != *$'\n'"$wt"$'\n'* ]] || continue
        seen+="$wt"$'\n'
        printf '%s ⑂ %s\t%s\n' "$label" "$(basename "$wt")" "$wt"
      done <<<"$wtlist"
    done <<<"$dirs"
  } | LC_ALL=C sort -t$'\t' -k1,1
}

# What <Tab> on a directory shows: its immediate subdirectories, plus its
# worktrees, which is the one case where hidden paths are worth surfacing.
children() {
  local dir=${1%/} sub wtlist wt
  [[ -n $dir && -d $dir ]] || die "not a directory: ${1:-}"

  {
    find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' |
      while IFS= read -r sub; do
        printf '%s\t%s\n' "$(basename "$sub")" "$sub"
      done

    if [[ -e $dir/.git ]]; then
      wtlist=$(worktree_paths "$dir")
      while IFS= read -r wt; do
        [[ -n $wt && -d $wt ]] || continue
        [[ $wt != "$dir" ]] || continue
        printf '⑂ %s\t%s\n' "$(basename "$wt")" "$wt"
      done <<<"$wtlist"
    fi
  } | LC_ALL=C sort -t$'\t' -k1,1
}

# ~/dev/openclaw                                   -> openclaw
# ~/dev/openclaw/sdk                               -> openclaw-sdk
# ~/dev/zero/AgentZeroApp/.claude/worktrees/rd-220 -> zero-AgentZeroApp-rd-220
#
# The full path relative to the root, so two nested `sdk` or `ios` directories
# can never collide, minus the container components that carry no meaning in a
# session name. Dots and colons are separators in tmux targets, so they become _.
session_name() {
  local dir=${1%/} rel part out=
  rel=${dir#"$DEV_ROOT"/}
  if [[ $rel == "$dir" ]]; then
    rel=$(basename "$dir")
  fi

  local IFS=/
  for part in $rel; do
    case $part in
      .claude | .git | worktrees) continue ;;
    esac
    out+="${out:+-}$part"
  done

  out=${out//./_}
  out=${out//:/_}
  printf '%s\n' "$out"
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
# command line, so no path ever needs shell/vim quoting. $SELF goes along so
# the picker can ask us for a directory's children when you press <Tab>.
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
    TMUX_SESSIONIZER_SELF="$SELF" \
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
    --children)
      children "${2:-}"
      ;;
    -s)
      n=${2:-}
      [[ $n =~ ^[0-9]+$ ]] || die '-s needs a non-negative index'
      dir=$(candidates | sed -n "$((n + 1))p" | cut -f2)
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
