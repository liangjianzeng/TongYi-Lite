# -*- coding: utf-8 -*-
# Launch a long command on remote PC, keep channel open, stream output locally.
# Usage: python rlaunch.py <timeout_sec> <command...>
import sys, threading, time, paramiko
HOST='100.100.140.75'; USER='jianz'; PW='Lxt201223'
def main():
    timeout = int(sys.argv[1]); cmd = ' '.join(sys.argv[2:])
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PW, timeout=20)
    c.get_transport().set_keepalive(15)
    ch = c.get_transport().open_session()
    ch.settimeout(30)
    ch.exec_command(cmd)
    buf = {'out': b'', 'err': b''}
    deadline = time.time() + timeout
    def reader(stream, key):
        while True:
            try:
                d = stream.recv(65536)
            except Exception:
                return
            if not d: return
            buf[key] += d
    t1 = threading.Thread(target=reader, args=(ch, 'out'), daemon=True)
    t2 = threading.Thread(target=reader, args=(ch.recv_stderr, 'err'), daemon=True)
    t1.start(); t2.start()
    while True:
        if ch.exit_status_ready(): break
        if time.time() > deadline:
            sys.stdout.write('\n[TIMEOUT after %ds]\n' % timeout)
            c.close(); sys.exit(124)
        time.sleep(2)
    rc = ch.recv_exit_status()
    t1.join(5); t2.join(5)
    sys.stdout.write(buf['out'].decode('utf-8','replace'))
    if buf['err']: sys.stdout.write('\n[STDERR]\n'+buf['err'].decode('utf-8','replace'))
    sys.stdout.write('\n[RC=%d]\n' % rc)
    sys.stdout.flush()
    c.close()
main()
