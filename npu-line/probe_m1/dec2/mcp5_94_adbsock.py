#!/usr/bin/env python3
# [npu-line] Mini adb host-protocol client over the live adb server (127.0.0.1:5037) —
# written when adb.exe vanished from platform-tools (Android Studio mid-update). Covers
# shell / push / pull via the sync subprotocol; no adb binary needed. Drop-in for the
# small adb surface the mcp5_94_* power drivers use.
import os
import socket


def _msg(s):
    return f"{len(s):04x}{s}".encode()


class AdbSock:
    def __init__(self, serial, host="127.0.0.1", port=5037):
        self.serial, self.host, self.port = serial, host, port

    def _conn(self, service):
        s = socket.create_connection((self.host, self.port), 20)
        s.settimeout(600)  # long device-side commands (5G cat, quantize) exceed the
        # connect-phase default; recv inherits the socket timeout
        s.sendall(_msg(f"host:transport:{self.serial}"))
        if s.recv(4) != b"OKAY":
            raise RuntimeError("transport failed: " + s.recv(200).decode(errors="replace"))
        s.sendall(_msg(service))
        if s.recv(4) != b"OKAY":
            raise RuntimeError("service failed: " + s.recv(200).decode(errors="replace"))
        return s

    def shell(self, cmd):
        s = self._conn(f"shell:{cmd}")
        buf = b""
        while True:
            c = s.recv(65536)
            if not c:
                break
            buf += c
        s.close()
        return buf.decode(errors="replace")

    def push(self, local, remote):
        s = self._conn("sync:")
        path = remote + ",0644"
        s.sendall(b"SEND" + len(path).to_bytes(4, "little") + path.encode())
        with open(local, "rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                s.sendall(b"DATA" + len(chunk).to_bytes(4, "little") + chunk)
        s.sendall(b"DONE" + (0).to_bytes(4, "little"))
        if s.recv(4) != b"OKAY":
            raise RuntimeError("push failed: " + s.recv(200).decode(errors="replace"))
        s.recv(4)
        s.close()

    def pull(self, remote, local):
        s = self._conn("sync:")
        s.sendall(b"RECV" + len(remote).to_bytes(4, "little") + remote.encode())
        data = b""
        while True:
            hdr = s.recv(8)
            if hdr[:4] != b"DATA":
                break
            n = int.from_bytes(hdr[4:8], "little")
            while n:
                c = s.recv(n)
                data += c
                n -= len(c)
        if hdr[:4] != b"DONE":
            raise RuntimeError("pull failed: " + s.recv(200).decode(errors="replace"))
        s.close()
        d = os.path.dirname(local)
        if d:
            os.makedirs(d, exist_ok=True)
        open(local, "wb").write(data)
