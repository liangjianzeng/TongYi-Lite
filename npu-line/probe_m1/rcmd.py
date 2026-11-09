# -*- coding: utf-8 -*-
# Upload a local bash script to remote PC and run it in WSL (foreground).
# Usage: python rcmd.py <local.sh> [timeout_sec]
# The script is uploaded to E:/MyLLM_exp/_run.sh and executed as
#   wsl -e bash /mnt/e/MyLLM_exp/_run.sh
# avoiding all cmd.exe / wsl.exe quoting pitfalls (see handover pitfall #1/#5).
import sys, time, paramiko
HOST = '<redacted-tailscale-pc>'; USER = 'jianz'; PW = '<redacted-ssh-passwd>'

def main():
    local = sys.argv[1]
    timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 570
    remote_name = sys.argv[3] if len(sys.argv) > 3 else '_run.sh'
    with open(local, 'r', encoding='utf-8') as f:
        body = f.read()
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PW, timeout=20)
    c.get_transport().set_keepalive(15)
    sftp = c.open_sftp()
    with sftp.open('E:/MyLLM_exp/' + remote_name, 'w') as rf:
        rf.write(body)
    sftp.close()
    ch = c.get_transport().open_session()
    ch.settimeout(30)
    ch.exec_command('wsl -e bash /mnt/e/MyLLM_exp/' + remote_name)
    deadline = time.time() + timeout
    def reader(stream, key, buf):
        while True:
            try:
                d = stream.recv(65536)
            except Exception:
                return
            if not d:
                return
            buf[key] += d
    buf = {'out': b'', 'err': b''}
    t1 = threading.Thread(target=reader, args=(ch, 'out', buf), daemon=True)
    t2 = threading.Thread(target=reader, args=(ch.recv_stderr, 'err', buf), daemon=True)
    t1.start(); t2.start()
    while True:
        if ch.exit_status_ready():
            break
        if time.time() > deadline:
            sys.stdout.write('\n[TIMEOUT after %ds]\n' % timeout)
            sys.stdout.write(buf['out'].decode('utf-8', 'replace')[-4000:])
            c.close(); sys.exit(124)
        time.sleep(2)
    rc = ch.recv_exit_status()
    t1.join(5); t2.join(5)
    sys.stdout.write(buf['out'].decode('utf-8', 'replace'))
    if buf['err']:
        sys.stdout.write('\n[STDERR]\n' + buf['err'].decode('utf-8', 'replace'))
    sys.stdout.write('\n[RC=%d]\n' % rc)
    sys.stdout.flush()
    c.close()

import threading
main()
