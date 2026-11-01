# -*- coding: utf-8 -*-
# Run a Windows-side command on the remote PC via paramiko exec_command (no WSL).
import sys, paramiko
HOST='100.100.140.75'; USER='jianz'; PW='Lxt201223'
cmd = sys.argv[1]
c=paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, password=PW, timeout=20)
si,so,se=c.exec_command(cmd, timeout=120)
out=so.read().decode('utf-8','replace'); err=se.read().decode('utf-8','replace')
print(out)
if err.strip(): print('STDERR:', err[:500])
c.close()
