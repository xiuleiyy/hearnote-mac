#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")" && pwd)"
bash "$project_root/scripts/build-mac.sh" --open
