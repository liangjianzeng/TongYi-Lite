# -*- coding: utf-8 -*-
# Upload one local file to remote PC. Usage: python rput.py <local> <remote_windows_path>
import sys, paramiko
HOST = '<redacted-tailscale-pc>'; USER = 'jianz'; PW = '<redacted-ssh-passwd>'
local, remote = sys.argv[1], sys.argv[2]
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, password=PW, timeout=20)
sftp = c.open_sftp()
sftp.put(local, remote)
sftp.close(); c.close()
print('put', local, '->', remote)
