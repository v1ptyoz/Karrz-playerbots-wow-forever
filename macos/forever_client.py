#!/usr/bin/env python3
"""Use the macOS WoW Forever client with this server, without touching the original client.

    python3 -I macos/forever_client.py scout   [--client DIR]   read-only report: what would be patched (nothing is changed)
    python3 -I macos/forever_client.py patch   [--client DIR]   make the patched copy "<app> (Forever).app" next to the original
    python3 -I macos/forever_client.py play    [--client DIR]   start the copy with its own settings and cache, put them back after
    python3 -I macos/forever_client.py restore [--client DIR]   put the official settings and cache back (after a crash)
    python3 -I macos/forever_client.py remove  [--client DIR]   delete the copy and the Forever settings; the original stays as it is
    python3 -I macos/forever_client.py status  [--client DIR]

Why a patch is needed: when entering the world the server signs SMSG_ENTER_ENCRYPTED_MODE with Ed25519 (context
EnableEncryptionContext) and the client checks it with a public key built into the game program. advocaite's
ForeverLauncher (Windows) swaps that key for the server's one; this does the same for the macOS program.

What is guaranteed:
- The original app is never written to: everything happens on an APFS clone ("<app> (Forever).app"), the original's
  SHA-256 is checked before and after.
- The key is only replaced when it is found without doubt: next to the EnableEncryptionContext constant there must be
  exactly one table of valid Ed25519 public keys. Otherwise nothing is changed and "scout" says what was found.
- While you play on this server, WTF/Config.wtf and Cache are the Forever ones (the portal points here); when the game
  quits, the official ones are put back. Battle.net and the official realms see the client exactly as before.
Python 3.9 standard library only (the python3 of the Xcode Command Line Tools).
"""

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import time

# --- the server's side (src/server/game/Server/Packets/AuthenticationPackets.cpp) ------------------------------------
ENABLE_ENCRYPTION_CONTEXT = bytes([0xA7, 0x1F, 0xB6, 0x9B, 0xC9, 0x7C, 0xDD, 0x96, 0xE9, 0xBB, 0xB8, 0x21, 0x39, 0x8D, 0x5A, 0xD4])
ENABLE_ENCRYPTION_SEED = bytes([0x66, 0xBE, 0x29, 0x79, 0xEF, 0xF2, 0xD5, 0xB5, 0x61, 0x53, 0xF6, 0x5F, 0x45, 0xAE, 0x81, 0xCB,
                                0x32, 0xEC, 0x94, 0xEC, 0x75, 0xB3, 0x5F, 0x44, 0x6A, 0x63, 0x43, 0x67, 0x17, 0x20, 0x44, 0x34])
# Ed25519 public key of EnterEncryptedModePrivateKey (08BDC7A3...A7C9); derive_public_key() recomputes it at start.
SERVER_PRIVATE_KEY = bytes.fromhex("08BDC7A3CCC34F3F6A0BFFCF31C1B697691E729A0AAB2C77C36F8AE75A9AA7C9")
SERVER_PUBLIC_KEY = bytes.fromhex("02596f0d0c061a8b30745988fd72c59e29ec367fb0f341f28e0f08d037bafc69")
REGION_GROUP = 8                 # Network.EnterEncryptedModeRegionGroup: the client picks its key by this index
SEARCH_WINDOW = 64 * 1024        # how far from the context constant the key table may be (same function's constants)
MIN_TABLE_KEYS = REGION_GROUP + 1

PORTAL = "trinity.actual.battle.net"
COPY_SUFFIX = " (Forever)"
HOME = os.environ.get("WOWF_HOME") or os.path.expanduser("~/WoWForever")
STATE_FILE = os.path.join(HOME, "client-state.json")

# --- Ed25519 point check (RFC 8032) ------------------------------------------------------------------------------------
P = 2 ** 255 - 19
D = (-121665 * pow(121666, P - 2, P)) % P


def _point_add(a, b):
    x1, y1 = a
    x2, y2 = b
    t = D * x1 * x2 * y1 * y2 % P
    return ((x1 * y2 + x2 * y1) * pow(1 + t, P - 2, P) % P, (y1 * y2 + x1 * x2) * pow(1 - t, P - 2, P) % P)


def _point_mul(s, pt):
    r = (0, 1)
    while s:
        if s & 1:
            r = _point_add(r, pt)
        pt = _point_add(pt, pt)
        s >>= 1
    return r


def _recover_x(y, sign):
    xx = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    if xx == 0:
        return None if sign else 0
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P:
        x = x * pow(2, (P - 1) // 4, P) % P
    if (x * x - xx) % P:
        return None
    if x & 1 != sign:
        x = P - x
    return x


def is_public_key(b):
    """A 32-byte string that decodes to a point of the Ed25519 curve (RFC 8032 5.1.3), with high entropy.
    x^2 = u/v has a root exactly when u*v is a square mod p (Euler's criterion): one modular power per test."""
    if len(set(b)) < 20:          # code, text and padding never look like this; random 32 bytes have ~30 distinct
        return False
    y = int.from_bytes(b, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    if y >= P or y in (0, 1, P - 1):
        return False
    yy = y * y % P
    u = (yy - 1) % P
    v = (D * yy + 1) % P
    if u == 0:
        return sign == 0
    return pow(u * v % P, (P - 1) // 2, P) == 1


def derive_public_key(sk):
    gy = 4 * pow(5, P - 2, P) % P
    g = (_recover_x(gy, 0), gy)
    h = hashlib.sha512(sk).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    x, y = _point_mul(a, g)
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


# --- helpers ------------------------------------------------------------------------------------------------------------
def say(msg=""):
    print(msg, flush=True)


def fail(msg):
    print("\nERROR: " + msg, file=sys.stderr, flush=True)
    sys.exit(1)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cmd, check=True):
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    if check and r.returncode != 0:
        fail("%s failed:\n%s" % (" ".join(cmd), r.stdout.strip()))
    return r


def read_env():
    env = {}
    path = os.path.join(HOME, "wowforever.env")
    if os.path.isfile(path):
        with open(path) as f:
            for line in f:
                if "=" in line and not line.startswith("#"):
                    k, v = line.rstrip("\n").split("=", 1)
                    env[k] = v.strip("'\"").replace("\\ ", " ")
    return env


def find_client_root(arg):
    cand = arg or read_env().get("WOWF_CLIENT")
    if not cand:
        for base in ("/Applications/World of Warcraft", os.path.expanduser("~/Applications/World of Warcraft")):
            if os.path.isfile(os.path.join(base, ".build.info")):
                cand = base
                break
    if not cand or not os.path.isfile(os.path.join(cand, ".build.info")):
        fail("Game folder not found (the one with .build.info). Pass --client \"/Applications/World of Warcraft\".")
    return os.path.abspath(cand)


def flavor_dir(root):
    for name in ("_forever_", "_classic_beta_"):
        d = os.path.join(root, name)
        if os.path.isdir(d):
            return d
    cands = [os.path.join(root, n) for n in sorted(os.listdir(root))
             if n.startswith("_") and n.endswith("_") and os.path.isdir(os.path.join(root, n))
             and any(x.endswith(".app") for x in os.listdir(os.path.join(root, n)))]
    if len(cands) == 1:
        return cands[0]
    fail("%s has no _forever_ folder (found: %s)." % (root, ", ".join(os.path.basename(c) for c in cands) or "none"))


def find_original_app(flavor):
    apps = sorted(n for n in os.listdir(flavor) if n.endswith(".app") and COPY_SUFFIX not in n)
    apps = [a for a in apps if os.path.isfile(os.path.join(flavor, a, "Contents", "Info.plist"))]
    if not apps:
        fail("No game app (*.app) in %s." % flavor)
    if len(apps) > 1:
        # the game program, not a helper such as a crash reporter: the biggest executable
        apps.sort(key=lambda a: -os.path.getsize(app_executable(os.path.join(flavor, a))))
    return os.path.join(flavor, apps[0])


def app_executable(app):
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    exe = os.path.join(app, "Contents", "MacOS", info.get("CFBundleExecutable", ""))
    if not os.path.isfile(exe):
        fail("No program in %s" % app)
    return exe


def copy_path(original_app):
    base = original_app[:-4]
    return base + COPY_SUFFIX + ".app"


def client_build(root):
    try:
        with open(os.path.join(root, ".build.info"), errors="replace") as f:
            lines = f.read().splitlines()
        head = lines[0].split("|")
        for row in lines[1:]:
            cols = row.split("|")
            rec = dict(zip([h.split("!")[0] for h in head], cols))
            if rec.get("Product", "").startswith("wow") and rec.get("Version"):
                return rec["Version"]
    except (OSError, IndexError):
        pass
    return "?"


def macho_slices(data):
    """[(cpu name, start, end)] of a Mach-O file, fat or thin."""
    names = {7: "x86", 0x01000007: "x86_64", 12: "arm", 0x0100000C: "arm64"}
    magic = data[:4]
    if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        is64 = magic == b"\xca\xfe\xba\xbf"
        n = int.from_bytes(data[4:8], "big")
        out, off = [], 8
        for _ in range(n):
            cpu = int.from_bytes(data[off:off + 4], "big")
            if is64:
                start = int.from_bytes(data[off + 8:off + 16], "big")
                size = int.from_bytes(data[off + 16:off + 24], "big")
                off += 32
            else:
                start = int.from_bytes(data[off + 8:off + 12], "big")
                size = int.from_bytes(data[off + 12:off + 16], "big")
                off += 20
            out.append((names.get(cpu, hex(cpu)), start, start + size))
        return out
    if magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
        cpu = int.from_bytes(data[4:8], "little")
        return [(names.get(cpu, hex(cpu)), 0, len(data))]
    return [("unknown", 0, len(data))]


def find_all(data, needle, start, end):
    out, i = [], data.find(needle, start, end)
    while i != -1:
        out.append(i)
        i = data.find(needle, i + 1, end)
    return out


MIN_REPORTED_KEYS = 4


def looks_random(b):
    """64 random bytes have about 50 distinct values; code, tables of numbers, text and padding far fewer."""
    return len(b) >= 48 and len(set(b)) >= 40


def key_tables(data, lo, hi, exclude=()):
    """Runs of consecutive 32-byte Ed25519 public keys in data[lo:hi] (at least MIN_REPORTED_KEYS), longest first:
    [(offset, count)]. Every MIN_REPORTED_KEYS-th position of each stride-32 chain is tested, and a hit is grown both
    ways, so no run of that length can be missed while most positions are never tested."""
    say("  looking for Ed25519 key tables in %d KB around the context..." % ((hi - lo) // 1024))
    memo = {}
    blocked = [(e, e + n) for e, n in exclude]   # the context and seed constants are never part of a key table

    def ok(off):
        if off < lo or off + 32 > hi:
            return False
        if any(off < e_end and off + 32 > e for e, e_end in blocked):
            return False
        r = memo.get(off)
        if r is None:
            r = memo[off] = is_public_key(data[off:off + 32])
        return r

    runs = {}
    step = 32 * MIN_REPORTED_KEYS
    for off in range(lo, hi - 31):
        if (off - lo) // 32 % MIN_REPORTED_KEYS:
            continue                      # only every MIN_REPORTED_KEYS-th slot of the chain off % 32
        if not ok(off):
            continue
        start = off
        while ok(start - 32):
            start -= 32
        if start in runs:
            continue
        n, o = 0, start
        while ok(o):
            n += 1
            o += 32
        if n >= MIN_REPORTED_KEYS:
            runs[start] = n
    del step
    out = []
    for start, n in runs.items():
        end = start + 32 * n
        # a real table sits between other constants; a run inside compressed or encrypted data has noise on both sides
        isolated = not looks_random(data[max(0, start - 64):start]) and not looks_random(data[end:end + 64])
        out.append((start, n, isolated))
    return sorted(out, key=lambda r: (not r[2], -r[1], r[0]))


# --- code references: which constants the code next to EnableEncryptionContext loads ----------------------------------
XREF_WINDOW = 0x800              # bytes of code around each use of the context (the same function)


def macho_segments(data, start):
    """Thin Mach-O at data[start:]: segments [(name, vmaddr, vmsize, fileoff, filesize)], the code sections
    [(vmaddr, size, fileoff)] (any section marked as holding instructions) and all sections for the report."""
    if data[start:start + 4] != b"\xcf\xfa\xed\xfe":
        return [], [], []
    ncmds = int.from_bytes(data[start + 16:start + 20], "little")
    off, segs, code, allsect = start + 32, [], [], []
    for _ in range(ncmds):
        cmd = int.from_bytes(data[off:off + 4], "little")
        size = int.from_bytes(data[off + 4:off + 8], "little")
        if cmd == 0x19:   # LC_SEGMENT_64
            q = lambda o: int.from_bytes(data[off + o:off + o + 8], "little")
            name = data[off + 8:off + 24].rstrip(b"\0").decode("ascii", "replace")
            segs.append((name, q(24), q(32), q(40), q(48)))
            nsects = int.from_bytes(data[off + 64:off + 68], "little")
            for k in range(nsects):
                so = off + 72 + 80 * k
                sect = data[so:so + 16].rstrip(b"\0").decode("ascii", "replace")
                addr = int.from_bytes(data[so + 32:so + 40], "little")
                sz = int.from_bytes(data[so + 40:so + 48], "little")
                fo = int.from_bytes(data[so + 48:so + 52], "little")
                flags = int.from_bytes(data[so + 64:so + 68], "little")
                allsect.append((name, sect, addr, sz, fo, flags))
                if fo and sz and (flags & 0x80000400 or (name, sect) == ("__TEXT", "__text")):
                    code.append((addr, sz, fo))           # marked as instructions, or the usual code section
        elif cmd in (0x2C, 0x21):                          # LC_ENCRYPTION_INFO(_64)
            allsect.append(("LC_ENCRYPTION_INFO", "cryptid=%d" % int.from_bytes(data[off + 16:off + 20], "little"),
                            0, int.from_bytes(data[off + 12:off + 16], "little"), int.from_bytes(data[off + 8:off + 12], "little"), 0))
        off += size
    return segs, code, allsect


def _vm_to_off(segs, start, vm):
    for _, va, vs, fo, fs in segs:
        if va <= vm < va + fs:
            return start + fo + (vm - va)
    return None


def _off_to_vm(segs, start, off):
    for _, va, vs, fo, fs in segs:
        if start + fo <= off < start + fo + fs:
            return va + (off - start - fo)
    return None


def code_refs_arm64(data, start, text):
    """[(pc, target)] for ADRP followed by ADD / LDR (64-bit or 128-bit) on the same register."""
    import array
    addr, size, fo = text
    words = array.array("I")
    words.frombytes(data[start + fo:start + fo + size - size % 4])
    if sys.byteorder != "little":
        words.byteswap()
    out, n = [], len(words)
    for i in range(n):
        w = words[i]
        if w & 0x9F000000 != 0x90000000:
            continue
        rd = w & 31
        imm = ((w >> 5) & 0x7FFFF) << 2 | (w >> 29) & 3
        if imm & (1 << 20):
            imm -= 1 << 21
        pc = addr + 4 * i
        page = (pc & ~0xFFF) + (imm << 12)
        for j in range(i + 1, min(n, i + 8)):
            w2 = words[j]
            if (w2 >> 5) & 31 != rd:
                continue
            if w2 & 0xFF800000 == 0x91000000:          # ADD Xd, Xn, #imm{, LSL 12}
                out.append((pc, page + (((w2 >> 10) & 0xFFF) << (12 * ((w2 >> 22) & 1)))))
                break
            if w2 & 0xFFC00000 == 0xF9400000:          # LDR Xt, [Xn, #imm]
                out.append((pc, page + ((w2 >> 10) & 0xFFF) * 8))
                break
            if w2 & 0xFFC00000 == 0x3DC00000:          # LDR Qt, [Xn, #imm]
                out.append((pc, page + ((w2 >> 10) & 0xFFF) * 16))
                break
    return out


def code_refs_x86_64(data, start, text):
    """[(pc, target)] for RIP-relative LEA / MOV / MOVUPS / MOVAPS (disp32, 7-byte forms)."""
    import re
    addr, size, fo = text
    code = data[start + fo:start + fo + size]
    out = []
    for m in re.finditer(rb"(?:[\x48\x4c][\x8d\x8b]|\x0f[\x10\x28])[\x05\x0d\x15\x1d\x25\x2d\x35\x3d]", code):
        i = m.start()
        disp = int.from_bytes(code[i + 3:i + 7], "little", signed=True)
        out.append((addr + i, addr + i + 7 + disp))
    return out


def count_keys(data, off, lo, hi, limit=64):
    n = 0
    while n < limit and lo <= off + 32 * n and off + 32 * (n + 1) <= hi and is_public_key(data[off + 32 * n:off + 32 * (n + 1)]):
        n += 1
    return n


CONST_WINDOW = 0x400              # code may load a base address and reach the context at an offset from it


def xref_tables(data, cpu, start, end, consts):
    """What the code that uses the context (or the seed) loads nearby: [(file offset, keys in a row, code distance)],
    the code places, and the section list (for the report)."""
    segs, code, allsect = macho_segments(data, start)
    if not code:
        return [], [], allsect
    say("  reading the %s code (%d MB) for what it loads next to the context..." % (cpu, sum(c[1] for c in code) >> 20))
    refs = []
    for sect in code:
        refs += code_refs_arm64(data, start, sect) if cpu == "arm64" else code_refs_x86_64(data, start, sect)
    want = sorted({_off_to_vm(segs, start, c) for c in consts} - {None})
    near = lambda t: any(w - CONST_WINDOW <= t <= w + CONST_WINDOW for w in want)
    sites = sorted({pc for pc, t in refs if near(t)})
    seen, tables = set(), []
    refs.sort()
    import bisect
    pcs = [r[0] for r in refs]
    for pc in sites:
        for pc2, t in refs[bisect.bisect_left(pcs, pc - XREF_WINDOW):bisect.bisect_right(pcs, pc + XREF_WINDOW)]:
            if near(t) or t in seen:
                continue
            seen.add(t)
            o = _vm_to_off(segs, start, t)
            if o is None or not (start <= o < end):
                continue
            tables.append((o, count_keys(data, o, start, end), pc2 - pc))
    tables.sort(key=lambda r: (-r[1], abs(r[2])))
    return tables, sites, allsect


def data_hex(report, off):
    return report["_data"][off:off + 32].hex()


def analyse(exe):
    with open(exe, "rb") as f:
        data = f.read()
    report = {"size": len(data), "slices": [], "_data": data}
    for cpu, start, end in macho_slices(data):
        s = {"cpu": cpu, "start": start, "end": end}
        s["context"] = find_all(data, ENABLE_ENCRYPTION_CONTEXT, start, end)
        s["seed"] = find_all(data, ENABLE_ENCRYPTION_SEED, start, end)
        s["server_key"] = find_all(data, SERVER_PUBLIC_KEY, start, end)
        s["tables"] = []
        if len(s["context"]) == 1:
            c = s["context"][0]
            excl = [(c, len(ENABLE_ENCRYPTION_CONTEXT))] + [(x, len(ENABLE_ENCRYPTION_SEED)) for x in s["seed"]]
            s["tables"] = key_tables(data, max(start, c - SEARCH_WINDOW), min(end, c + SEARCH_WINDOW), excl)
        s["xref"], s["sites"], s["sections"] = xref_tables(data, cpu, start, end, s["context"] + s["seed"])
        report["slices"].append(s)
    return data, report


def parse_tables(specs):
    """--table arm64:0x1234ab:9 -> {"arm64": (0x1234ab, 9)}"""
    out = {}
    for spec in specs or ():
        try:
            cpu, off, n = spec.split(":")
            out[cpu] = (int(off, 0), int(n))
        except ValueError:
            fail("--table wants cpu:offset:count, for example arm64:0x1a2b3c:9 (got %s)" % spec)
    return out


def decide(report, manual=None):
    """The patch: [(cpu, offset, count)], or a reason why not. manual: tables given by hand (--table), still checked."""
    plan = []
    if manual:
        data = report["_data"]
        for s in report["slices"]:
            if s["server_key"]:
                return None, "the program already holds the server key (already patched?)"
            if s["cpu"] not in manual:
                return None, "--table missing for the %s part of the program" % s["cpu"]
            off, n = manual[s["cpu"]]
            if len(s["context"]) != 1 or abs(off - s["context"][0]) > SEARCH_WINDOW:
                return None, "%s: the given table is not next to EnableEncryptionContext" % s["cpu"]
            if not (s["start"] <= off and off + 32 * n <= s["end"]):
                return None, "%s: the given table is outside this part of the program" % s["cpu"]
            if not all(is_public_key(data[off + 32 * k:off + 32 * k + 32]) for k in range(n)):
                return None, "%s: the given table does not hold %d Ed25519 public keys" % (s["cpu"], n)
            plan.append((s["cpu"], off, n))
        return plan, None
    for s in report["slices"]:
        if s["server_key"]:
            return None, "the program already holds the server key (already patched?)"
        if len(s["context"]) != 1:
            return None, "%s: EnableEncryptionContext found %d times (needs exactly once)" % (s["cpu"], len(s["context"]))
        if len(s["seed"]) != 1:
            return None, "%s: EnableEncryptionSeed found %d times (needs exactly once)" % (s["cpu"], len(s["seed"]))
        # the table the code next to the context loads (a run of keys that only sits near it can be anything)
        if not s.get("sites"):
            return None, "%s: no code found that uses EnableEncryptionContext" % s["cpu"]
        big = [t for t in s.get("xref", []) if t[1] >= MIN_TABLE_KEYS and t[0] % 4 == 0]
        if len(big) != 1:
            return None, "%s: the code next to the context loads %d key tables with %d or more keys (needs exactly one)" % (
                s["cpu"], len(big), MIN_TABLE_KEYS)
        # only the entries up to our region group: past the real table, random-looking data can pass as keys too
        plan.append((s["cpu"], big[0][0], MIN_TABLE_KEYS))
    if not plan:
        return None, "no Mach-O slice found"
    return plan, None


def print_report(root, app, exe, report):
    say("Game folder : %s" % root)
    say("Build       : %s" % client_build(root))
    say("App         : %s" % app)
    say("Program     : %s (%d bytes, sha256 %s)" % (exe, report["size"], report.get("sha256", "?")))
    for s in report["slices"]:
        say("")
        say("[%s] bytes %d..%d" % (s["cpu"], s["start"], s["end"]))
        say("  EnableEncryptionContext at: %s" % (", ".join(hex(x) for x in s["context"]) or "not found"))
        say("  EnableEncryptionSeed    at: %s" % (", ".join(hex(x) for x in s["seed"]) or "not found"))
        if s["server_key"]:
            say("  server key already present at: %s" % ", ".join(hex(x) for x in s["server_key"]))
        say("  code that uses the context or seed: %d place(s)%s" % (len(s.get("sites", [])),
            "" if not s.get("sites") else ": " + ", ".join(hex(x) for x in s["sites"][:8])))
        if not s.get("sites"):
            d = report["_data"]
            say("    Mach-O header: magic %s, %d load commands" % (d[s["start"]:s["start"] + 4].hex(),
                int.from_bytes(d[s["start"] + 16:s["start"] + 20], "little")))
            for seg, sect, addr, sz, fo, flags in s.get("sections", []):
                say("    section %-16s %-24s vm %#x size %#x file %#x flags %#x" % (seg, sect, addr, sz, fo, flags))
        for off, n, dist in s.get("xref", [])[:16]:
            say("  loads %s (%+d bytes of code away): %2d key(s) in a row  %s" % (hex(off), dist, n, data_hex(report, off)))
    plan, why = decide(report)
    say("")
    if plan:
        say("Patch plan: replace every key of the table with the server key:")
        for cpu, off, n in plan:
            say("  [%s] %d keys at %s" % (cpu, n, hex(off)))
    else:
        say("No safe patch: " + why + ".")
        say("Nothing was changed. Send this report (the file next to it) to whoever maintains the macOS scripts.")


# --- entitlements: an ad-hoc signature cannot carry the ones tied to Blizzard's team ID --------------------------------
ALLOWED_ENTITLEMENT_PREFIXES = ("com.apple.security.cs.", "com.apple.security.device.", "com.apple.security.network.",
                                "com.apple.security.personal-information.", "com.apple.security.automation.")


def entitlements_of(app):
    for cmd in (["codesign", "-d", "--entitlements", "-", "--xml", app], ["codesign", "-d", "--entitlements", ":-", app]):
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        i = r.stdout.find(b"<?xml")
        if r.returncode == 0 and i >= 0:
            try:
                return plistlib.loads(r.stdout[i:])
            except Exception:
                pass
        if r.returncode == 0 and i < 0 and b"<" not in r.stdout:
            return {}
    return {}


# --- commands -----------------------------------------------------------------------------------------------------------
def cmd_scout(args):
    root = find_client_root(args.client)
    app = find_original_app(flavor_dir(root))
    exe = app_executable(app)
    say("Reading the program (read only)...")
    _, report = analyse(exe)
    report["sha256"] = sha256_of(exe)
    print_report(root, app, exe, report)
    ent = entitlements_of(app)
    say("")
    say("Entitlements: " + (", ".join(sorted(ent)) or "none"))
    os.makedirs(HOME, exist_ok=True)
    out = os.path.join(HOME, "client-scout.json")
    report.update({"root": root, "app": app, "build": client_build(root), "entitlements": sorted(ent)})
    with open(out, "w") as f:
        slim = dict(report, slices=[{k: v for k, v in sl.items() if k != "tables"} for sl in report["slices"]])
        slim.pop("_data", None)
        json.dump(slim, f, indent=1)
    say("Report: " + out)


# allow-dyld-environment-variables lets the copy honour DYLD_INSERT_LIBRARIES; the key is set in memory, not on disk
DYLD_ENV_ENTITLEMENT = "com.apple.security.cs.allow-dyld-environment-variables"
DISABLE_LV_ENTITLEMENT = "com.apple.security.cs.disable-library-validation"


def resign_adhoc(app, dst_exe, extra_entitlements=()):
    """Re-sign just the program (not the whole bundle: data files such as icudt*.dat sit beside it and are not
    signable, and we launch the program directly, so its own signature is what dyld reads) ad-hoc, no hardened
    runtime, keeping the entitlements an ad-hoc signature may carry plus the given extras."""
    ent = {k: v for k, v in entitlements_of(app).items() if k.startswith(ALLOWED_ENTITLEMENT_PREFIXES)}
    for k in extra_entitlements:
        ent[k] = True
    ent_file = os.path.join(HOME, "client-entitlements.plist")
    os.makedirs(HOME, exist_ok=True)
    with open(ent_file, "wb") as f:
        plistlib.dump(ent, f)
    run(["codesign", "--force", "--sign", "-", "--entitlements", ent_file, dst_exe])
    run(["codesign", "--verify", "--strict", dst_exe])
    return ent


def make_signed_copy(app, dst, dst_exe, extra_entitlements=()):
    """APFS-clone app to dst and re-sign the program ad-hoc so dyld honours DYLD_* and loads our module."""
    if os.path.exists(dst):
        say("Removing the old copy")
        shutil.rmtree(dst)
    say("Making the copy (APFS clone: takes no extra disk space)")
    r = run(["cp", "-cR", app, dst], check=False)
    if r.returncode != 0:
        run(["ditto", app, dst])
    run(["xattr", "-dr", "com.apple.quarantine", dst], check=False)
    return resign_adhoc(app, dst_exe, extra_entitlements)


def cmd_prepare(args):
    """Make the signed copy the in-memory key-setter runs against, and confirm macOS honours DYLD_* on it."""
    root = find_client_root(args.client)
    app = find_original_app(flavor_dir(root))
    exe = app_executable(app)
    dst = copy_path(app)
    dst_exe = os.path.join(dst, os.path.relpath(exe, app))
    orig_hash = sha256_of(exe)
    say("Original : %s" % app)
    say("Copy     : %s" % dst)
    ent = make_signed_copy(app, dst, dst_exe, (DYLD_ENV_ENTITLEMENT, DISABLE_LV_ENTITLEMENT))
    if sha256_of(exe) != orig_hash:
        fail("The original program changed. Repair the game in Battle.net.")
    with open(os.path.join(dst, "Contents", "forever-prepare.json"), "w") as f:
        json.dump({"original_sha256": orig_hash, "build": client_build(root),
                   "entitlements": sorted(ent), "time": time.strftime("%Y-%m-%d %H:%M:%S")}, f, indent=1)
    say("")
    say("Entitlements on the copy: " + ", ".join(sorted(ent)))
    say("Done. The original app is unchanged (sha256 %s)." % orig_hash[:16])
    say("")
    dst_exe = os.path.join(dst, os.path.relpath(exe, app))
    say("Now confirm macOS loads an inserted library into the copy:")
    say('  DYLD_PRINT_LIBRARIES=1 "%s" >~/Desktop/forever-copy-dyld.log 2>&1 &' % dst_exe)
    say("  sleep 8; kill %1 2>/dev/null; wc -l <~/Desktop/forever-copy-dyld.log")
    say("A log with many lines means DYLD_* now works on the copy (it was empty on the original).")


def cmd_patch(args):
    if SERVER_PUBLIC_KEY != derive_public_key(SERVER_PRIVATE_KEY):
        fail("internal: the server key does not match its private key")
    root = find_client_root(args.client)
    flavor = flavor_dir(root)
    app = find_original_app(flavor)
    exe = app_executable(app)
    dst = copy_path(app)
    orig_hash = sha256_of(exe)

    say("Original : %s" % app)
    say("Copy     : %s" % dst)
    if args.expect_sha256 and args.expect_sha256.lower() != orig_hash:
        fail("The program is not the one the --table values were made for (sha256 %s). Nothing was changed." % orig_hash)
    if args.table and not args.expect_sha256:
        fail("--table needs --expect-sha256 (from the scout report), so it can never hit another version.")
    data, report = analyse(exe)
    plan, why = decide(report, parse_tables(args.table))
    if not plan:
        print_report(root, app, exe, report)
        fail("Not patched: " + why + ". The client was not changed.")

    if os.path.exists(dst):
        say("Removing the old copy")
        shutil.rmtree(dst)
    say("Making the copy (APFS clone: takes no extra disk space)")
    r = run(["cp", "-cR", app, dst], check=False)
    if r.returncode != 0:
        run(["ditto", app, dst])
    run(["xattr", "-dr", "com.apple.quarantine", dst], check=False)

    dst_exe = os.path.join(dst, os.path.relpath(exe, app))
    patched = bytearray(data)
    for cpu, off, n in plan:
        for k in range(n):
            o = off + 32 * k
            patched[o:o + 32] = SERVER_PUBLIC_KEY
        say("  [%s] %d keys replaced at %s" % (cpu, n, hex(off)))
    # write next to it, then rename: the clone's program becomes a file of its own, the original keeps its blocks
    tmp = dst_exe + ".forever-tmp"
    with open(tmp, "wb") as f:
        f.write(patched)
    os.chmod(tmp, os.stat(exe).st_mode)
    os.replace(tmp, dst_exe)

    # re-sign the copy (the patch breaks Blizzard's signature): ad-hoc, without hardened runtime, keeping only
    # entitlements an ad-hoc signature may carry
    ent = {k: v for k, v in entitlements_of(app).items() if k.startswith(ALLOWED_ENTITLEMENT_PREFIXES)}
    ent_file = os.path.join(HOME, "client-entitlements.plist")
    os.makedirs(HOME, exist_ok=True)
    with open(ent_file, "wb") as f:
        plistlib.dump(ent, f)
    run(["codesign", "--force", "--sign", "-", "--entitlements", ent_file, dst_exe])
    run(["codesign", "--verify", "--strict", dst_exe])

    with open(dst_exe, "rb") as f:
        check = f.read()
    for cpu, off, n in plan:
        if check[off:off + 32 * n] != SERVER_PUBLIC_KEY * n:
            fail("The copy did not take the patch (%s)." % cpu)
    if sha256_of(exe) != orig_hash:
        fail("The original program changed during the patch. Repair the game in Battle.net.")
    with open(os.path.join(dst, "Contents", "forever-patch.json"), "w") as f:
        json.dump({"original_sha256": orig_hash, "build": client_build(root), "plan": plan,
                   "time": time.strftime("%Y-%m-%d %H:%M:%S")}, f, indent=1)
    say("")
    say("Done. The original app is unchanged (sha256 %s)." % orig_hash[:16])
    say("Play on this server with: macos/wowforever.sh play")


# --- settings and cache swap ------------------------------------------------------------------------------------------
SWAP_ITEMS = (os.path.join("WTF", "Config.wtf"), "Cache")


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(st):
    os.makedirs(HOME, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, STATE_FILE)


def set_portal(config_path):
    lines = []
    if os.path.isfile(config_path):
        with open(config_path, errors="replace") as f:
            lines = [l for l in f.read().splitlines() if not l.lower().startswith('set portal ')]
    lines.append('SET portal "%s"' % PORTAL)
    os.makedirs(os.path.dirname(config_path), exist_ok=True)
    with open(config_path, "w") as f:
        f.write("\n".join(lines) + "\n")


def swap_in(flavor):
    """Official Config.wtf and Cache -> *.official, Forever's own -> in place, portal set to this server.
    The state file is written first, so 'restore' can always undo it (even after a crash or a power cut)."""
    save_state({"flavor": flavor, "swapped": True})
    for item in SWAP_ITEMS:
        live = os.path.join(flavor, item)
        official, forever = live + ".official", live + ".forever"
        if os.path.exists(official):
            fail("%s exists: run 'restore' first." % official)
        if os.path.exists(live):
            os.rename(live, official)
        if os.path.exists(forever):
            os.rename(forever, live)
        elif item.endswith("Config.wtf") and os.path.exists(official):
            shutil.copy2(official, live)        # first time: start from your own settings, only the portal differs
    set_portal(os.path.join(flavor, "WTF", "Config.wtf"))


def _remove(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    elif os.path.lexists(path):
        os.remove(path)


def swap_out(flavor):
    """What the session used -> *.forever (kept for next time), *.official -> in place."""
    for item in SWAP_ITEMS:
        live = os.path.join(flavor, item)
        official, forever = live + ".official", live + ".forever"
        if os.path.lexists(live):
            _remove(forever)
            os.rename(live, forever)
        if os.path.lexists(official):
            os.rename(official, live)
    save_state({"swapped": False})


def game_running(app):
    """True while a program from inside this app bundle runs (compared as text: the name has parentheses)."""
    prefix = os.path.join(app, "Contents", "MacOS") + os.sep
    r = subprocess.run(["ps", "-axo", "command="], stdout=subprocess.PIPE, universal_newlines=True)
    return any(line.strip().startswith(prefix) for line in r.stdout.splitlines())


def cmd_restore(args):
    st = load_state()
    flavor = st.get("flavor") or flavor_dir(find_client_root(args.client))
    if not st.get("swapped"):
        say("The official settings and cache are in place.")
        return
    swap_out(flavor)
    say("Official settings and cache put back.")


def cmd_play(args):
    root = find_client_root(args.client)
    flavor = flavor_dir(root)
    app = find_original_app(flavor)
    dst = copy_path(app)
    meta = os.path.join(dst, "Contents", "forever-patch.json")
    if not os.path.isfile(meta):
        say("First time: making the patched copy of the game (the original stays as it is).")
        cmd_patch(args)
    with open(meta) as f:
        info = json.load(f)
    if info.get("original_sha256") != sha256_of(app_executable(app)):
        say("The game was updated since the copy was made: patching the new version first.")
        args.table, args.expect_sha256 = None, None
        cmd_patch(args)
    if game_running(app) or game_running(dst):
        fail("The game is running: quit it first.")
    if load_state().get("swapped"):
        cmd_restore(args)
    swap_in(flavor)
    try:
        say("Starting %s (portal %s). Your official settings come back when the game quits." % (os.path.basename(dst), PORTAL))
        subprocess.call(["open", "-W", "-n", dst])
        time.sleep(2)
        while game_running(dst):
            time.sleep(2)
    finally:
        swap_out(flavor)
        say("Official settings and cache put back.")


def cmd_remove(args):
    root = find_client_root(args.client)
    flavor = flavor_dir(root)
    if load_state().get("swapped"):
        swap_out(flavor)
    app = find_original_app(flavor)
    dst = copy_path(app)
    if game_running(dst):
        fail("The Forever copy is running: quit the game first.")
    if os.path.isdir(dst):
        shutil.rmtree(dst)
        say("Removed " + dst)
    for item in SWAP_ITEMS:
        _remove(os.path.join(flavor, item) + ".forever")
    say("The original client is as Battle.net installed it.")


def cmd_status(args):
    root = find_client_root(args.client)
    flavor = flavor_dir(root)
    app = find_original_app(flavor)
    dst = copy_path(app)
    say("Build    : %s" % client_build(root))
    say("Original : %s" % app)
    meta = os.path.join(dst, "Contents", "forever-patch.json")
    if os.path.isfile(meta):
        with open(meta) as f:
            info = json.load(f)
        fresh = info.get("original_sha256") == sha256_of(app_executable(app))
        say("Copy     : %s (patched %s%s)" % (dst, info.get("time", "?"), "" if fresh else ", game updated since: patched again on play"))
    else:
        say("Copy     : none (run patch)")
    say("Settings : %s" % ("Forever's (the game runs or a session did not end: run restore)" if load_state().get("swapped") else "official"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("command", choices=["scout", "patch", "prepare", "play", "restore", "remove", "status"])
    ap.add_argument("--client", help="the game folder (holds .build.info and _forever_)")
    ap.add_argument("--table", action="append", metavar="CPU:OFFSET:COUNT",
                    help="patch: the key table by hand (from a reviewed scout report), once per part (x86_64, arm64)")
    ap.add_argument("--expect-sha256", help="patch with --table: the program's sha256 from the scout report")
    args = ap.parse_args()
    if sys.platform != "darwin" and args.command != "scout":
        fail("This is for macOS.")
    {"scout": cmd_scout, "patch": cmd_patch, "prepare": cmd_prepare, "play": cmd_play, "restore": cmd_restore,
     "remove": cmd_remove, "status": cmd_status}[args.command](args)


if __name__ == "__main__":
    main()
