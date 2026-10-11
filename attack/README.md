# jFTP bookmark-decryption -> FTP exam exfiltration/deletion (spike demo)

Simulates, end-to-end, how a leaked **jFTP** bookmark/login file can be used
to recover a real FTP password and then compromise a **pyftpdlib** server
that is otherwise configured correctly (auth required, no anonymous access).

Cross-platform: everything here is plain Python (`attack.py`, `setup.py`,
`server.py`, `common.py`) plus one small Java helper class. It runs the
same way on Windows (`cmd.exe`/PowerShell), macOS, and Linux -- there is no
bash script to translate.

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
common.py             shared helpers: path resolution, classpath building,
                       JDK lookup, asyncore/asynchat availability check
server.py             pyftpdlib FTP server (one account, no anonymous access)
attack.py             orchestrates the whole simulation (replaces attack.sh)
setup.py              one-time environment check + build (replaces setup.sh)
server_root/           FTP server document root (contains exam.txt)
fixtures/              canonical copy of exam.txt, restored each run
jftp_config/            where the simulated jFTP bookmark file gets written
attacker_workspace/     where the "attacker" downloads the exfiltrated file
logs/                   server.log from the most recent run
crypto_helper/          CryptoCli.java, a thin wrapper around jFTP's real,
                        unmodified Crypto class (used by both the victim,
                        to encrypt, and the attacker, to decrypt), plus the
                        compiled .class output under crypto_helper/out/
```

## Prerequisites

- A JDK (`javac`/`java`) on `PATH`, or set `JAVA_HOME` to the JDK install
  directory.
  - Windows: install a JDK (e.g. [Temurin 21](https://adoptium.net/)) and
    make sure its `bin` folder is on `PATH`.
  - macOS: `brew install openjdk@21` (or similar).
  - Linux: `sudo apt-get install openjdk-21-jdk-headless` (Debian/Ubuntu)
    or your distro's equivalent.
- Python 3.9–3.11 is recommended. pyftpdlib's handler code imports the
  stdlib `asyncore`/`asynchat` modules, which were removed in Python 3.12
  (PEP 594). On 3.12+, `setup.py` will install the `pyasynchat`/
  `pyasyncore` backport packages for you via pip. (This is an
  environment-compatibility fix only, unrelated to the vulnerability being
  demonstrated.)

By default, `jftp/` and `pyftpdlib/` are located automatically as siblings
of this `attack/` folder (i.e. directly under the repo root, which is how
this repo is actually laid out). If you've moved this folder elsewhere,
point at your checkouts with environment variables:

```sh
# macOS/Linux
export JFTP_SRC=/path/to/jftp
export PYFTPDLIB_SRC=/path/to/pyftpdlib
```

```bat
:: Windows cmd.exe
set JFTP_SRC=C:\path\to\jftp
set PYFTPDLIB_SRC=C:\path\to\pyftpdlib
```

## Running it

```sh
python setup.py      # one-time: checks for a JDK, checks/installs
                      # asyncore/asynchat if needed, compiles crypto_helper
python attack.py      # runs the full simulation
```

(Use `python3` instead of `python` if that's how your system's Python 3 is
invoked, e.g. on macOS/Linux where `python` may point at Python 2 or not
exist at all.) `attack.py` will also call `setup.py` for you automatically
on first run if the Java helper hasn't been compiled yet.

## What `attack.py` does

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
   public, hardcoded constant rather than a secret. The script asserts the
   recovered value matches the password the server was actually started
   with, so a successful run is proof the decryption — not a lucky guess —
   is what unlocked the account.
5. **Exploit** — logs in with the recovered credentials, lists the
   directory, downloads `exam.txt`, then deletes it from the server.
6. Prints the resulting state (file gone from `server_root/`, present in
   `attacker_workspace/`), the server's own session log, and a short
   root-cause/remediation summary.

Everything only ever talks to the local demo server on `127.0.0.1:2121`
started by the script itself.
