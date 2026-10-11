#!/usr/bin/env python3
"""
One-time environment check + build step for the attack demo.
Cross-platform: run with `python setup.py` (Windows) or
`python3 setup.py` (macOS/Linux).

What it does:
  1. Verifies a JDK is available (javac/java on PATH or $JAVA_HOME/bin),
     with an OS-appropriate install hint if not.
  2. Verifies this interpreter has (or installs, with your consent) the
     asyncore/asynchat modules pyftpdlib's handler code imports -- these
     were removed from the stdlib in Python 3.12 (PEP 594), so on 3.12+
     the `pyasynchat`/`pyasyncore` backport packages are required.
  3. Compiles jFTP's real, unmodified Crypto.java plus the small
     CryptoCli.java wrapper into attack/crypto_helper/out/.

Env vars (optional, override auto-detected paths):
  JFTP_SRC       path to the jftp/ checkout (contains src/java/... and lib/)
  PYFTPDLIB_SRC  path to the pyftpdlib/ checkout (contains the pyftpdlib/
                 package directory)
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import DEMO_DIR, find_java_tool, jftp_src  # noqa: E402


def check_asyncore() -> None:
    try:
        import asynchat  # noqa: F401
        import asyncore  # noqa: F401
        print(f"[setup] asyncore/asynchat available (Python {sys.version.split()[0]})")
        return
    except ModuleNotFoundError:
        pass

    print(
        f"[setup] Python {sys.version.split()[0]} does not ship asyncore/"
        "asynchat (removed in 3.12+); pyftpdlib's handler code imports them "
        "directly."
    )
    print(f"[setup] installing pyasynchat/pyasyncore backports via {sys.executable} -m pip ...")
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "pyasynchat", "pyasyncore"],
        check=True,
    )


def compile_crypto_helper() -> None:
    javac = find_java_tool("javac")
    jftp = jftp_src()
    out_dir = DEMO_DIR / "crypto_helper" / "out"
    out_dir.mkdir(parents=True, exist_ok=True)

    print("[setup] compiling jFTP's real Crypto.java + the CryptoCli wrapper ...")
    cmd = [
        javac,
        "-cp", str(jftp / "lib"),
        "-d", str(out_dir),
        str(jftp / "src" / "java" / "net" / "sf" / "jftp" / "config" / "Crypto.java"),
        str(DEMO_DIR / "crypto_helper" / "src" / "CryptoCli.java"),
    ]
    subprocess.run(cmd, check=True)
    print(f"[setup] compiled classes written to {out_dir}")


def main() -> int:
    print("[setup] checking for a JDK (javac) ...")
    find_java_tool("javac")
    find_java_tool("java")
    print("[setup] JDK found.")

    check_asyncore()
    compile_crypto_helper()

    print("[setup] done. Run `python attack.py` (or `python3 attack.py`) to execute the simulation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
