#!/usr/bin/env bash
# Activate the pyslam venv (created by pyslam's install_all.sh) and the repo
# environment, then exec the given command.
set -e
cd /opt/pyslam
source ./pyenv-activate.sh
exec "$@"
