"""Test-only driver of guard_team_egress_clear.py (#323 R1-8): runs its CLI with the classifier's
resolver swapped for an offline stub — every lexically public name resolves to a public address,
the names in PRIVATE to a private one. Production code reads no resolver setting; this file is
never registered in a hook or a profile.
Usage: python3 -I drive.py <hooks lib dir> <guard_team_egress_clear.py arguments…>"""
import socket
import sys
sys.dont_write_bytecode = True

PRIVATE = {"intranet-mirror.acme-docs.com"}


def stub(host, port, *a, **k):
    addr = "10.0.0.5" if str(host).rstrip(".").lower() in PRIVATE else "93.184.216.34"
    return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (addr, port))]


sys.path.insert(0, sys.argv[1])
import guard_team_egress_classify  # noqa: E402
guard_team_egress_classify.RESOLVER = stub
import guard_team_egress_clear  # noqa: E402
sys.exit(guard_team_egress_clear.main(sys.argv[2:]))
