#!/usr/bin/env bash
# PreToolUse + SessionStart hook: loads the LawSpec prelude into the session
# the first time a tool call touches LawSpec work (lawspec/README.md,
# "The prelude in Claude Code sessions").
#
# This script is only the cheap gate, because it runs before every Read,
# Edit, Write, Grep, Glob and Bash call in the repository: a call whose input
# never mentions lawspec costs one `case`, and node starts only for the rest.
# lawspec-prelude.mjs makes the real decision and renders the prelude.
#
# It must never block or fail a tool call, so every path exits 0.
input="$(cat)"

# Case-insensitive, as lawspec-prelude.mjs is: a search for "LawSpec" is
# LawSpec work too.
shopt -s nocasematch

case "$input" in
  *lawspec* | *SessionStart*) ;;
  *) exit 0 ;;
esac

# No node means no LawSpec either (it is an npm package), so there is no
# prelude to load.
command -v node >/dev/null 2>&1 || exit 0

printf '%s' "$input" | node "$(dirname "$0")/lawspec-prelude.mjs" || exit 0
