#!/usr/bin/env bash
# One-time environment setup for the demo.
#
#   JFTP_SRC  - path to the jftp/ checkout (contains src/java/... and lib/)
#   PYFTPDLIB_SRC - path to the pyftpdlib/ checkout (contains pyftpdlib/ package)
#
# Adjust the two paths below if you place this folder somewhere other than
# next to the 477-spike checkout it was generated alongside.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JFTP_SRC="${JFTP_SRC:-/home/claude/work/477-spike/jftp}"
PYFTPDLIB_SRC="${PYFTPDLIB_SRC:-/home/claude/work/477-spike/pyftpdlib}"

echo "[setup] installing a JDK (for javac) ..."
if ! command -v javac >/dev/null 2>&1; then
    apt-get update
    apt-get install -y openjdk-21-jdk-headless
fi

echo "[setup] installing asyncore/asynchat backports (needed on Python 3.12+, pyftpdlib predates their removal) ..."
pip install --break-system-packages pyasynchat pyasyncore

echo "[setup] compiling jFTP's real Crypto.java + the CryptoCli wrapper ..."
mkdir -p "${DEMO_DIR}/crypto_helper/out"
javac -cp "${JFTP_SRC}/lib" -d "${DEMO_DIR}/crypto_helper/out" \
    "${JFTP_SRC}/src/java/net/sf/jftp/config/Crypto.java" \
    "${DEMO_DIR}/crypto_helper/src/CryptoCli.java"

echo "[setup] done. Run ./attack.sh to execute the simulation."
