# -*- coding: utf-8 -*-
# Restore pristine QAIRT op_graph_optimizations.py from this session's backup.
import paramiko
HOST = '<redacted-tailscale-pc>'; USER = 'jianz'; PW = '<redacted-ssh-passwd>'
REMOTE = 'D:/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters/common/converter_ir/op_graph_optimizations.py'
BAK = REMOTE + '.bak_20261031'
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, password=PW, timeout=20)
sftp = c.open_sftp()
f = sftp.open(BAK, 'r'); data = f.read(); f.close()
g = sftp.open(REMOTE, 'w'); g.write(data); g.close()
f2 = sftp.open(REMOTE, 'r'); chk = f2.read().decode('utf-8'); f2.close()
print('restored; _npdt occurrences:', chk.count('_npdt'), '; np.ones(tensor_dimensions):', chk.count('np.ones(tensor_dimensions)'))
sftp.close(); c.close()
