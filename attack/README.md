# jFTP .login_default decryption -> FTP exam deletion (spike demo)

Simulates recovering a real FTP password from a leaked jFTP saved-login
file (`.login_default`), then using that password with an ordinary FTP
client to find and delete a "sensitive" exam from an **already-running**
pyftpdlib server. `attack.sh` does not start a server and does not create
its own `.login_default` — it only reads the real file jFTP already wrote,
and only talks to the real, already-running server over FTP.

## Process this demo assumes

1. **You** start the real pyftpdlib server yourself, from the `pyftpdlib/`
   directory, in your own terminal (e.g. `cmd` on Windows). For example:

   ```sh
   cd pyftpdlib
   python3 -m pyftpdlib -i 127.0.0.1 -p 2121 -d . -u ta_exams -P 'some-password' -w
   ```

   Put the exam file (or an exam directory) somewhere under that document
   root (`.` above) first.

2. **You** start jFTP yourself (e.g. run it from VS Code / however you
   normally build/launch it) and connect it to that server. Before
   connecting, make sure **Options → Security → "Store passwords
   (encrypted using internal password)"** is checked. On a successful
   connect, jFTP's `HostChooser` writes `~/.jftp/.login_default` via
   `SaveSet`, with the password field encrypted by `Crypto.Encrypt()`.

3. **Run `./attack.sh`** on the same machine. It:
   - finds `~/.jftp/.login_default` (the real file jFTP just wrote — not
     a copy this script made),
   - decrypts the password field using jFTP's own, unmodified `Crypto`
     class (same hardcoded key every install ships with),
   - connects to the host/port/user named in that file using a plain FTP
     client (`curl` — not jFTP),
   - recursively searches the server for anything named like an exam, and
     deletes it (file or whole directory).

The server and jFTP are both already-running, independent processes that
`attack.sh` never starts, stops, or writes into — it only ever talks to
the server over the FTP protocol, and only ever reads `.login_default`
off disk.

## Vulnerability

`jftp/src/java/net/sf/jftp/config/Crypto.java` "encrypts" saved passwords
with `PBEWithMD5AndDES` using a password and salt that are **hardcoded
constants**, identical for every install:

```java
private static final char[] PASSWORD = "(l_[m^5][:]FQ8D* ;zoG,7".toCharArray();
private static final byte[] SALT = { 0x56, 0x40, 0x77, 0x32, 0x10, 0x63, 0x25, 0x3C };
```

`.login_default` (`Settings.login_def` = `${user.home}/.jftp/.login_default`)
is written by `SaveSet.savePW()` every time `HostChooser` completes a
successful FTP connection with "Store passwords" enabled (see
`HostChooser.java`'s `actionPerformed()`), with the password field run
through `Crypto.Encrypt()`. Anyone who can read that file can decrypt the
password with the exact same (public, open-source) class — no brute
force, no sniffing, no interaction with the server required. This is
CWE-321 / CWE-798 (use of a hardcoded cryptographic key / hardcoded
credentials): storing a password this way is only cosmetically different
from plaintext.

**Note: this is specifically about `.login_default`, not `bookmarks.txt`.**
`bookmarks.txt` is a different jFTP feature (`AddBookmarks`/
`BookmarkManager`) that writes `protocol#host#user#password#port#dir#local`
lines with the password stored as **plain text** — it never calls
`Crypto.Encrypt()` at all (see `AddBookmarks.getData()` and
`BookmarkManager.save()`). That file is arguably worse (no obfuscation
whatsoever) but it isn't an example of this specific hardcoded-key
vulnerability, so this demo targets `.login_default`, the file this
attack is actually about.

## Layout

```
crypto_helper/   CryptoCli.java, a thin wrapper around jFTP's real,
                 unmodified Crypto class (compiled, then used by
                 attack.sh to decrypt the recovered password)
attack.sh        runs the attack against the already-running server
setup.sh         one-time environment check (JDK, curl) + compiles
                 crypto_helper
```

## Prerequisites

- A JDK (`javac`/`java`) on `PATH`. `setup.sh` checks for this and tells
  you how to install one if it's missing (Windows/macOS/Linux hints
  included). It installs nothing itself — no admin/sudo required.
- `curl` on `PATH` (ships with Git Bash and most modern OSes).
- Run from a shell that understands bash scripts: Git Bash or WSL on
  Windows, or a regular terminal on macOS/Linux.
- The pyftpdlib server already running, and jFTP already connected to it
  once with "Store passwords" enabled (see Process above).

## Running it

```sh
./setup.sh     # one-time: checks for a JDK + curl, compiles crypto_helper
./attack.sh    # runs the attack against your already-running server
```

By default, `setup.sh`/`attack.sh` find `jftp/` automatically as a sibling
of this `attack/` folder (i.e. directly under the repo root). Override
with `JFTP_SRC` if you've moved things, e.g.:

```sh
JFTP_SRC=/path/to/jftp ./setup.sh
JFTP_SRC=/path/to/jftp ./attack.sh
```

`attack.sh` also reads these (all optional):

| Variable         | Default                    | Meaning |
|------------------|-----------------------------|---------|
| `JFTP_HOME_DIR`  | `${HOME}/.jftp`             | where to look for jFTP's config dir |
| `LOGIN_DEFAULT`  | `${JFTP_HOME_DIR}/.login_default` | the saved-login file to read |
| `EXAM_NAME`      | `exam`                      | case-insensitive substring to search for (file or directory name) |
| `MAX_DEPTH`      | `6`                         | how many directory levels deep to search on the server |

e.g. if your exam file is named `midterm.pdf`:

```sh
EXAM_NAME=midterm ./attack.sh
```

## What `attack.sh` does

1. **Locate the leak** — reads `.login_default` off disk (real file,
   written by jFTP itself; this script never creates or edits it) and
   parses out host/user/encrypted-password/port.
2. **Decrypt** — calls jFTP's own `Crypto.Decrypt()` (via the compiled
   `CryptoCli` wrapper) on the encrypted password field.
3. **Connect** — logs in to the real host/port/user with `curl` as a
   plain FTP client (not jFTP) and lists the root directory to confirm
   the credentials work.
4. **Search** — recursively walks the server's directory tree (via
   `LIST`) looking for a file or directory whose name contains
   `EXAM_NAME` (case-insensitive), up to `MAX_DEPTH` levels deep.
5. **Delete** — if a file: `DELE`s it directly. If a directory: recursively
   `DELE`s every file inside it, then `RMD`s every subdirectory from the
   deepest level up (FTP's `RMD` only removes empty directories, so
   contents have to go first).
6. **Verify** — attempts to list the deleted path again and confirms it's
   gone, then prints a root-cause/remediation summary.

Nothing in this script starts, stops, or configures the FTP server or
jFTP — both are expected to already be running when you invoke it.
