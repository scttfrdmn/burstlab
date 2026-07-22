#!/usr/bin/env bash
# Installs the BurstLab git hooks into this clone's .git/hooks/.
# Run once after cloning: bash scripts/hooks/install.sh
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
hooks_src="$repo_root/scripts/hooks"
hooks_dst="$repo_root/.git/hooks"

install -m 0755 "$hooks_src/pre-commit" "$hooks_dst/pre-commit"
echo "Installed pre-commit hook -> $hooks_dst/pre-commit"
echo "It blocks committing *.tfstate, terraform.tfvars, and private keys (see issue #1)."
