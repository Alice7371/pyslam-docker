#!/usr/bin/env bash
# Activate the pyslam venv (created by pyslam's install_all.sh) and the repo
# environment, then exec the given command.
# NOTE: positional args must be cleared before sourcing: pyenv-venv-activate.sh
# inherits the caller's $1 as the venv name ("docker run img python -c ..."
# would otherwise make it look for a venv called "python").
set -e
cd /opt/pyslam
CMD=("$@")
set --
source ./pyenv-activate.sh
exec "${CMD[@]}"
