#!/usr/bin/env python3
"""Fake Daikin Smart AC unit for development: speaks the local protocol on localhost.

    Scripts/mock-device.py [--state '{"power":0}']

Lets the app and the CLI be exercised, commands included, without touching a real unit:

    daikin status --host 127.0.0.1 --key AAECAwQFBgcICQoLDA0ODw==

It is an independent implementation (Python + the openssl CLI), so it also cross-checks
the Swift encoder. Every command received is printed as the unit would see it.
"""
import argparse
import base64
import json
import os
import re
import socketserver
import subprocess

KEY = bytes(range(16))
PORT = 15914

STATE = {
    "port1": {
        "power": 1, "mode": 3, "temperature": 24, "fan": 17, "h_swing": 0, "v_swing": 0,
        "coanda": 0, "econo": 0, "powerchill": 0, "good_sleep": 0, "streamer": 0, "out_quite": 0,
        "on_timer_set": 0, "on_timer_value": 0, "off_timer_set": 0, "off_timer_value": 0,
        "sensors": {"room_temp": 26, "out_temp": 29}, "rst_r": 12, "fw_ver": "mock",
    },
    "idu": 1,
}
DEVICE = {"apn": "DAIKIN:000000000000", "eepid": "0000", "h_sw": 0, "heat": 0, "mic": "FFFF", "v_bld": 0, "v_sw": 1}
STATUS = {"username": "mock", "sta_ssid": "mock", "status": {"ac": 1, "sta": 1, "cloud": 0, "auth": 0}}

# Setting the first field to 1 clears the second, as the firmware does.
EXCLUSIVE = [("econo", "powerchill"), ("powerchill", "econo"), ("coanda", "v_swing"), ("v_swing", "coanda")]


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else crc << 1
            crc &= 0xFFFF
    return crc ^ 0xFFFF


def aes_cfb(data: bytes, iv: bytes, decrypt: bool = False) -> bytes:
    command = ["openssl", "enc", "-aes-128-cfb", "-K", KEY.hex(), "-iv", iv.hex()]
    return subprocess.run(command + (["-d"] if decrypt else []), input=data, capture_output=True, check=True).stdout


def encode(payload: dict) -> bytes:
    plaintext = json.dumps(payload, separators=(",", ":")).encode()
    iv = os.urandom(16)
    frame = iv + bytes([len(plaintext) & 0xFF]) + aes_cfb(plaintext, iv)
    crc = crc16(frame)
    return base64.b64encode(frame + bytes([crc & 0xFF, crc >> 8]))


def decode_command(body: bytes) -> dict:
    frame = base64.b64decode(body, validate=True)
    if crc16(frame[:-2]) != frame[-2] | frame[-1] << 8:
        raise ValueError("bad CRC")
    plaintext = aes_cfb(frame[16:-2], frame[:16], decrypt=True)
    if not plaintext.endswith(b"BZ"):
        raise ValueError(f"missing BZ suffix: {plaintext!r}")
    return json.loads(plaintext[:-2])


def apply(command: dict) -> None:
    fields = command["port1"]
    port = STATE["port1"]
    port.update(fields)
    for setter, cleared in EXCLUSIVE:
        if fields.get(setter) == 1 and cleared not in fields:
            port[cleared] = 0


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = self.request.recv(4096)
            if not chunk:
                return
            request += chunk
        head, _, body = request.partition(b"\r\n\r\n")
        method, path = head.split(b"\r\n")[0].decode().split(" ")[:2]
        length = re.search(rb"(?i)content-length:\s*(\d+)", head)
        while length and len(body) < int(length.group(1)):
            body += self.request.recv(4096)

        if method == "GET" and path == "/acstatus":
            self.reply(STATE)
        elif method == "GET" and path == "/device":
            self.reply(DEVICE)
        elif method == "GET" and path == "/status":
            self.reply(STATUS)
        elif method == "POST" and path == "/acstatus":
            try:
                command = decode_command(body)
                apply(command)
                print("command:", json.dumps(command, separators=(",", ":")), flush=True)
                self.reply(STATE)
            except Exception as error:  # a real unit answers with an empty port1
                print("rejected:", error, flush=True)
                self.reply({"port1": {}})
        else:
            self.request.sendall(b"HTTP/1.1 404 Not Found\r\n\r\n")

    def reply(self, payload: dict) -> None:
        body = encode(payload)
        # Tab-prefixed headers, exactly like the real module.
        head = f"HTTP/1.1 200 OK\r\n\t\tContent-Type: application/json\r\n\t\tContent-Length: {len(body)}\r\n\t\tConnection: Closed\r\n\r\n"
        self.request.sendall(head.encode() + body)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--state", help="JSON with port1 fields to override, e.g. '{\"power\":0}'")
    arguments = parser.parse_args()
    if arguments.state:
        STATE["port1"].update(json.loads(arguments.state))

    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("127.0.0.1", PORT), Handler) as server:
        print(f"mock unit on 127.0.0.1:{PORT}  key={base64.b64encode(KEY).decode()}", flush=True)
        server.serve_forever()
