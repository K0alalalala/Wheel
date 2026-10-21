#!/bin/zsh
# Fails if the protected credits differ from a base git ref.
#   scripts/check-credits.sh              compare the working tree with HEAD
#   scripts/check-credits.sh origin/main  compare with another ref (CI uses the PR base)
# Protected: Sources/Wheel/Credits.swift, LICENSE, .github/CODEOWNERS, this script,
# the README block between <!-- credits:start --> and <!-- credits:end -->,
# and the copyright line in Resources/Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE="${1:-HEAD}"

if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
  echo "credits-guard: no base '$BASE' to compare with; skipping."; exit 0
fi

fail=0
for f in Sources/Wheel/Credits.swift LICENSE .github/CODEOWNERS scripts/check-credits.sh; do
  if git cat-file -e "$BASE:$f" 2>/dev/null; then
    if ! git show "$BASE:$f" | cmp -s - "$f"; then echo "✗ $f changed"; fail=1; fi
  fi
done

readme_block() { sed -n '/<!-- credits:start/,/<!-- credits:end -->/p'; }
if [[ "$(git show "$BASE:README.md" | readme_block)" != "$(readme_block < README.md)" ]]; then
  echo "✗ README credits block changed"; fail=1
fi

copyright() { grep -A0 'NSHumanReadableCopyright' | head -1; }
if git cat-file -e "$BASE:Resources/Info.plist" 2>/dev/null &&
   [[ "$(git show "$BASE:Resources/Info.plist" | copyright)" != "$(copyright < Resources/Info.plist)" ]]; then
  echo "✗ Info.plist copyright changed"; fail=1
fi

if (( fail )); then
  echo "Credits are protected. Revert these changes (see AGENTS.md → Protected)."
  exit 1
fi
echo "✓ Credits untouched."
