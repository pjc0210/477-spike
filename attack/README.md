# jFTP .login_default decryption -> FTP exam exfiltration/deletion (spike demo)

Simulates, end-to-end, how a leaked **jFTP** saved-login file (`.login_default`)
can be used to recover a real FTP password and then compromise a
**pyftpdlib** server that is otherwise configured correctly (auth required,
no anonymous access).

## Vulnerability

`jftp/src/java/net/sf/jftp/config/Crypto.java` "encrypts" saved passwords
with `PBEWithMD5AndDES` using a password and salt that are **hardcoded
constants**, identical for every install:

```java
private static final char[] PASSWORD = "(l_[m^5][:]FQ8D* ;zoG,7".toCharArray();
private static final byte[] SALT = { 0x56, 0x40, 0x77, 0x32, 0x10, 0x63, 0x25, 0x3C };
```

Anyone who can read `.login_default` — the file jFTP writes via
`SaveSet.savePW()` whenever you check "remember this login" in the
connect dialog (`HostChooser`/`LocalDir`/`RemoteDir`), using
`Crypto.Encrypt()` for the password field — can decrypt that password
with the exact same (public, open-source) class, no brute force, no
sniffing, no interaction with the server required. This is CWE-321 /
CWE-798 (use of a hardcoded cryptographic key / hardcoded credentials):
storing a password this way is only cosmetically different from
plaintext.

Note: this is specifically about `.login_default`, not `bookmarks.txt`.
`bookmarks.txt` is a different jFTP feature (`AddBookmarks`/
`BookmarkManager`) that writes `protocol#host#user#password#port#dir#local`
lines with the password stored as **plain text** — it never calls
`Crypto.Encrypt()` at all (see `AddBookmarks.getData()` and
`BookmarkManager.save()`). That file is arguably worse (no obfuscation
whatsoever) but it isn't an example of this specific hardcoded-key
vulnerability, so this demo targets `.login_default` instead, which is
the file this attack is actually about.

## Layout

```
fixtures/              canonical copy of exam.txt, restored each run into
                        the pyftpdlib/ checkout (the server's document root)
jftp_config/            where the simulated jFTP .login_default file gets written
attacker_workspace/     where the "attacker" downloads the exfiltrated file
crypto_helper/          CryptoCli.java, a thin wrapper around jFTP's real,
                        unmodified Crypto class (used by both the victim,
                        to encrypt, and the attacker, to decrypt)
server.py               pyftpdlib FTP server (one account, no anonymous access)
ftp_probe.py            FTP client helper (baseline check + exploit steps)
attack.sh               orchestrates the whole simulation
setup.sh                one-time environment check (JDK, pyftpdlib import)
```

Note: there is no `server_root/` directory in this demo. The FTP server's
document root is the sibling `pyftpdlib/` checkout itself (see `attack.sh`'s
`SERVER_ROOT="${PYFTPDLIB_SRC}"`) — `exam.txt` is written directly into
`pyftpdlib/exam.txt` and served/deleted from there, so the attack runs
against the real project directory rather than an artificial sandbox.

## Prerequisites

- A JDK (`javac`/`java`) on `PATH`. `setup.sh` checks for this and tells you
  how to install one if it's missing (it does **not** install anything for
  you — no `apt-get`, no admin/sudo required).
- A `python3` that can `import pyftpdlib` from the `pyftpdlib/` checkout
  this demo points at. `setup.sh` checks this too. If it fails because
  your interpreter is Python 3.12+ (which dropped the stdlib `asyncore`/
  `asynchat` modules that pyftpdlib's handler code imports — PEP 594),
  either use a 3.10/3.11 interpreter, or install the backports yourself:
  `python3 -m pip install pyasynchat pyasyncore`.
- Run from a shell that understands bash scripts: Git Bash or WSL on
  Windows, or a regular terminal on macOS/Linux.

## Running it

```sh
./setup.sh     # one-time: checks for a JDK + a working pyftpdlib import,
                # compiles crypto_helper
./attack.sh    # runs the full simulation
```

By default, `setup.sh` / `attack.sh` find `jftp/` and `pyftpdlib/`
automatically as siblings of this `attack/` folder (i.e. directly under the
repo root, which is how this repo is actually laid out). Override with the
`JFTP_SRC` / `PYFTPDLIB_SRC` env vars if you've moved things around, e.g.:

```sh
JFTP_SRC=/path/to/jftp PYFTPDLIB_SRC=/path/to/pyftpdlib ./setup.sh
JFTP_SRC=/path/to/jftp PYFTPDLIB_SRC=/path/to/pyftpdlib ./attack.sh
```

## What `attack.sh` does

1. Starts the FTP server with a single account (`ta_exams`) that owns the
   `pyftpdlib/` checkout (used as the document root) with full permissions.
   Anonymous access is **not** configured, so in theory the exam cannot be
   reached without that account's password.
2. **Baseline** — confirms an anonymous/no-credential login is rejected.
3. **Victim side** — simulates the TA using jFTP's "remember this login"
   checkbox in the connect dialog, which writes `jftp_config/.login_default`
   in the real `SaveSet` 6-line format (`host/user/encrypted-pass/port/cwd/
   lcwd`), with the password field produced by jFTP's actual
   `Crypto.Encrypt()`.
4. **Attacker side** — reads that file (its only starting point — it never
   sees the plaintext password) and calls the same `Crypto` class's
   `Decrypt()` to recover the real FTP password, because the key is a
   public, hardcoded constant rather than a secret.
5. **Exploit** — logs in with the recovered credentials, lists the
   directory, downloads `exam.txt`, then deletes it from the server.
6. Prints the resulting state (`exam.txt` gone from `pyftpdlib/`, present
   in `attacker_workspace/`), the server's own session log, and a short
   root-cause/remediation summary.

Everything only ever talks to the local demo server on `127.0.0.1:2121`
started by the script itself.
