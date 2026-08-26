#!/usr/bin/env python
"""
Quien tiene tomado un puerto TCP, sin depender de fuser/lsof/ss.

En Android `fuser` falla con "Bad system call" (seccomp bloquea los syscalls
que usa) y `lsof`/`ss` no suelen estar instalados. Pero /proc si se puede leer:
  1. /proc/net/tcp[6]  -> inodo del socket que escucha en el puerto
  2. /proc/<pid>/fd/*  -> que proceso tiene ese inodo abierto

Uso:
    python tools/port_utils.py owners <puerto>   # lista PIDs (uno por linea)
    python tools/port_utils.py info   <puerto>   # PID + linea de comandos
    python tools/port_utils.py kill   <puerto>   # los mata (TERM, luego KILL)
    python tools/port_utils.py free   <puerto>   # 0 si esta libre, 1 si ocupado
"""
import os, sys, time, socket, signal

LISTEN = '0A'


def _listen_inodes(port):
    inodes = set()
    for path in ('/proc/net/tcp', '/proc/net/tcp6'):
        try:
            with open(path) as fh:
                lines = fh.read().splitlines()[1:]
        except OSError:
            continue
        for ln in lines:
            f = ln.split()
            if len(f) < 10:
                continue
            try:
                local_port = int(f[1].split(':')[1], 16)
            except (IndexError, ValueError):
                continue
            if local_port == port and f[3] == LISTEN:
                inodes.add(f[9])
    return inodes


def owners(port):
    inodes = _listen_inodes(port)
    if not inodes:
        return []
    pids = []
    for d in os.listdir('/proc'):
        if not d.isdigit():
            continue
        fddir = '/proc/%s/fd' % d
        try:
            fds = os.listdir(fddir)
        except OSError:
            continue          # otro usuario o el proceso ya murio
        for fd in fds:
            try:
                link = os.readlink(os.path.join(fddir, fd))
            except OSError:
                continue
            if link.startswith('socket:[') and link[8:-1] in inodes:
                pids.append(int(d))
                break
    return sorted(set(pids))


def cmdline(pid):
    try:
        with open('/proc/%d/cmdline' % pid, 'rb') as fh:
            return ' '.join(p for p in fh.read().decode('utf8', 'replace').split('\0') if p)
    except OSError:
        return '(desconocido)'


def is_busy(port):
    s = socket.socket()
    s.settimeout(1.5)
    try:
        return s.connect_ex(('127.0.0.1', port)) == 0
    finally:
        s.close()


def kill_owners(port):
    pids = owners(port)
    if not pids:
        return []
    me = os.getpid()
    killed = []
    for sig in (signal.SIGTERM, signal.SIGKILL):
        alive = [p for p in pids if p != me and os.path.exists('/proc/%d' % p)]
        if not alive:
            break
        for p in alive:
            try:
                os.kill(p, sig)
                killed.append(p)
            except OSError:
                pass
        time.sleep(2)
    return sorted(set(killed))


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip())
        return 2
    action, port = sys.argv[1], int(sys.argv[2])
    if action == 'owners':
        for p in owners(port):
            print(p)
    elif action == 'info':
        pids = owners(port)
        if not pids:
            print('nadie escucha en el puerto %d'
                  % port if not is_busy(port)
                  else 'puerto %d ocupado, pero el proceso es de otro usuario' % port)
        for p in pids:
            print('%d  %s' % (p, cmdline(p)))
    elif action == 'kill':
        for p in kill_owners(port):
            print('matado %d' % p)
    elif action == 'free':
        return 0 if not is_busy(port) else 1
    else:
        print('accion desconocida: %s' % action)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
