#!/bin/zsh
# Fails if anything identifying about this Mac or its owner would be published:
# your username, home folder path, real name, personal email, or secrets.
# Checks the files git would publish and the built app (if present).
# Runs automatically from make-dmg.sh; run it yourself before every push.
set -uo pipefail
cd "$(dirname "$0")/.."

needles=()
# On CI the machine is a throwaway runner ("runner" also matches ActionRunner.swift), so only
# your own Mac's identity is worth scanning for.
if [[ -z "${CI:-}" ]]; then
  needles+=("$HOME" "$(id -un)")
  full_name="$(id -F 2>/dev/null || true)"
  [[ -n "$full_name" ]] && needles+=("$full_name")
fi
for scope in --global --system; do
  email="$(git config $scope user.email 2>/dev/null || true)"
  [[ -n "$email" && "$email" != *noreply* ]] && needles+=("$email")
done

# Files that would be published: tracked + new, minus ignored. Works before the first commit too.
if git rev-parse --git-dir >/dev/null 2>&1; then
  files=("${(@f)$(git ls-files --cached --others --exclude-standard)}")
else
  files=("${(@f)$(find . -type f -not -path './.build/*' -not -path './build/*' -not -path './.git/*')}")
fi
[[ -d build/Wheel.app ]] && files+=("${(@f)$(find build/Wheel.app -type f)}")

fail=0
for needle in "${needles[@]:-}"; do
  [[ -z "$needle" ]] && continue
  [[ ${#needle} -lt 3 ]] && continue
  hits="$(grep -l -a -i -F -- "$needle" "${files[@]}" 2>/dev/null)"
  if [[ -n "$hits" ]]; then
    echo "✗ Found personal info (${needle:0:3}…) in:"; echo "$hits" | sed 's/^/    /'; fail=1
  fi
done

secrets='(BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-)'
hits="$(grep -l -a -E -- "$secrets" "${files[@]:#*privacy-check.sh}" 2>/dev/null)"
if [[ -n "$hits" ]]; then echo "✗ Possible secret in:"; echo "$hits" | sed 's/^/    /'; fail=1; fi

# Commit authors must not use a personal address.
if git rev-parse HEAD >/dev/null 2>&1; then
  bad="$(git log --format='%ae%n%ce' | sort -u | grep -v -i noreply || true)"
  if [[ -n "$bad" ]]; then echo "✗ Commits use a non-noreply email. Rewrite them before pushing."; fail=1; fi
fi
local_email="$(git config user.email 2>/dev/null || true)"
if [[ -n "$local_email" && "$local_email" != *noreply* ]]; then
  echo "✗ git user.email for this repo isn't a GitHub noreply address."; fail=1
fi

(( fail )) && { echo "Privacy check failed."; exit 1; }
echo "✓ Privacy check passed: no username, home path, real name, personal email or secrets found."
