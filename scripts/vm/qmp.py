#!/usr/bin/env python3
"""Inspect/control only the Gliff build VM through its private QMP socket."""

import argparse
import json
import os
from pathlib import Path
import socket
import time


class QMP:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(15)
        self.socket.connect(str(path))
        self.stream = self.socket.makefile("rwb")
        self.read()
        self.call("qmp_capabilities")

    def read(self):
        line = self.stream.readline()
        if not line:
            raise RuntimeError("VM closed the QMP connection")
        return json.loads(line)

    def call(self, command, arguments=None):
        request = {"execute": command}
        if arguments is not None:
            request["arguments"] = arguments
        self.stream.write((json.dumps(request) + "\n").encode())
        self.stream.flush()
        while True:
            response = self.read()
            if "error" in response:
                raise RuntimeError(response["error"])
            if "return" in response:
                return response["return"]

    def key(self, keys, hold_time=100):
        self.call("send-key", {"keys": [{"type": "qcode", "data": key} for key in keys],
                               "hold-time": hold_time})

    def type_text(self, text, delay=0.06, hold_time=25):
        plain = {" ": "spc", "\n": "ret", "\t": "tab", "-": "minus", "=": "equal",
                 "[": "bracket_left", "]": "bracket_right", "\\": "backslash",
                 ";": "semicolon", "'": "apostrophe", "`": "grave_accent",
                 ",": "comma", ".": "dot", "/": "slash"}
        shifted = dict(zip('!@#$%^&*()_+{}|:\"~<>?',
                           ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0',
                            'minus', 'equal', 'bracket_left', 'bracket_right', 'backslash',
                            'semicolon', 'apostrophe', 'grave_accent', 'comma', 'dot', 'slash']))
        for character in text:
            if character in shifted:
                keys = ["shift", shifted[character]]
            elif character.isascii() and character.isalnum():
                keys = (["shift"] if character.isupper() else []) + [character.lower()]
            elif character in plain:
                keys = [plain[character]]
            else:
                raise ValueError("Only ASCII terminal input is supported")
            self.key(keys, hold_time=hold_time)
            time.sleep(delay)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    commands.add_parser("powerdown")
    screenshot = commands.add_parser("screenshot")
    screenshot.add_argument("path", type=Path)
    key = commands.add_parser("key")
    key.add_argument("keys", help="QEMU qcodes separated by +, e.g. ctrl+alt+delete")
    text = commands.add_parser("type")
    text.add_argument("text", help="ASCII text for the active VM window (never credentials)")
    click = commands.add_parser("click")
    click.add_argument("x", type=float, help="horizontal fraction from 0 to 1")
    click.add_argument("y", type=float, help="vertical fraction from 0 to 1")
    args = parser.parse_args()
    directory = Path(os.environ.get("GLIFF_VM_DIR", str(Path.home() / ".local/share/gliff-mac-vm")))
    qmp = QMP(directory / "qmp.sock")
    if args.command == "status":
        print(json.dumps(qmp.call("query-status"), indent=2))
    elif args.command == "powerdown":
        qmp.call("system_powerdown")
    elif args.command == "key":
        qmp.key(args.keys.split("+"))
    elif args.command == "type":
        qmp.type_text(args.text)
    elif args.command == "click":
        if not (0 <= args.x <= 1 and 0 <= args.y <= 1):
            parser.error("coordinates must be fractions between 0 and 1")
        qmp.call("input-send-event", {"events": [
            {"type": "abs", "data": {"axis": "x", "value": round(args.x * 32767)}},
            {"type": "abs", "data": {"axis": "y", "value": round(args.y * 32767)}},
            {"type": "btn", "data": {"button": "left", "down": True}},
        ]})
        time.sleep(0.1)
        qmp.call("input-send-event", {"events": [
            {"type": "btn", "data": {"button": "left", "down": False}},
        ]})
    elif args.command == "screenshot":
        path = args.path.resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        qmp.call("screendump", {"filename": str(path), "format": "png"})
        print(path)


if __name__ == "__main__":
    main()
