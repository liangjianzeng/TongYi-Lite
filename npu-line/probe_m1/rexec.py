# -*- coding: utf-8 -*-
import sys, paramiko
HOST='<redacted-tailscale-pc>'; USER='jianz'; PW='<redacted-ssh-passwd>'
def main():
    cmd = sys.argv[1]
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PW, timeout=20)
    stdin, stdout, stderr = c.exec_command(cmd, timeout=590)
    out = stdout.read().decode('utf-8', 'replace'); err = stderr.read().decode('utf-8', 'replace')
    rc = stdout.channel.recv_exit_status()
    sys.stdout.write(out)
    if err: sys.stdout.write('\n[STDERR]\n' + err)
    sys.stdout.write('\n[RC=%d]\n' % rc)
    c.close()
main()
