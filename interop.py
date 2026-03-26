#!/usr/bin/env python3
import struct
import subprocess
import tempfile
import os
import sys
import math

try:
    import cbor2
except ImportError:
    print("Error: cbor2 not installed. Run: zypper install python313-cbor2")
    sys.exit(1)

try:
    from cbor_diag import cbor2diag
    HAVE_CBOR_DIAG = True
except ImportError:
    HAVE_CBOR_DIAG = False

INT64_MIN = -(2**63)

def python_to_mruby(obj):
    if obj is True: return "true"
    elif obj is False: return "false"
    elif obj is None: return "nil"
    elif isinstance(obj, float):
        if math.isnan(obj): return "Float::NAN"
        if math.isinf(obj): return "Float::INFINITY" if obj > 0 else "-Float::INFINITY"
        return repr(obj)
    elif isinstance(obj, str): return repr(obj)
    elif isinstance(obj, int):
        # Negative integers below INT64_MIN overflow mrb_int as a literal.
        # Emit them as -(abs_value) so mruby parses the positive part as a
        # bigint first and then negates.
        if obj < INT64_MIN:
            return f"-({-obj})"
        return str(obj)
    elif isinstance(obj, list):
        return "[" + ", ".join(python_to_mruby(i) for i in obj) + "]"
    elif isinstance(obj, dict):
        return "{" + ", ".join(f"{python_to_mruby(k)} => {python_to_mruby(v)}" for k, v in obj.items()) + "}"
    return repr(obj)

def mruby_run(script):
    with tempfile.NamedTemporaryFile(mode='w', suffix='.rb', delete=False) as f:
        f.write(script)
        fname = f.name
    try:
        result = subprocess.run(
            ['./mruby/bin/mruby', fname],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            print(f"mruby error: {result.stderr.strip()}")
            sys.exit(1)
        return result.stdout.strip()
    finally:
        os.unlink(fname)

def mruby_encode(obj):
    return bytes.fromhex(mruby_run(f"""
obj = {python_to_mruby(obj)}
puts CBOR.encode(obj).bytes.map {{ |b| "%02x" % b }}.join
"""))

def mruby_encode_rb(rb_literal):
    return bytes.fromhex(mruby_run(
        f"puts CBOR.encode({rb_literal}).bytes.map {{|b| \"%02x\" % b}}.join\n"
    ))

def mruby_decode_reencode(cbor_bytes):
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.cbor', delete=False) as f:
        f.write(cbor_bytes)
        fname = f.name
    try:
        return bytes.fromhex(mruby_run(f"""
data = File.read('{fname}')
decoded = CBOR.decode(data)
puts CBOR.encode(decoded).bytes.map {{|b| "%02x" % b}}.join
"""))
    finally:
        os.unlink(fname)

def mruby_decode(cbor_bytes):
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.cbor', delete=False) as f:
        f.write(cbor_bytes)
        fname = f.name
    try:
        return mruby_run(f"""
data = File.read('{fname}')
puts CBOR.decode(data).inspect
""")
    finally:
        os.unlink(fname)

def mruby_diagnose(cbor_bytes):
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.cbor', delete=False) as f:
        f.write(cbor_bytes)
        fname = f.name
    try:
        return mruby_run(f"""
data = File.read('{fname}')
puts CBOR.diagnose(data)
""")
    finally:
        os.unlink(fname)

# ── Reference preferred-encoding implementation ───────────────────────────────

def our_preferred_encode(v):
    if math.isnan(v): return bytes([0xF9, 0x7E, 0x00])
    u64, = struct.unpack('>Q', struct.pack('>d', v))
    exp64 = (u64 >> 52) & 0x7FF
    mant64 = u64 & 0x000FFFFFFFFFFFFF
    sign = u64 >> 63
    if (mant64 & 0x1FFFFFFF) != 0: return _f64(u64)
    mant32 = mant64 >> 29
    if exp64 == 0x7FF: exp32 = 0xFF
    elif exp64 == 0:
        if mant64 != 0: return _f64(u64)
        exp32 = 0
    elif 897 <= exp64 <= 1150: exp32 = exp64 - 896
    else: return _f64(u64)
    u32 = (sign << 31) | (exp32 << 23) | mant32
    if exp32 in (0, 0xFF): return _f16(u32)
    if 113 <= exp32 <= 142 and (mant32 & 0x1FFF) == 0: return _f16(u32)
    if 103 <= exp32 <= 112 and (mant32 & ((1 << (126 - exp32)) - 1)) == 0: return _f16(u32)
    return _f32(u32)

def _f16(u32):
    s = u32 >> 31; e32 = (u32 >> 23) & 0xFF; m32 = u32 & 0x7FFFFF
    if e32 == 0xFF: e16, m16 = 0x1F, 0
    elif e32 == 0: e16, m16 = 0, 0
    elif e32 >= 113: e16, m16 = e32 - 112, m32 >> 13
    else: m16 = (0x800000 | m32) >> (126 - e32); e16 = 0
    h = (s << 15) | (e16 << 10) | m16
    return bytes([0xF9, h >> 8, h & 0xFF])

def _f32(u32):
    return bytes([0xFA, (u32>>24)&0xFF, (u32>>16)&0xFF, (u32>>8)&0xFF, u32&0xFF])

def _f64(u64):
    return bytes([0xFB,
                  (u64>>56)&0xFF, (u64>>48)&0xFF, (u64>>40)&0xFF, (u64>>32)&0xFF,
                  (u64>>24)&0xFF, (u64>>16)&0xFF, (u64>>8)&0xFF, u64&0xFF])

def cbor2_known_wrong(v):
    if math.isnan(v) or math.isinf(v): return False
    u64, = struct.unpack('>Q', struct.pack('>d', v))
    exp64 = (u64 >> 52) & 0x7FF
    mant64 = u64 & 0x000FFFFFFFFFFFFF
    if (mant64 & 0x1FFFFFFF) != 0: return False
    if not (897 <= exp64 <= 1150): return False
    exp32 = exp64 - 896
    return 113 <= exp32 <= 142 and exp32 - 112 == 30

def preferred_encode_ref(v):
    if cbor2_known_wrong(v): return our_preferred_encode(v)
    return cbor2.dumps(v, canonical=True)

# ── Diagnostic notation comparison ───────────────────────────────────────────

def parse_diag_float(s):
    if '_' not in s:
        return None, None
    val_str, width = s.rsplit('_', 1)
    if width not in ('1', '2', '3'):
        return None, None
    if val_str == 'NaN':       return math.nan, width
    if val_str == 'Infinity':  return math.inf, width
    if val_str == '-Infinity': return -math.inf, width
    try:
        return float(val_str), width
    except ValueError:
        return None, None

def diag_floats_equal(got, want):
    gv, gw = parse_diag_float(got)
    wv, ww = parse_diag_float(want)
    if gv is None or wv is None:
        return got == want
    if gw != ww:
        return False
    if math.isnan(gv) and math.isnan(wv): return True
    if math.isinf(gv) or math.isinf(wv): return gv == wv
    gb, = struct.unpack('>Q', struct.pack('>d', gv))
    wb, = struct.unpack('>Q', struct.pack('>d', wv))
    return gb == wb

# ── Test data ─────────────────────────────────────────────────────────────────

test_cases = [
    {"hello": [1, 2, 3], "ok": True},
    {"nested": {"x": 42, "y": "test"}},
    [1, 2, 3, 4, 5],
    "hello world",
    42,
    -100,
    3.14,
    True,
    False,
    None,
    2**63,
    2**128,
    -2**63 - 1,
]

float_cases = [
    ("0.0",       0.0,         None),
    ("-0.0",      -0.0,        None),
    ("1.0",       1.0,         None),
    ("1.5",       1.5,         None),
    ("-1.5",      -1.5,        None),
    ("0.5",       0.5,         None),
    ("0.25",      0.25,        None),
    ("100.0",     100.0,       None),
    ("65504.0",   65504.0,     None),
    ("+Inf",      math.inf,    None),
    ("-Inf",      -math.inf,   None),
    ("NaN",       math.nan,    None),
    ("2^-24",     2**-24,      "1.0/16777216.0"),
    ("2^-23",     2**-23,      "1.0/8388608.0"),
    ("2^-22",     2**-22,      "1.0/4194304.0"),
    ("2^-15",     2**-15,      "1.0/32768.0"),
    ("65505.0",   65505.0,     None),
    ("1.0e10",    1.0e10,      None),
    ("3.14",      3.14,        None),
    ("1/3",       1.0/3.0,     None),
    ("1.0e300",   1.0e300,     None),
    ("1.0e38",    1.0e38,      None),
]

decode_cases = [
    ("f16 1.0",   bytes([0xF9, 0x3C, 0x00])),
    ("f16 1.5",   bytes([0xF9, 0x3E, 0x00])),
    ("f16 100.0", bytes([0xF9, 0x56, 0x40])),
    ("f16 -0.0",  bytes([0xF9, 0x80, 0x00])),
    ("f16 +Inf",  bytes([0xF9, 0x7C, 0x00])),
    ("f16 -Inf",  bytes([0xF9, 0xFC, 0x00])),
    ("f16 NaN",   bytes([0xF9, 0x7E, 0x00])),
    ("f16 2^-24", bytes([0xF9, 0x00, 0x01])),
    ("f32 1.0",   bytes([0xFA, 0x3F, 0x80, 0x00, 0x00])),
    ("f64 3.14",  preferred_encode_ref(3.14)),
]

diagnose_cases = [
    ("uint 0",        bytes([0x00])),
    ("uint 1",        bytes([0x01])),
    ("uint 1000000",  bytes.fromhex("1a000f4240")),
    ("neg -1",        bytes([0x20])),
    ("neg -1000",     bytes.fromhex("3903e7")),
    ("f16 0.0",       bytes([0xF9, 0x00, 0x00])),
    ("f16 1.0",       bytes([0xF9, 0x3C, 0x00])),
    ("f16 1.5",       bytes([0xF9, 0x3E, 0x00])),
    ("f16 65504.0",   bytes([0xF9, 0x7B, 0xFF])),
    ("f16 +Inf",      bytes([0xF9, 0x7C, 0x00])),
    ("f16 NaN",       bytes([0xF9, 0x7E, 0x00])),
    ("f16 -Inf",      bytes([0xF9, 0xFC, 0x00])),
    ("f16 2^-24",     bytes([0xF9, 0x00, 0x01])),
    ("f32 100000.0",  bytes.fromhex("fa47c35000")),
    ("f64 1.1",       bytes.fromhex("fb3ff199999999999a")),
    ("f64 1e300",     bytes.fromhex("fb7e37e43c8800759c")),
    ("text empty",    bytes([0x60])),
    ("text hello",    cbor2.dumps("hello")),
    ("bytes empty",   bytes([0x40])),
    ("bytes 01020304",bytes.fromhex("4401020304")),
    ("array []",      bytes([0x80])),
    ("array [1,2,3]", bytes.fromhex("83010203")),
    ("map {}",        bytes([0xA0])),
    ("map {a:1}",     cbor2.dumps({"a": 1})),
    ("false",         bytes([0xF4])),
    ("true",          bytes([0xF5])),
    ("null",          bytes([0xF6])),
    ("undefined",     bytes([0xF7])),
    ("simple 16",     bytes([0xF0])),
    ("simple 255",    bytes([0xF8, 0xFF])),
    ("tag 0",         bytes.fromhex("c074323031332d30332d32315432303a30343a30305a")),
    ("tag 1 int",     bytes.fromhex("c11a514b67b0")),
    ("tag 32",        bytes.fromhex("d82076687474703a2f2f7777772e6578616d706c652e636f6d")),
    ("nested array",  bytes.fromhex("8301820203820405")),
    ("nested map",    cbor2.dumps({"a": 1, "b": [2, 3]})),
]

# ── General interop tests ─────────────────────────────────────────────────────

print("=" * 60)
print("CBOR Interop Test: mruby-cbor vs cbor2")
print("=" * 60)

for i, obj in enumerate(test_cases, 1):
    print(f"\n[{i}] Testing: {obj}")
    try:
        encoded = mruby_encode(obj)
        decoded_by_python = cbor2.loads(encoded)
        print(f"  mruby→python: {decoded_by_python}")
        assert decoded_by_python == obj, f"Mismatch: {decoded_by_python} != {obj}"
        print(f"  ✓ Round-trip OK")
    except Exception as e:
        print(f"  ✗ FAILED: {e}")
        sys.exit(1)

    try:
        encoded = cbor2.dumps(obj)
        decoded_by_mruby = mruby_decode(encoded)
        print(f"  python→mruby: {decoded_by_mruby}")
        print(f"  ✓ Reverse OK")
    except Exception as e:
        print(f"  ✗ FAILED: {e}")
        sys.exit(1)

# ── Float preferred encoding tests ───────────────────────────────────────────

print("\n" + "=" * 60)
print("Float Preferred Encoding Tests (mruby vs reference)")
print("=" * 60)

width_name = {3: "f16", 5: "f32", 9: "f64"}
failures = 0

for desc, v, rb_literal in float_cases:
    got = mruby_encode_rb(rb_literal) if rb_literal else mruby_encode(v)
    got_label = width_name.get(len(got), "?")
    if math.isnan(v):
        ok = len(got) == 3 and got[0] == 0xF9
        print(f"  {'✓' if ok else '✗'} {'NaN':12s}  {got.hex()}  ({got_label})")
        if not ok: failures += 1
        continue
    want = preferred_encode_ref(v)
    want_label = width_name.get(len(want), "?")
    if got == want:
        note = " [cbor2*]" if cbor2_known_wrong(v) else ""
        print(f"  ✓ {desc:12s}  {got.hex()}  ({got_label}){note}")
    else:
        print(f"  ✗ {desc:12s}  mruby {got.hex()} ({got_label})  want {want.hex()} ({want_label})")
        failures += 1

print("\n  -- Decode: wire bytes → mruby (decode→re-encode) --")
for desc, wire in decode_cases:
    decoded_val = cbor2.loads(wire)
    reencoded = mruby_decode_reencode(wire)
    if math.isnan(decoded_val):
        ok = len(reencoded) == 3 and reencoded[0] == 0xF9
    else:
        want = preferred_encode_ref(decoded_val)
        ok = reencoded == want
    print(f"  {'✓' if ok else '✗'} {desc:12s}  {wire.hex()} → {reencoded.hex()}")
    if not ok:
        print(f"    want {want.hex()}")
        failures += 1

# ── Diagnostic notation tests ─────────────────────────────────────────────────

print("\n" + "=" * 60)
print("Diagnostic Notation Tests (mruby CBOR.diagnose vs cbor2diag)")
print("=" * 60)

if not HAVE_CBOR_DIAG:
    print("  SKIP: cbor-diag not installed (pip install cbor-diag --break-system-packages)")
else:
    for desc, wire in diagnose_cases:
        got  = mruby_diagnose(wire)
        want = cbor2diag(wire, pretty=False)

        gv, gw = parse_diag_float(got)
        wv, ww = parse_diag_float(want)
        if gv is not None and wv is not None:
            ok = diag_floats_equal(got, want)
        else:
            ok = got == want

        print(f"  {'✓' if ok else '✗'} {desc:18s}  {got!r}")
        if not ok:
            print(f"    want {want!r}")
            failures += 1

# ── Summary ───────────────────────────────────────────────────────────────────

print("\n" + "=" * 60)
if failures == 0:
    print("✓ All interop tests passed!")
else:
    print(f"✗ {failures} test(s) failed.")
    sys.exit(1)
print("=" * 60)