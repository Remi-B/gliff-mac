#!/usr/bin/env python3
"""Validate exported macOS/XKB maps using Linux libxkbcommon.

Run locally on Linux: check-keyboard-layouts.py layouts.json
Or from macOS: check-keyboard-layouts.py layouts.json --ssh HOST --identity PATH
No compositor session, packages, remote files or display changes are required.
"""
import argparse
import ctypes as c
import json
from pathlib import Path
import shlex
import subprocess
import sys


def validate(layouts):
    lib = c.CDLL("libxkbcommon.so.0")
    ptr, uint = c.c_void_p, c.c_uint32

    def api(name, args, result):
        func = getattr(lib, "xkb_" + name)
        func.argtypes, func.restype = args, result
        return func

    context = api("context_new", [c.c_int], ptr)(0)
    compile_map = api("keymap_new_from_string", [ptr, c.c_char_p, c.c_int, c.c_int], ptr)
    state_new = api("state_new", [ptr], ptr)
    update = api("state_update_key", [ptr, uint, c.c_int], uint)
    utf32 = api("state_key_get_utf32", [ptr, uint], uint)
    keysym = api("state_key_get_one_sym", [ptr, uint], uint)
    name = api("keysym_get_name", [uint, c.c_char_p, c.c_size_t], c.c_int)
    free_map = api("keymap_unref", [ptr], None)
    free_state = api("state_unref", [ptr], None)
    compose_table = api("compose_table_new_from_locale", [ptr, c.c_char_p, c.c_int], ptr)(context, b"C.UTF-8", 0)
    compose_new = api("compose_state_new", [ptr, c.c_int], ptr)
    compose_feed = api("compose_state_feed", [ptr, uint], c.c_int)
    compose_text = api("compose_state_get_utf8", [ptr, c.c_char_p, c.c_size_t], c.c_int)
    compose_free = api("compose_state_unref", [ptr], None)
    assert context and compose_table, "XKB context/compose table unavailable"
    accents = {"`": "dead_grave", "´": "dead_acute", "^": "dead_circumflex", "ˆ": "dead_circumflex", "¨": "dead_diaeresis", "~": "dead_tilde", "˜": "dead_tilde"}
    printable = set(range(2, 14)) | set(range(16, 28)) | set(range(30, 42)) | set(range(43, 54)) | {57, 86}
    results = []
    for layout in layouts:
        keymap = compile_map(context, layout["keymap"].encode(), 1, 0)
        assert keymap, "cannot compile " + layout["id"]
        state = state_new(keymap)
        checked, dead_checked, differences = 0, 0, []
        for key in layout["keys"]:
            if key["evdev"] not in printable:
                continue
            for level, mods in enumerate([[], [42], [100], [42, 100]]):
                for mod in mods:
                    update(state, mod + 8, 1)
                symbol = keysym(state, key["evdev"] + 8)
                value = utf32(state, key["evdev"] + 8)
                symbol_name = c.create_string_buffer(100)
                name(symbol, symbol_name, len(symbol_name))
                actual = chr(value) if value else symbol_name.value.decode()
                expected = key["values"][level]
                if expected.startswith("dead:"):
                    expected = accents[expected[5:]]
                    # Compose each supported accent with e through XKB's real
                    # Compose table, rather than treating a dead key as text.
                    compose = compose_new(compose_table, 0)
                    compose_feed(compose, symbol)
                    compose_feed(compose, ord("e"))
                    output = c.create_string_buffer(32)
                    compose_text(compose, output, len(output))
                    expected_text = {"dead_grave": "è", "dead_acute": "é", "dead_circumflex": "ê", "dead_diaeresis": "ë", "dead_tilde": "ẽ"}[expected]
                    assert output.value.decode() == expected_text, (layout["id"], expected, output.value)
                    compose_free(compose)
                    dead_checked += 1
                if actual != expected:
                    differences.append({"mac": key["mac"], "level": level, "expected": expected, "actual": actual})
                for mod in reversed(mods):
                    update(state, mod + 8, 0)
                checked += 1
        free_state(state)
        free_map(keymap)
        results.append({"source": layout["id"], "keyboard_type": layout["keyboardType"], "compiled": True,
                        "symbols_checked": checked, "dead_compositions_checked": dead_checked, "differences": differences})
    api("compose_table_unref", [ptr], None)(compose_table)
    api("context_unref", [ptr], None)(context)
    print(json.dumps(results, indent=2, ensure_ascii=False))
    return int(any(result["differences"] for result in results))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("layouts")
    parser.add_argument("--ssh")
    parser.add_argument("--identity")
    args = parser.parse_args()
    data = sys.stdin.buffer.read() if args.layouts == "-" else Path(args.layouts).read_bytes()
    if args.ssh:
        source = Path(__file__).read_text()
        command = ["ssh", "-oBatchMode=yes", "-oConnectTimeout=10"]
        if args.identity:
            command += ["-i", args.identity]
        command += ["--", args.ssh, "python3 -c " + shlex.quote(source) + " -"]
        return subprocess.run(command, input=data).returncode
    return validate(json.loads(data))


if __name__ == "__main__":
    sys.exit(main())
