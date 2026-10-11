# jFTP bookmark-decryption -> FTP exam exfiltration/deletion (spike demo)

Simulates, end-to-end, how a leaked **jFTP** bookmark/login file can be used
to recover a real FTP password and then compromise a **pyftpdlib** server
that is otherwise configured correctly (auth required, no anonymous access).

## Vulnerability

`jftp/src/java/net/sf/jftp/config/Crypto.java` "encrypts" saved passwords
with `PBEWithMD5AndDES` using a password and salt that are **hardcoded
constants**, identical for every install:

```java
private static final char[] PASSWORD = "(l_[m^5][:]FQ8D* ;zoG,7".toCharArray();
private static final byte[] SALT = { 0x56, 0x40, 0x77, 0x32, 0x10, 0x63, 0x25, 0x3C };
```

Anyone who can read a saved-login file (`bookmarks.txt` or `.login_default`,
written by `SaveSet`/`BookmarkManager`) can decrypt the password field with
the exact same (public, open-source) class — no brute force, no sniffing,
no interaction with the server required. This is CWE-321 / CWE-798
(use of a hardcoded cryptographic key / hardcoded credentials): storing a
password this way is only cosmetically different from plaintext.

## Layout

```
server_root/        FTP server document root (contains exam.txt)
fixtures/            canonical copy of exam.txt, restored each run
jftp_config/          where the simulated jFTP bookmark file gets written
attacker_workspace/   where the "attacker" downloads the exfiltrated file
crypto_helper/        CryptoCli.java, a thin wrapper around jFTP's real,
                       unmodified Crypto class (used by both the victim,
                       to encrypt, and the attacker, to decrypt)
server.py             pyftpdlib FTP server (one account, no anonymous access)
ftp_probe.py          FTP client helper (baseline check + exploit steps)
attack.sh             orchestrates the whole simulation
setup.sh              one-time environment setup (JDK, Python compat shims)
```

## Running it

```sh
./setup.sh     # one-time: installs javac + asyncore/asynchat backports,
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

Note: pyftpdlib's handler code imports the long-removed `asynchat`/
`asyncore` stdlib modules (dropped in Python 3.12 via PEP 594); `setup.sh`
installs the `pyasynchat`/`pyasyncore` backport packages so it runs on a
modern interpreter. That's an environment-compatibility fix only, unrelated
to the vulnerability being demonstrated.

## What `attack.sh` does

1. Starts the FTP server with a single account (`ta_exams`) that owns
   `server_root` with full permissions. Anonymous access is **not**
   configured, so in theory the exam cannot be reached without that
   account's password.
2. **Baseline** — confirms an anonymous/no-credential login is rejected.
3. **Victim side** — simulates the TA using jFTP's "remember password"
   bookmark feature: writes `jftp_config/.login_default` in the real
   `SaveSet` 6-line format (`host/user/encrypted-pass/port/cwd/lcwd`),
   with the password field produced by jFTP's actual `Crypto.Encrypt()`.
4. **Attacker side** — reads that file (its only starting point — it never
   sees the plaintext password) and calls the same `Crypto` class's
   `Decrypt()` to recover the real FTP password, because the key is a
   public, hardcoded constant rather than a secret.
5. **Exploit** — logs in with the recovered credentials, lists the
   directory, downloads `exam.txt`, then deletes it from the server.
6. Prints the resulting state (file gone from `server_root/`, present in
   `attacker_workspace/`), the server's own session log, and a short
   root-cause/remediation summary.

Everything only ever talks to the local demo server on `127.0.0.1:2121`
started by the script itself.
