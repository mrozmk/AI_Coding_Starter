"""Machine-wide lock for full gate runs: one test-gate / merge-check build+test at a time.

Usage: python3 -I gate_lock.py acquire <owner_pid> <clone> <what>  → "<token> <waited s>", exit 0
       python3 -I gate_lock.py release <owner_pid> <token>          → exit 0 (owner-only, else no-op)
       python3 -I gate_lock.py held <token>                         → exit 0 iff that live holder
       python3 -I gate_lock.py load                                 → "<1m> <5m> <15m>"
acquire exits 4 on timeout, 5 on a lock error or a vanished caller, 130 when cancelled; usage 2.
The lock is <root>/lock/holder, published by one rename. Waiters queue as <root>/queue/ tickets;
only the oldest live ticket may publish, reclaim or sweep, all under the <root>/control.lock flock.
Env: TEAM_GATE_LOCK_DIR, _LOG, _WAIT (s), _NOTICE (s), _POLL (s), _WORKLOAD (regex),
_TEST_PAUSE (smoke hook only).
"""
import contextlib
import datetime
import errno
import fcntl
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import time

# A surviving member of the holder's process group still running a gate keeps the lock (no
# reclaim). The engine knows only its own scripts; a project adds its build/test tools with
# TEAM_GATE_LOCK_WORKLOAD, e.g. 'dotnet (build|test)|testhost' or 'pytest|jest'.
WORKLOAD = re.compile(r'test-gate\.sh|team-merge-check\.sh'
                      + ('|' + os.environ['TEAM_GATE_LOCK_WORKLOAD']
                         if os.environ.get('TEAM_GATE_LOCK_WORKLOAD') else ''))
SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
HOLDER_KEYS = ('pid', 'pid_start', 'pgid', 'clone', 'what', 'since', 'token')


class Cancelled(Exception):
    pass


class LockError(Exception):
    pass


def on_signal(signum, frame):
    raise Cancelled()


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


@contextlib.contextmanager
def control(root):
    # Signals stay pending until the mutex is released: no half-done reclaim, no flock re-entry.
    old = signal.pthread_sigmask(signal.SIG_BLOCK, SIGNALS)
    fd = None
    try:
        fd = os.open(os.path.join(root, 'control.lock'), os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        if fd is not None:
            os.close(fd)
        signal.pthread_sigmask(signal.SIG_SETMASK, old)


def proc(pid):
    """(lstart, pgid) of a live pid, or None."""
    r = subprocess.run(['ps', '-o', 'pgid=,lstart=', '-p', str(pid)],
                       capture_output=True, text=True, check=False)
    parts = r.stdout.strip().split(None, 1)
    if r.returncode != 0 or len(parts) != 2:
        return None
    return parts[1].strip(), parts[0]


def pid_exists(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


def alive(pid, lstart):
    p = proc(pid) if pid_exists(pid) else None
    return p is not None and p[0] == lstart


def read_kv(path):
    """key=value file → dict; None when absent; a partial file yields a partial dict."""
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return None
    except OSError:
        return {}
    return dict(line.split('=', 1) for line in lines if '=' in line)


def write_kv(path, data):
    with open(path, 'w', encoding='utf-8') as f:
        f.writelines(f'{k}={v}\n' for k, v in data.items())


def complete(holder):
    return bool(holder) and all(holder.get(k) for k in HOLDER_KEYS) and holder['pid'].isdigit()


def describe(holder):
    if holder is None:
        return '— (queue ahead)'
    if not complete(holder):
        return 'holder unreadable'
    return f"{holder['clone']} pid {holder['pid']} ({holder['what']}) since {holder['since']}"


def workload(pgid, skip):
    """First (pid, command) of process group <pgid> running a build/test, ignoring <skip> pids."""
    if not pgid.isdigit() or int(pgid) <= 1:
        return None
    r = subprocess.run(['ps', '-axo', 'pid=,pgid=,command='],
                       capture_output=True, text=True, check=False)
    for line in r.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[1] == pgid and parts[0] not in skip \
                and WORKLOAD.search(parts[2]):
            return parts[0], parts[2]
    return None


def lock_root():
    return os.path.expanduser(os.environ.get('TEAM_GATE_LOCK_DIR') or '~/.agent-ops/locks/test-gate')


class Gate:
    def __init__(self, owner, clone='', what=''):
        self.root = lock_root()
        self.log = os.path.expanduser(
            os.environ.get('TEAM_GATE_LOCK_LOG') or '~/.agent-ops/test-gate-lock.log')
        self.queue = os.path.join(self.root, 'queue')
        self.lock = os.path.join(self.root, 'lock')
        os.makedirs(self.queue, exist_ok=True)
        os.makedirs(os.path.dirname(self.log) or '.', exist_ok=True)
        self.owner, self.clone, self.what = owner, clone, what
        self.me = None
        self.ticket = None
        self.published = False
        self.start = time.monotonic()

    def holder(self):
        return read_kv(os.path.join(self.lock, 'holder'))

    def new_ticket(self):
        name = f'{time.time_ns():020d}-{self.owner}'
        write_kv(os.path.join(self.queue, name),
                 {'pid_start': self.me[0], 'clone': self.clone, 'what': self.what})
        self.ticket = name

    def drop_ticket(self):
        if self.ticket:
            with contextlib.suppress(FileNotFoundError):
                os.remove(os.path.join(self.queue, self.ticket))
            self.ticket = None
        for d in os.listdir(self.root):
            if d.startswith(f'tmp-{self.owner}-'):
                shutil.rmtree(os.path.join(self.root, d), ignore_errors=True)

    def live_tickets(self):
        """Sorted live ticket names; dead ones are removed."""
        live = []
        for name in sorted(os.listdir(self.queue)):
            pid = name.rpartition('-')[2]
            data = read_kv(os.path.join(self.queue, name)) or {}
            if pid.isdigit() and alive(int(pid), data.get('pid_start')):
                live.append(name)
            else:
                with contextlib.suppress(FileNotFoundError):
                    os.remove(os.path.join(self.queue, name))
        return live

    def sweep(self):
        for d in os.listdir(self.root):
            pid = d.split('-')[1] if d.startswith('tmp-') and d.count('-') >= 2 else ''
            dead_tmp = pid.isdigit() and not pid_exists(int(pid))
            if dead_tmp or d.startswith('stale-'):
                shutil.rmtree(os.path.join(self.root, d), ignore_errors=True)

    def publish(self):
        token = secrets.token_hex(8)
        tmp = os.path.join(self.root, f'tmp-{self.owner}-{token}')
        os.mkdir(tmp)
        write_kv(os.path.join(tmp, 'holder'), {
            'pid': self.owner, 'pid_start': self.me[0], 'pgid': self.me[1], 'clone': self.clone,
            'what': self.what, 'since': utc_now(), 'token': token})
        try:
            os.rename(tmp, self.lock)
        except OSError as e:
            shutil.rmtree(tmp, ignore_errors=True)
            if e.errno in (errno.EEXIST, errno.ENOTEMPTY):
                return None
            raise LockError(f'cannot publish {self.lock}: {e}') from e
        return token

    def reclaim(self, observed):
        test_pause()
        aside = os.path.join(self.root, f"stale-{observed['token']}-{self.owner}")
        try:
            os.rename(self.lock, aside)
        except FileNotFoundError:
            return
        moved = read_kv(os.path.join(aside, 'holder')) or {}
        if moved.get('token') != observed['token']:
            try:
                os.rename(aside, self.lock)
            except OSError as e:
                raise LockError(f'reclaim restore failed: {aside} → {self.lock} ({e})') from e
            print('gate lock: reclaim aborted — the lock changed hands', file=sys.stderr)
            return
        shutil.rmtree(aside, ignore_errors=True)
        print(f'gate lock: reclaimed from dead {describe(observed)}', file=sys.stderr)
        with open(self.log, 'a', encoding='utf-8') as f:
            f.write(f'{utc_now()} reclaimed {describe(observed)} '
                    f'by {self.clone} pid {self.owner}\n')


def test_pause():
    path = os.environ.get('TEAM_GATE_LOCK_TEST_PAUSE')
    if not path or not os.path.exists(path):
        return
    open(path + '.reached', 'w').close()
    deadline = time.monotonic() + 30
    while os.path.exists(path) and time.monotonic() < deadline:
        time.sleep(0.05)


def step(g):
    """One locked decision → None (acquired), 'retry', or (holder, position, extra) to wait on."""
    if not alive(g.owner, g.me[0]):
        raise LockError(f'caller pid {g.owner} is gone — nothing published')
    tickets = g.live_tickets()
    if g.ticket not in tickets:
        raise LockError(f'own queue ticket {g.ticket} vanished')
    holder = g.holder()
    pos = tickets.index(g.ticket)
    if pos > 0:
        return holder, pos + 1, ''
    g.sweep()
    if holder is None:
        token = g.publish()
        if token is None:
            return 'retry'
        g.published = True
        print(f'{token} {int(time.monotonic() - g.start)}', flush=True)
        g.drop_ticket()
        return None
    if not complete(holder) or alive(int(holder['pid']), holder['pid_start']):
        return holder, 1, ''
    skip = {str(g.owner)} | {t.rpartition('-')[2] for t in tickets}
    found = workload(holder['pgid'], skip)
    if found:
        return holder, 1, f' (holder dead, its workload pid {found[0]} still running)'
    g.reclaim(holder)
    return 'retry'


def acquire(g):
    limit = float(os.environ.get('TEAM_GATE_LOCK_WAIT') or 1800)
    notice = float(os.environ.get('TEAM_GATE_LOCK_NOTICE') or 60)
    poll = float(os.environ.get('TEAM_GATE_LOCK_POLL') or 1.0)
    g.me = proc(g.owner)
    if g.me is None:
        raise LockError(f'caller pid {g.owner} not found')
    with control(g.root):
        g.new_ticket()
    last = None
    while True:
        with control(g.root):
            state = step(g)
        if state is None:
            return 0
        if state == 'retry':
            continue
        holder, pos, extra = state
        waited = time.monotonic() - g.start
        if waited >= limit:
            with control(g.root):
                g.drop_ticket()
            print(f'gate lock: timeout after {int(waited)}s — held by {describe(holder)}{extra}; '
                  'nothing started', file=sys.stderr)
            return 4
        if last is None or time.monotonic() - last >= notice:
            last = time.monotonic()
            print(f'gate lock: waiting for the machine gate lock held by {describe(holder)} — '
                  f'queue position {pos}, waited {int(waited // 60)}m of {int(limit // 60)}m'
                  f'{extra}', file=sys.stderr, flush=True)
        time.sleep(poll)


def run_acquire(owner, clone, what):
    try:
        g = Gate(owner, clone, what)
    except OSError as e:
        print(f'gate lock: cannot prepare the lock root: {e}', file=sys.stderr)
        return 5
    for s in SIGNALS:
        signal.signal(s, on_signal)
    try:
        return acquire(g)
    except (Cancelled, LockError, OSError) as e:
        for s in SIGNALS:
            signal.signal(s, signal.SIG_IGN)
        if g.published:
            return 0
        with control(g.root):
            g.drop_ticket()
        if isinstance(e, Cancelled):
            return 130
        print(f'gate lock: {e}', file=sys.stderr)
        return 5


def release(owner, token):
    g = Gate(owner)
    with control(g.root):
        h = g.holder()
        if h and h.get('pid') == str(owner) and h.get('token') == token:
            aside = os.path.join(g.root, f'stale-release-{token}')
            os.rename(g.lock, aside)
            shutil.rmtree(aside, ignore_errors=True)
    return 0


def held(token):
    h = read_kv(os.path.join(lock_root(), 'lock', 'holder'))
    ok = bool(token) and complete(h) and h['token'] == token \
        and alive(int(h['pid']), h['pid_start'])
    return 0 if ok else 1


def main(argv):
    if argv[:1] == ['acquire'] and len(argv) == 4 and argv[1].isdigit():
        return run_acquire(int(argv[1]), argv[2], argv[3])
    if argv[:1] == ['release'] and len(argv) == 3 and argv[1].isdigit():
        try:
            return release(int(argv[1]), argv[2])
        except OSError as e:
            print(f'gate lock: release failed: {e}', file=sys.stderr)
            return 5
    if argv[:1] == ['held'] and len(argv) == 2:
        return held(argv[1])
    if argv == ['load']:
        print(' '.join(f'{x:.2f}' for x in os.getloadavg()))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
