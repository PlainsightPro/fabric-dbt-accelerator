#!/usr/bin/env bash
#
# One-shot setup of the Fabric side of the accelerator.
#
# Thin wrapper around scripts/bootstrap.py: finds an interpreter, forwards every
# argument. All the behaviour and the --help text live in the Python.
#
#   ./infra/bootstrap.sh
#   ./infra/bootstrap.sh --dry-run
#   ./infra/bootstrap.sh --sp-mode existing --sp-id <appId>

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bootstrap="${script_dir}/scripts/bootstrap.py"

# The repo's venv first, so this works before anything is activated.
# bootstrap.py itself is stdlib-only and runs under either interpreter.
if [[ -x "${script_dir}/../.venv/bin/python" ]]; then
    python="${script_dir}/../.venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
    python="python3"
elif command -v python >/dev/null 2>&1; then
    python="python"
else
    echo "No Python interpreter found. Install Python 3.11+ or create the venv: python3 -m venv .venv" >&2
    exit 1
fi

exec "$python" "$bootstrap" "$@"
