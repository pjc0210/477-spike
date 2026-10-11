#!/usr/bin/env python3
"""
Minimal pyftpdlib-based FTP server for the attack simulation.

Root of the server is ./server_root (contains the "sensitive" exam.txt).
Only ONE account exists: it owns server_root with full read/write/delete
permissions. There is NO anonymous access, so "in theory" nobody can touch
exam.txt without that account's password.

The password is intentionally passed in on the command line so the rest of
the demo (attack.sh) can both (a) feed it to the "victim" side, which saves
it into a jFTP bookmark file via the real Crypto.Encrypt(), and (b) use the
server logs to confirm who actually logged in and when.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import check_asyncore_available, pyftpdlib_src  # noqa: E402

# Point sys.path at the directory that CONTAINS the pyftpdlib/ package (the
# pyftpdlib checkout root). By default this is the `pyftpdlib/` directory
# that sits as a sibling of this repo's `attack/` folder; override with the
# PYFTPDLIB_SRC environment variable if yours lives elsewhere.
sys.path.insert(0, str(pyftpdlib_src()))
check_asyncore_available()

from pyftpdlib.authorizers import DummyAuthorizer  # noqa: E402
from pyftpdlib.handlers import FTPHandler  # noqa: E402
from pyftpdlib.servers import FTPServer  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, help="server document root")
    parser.add_argument("--user", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=2121)
    args = parser.parse_args()

    authorizer = DummyAuthorizer()
    # Full perm set: list/enter dirs, retrieve, append, delete, rename,
    # mkdir, store, chmod, change timestamp. This is the "legitimate"
    # account that is SUPPOSED to be the only way to reach exam.txt.
    authorizer.add_user(
        args.user,
        args.password,
        args.root,
        perm="elradfmwMT",
    )
    # Deliberately no authorizer.add_anonymous(...) call: anonymous / guest
    # access is disabled, so "in theory" the exam cannot be reached without
    # valid credentials for the account above.

    handler = FTPHandler
    handler.authorizer = authorizer
    handler.banner = "demo ftpd ready."

    server = FTPServer((args.host, args.port), handler)
    server.max_cons = 50
    server.max_cons_per_ip = 10

    print(f"[server] listening on {args.host}:{args.port}, root={args.root}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
