#!/usr/bin/env python3
import subprocess
import tempfile
import os
import sys

try:
    import cbor2
except ImportError:
    print("Error: cbor2 not installed. Run: zypper install python313-cbor2")
    sys.exit(1)

def python_to_mruby(obj):
    if obj is True: return "true"
    elif obj is False: return "false"
    elif obj is None: return "nil"
    elif isinstance(obj, str): return repr(obj)
    elif isinstance(obj, (int, float)): return str(obj)
    elif isinstance(obj, list):
        return "[" + ", ".join(python_to_mruby(i) for i in obj) + "]"
    elif isinstance(obj, dict):
        return "{" + ", ".join(f"{python_to_mruby(k)} => {python_to_mruby(v)}" for k, v in obj.items()) + "}"
    return repr(obj)

def mruby_encode(obj):
    with tempfile.NamedTemporaryFile(mode='w', suffix='.rb', delete=False) as f:
        f.write(f"""
obj = {python_to_mruby(obj)}
puts CBOR.encode(obj).bytes.map {{ |b| "%02x" % b }}.join
""")
        f.flush()
        try:
            result = subprocess.run(
                ['./mruby/bin/mruby', f.name],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode != 0:
                print(f"mruby encode error: {result.stderr}")
                sys.exit(1)
            return bytes.fromhex(result.stdout.strip())
        finally:
            os.unlink(f.name)

def mruby_decode(cbor_bytes):
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.cbor', delete=False) as f:
        f.write(cbor_bytes)
        f.flush()
        
        with tempfile.NamedTemporaryFile(mode='w', suffix='.rb', delete=False) as rb:
            rb.write(f"""
data = File.read('{f.name}')
puts CBOR.decode(data).inspect
""")
            rb.flush()
            try:
                result = subprocess.run(
                    ['./mruby/bin/mruby', rb.name],
                    capture_output=True, text=True, timeout=5
                )
                if result.returncode != 0:
                    print(f"mruby decode error: {result.stderr}")
                    sys.exit(1)
                return result.stdout.strip()
            finally:
                os.unlink(rb.name)
                os.unlink(f.name)

# Test objects
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
    2**63,           # Larger than int64
    2**128,          # Way larger
    -2**63 - 1,      # Negative bigint
]

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

print("\n" + "=" * 60)
print("✓ All interop tests passed!")
print("=" * 60)
