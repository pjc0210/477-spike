#!/usr/bin/env bash
# One-time environment setup for the demo.
#
#   JFTP_SRC  - path to the jftp/ checkout (contains src/java/... and lib/)
#   PYFTPDLIB_SRC - path to the pyftpdlib/ checkout (contains pyftpdlib/ package)
#
# By default, jftp/ and pyftpdlib/ are found automatically as siblings of
# this attack/ folder (i.e. directly under the repo root -- this repo's
# actual layout). Override with the env vars above if you've moved things.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${DEMO_DIR}/.." && pwd)"
JFTP_SRC="${JFTP_SRC:-${REPO_ROOT}/jftp}"
PYFTPDLIB_SRC="${PYFTPDLIB_SRC:-${REPO_ROOT}/pyftpdlib}"

if [[ ! -f "${JFTP_SRC}/src/java/net/sf/jftp/config/Crypto.java" ]]; then
    echo "Could not find jftp/src/java/.../Crypto.java under ${JFTP_SRC}" >&2
    echo "Set JFTP_SRC to the path of your jftp/ checkout and re-run." >&2
    exit 1
fi
if [[ ! -f "${PYFTPDLIB_SRC}/pyftpdlib/__init__.py" ]]; then
    echo "Could not find pyftpdlib/pyftpdlib/__init__.py under ${PYFTPDLIB_SRC}" >&2
    echo "Set PYFTPDLIB_SRC to the path of your pyftpdlib/ checkout and re-run." >&2
    exit 1
fi

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
