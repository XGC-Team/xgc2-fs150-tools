#!/usr/bin/env python3
"""Compare or apply the FS150 VRPN-flight PX4 table.

No MAVROS, no ROS. Default is read-only. --apply writes only
DEFAULT_EXPECTED (the check batch). On the aircraft use loopback
127.0.0.1:14561. From the ground use host:14560. Do not open
/dev/ttyS7 while the router owns it.

Exit: 0 all listed params match; 1 mismatch / missing / set failed;
2 no link / usage / armed apply.
"""
from __future__ import print_function

import argparse
import json
import socket
import struct
import sys
import time

# VRPN-flight core for every FS150. Confirmed 2026-08-31 on the field
# aircraft. --apply may PARAM_SET only these names. MAV_SYS_ID is
# per-aircraft, not listed.
DEFAULT_EXPECTED = {
    "SER_TEL1_BAUD": 921600,
    "MAV_0_CONFIG": 101,
    "SYS_MC_EST_GROUP": 2,
    "EKF2_AID_MASK": 24,
    "EKF2_HGT_MODE": 3,
    "EKF2_MAG_TYPE": 5,
    "EKF2_EV_DELAY": 50,  # check table 2026-09-16. empirical formula is 40/25; reboot to resize EKF IMU ring.
    "COM_ARM_WO_GPS": 1,
    "COM_KILL_DISARM": 0,
    "COM_DISARM_LAND": 1,
    "BAT1_N_CELLS": 3,
}

CRC_EXTRA = {
    0: 50,  # HEARTBEAT
    20: 214,  # PARAM_REQUEST_READ
    22: 220,  # PARAM_VALUE
    23: 168,  # PARAM_SET
    76: 152,  # COMMAND_LONG
}

PARAM_TYPE_INT = {1, 2, 3, 4, 5, 6}  # UINT8..INT32
ARMED_FLAG = 128
CMD_PREFLIGHT_REBOOT_SHUTDOWN = 246
MAV_RESULT_ACCEPTED = 0
MAV_RESULT_IN_PROGRESS = 5
REBOOT_HINT = frozenset(("SER_TEL1_BAUD", "MAV_0_CONFIG", "SYS_MC_EST_GROUP", "EKF2_EV_DELAY"))


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
    # type=GCS(6), autopilot=INVALID(8)
    payload = struct.pack("<IBBBBB", 0, 6, 8, 0, 0, 0)
    return pack_v1(0, payload, seq)


def param_request_read_pkt(seq, target_sys, target_comp, name):
    raw = name.encode("ascii")
    if len(raw) > 16:
        raise ValueError("param id longer than 16: %s" % name)
    param_id = raw + b"\x00" * (16 - len(raw))
    # Wire order follows MAVLink (int16 before the uint8 targets).
    payload = struct.pack("<hBB16s", -1, target_sys, target_comp, param_id)
    return pack_v1(20, payload, seq)


def encode_param_bits(value, ptype):
    if ptype in (1, 2, 3, 4, 6):
        return struct.pack("<i", int(round(float(value))))
    if ptype == 5:
        return struct.pack("<I", int(round(float(value))))
    return struct.pack("<f", float(value))


def command_long_pkt(seq, target_sys, target_comp, command, param1=0, param2=0, param3=0, param4=0, param5=0, param6=0, param7=0):
    payload = struct.pack(
        "<fffffffHBBB",
        float(param1),
        float(param2),
        float(param3),
        float(param4),
        float(param5),
        float(param6),
        float(param7),
        int(command),
        target_sys,
        target_comp,
        0,
    )
    return pack_v1(76, payload, seq)


def decode_command_ack(payload):
    if len(payload) < 3:
        return None
    command, result = struct.unpack_from("<HB", payload, 0)
    return command, result


def param_set_pkt(seq, target_sys, target_comp, name, value, ptype):
    raw = name.encode("ascii")
    if len(raw) > 16:
        raise ValueError("param id longer than 16: %s" % name)
    param_id = raw + b"\x00" * (16 - len(raw))
    payload = encode_param_bits(value, ptype) + struct.pack(
        "<BB16sB", target_sys, target_comp, param_id, ptype
    )
    return pack_v1(23, payload, seq)


def heartbeat_armed(payload):
    if len(payload) < 7:
        return False
    return (payload[6] & ARMED_FLAG) != 0


def parse_one(buf):
    if not buf:
        return None
    if buf[0] == 0xFE and len(buf) >= 8:
        plen = buf[1]
        if len(buf) < 8 + plen:
            return None
        msgid = buf[5]
        payload = buf[6 : 6 + plen]
        return msgid, payload, buf[3]
    if buf[0] == 0xFD and len(buf) >= 12:
        plen = buf[1]
        if len(buf) < 12 + plen:
            return None
        msgid = buf[7] | (buf[8] << 8) | (buf[9] << 16)
        payload = buf[10 : 10 + plen]
        return msgid, payload, buf[5]
    return None


def decode_param_value(payload):
    if len(payload) < 25:
        return None
    _count, _index = struct.unpack_from("<HH", payload, 4)
    param_id = payload[8:24].split(b"\x00", 1)[0].decode("ascii", "replace")
    ptype = payload[24]
    # Integer PX4 params memcpy the int into the 4-byte param_value field.
    if ptype in (1, 2, 3, 4, 6):
        value = struct.unpack_from("<i", payload, 0)[0]
    elif ptype == 5:
        value = struct.unpack_from("<I", payload, 0)[0]
    else:
        value = struct.unpack_from("<f", payload, 0)[0]
    return param_id, value, ptype


def values_match(expected, actual, ptype):
    if isinstance(expected, bool):
        return bool(actual) == expected
    if isinstance(expected, int) and not isinstance(expected, bool):
        if ptype in PARAM_TYPE_INT or float(actual).is_integer():
            return int(round(float(actual))) == int(expected)
        return abs(float(actual) - float(expected)) < 0.5
    exp = float(expected)
    act = float(actual)
    return abs(act - exp) <= max(1e-3, 1e-4 * abs(exp))


def format_actual(value, ptype):
    if ptype in PARAM_TYPE_INT or float(value).is_integer():
        return str(int(round(float(value))))
    return "%.6g" % float(value)


def load_expected(path):
    with open(path, "r") as fh:
        data = json.load(fh)
    params = data.get("params")
    if not isinstance(params, dict) or not params:
        raise ValueError("expected file needs a non-empty params object")
    return params


def recv_until(sock, deadline, want_msgid, pred=None):
    while time.time() < deadline:
        try:
            data, _addr = sock.recvfrom(2048)
        except socket.timeout:
            continue
        parsed = parse_one(data)
        if not parsed:
            continue
        msgid, payload, sysid = parsed
        if msgid != want_msgid:
            continue
        if pred is None or pred(payload, sysid):
            return msgid, payload, sysid
    return None


def open_link(host, port, seconds, sysid_hint):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(0.4)
    sock.bind(("0.0.0.0", 0))
    target = (host, port)
    seq = [0]

    def send(pkt):
        sock.sendto(pkt, target)

    def next_seq():
        current = seq[0]
        seq[0] = (seq[0] + 1) & 0xFF
        return current

    send(heartbeat_pkt(next_seq()))
    hb = recv_until(sock, time.time() + min(5.0, seconds), 0, lambda _p, sid: sid not in (0, 255))
    if hb is None:
        sock.close()
        return None, "no FC HEARTBEAT on %s:%s within %.1fs" % (host, port, min(5.0, seconds))
    target_sys = sysid_hint if sysid_hint is not None else hb[2]
    return {
        "sock": sock,
        "send": send,
        "next_seq": next_seq,
        "target_sys": target_sys,
        "armed": heartbeat_armed(hb[1]),
    }, None


def read_one(link, name, budget):
    got = None
    deadline = time.time() + budget
    while time.time() < deadline and got is None:
        link["send"](heartbeat_pkt(link["next_seq"]()))
        link["send"](param_request_read_pkt(link["next_seq"](), link["target_sys"], 1, name))
        hit = recv_until(
            link["sock"],
            min(deadline, time.time() + 0.8),
            22,
            lambda payload, _sid: (decode_param_value(payload) or (None,))[0] == name,
        )
        if hit is None:
            continue
        decoded = decode_param_value(hit[1])
        if decoded:
            got = decoded
    return got


def confirm_reboot(need_names, force, yes, no_reboot, stdin=None):
    if no_reboot:
        return False
    if not force and not need_names:
        return False
    if need_names:
        print("reboot the flight controller for: %s" % ", ".join(need_names))
    elif force:
        print("reboot the flight controller (--reboot)")
    if yes:
        return True
    stream = stdin if stdin is not None else sys.stdin
    if not hasattr(stream, "isatty") or not stream.isatty():
        print("skipped FC reboot; type yes on a TTY, or rerun with --apply --reboot --yes", file=sys.stderr)
        return False
    try:
        answer = input("type yes to reboot the flight controller: ")
    except EOFError:
        return False
    return answer.strip() == "yes"


def reboot_autopilot(link):
    hb = recv_until(link["sock"], time.time() + 2.0, 0, lambda _p, sid: sid not in (0, 255))
    if hb is None:
        return "no HEARTBEAT before reboot"
    if heartbeat_armed(hb[1]):
        return "FC is armed; refuse reboot"
    target_sys = hb[2]
    link["send"](heartbeat_pkt(link["next_seq"]()))
    link["send"](
        command_long_pkt(
            link["next_seq"](),
            target_sys,
            1,
            CMD_PREFLIGHT_REBOOT_SHUTDOWN,
            1,
        )
    )
    ack = recv_until(
        link["sock"],
        time.time() + 2.0,
        77,
        lambda payload, _sid: (decode_command_ack(payload) or (None,))[0] == CMD_PREFLIGHT_REBOOT_SHUTDOWN,
    )
    if ack is None:
        return None
    _command, result = decode_command_ack(ack[1])
    if result not in (MAV_RESULT_ACCEPTED, MAV_RESULT_IN_PROGRESS):
        return "FC rejected reboot (MAV_RESULT %s)" % result
    return None


def check_params(host, port, expected, seconds, sysid_hint, apply=False):
    link, err = open_link(host, port, seconds, sysid_hint)
    if err:
        return None, err
    if apply and link["armed"]:
        link["sock"].close()
        return None, "FC is armed; refuse PARAM_SET"
    rows = []
    wrote = []
    per = max(1.5, float(seconds) / max(len(expected), 1))
    for name in sorted(expected):
        want = expected[name]
        got = read_one(link, name, per)
        if got is None:
            rows.append((name, want, None, None, "MISSING"))
            continue
        _id, value, ptype = got
        if want is None:
            rows.append((name, "-", value, ptype, "READ"))
            continue
        if values_match(want, value, ptype):
            rows.append((name, want, value, ptype, "OK"))
            continue
        if not apply:
            rows.append((name, want, value, ptype, "MISMATCH"))
            continue
        link["send"](heartbeat_pkt(link["next_seq"]()))
        link["send"](param_set_pkt(link["next_seq"](), link["target_sys"], 1, name, want, ptype))
        recv_until(
            link["sock"],
            time.time() + 1.2,
            22,
            lambda payload, _sid: (decode_param_value(payload) or (None,))[0] == name,
        )
        again = read_one(link, name, max(2.0, per))
        if again is None:
            rows.append((name, want, value, ptype, "SET_NOREAD"))
            continue
        _nid, new_value, new_type = again
        if values_match(want, new_value, new_type):
            wrote.append(name)
            rows.append((name, want, new_value, new_type, "SET"))
        else:
            rows.append((name, want, new_value, new_type, "SET_FAIL"))
    link["sock"].close()
    return {"rows": rows, "wrote": wrote}, None


def print_table(rows):
    print("%-18s %-12s %-12s %s" % ("param", "expected", "actual", "result"))
    print("-" * 52)
    bad = 0
    for name, want, value, ptype, result in rows:
        actual = "-" if value is None else format_actual(value, ptype)
        print("%-18s %-12s %-12s %s" % (name, want, actual, result))
        if result in ("MISMATCH", "MISSING", "SET_FAIL", "SET_NOREAD"):
            bad += 1
    print("-" * 52)
    print("%d listed, %d not matching" % (len(rows), bad))
    return bad


def self_test():
    pkt = param_request_read_pkt(0, 14, 1, "SER_TEL1_BAUD")
    assert pkt[0] == 0xFE
    assert pkt[5] == 20
    parsed = parse_one(pkt)
    assert parsed[0] == 20
    assert parsed[1][:4] == b"\xff\xff\x0e\x01"
    payload = struct.pack("<iHH16sB", 921600, 1, 0, b"SER_TEL1_BAUD\x00\x00\x00", 6)
    name, value, ptype = decode_param_value(payload)
    assert name == "SER_TEL1_BAUD"
    assert values_match(921600, value, ptype)
    assert not values_match(921600, 115200.0, 6)
    assert values_match(1.5, 1.50001, 9)
    assert DEFAULT_EXPECTED["SER_TEL1_BAUD"] == 921600
    assert DEFAULT_EXPECTED["EKF2_AID_MASK"] == 24
    assert DEFAULT_EXPECTED["EKF2_EV_DELAY"] == 50
    assert "EKF2_EV_DELAY" in REBOOT_HINT
    assert DEFAULT_EXPECTED["BAT1_N_CELLS"] == 3
    set_pkt = param_set_pkt(0, 14, 1, "SER_TEL1_BAUD", 921600, 6)
    assert set_pkt[0] == 0xFE
    assert set_pkt[5] == 23
    set_parsed = parse_one(set_pkt)
    assert set_parsed[0] == 23
    assert set_parsed[1] == struct.pack("<iBB16sB", 921600, 14, 1, b"SER_TEL1_BAUD\x00\x00\x00", 6)
    assert not heartbeat_armed(struct.pack("<IBBBBB", 0, 2, 12, 0, 3, 3))
    assert heartbeat_armed(struct.pack("<IBBBBB", 0, 2, 12, ARMED_FLAG, 3, 3))
    reboot_pkt = command_long_pkt(0, 14, 1, CMD_PREFLIGHT_REBOOT_SHUTDOWN, 1)
    assert reboot_pkt[0] == 0xFE
    assert reboot_pkt[5] == 76
    reboot_parsed = parse_one(reboot_pkt)
    assert reboot_parsed[0] == 76
    reboot_fields = struct.unpack("<fffffffHBBB", reboot_parsed[1])
    assert reboot_fields[0] == 1.0
    assert reboot_fields[7] == CMD_PREFLIGHT_REBOOT_SHUTDOWN
    assert reboot_fields[8] == 14
    assert decode_command_ack(struct.pack("<HB", 246, 0)) == (246, 0)
    class _Closed(object):
        def isatty(self):
            return False
    assert confirm_reboot(["SER_TEL1_BAUD"], False, True, False) is True
    assert confirm_reboot([], False, True, False) is False
    assert confirm_reboot([], True, True, False) is True
    assert confirm_reboot(["SER_TEL1_BAUD"], True, True, True) is False
    assert confirm_reboot(["SER_TEL1_BAUD"], False, False, False, stdin=_Closed()) is False
    print("self-test ok")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", default="127.0.0.1:14561", help="host:port UDP (router local 14561 or remote 14560)")
    parser.add_argument(
        "--expected",
        default="",
        help="optional JSON {\"params\": {NAME: value}}; omit to use builtin table",
    )
    parser.add_argument("--seconds", type=float, default=12.0, help="budget across all listed params")
    parser.add_argument("--sysid", type=int, default=0, help="0 = use first HEARTBEAT sysid")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--get",
        default="",
        help="comma-separated param names to read only (no expected compare)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="PARAM_SET only DEFAULT_EXPECTED names that do not already match",
    )
    parser.add_argument(
        "--reboot",
        action="store_true",
        help="after --apply, ask to reboot the FC (type yes). Use with --yes to skip the prompt",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="answer yes to the FC reboot prompt (only with --apply)",
    )
    parser.add_argument(
        "--no-reboot",
        action="store_true",
        help="never reboot after --apply",
    )
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()

    if args.apply and args.get.strip():
        print("error: --apply cannot be combined with --get", file=sys.stderr)
        return 2
    if args.apply and args.expected.strip():
        print("error: --apply uses the builtin check table only", file=sys.stderr)
        return 2
    if args.reboot and not args.apply:
        print("error: --reboot requires --apply", file=sys.stderr)
        return 2
    if args.yes and not args.apply:
        print("error: --yes only confirms reboot after --apply", file=sys.stderr)
        return 2
    if args.reboot and args.no_reboot:
        print("error: --reboot cannot be combined with --no-reboot", file=sys.stderr)
        return 2

    if args.get.strip():
        names = [n.strip() for n in args.get.split(",") if n.strip()]
        expected = {n: None for n in names}
        expected_path = "(--get)"
    elif args.expected.strip():
        expected_path = args.expected
        try:
            expected = load_expected(expected_path)
        except (OSError, ValueError, json.JSONDecodeError) as err:
            print("error: %s" % err, file=sys.stderr)
            return 2
    else:
        expected = dict(DEFAULT_EXPECTED)
        expected_path = "(builtin)"

    if ":" not in args.endpoint:
        print("error: --endpoint must be host:port", file=sys.stderr)
        return 2
    host, port_s = args.endpoint.rsplit(":", 1)
    try:
        port = int(port_s)
    except ValueError:
        print("error: bad port in %s" % args.endpoint, file=sys.stderr)
        return 2

    print(
        "endpoint %s  expected %s  (%d params)%s"
        % (args.endpoint, expected_path, len(expected), "  apply" if args.apply else "")
    )
    sysid = args.sysid if args.sysid > 0 else None
    result, err = check_params(host, port, expected, args.seconds, sysid, apply=args.apply)
    if err:
        print("error: %s" % err, file=sys.stderr)
        print("hint: router must be up; do not lower companion Baud; do not apply while armed", file=sys.stderr)
        return 2
    bad = print_table(result["rows"])
    need_reboot = []
    if args.apply and result["wrote"]:
        print("wrote: %s" % ", ".join(result["wrote"]))
        need_reboot = [name for name in result["wrote"] if name in REBOOT_HINT]
    if bad:
        if args.apply:
            print("apply failed for the rows above. remaining mismatches still need QGC if SET_FAIL.")
        else:
            print("mismatch: insert apply PX4 params, or set the same names in QGC.")
        return 1
    if args.apply and confirm_reboot(need_reboot, args.reboot, args.yes, args.no_reboot):
        link, reboot_err = open_link(host, port, args.seconds, sysid)
        if reboot_err:
            print("error: %s" % reboot_err, file=sys.stderr)
            return 2
        reboot_err = reboot_autopilot(link)
        link["sock"].close()
        if reboot_err:
            print("error: %s" % reboot_err, file=sys.stderr)
            return 2
        print("FC reboot command sent")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
