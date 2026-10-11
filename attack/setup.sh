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

echo "[setup] checking for a JDK (javac) ..."
if ! command -v javac >/dev/null 2>&1; then
    echo "Could not find 'javac' on PATH." >&2
    echo "Install a JDK and make sure its bin/ directory is on PATH, then re-run." >&2
    echo "  Windows (winget):  winget install EclipseAdoptium.Temurin.21.JDK" >&2
    echo "  macOS (Homebrew):  brew install openjdk@21" >&2
    echo "  Debian/Ubuntu:     sudo apt-get install openjdk-21-jdk-headless" >&2
    exit 1
fi

echo "[setup] checking that this Python can import pyftpdlib from PYFTPDLIB_SRC ..."
if ! IMPORT_ERR=$(PYTHONPATH="${PYFTPDLIB_SRC}${PYTHONPATH:+:${PYTHONPATH}}" python3 -c "import pyftpdlib" 2>&1); then
    echo "python3 ($(command -v python3)) could not import pyftpdlib from ${PYFTPDLIB_SRC}:" >&2
    echo "${IMPORT_ERR}" >&2
    echo >&2
    echo "pyftpdlib's handler code imports the stdlib 'asyncore'/'asynchat' modules," >&2
    echo "which were removed in Python 3.12+ (PEP 594). If that's the failure above," >&2
    echo "either run this with a Python 3.10/3.11 interpreter, or install the" >&2
    echo "backport packages yourself first:" >&2
    echo "    python3 -m pip install pyasynchat pyasyncore" >&2
    exit 1
fi

echo "[setup] compiling jFTP's real Crypto.java + the CryptoCli wrapper ..."
mkdir -p "${DEMO_DIR}/crypto_helper/out"
javac -cp "${JFTP_SRC}/lib" -d "${DEMO_DIR}/crypto_helper/out" \
    "${JFTP_SRC}/src/java/net/sf/jftp/config/Crypto.java" \
    "${DEMO_DIR}/crypto_helper/src/CryptoCli.java"

echo "[setup] done. Run ./attack.sh to execute the simulation."
