#!/usr/bin/env python3
"""Persist PX4 msgid 31/32 at 15 Hz in /fs/microsd/etc/extras.txt.

Talks MAVLink nsh on 127.0.0.1:14561. No pymavlink. Does not reboot.
LOCAL_POSITION_NED may be silent without vision; ATTITUDE_QUATERNION is
the field proof that extras stream -r is honored.
"""
from __future__ import print_function

import argparse
import re
import socket
import struct
import sys
import time

STREAM_RE = re.compile(
    r"^mavlink stream -d (/dev/ttyS\d+) -s\s+(\S+) -r (\d+)\s*$"
)
WANT = (("LOCAL_POSITION_NED", "15"), ("ATTITUDE_QUATERNION", "15"))
CRC_EXTRA = {0: 50, 126: 220}
ARMED_FLAG = 128
DEV_SHELL = 10
FLAG_RESPOND = 2
FLAG_EXCLUSIVE = 4
FLAG_MULTI = 16


def crc_x25(data):
    crc = 0xFFFF
    for b in bytearray(data):
        tmp = b ^ (crc & 0xFF)
        tmp = (tmp ^ ((tmp << 4) & 0xFF)) & 0xFF
        crc = ((crc >> 8) ^ (tmp << 8) ^ (tmp << 3) ^ (tmp >> 4)) & 0xFFFF
    return crc


def pack_v1(msgid, payload, seq, sysid=255, compid=190):
    extra = CRC_EXTRA[msgid]
    header = struct.pack("BBBBB", len(payload), seq & 0xFF, sysid, compid, msgid)
    crc = crc_x25(header + payload + bytes(bytearray([extra])))
    return b"\xfe" + header + payload + struct.pack("<H", crc)


def heartbeat_pkt(seq):
    payload = struct.pack("<IBBBBB", 0, 6, 8, 0, 0, 0)
    return pack_v1(0, payload, seq)


def serial_control_pkt(seq, flags, data):
    chunk = data[:70]
    payload = struct.pack(
        "<BBHIB70s",
        DEV_SHELL,
        flags,
        0,
        0,
        len(chunk),
        chunk.ljust(70, b"\x00"),
    )
    return pack_v1(126, payload, seq)


def parse_one(buf):
    if not buf:
        return None
    if buf[0] == 0xFE and len(buf) >= 8:
        plen = buf[1]
        if len(buf) < 8 + plen:
            return None
        return buf[5], buf[6 : 6 + plen], buf[3], 8 + plen
    if buf[0] == 0xFD and len(buf) >= 12:
        plen = buf[1]
        if len(buf) < 12 + plen:
            return None
        msgid = buf[7] | (buf[8] << 8) | (buf[9] << 16)
        return msgid, buf[10 : 10 + plen], buf[5], 12 + plen
    return None


def merge_extras(text):
    lines = text.splitlines()
    devices = []
    for ln in lines:
        m = STREAM_RE.match(ln.strip()) if ln.strip() else None
        if m and m.group(1) not in devices:
            devices.append(m.group(1))
    if not devices:
        devices = ["/dev/ttyS1", "/dev/ttyS0"]
    seen = {d: set() for d in devices}
    out = []
    for ln in lines:
        s = ln.strip()
        m = STREAM_RE.match(s) if s else None
        if not m:
            out.append(ln)
            continue
        dev, stream, _rate = m.group(1), m.group(2), m.group(3)
        wanted = dict(WANT)
        if stream in wanted:
            out.append("mavlink stream -d %s -s  %s -r %s" % (dev, stream, wanted[stream]))
            seen.setdefault(dev, set()).add(stream)
        else:
            out.append(ln)
            seen.setdefault(dev, set())
    for dev in devices:
        have = seen.get(dev, set())
        for stream, rate in WANT:
            if stream not in have:
                out.append("mavlink stream -d %s -s  %s -r %s" % (dev, stream, rate))
                have.add(stream)
    return "\n".join(out).rstrip() + "\n"


def extras_ok(text):
    if "LOCAL_POSITION_NED -r 30" in text or "LOCAL_POSITION_NED  -r 30" in text:
        return False
    if "ATTITUDE_QUATERNION -r 15" not in text and "ATTITUDE_QUATERNION  -r 15" not in text:
        return False
    if "LOCAL_POSITION_NED -r 15" not in text and "LOCAL_POSITION_NED  -r 15" not in text:
        return False
    return True


def self_test():
    sample = (
        "mavlink stream -d /dev/ttyS1 -s  LOCAL_POSITION_NED -r 30\n"
        "mavlink stream -d /dev/ttyS1 -s  ATTITUDE -r 10\n"
        "\n"
        "mavlink stream -d /dev/ttyS0 -s  LOCAL_POSITION_NED -r 30\n"
        "mavlink stream -d /dev/ttyS0 -s  GPS_RAW_INT -r 5\n"
    )
    merged = merge_extras(sample)
    assert extras_ok(merged), merged
    assert "ATTITUDE -r 10" in merged
    assert "GPS_RAW_INT -r 5" in merged
    empty = merge_extras("")
    assert extras_ok(empty), empty
    print("extras merge self-test ok")
    return 0


class Link(object):
    def __init__(self, host, port):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(0.4)
        self.sock.bind(("0.0.0.0", 0))
        self.dest = (host, port)
        self.seq = 0
        self.buf = b""
        self.target_sys = 1

    def send(self, pkt):
        self.sock.sendto(pkt, self.dest)
        self.seq = (self.seq + 1) & 0xFF

    def pump_hb(self):
        self.send(heartbeat_pkt(self.seq))

    def recv_msg(self, timeout=0.4):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if not self.buf:
                try:
                    data, _ = self.sock.recvfrom(2048)
                except socket.timeout:
                    return None
                self.buf += data
            parsed = parse_one(self.buf)
            if parsed is None:
                self.buf = self.buf[1:]
                continue
            msgid, payload, sysid, n = parsed
            self.buf = self.buf[n:]
            if msgid == 0 and sysid != 255:
                self.target_sys = sysid
            return msgid, payload, sysid
        return None

    def wait_fc(self, seconds):
        t0 = time.time()
        armed = False
        while time.time() - t0 < seconds:
            self.pump_hb()
            msg = self.recv_msg(0.4)
            if not msg:
                continue
            msgid, payload, sysid = msg
            if msgid == 0 and sysid != 255 and len(payload) >= 7:
                if payload[4] == 12:
                    armed = (payload[6] & ARMED_FLAG) != 0
                    return True, armed
        return False, False

    def nsh(self, cmd, wait=2.0):
        flags = FLAG_RESPOND | FLAG_EXCLUSIVE | FLAG_MULTI
        payload = (cmd + "\n").encode("ascii")
        off = 0
        while off < len(payload):
            self.send(serial_control_pkt(self.seq, flags, payload[off : off + 70]))
            off += 70
        out = b""
        t0 = time.time()
        while time.time() - t0 < wait:
            msg = self.recv_msg(0.4)
            if not msg:
                continue
            msgid, payload, _sysid = msg
            if msgid != 126 or len(payload) < 9:
                continue
            count = payload[8]
            data = payload[9 : 9 + count]
            out += data
        return out.decode("utf-8", "replace")

    def close_shell(self):
        self.send(serial_control_pkt(self.seq, 0, b""))


def apply_extras(host, port, seconds):
    link = Link(host, port)
    ok, armed = link.wait_fc(seconds)
    if not ok:
        print("error: no PX4 HEARTBEAT on %s:%s" % (host, port), file=sys.stderr)
        return 2
    if armed:
        print("error: FC armed; refuse extras write", file=sys.stderr)
        return 2
    print("HEARTBEAT sys=%s" % link.target_sys)
    bak = link.nsh("cp /fs/microsd/etc/extras.txt /fs/microsd/etc/extras.txt.bak", 2.0)
    current = link.nsh("cat /fs/microsd/etc/extras.txt", 4.0)
    # strip nsh prompt chrome
    body = current
    for token in ("nsh> ", "cat /fs/microsd/etc/extras.txt", "\x1b[K"):
        body = body.replace(token, "")
    merged = merge_extras(body)
    if not extras_ok(merged):
        print("error: merge failed\n%s" % merged, file=sys.stderr)
        return 1
    lines = merged.splitlines()
    first = True
    path = "/fs/microsd/etc/extras.txt"
    for ln in lines:
        if first:
            cmd = "echo %s > %s" % (ln, path) if ln else "echo > %s" % path
            first = False
        else:
            cmd = "echo %s >> %s" % (ln, path) if ln else "echo >> %s" % path
        link.nsh(cmd, 1.2)
    verify = link.nsh("cat /fs/microsd/etc/extras.txt", 4.0)
    link.close_shell()
    if not extras_ok(verify):
        print("error: extras verify failed\n%s" % verify, file=sys.stderr)
        print("backup nsh:\n%s" % bak, file=sys.stderr)
        return 1
    print("wrote 31/32 @ 15 Hz into extras.txt (takes effect on next FC reboot)")
    print(verify)
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=14561)
    parser.add_argument("--wait", type=float, default=12.0)
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    return apply_extras(args.host, args.port, args.wait)


if __name__ == "__main__":
    sys.exit(main())
