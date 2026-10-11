"""
Shared, pure-stdlib helpers for the attack demo.

Everything here is written to work unmodified on Windows (cmd.exe /
PowerShell), macOS, and Linux: no shell-outs, no hardcoded path
separators, no assumptions about where this checkout lives on disk.

Path resolution: this file lives in <repo>/attack/common.py, and jftp/
and pyftpdlib/ are expected to be siblings of attack/ (i.e. directly
under <repo>/). That matches how this repo is actually laid out. You
can still override either location with the JFTP_SRC / PYFTPDLIB_SRC
environment variables if you've moved things around.
"""
from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path


DEMO_DIR = Path(__file__).resolve().parent
REPO_ROOT = DEMO_DIR.parent


def jftp_src() -> Path:
    override = os.environ.get("JFTP_SRC")
    path = Path(override) if override else (REPO_ROOT / "jftp")
    if not (path / "src" / "java" / "net" / "sf" / "jftp" / "config" / "Crypto.java").is_file():
        raise SystemExit(
            f"Could not find jftp/src/java/.../Crypto.java under {path}.\n"
            "Set the JFTP_SRC environment variable to the path of your jftp/ "
            "checkout (the folder that directly contains 'src' and 'lib')."
        )
    return path


def pyftpdlib_src() -> Path:
    override = os.environ.get("PYFTPDLIB_SRC")
    path = Path(override) if override else (REPO_ROOT / "pyftpdlib")
    if not (path / "pyftpdlib" / "__init__.py").is_file():
        raise SystemExit(
            f"Could not find pyftpdlib/pyftpdlib/__init__.py under {path}.\n"
            "Set the PYFTPDLIB_SRC environment variable to the path of your "
            "pyftpdlib/ checkout (the folder that directly contains the "
            "'pyftpdlib' package directory)."
        )
    return path


def classpath(*entries: Path | str) -> str:
    """Join classpath entries with the OS-correct separator
    (';' on Windows, ':' on everything else) -- os.pathsep handles this.
    """
    return os.pathsep.join(str(e) for e in entries)


def _candidate_names(tool: str) -> list[str]:
    # On Windows the executables are <tool>.exe; shutil.which() already
    # checks PATHEXT for bare names, but we also try explicit .exe for
    # JAVA_HOME-based lookups below where we build the path manually.
    return [tool, f"{tool}.exe"]


def find_java_tool(tool: str) -> str:
    """Locate `javac` or `java` on PATH, falling back to $JAVA_HOME/bin.
    Raises SystemExit with OS-appropriate install instructions if not found.
    """
    found = shutil.which(tool)
    if found:
        return found

    java_home = os.environ.get("JAVA_HOME")
    if java_home:
        bin_dir = Path(java_home) / "bin"
        for name in _candidate_names(tool):
            candidate = bin_dir / name
            if candidate.is_file():
                return str(candidate)

    if sys.platform.startswith("win"):
        hint = (
            "Install a JDK (e.g. https://adoptium.net/, Temurin 21) and make "
            "sure its 'bin' directory (containing javac.exe) is on PATH, or "
            "set JAVA_HOME to the JDK install directory."
        )
    elif sys.platform == "darwin":
        hint = (
            "Install a JDK, e.g. `brew install openjdk@21`, and make sure "
            "`javac` is on PATH (or set JAVA_HOME)."
        )
    else:
        hint = (
            "Install a JDK, e.g. `sudo apt-get install openjdk-21-jdk-headless` "
            "(Debian/Ubuntu) or your distro's equivalent, and make sure "
            "`javac` is on PATH (or set JAVA_HOME)."
        )

    raise SystemExit(f"Could not find '{tool}' on PATH or $JAVA_HOME/bin.\n{hint}")


def check_asyncore_available() -> None:
    """pyftpdlib's handler modules import the stdlib `asyncore`/`asynchat`
    modules, which were removed in Python 3.12 (PEP 594). Give a clear,
    actionable error instead of a confusing ImportError deep in pyftpdlib.
    """
    try:
        import asynchat  # noqa: F401
        import asyncore  # noqa: F401
    except ModuleNotFoundError:
        raise SystemExit(
            "This Python interpreter ("
            f"{sys.version.split()[0]}) does not provide the 'asyncore'/"
            "'asynchat' modules (removed in Python 3.12+), which pyftpdlib's "
            "handler code imports directly.\n"
            "Fix: run\n"
            f"    {sys.executable} -m pip install pyasynchat pyasyncore\n"
            "or use a Python 3.10/3.11 interpreter to run this demo."
        ) from None
