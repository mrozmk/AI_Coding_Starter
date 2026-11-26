"""Test driver of the #322 effect classifier: no network, no live DNS.

python3 -I egress_classify_driver.py <project> <Bash|WebFetch> <input> [<name>=<ip>[,<ip>…] …]
  [@sleep=<secs>] [@cwd=<dir>] — sets the classifier's RESOLVER to a stub that answers the given
names (a name it does not know raises OSError: a failed lookup; @sleep stalls every lookup) and
prints `<kind>\t<reason>` for one call. <input> `@file:<path>` reads the input from a file.
"""
import os
import socket
import sys
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "hooks", "lib"))

import guard_team_egress_classify as c  # noqa: E402


def main(argv):
    project, tool, text = argv[1], argv[2], argv[3]
    if text.startswith("@file:"):
        with open(text[6:], encoding="utf-8") as fh:
            text = fh.read().rstrip("\n")
    table, delay, cwd = {}, 0.0, None
    for a in argv[4:]:
        if a.startswith("@sleep="):
            delay = float(a[7:])
        elif a.startswith("@cwd="):
            cwd = a[5:]
        else:
            name, _, ips = a.partition("=")
            table[name.lower()] = ips.split(",")

    def stub(host, port, *args, **kwargs):
        if delay:
            time.sleep(delay)
        if host.lower() not in table:
            raise OSError("stub: unknown name " + host)
        return [(socket.AF_INET6 if ":" in ip else socket.AF_INET, socket.SOCK_STREAM, 6, "",
                 (ip, port)) for ip in table[host.lower()]]
    c.RESOLVER = stub
    os.environ["CLAUDE_PROJECT_DIR"] = project
    if tool == "WebFetch":
        kind, reason = c.classify_webfetch(text, project)
    else:
        kind, reason = c.classify_bash(text, project, cwd)
    print(kind + "\t" + reason)


if __name__ == "__main__":
    main(sys.argv)
