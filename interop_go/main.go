// interop_go/main.go
//
// Strict CBOR interop test: mruby-cbor vs fxamacker/cbor (Go).
//
// fxamacker/cbor is the strictest widely-used CBOR implementation:
//   - Enforces preferred serialization (shortest-form floats and integers)
//   - Rejects non-minimal integer encodings
//   - Validates UTF-8 in text strings
//   - Rejects duplicate map keys
//   - Passes all RFC 8949 test vectors
//
// Usage:
//   cd interop_go
//   go mod tidy
//   go run . ../../mruby/bin/mruby
//
// Or from the repo root:
//   go -C interop_go run . ../mruby/bin/mruby

package main

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"math"
	"os"
	"os/exec"
	"strings"

	cbor "github.com/fxamacker/cbor/v2"
)

// ── mruby helpers ─────────────────────────────────────────────────────────────

var mrubyBin string

func mrubyEncode(rbExpr string) ([]byte, error) {
	script := fmt.Sprintf(`puts CBOR.encode(%s).bytes.map{|b| "%%02x"%%b}.join`, rbExpr)
	out, err := exec.Command(mrubyBin, "-e", script).Output()
	if err != nil {
		return nil, fmt.Errorf("mruby encode(%s): %w", rbExpr, err)
	}
	return hex.DecodeString(strings.TrimSpace(string(out)))
}

func mrubyDecode(wire []byte) (string, error) {
	script := fmt.Sprintf(
		`data = ["%s"].pack("H*"); puts CBOR.decode(data).inspect`,
		hex.EncodeToString(wire),
	)
	out, err := exec.Command(mrubyBin, "-e", script).Output()
	if err != nil {
		return "", fmt.Errorf("mruby decode(%x): %w", wire, err)
	}
	return strings.TrimSpace(string(out)), nil
}

func mrubyRoundtrip(wire []byte) ([]byte, error) {
	script := fmt.Sprintf(
		`data = ["%s"].pack("H*"); puts CBOR.encode(CBOR.decode(data)).bytes.map{|b| "%%02x"%%b}.join`,
		hex.EncodeToString(wire),
	)
	out, err := exec.Command(mrubyBin, "-e", script).Output()
	if err != nil {
		return nil, fmt.Errorf("mruby roundtrip(%x): %w", wire, err)
	}
	return hex.DecodeString(strings.TrimSpace(string(out)))
}

// ── test harness ──────────────────────────────────────────────────────────────

type result struct {
	desc string
	ok   bool
	msg  string
}

var results []result
var failures int

func pass(desc string) {
	results = append(results, result{desc, true, ""})
	fmt.Printf("  ✓ %s\n", desc)
}

func fail(desc, msg string) {
	results = append(results, result{desc, false, msg})
	fmt.Printf("  ✗ %s\n    %s\n", desc, msg)
	failures++
}

func check(desc string, err error) bool {
	if err != nil {
		fail(desc, err.Error())
		return false
	}
	return true
}

// ── Go CBOR encode mode (preferred serialization) ─────────────────────────────

var encMode cbor.EncMode
var decMode cbor.DecMode

func init() {
	var err error
	encMode, err = cbor.PreferredUnsortedEncOptions().EncMode()
	if err != nil {
		panic(err)
	}
	decMode, err = cbor.DecOptions{
		DupMapKey:   cbor.DupMapKeyEnforcedAPF,
		UTF8:        cbor.UTF8RejectInvalid,
		IndefLength: cbor.IndefLengthForbidden,
		MaxNestedLevels: 128,
	}.DecMode()
	if err != nil {
		panic(err)
	}
}

// ── Tests ─────────────────────────────────────────────────────────────────────

// goEncode encodes a Go value to CBOR using preferred serialization.
func goEncode(v any) ([]byte, error) {
	return encMode.Marshal(v)
}

// goDecode decodes CBOR bytes into a Go value.
func goDecode(wire []byte, dst any) error {
	return decMode.Unmarshal(wire, dst)
}

func testIntegerRoundtrips() {
	fmt.Println("\n── Integer roundtrips ───────────────────────────────────────")

	cases := []struct {
		desc string
		rb   string
		val  int64
	}{
		{"0", "0", 0},
		{"-1", "-1", -1},
		{"23", "23", 23},
		{"24", "24", 24},
		{"255", "255", 255},
		{"256", "256", 256},
		{"65535", "65535", 65535},
		{"65536", "65536", 65536},
		{"2^31-1", "2**31-1", math.MaxInt32},
		{"-2^31", "-(2**31)", math.MinInt32},
		{"2^63-1", "2**63-1", math.MaxInt64},
	}

	for _, c := range cases {
		// mruby → Go
		wire, err := mrubyEncode(c.rb)
		if !check(c.desc+" mruby→Go wire", err) {
			continue
		}
		var got int64
		if err := goDecode(wire, &got); err != nil {
			fail(c.desc+" mruby→Go decode", err.Error())
			continue
		}
		if got != c.val {
			fail(c.desc+" mruby→Go value", fmt.Sprintf("got %d want %d", got, c.val))
			continue
		}

		// Go → mruby
		goWire, err := goEncode(c.val)
		if !check(c.desc+" Go→mruby encode", err) {
			continue
		}
		mrubyOut, err := mrubyDecode(goWire)
		if !check(c.desc+" Go→mruby decode", err) {
			continue
		}
		if mrubyOut != fmt.Sprintf("%d", c.val) {
			fail(c.desc+" Go→mruby value", fmt.Sprintf("mruby got %s want %d", mrubyOut, c.val))
			continue
		}

		// wire must be identical (preferred encoding)
		if !bytes.Equal(wire, goWire) {
			fail(c.desc+" wire equality",
				fmt.Sprintf("mruby %x  go %x", wire, goWire))
			continue
		}

		pass(c.desc)
	}
}

func testFloatRoundtrips() {
	fmt.Println("\n── Float roundtrips ─────────────────────────────────────────")

	cases := []struct {
		desc    string
		rb      string
		val     float64
		wantHex string // expected wire bytes per RFC 8949 §4.1
	}{
		{"0.0",     "0.0",                     0.0,            "f90000"},
		{"-0.0",    "-0.0",                    math.Copysign(0, -1), "f98000"},
		{"1.0",     "1.0",                     1.0,            "f93c00"},
		{"1.5",     "1.5",                     1.5,            "f93e00"},
		{"65504.0", "65504.0",                 65504.0,        "f97bff"},
		{"+Inf",    "Float::INFINITY",          math.Inf(1),   "f97c00"},
		{"-Inf",    "-Float::INFINITY",         math.Inf(-1),  "f9fc00"},
		{"1.0e10",  "1.0e10",                  1.0e10,         "fa501502f9"},
		{"3.14",    "3.14",                    3.14,           "fb40091eb851eb851f"},
		{"1.0/3.0", "1.0/3.0",                1.0/3.0,        "fb3fd5555555555555"},
	}

	for _, c := range cases {
		// Check mruby preferred encoding against spec wire bytes
		wire, err := mrubyEncode(c.rb)
		if !check(c.desc+" mruby encode", err) {
			continue
		}
		wantWire, _ := hex.DecodeString(c.wantHex)
		if !bytes.Equal(wire, wantWire) {
			fail(c.desc+" mruby wire",
				fmt.Sprintf("got %x want %x", wire, wantWire))
			continue
		}

		// Go must produce identical wire bytes
		goWire, err := goEncode(c.val)
		if !check(c.desc+" Go encode", err) {
			continue
		}
		if !bytes.Equal(goWire, wantWire) {
			fail(c.desc+" Go wire",
				fmt.Sprintf("go got %x want %x", goWire, wantWire))
			continue
		}

		// mruby must decode Go's wire bytes back to the same value
		mrubyOut, err := mrubyDecode(goWire)
		if !check(c.desc+" Go→mruby", err) {
			continue
		}
		_ = mrubyOut // value check via roundtrip below

		// Full roundtrip: Go wire → mruby decode → mruby encode → same wire
		reencoded, err := mrubyRoundtrip(goWire)
		if !check(c.desc+" roundtrip", err) {
			continue
		}
		if !bytes.Equal(reencoded, wantWire) {
			fail(c.desc+" roundtrip wire",
				fmt.Sprintf("got %x want %x", reencoded, wantWire))
			continue
		}

		pass(c.desc)
	}

	// NaN separately — bit pattern equality doesn't hold for NaN != NaN
	wire, err := mrubyEncode("Float::NAN")
	if check("NaN mruby encode", err) {
		wantNaN, _ := hex.DecodeString("f97e00")
		if bytes.Equal(wire, wantNaN) {
			pass("NaN canonical f16")
		} else {
			fail("NaN canonical f16", fmt.Sprintf("got %x want f97e00", wire))
		}
	}
}

func testStringRoundtrips() {
	fmt.Println("\n── String roundtrips ────────────────────────────────────────")

	cases := []struct {
		desc string
		rb   string
		val  string
	}{
		{"empty",    `""`,          ""},
		{"hello",    `"hello"`,     "hello"},
		{"utf-8",    `"héllo"`,     "héllo"},
		{"emoji",    `"\xF0\x9F\x8E\xB2"`, "🎲"},
	}

	for _, c := range cases {
		wire, err := mrubyEncode(c.rb)
		if !check(c.desc+" mruby encode", err) {
			continue
		}

		// Go must decode it as the same string
		var got string
		if err := goDecode(wire, &got); err != nil {
			fail(c.desc+" Go decode", err.Error())
			continue
		}
		if got != c.val {
			fail(c.desc+" value", fmt.Sprintf("got %q want %q", got, c.val))
			continue
		}

		// Go encode → mruby decode roundtrip
		goWire, err := goEncode(c.val)
		if !check(c.desc+" Go encode", err) {
			continue
		}
		// Wire must be identical (both use major 3, shortest-form length)
		if !bytes.Equal(wire, goWire) {
			fail(c.desc+" wire equality",
				fmt.Sprintf("mruby %x  go %x", wire, goWire))
			continue
		}

		pass(c.desc)
	}
}

func testContainerRoundtrips() {
	fmt.Println("\n── Container roundtrips ─────────────────────────────────────")

	// Array
	{
		wire, err := mrubyEncode(`[1, 2, 3]`)
		if check("array mruby encode", err) {
			var got []int64
			if err := goDecode(wire, &got); err != nil {
				fail("array Go decode", err.Error())
			} else if len(got) != 3 || got[0] != 1 || got[1] != 2 || got[2] != 3 {
				fail("array value", fmt.Sprintf("got %v", got))
			} else {
				pass("array [1,2,3]")
			}
		}
	}

	// Map with string keys
	{
		wire, err := mrubyEncode(`{"a" => 1, "b" => 2}`)
		if check("map mruby encode", err) {
			var got map[string]int64
			if err := goDecode(wire, &got); err != nil {
				fail("map Go decode", err.Error())
			} else if got["a"] != 1 || got["b"] != 2 {
				fail("map value", fmt.Sprintf("got %v", got))
			} else {
				pass("map {a:1, b:2}")
			}
		}
	}

	// Nested structure
	{
		rb := `{"users" => [{"id" => 1, "name" => "Alice"}, {"id" => 2, "name" => "Bob"}], "count" => 2}`
		wire, err := mrubyEncode(rb)
		if check("nested mruby encode", err) {
			var got map[string]any
			if err := goDecode(wire, &got); err != nil {
				fail("nested Go decode", err.Error())
			} else {
				pass("nested map+array")
			}
		}
	}

	// Go → mruby: Go-encoded map decoded by mruby
	{
		type Point struct {
			X int `cbor:"x"`
			Y int `cbor:"y"`
		}
		goWire, err := goEncode(Point{X: 3, Y: 7})
		if check("struct Go encode", err) {
			mrubyOut, err := mrubyDecode(goWire)
			if check("struct Go→mruby", err) {
				if strings.Contains(mrubyOut, "3") && strings.Contains(mrubyOut, "7") {
					pass("struct Go→mruby")
				} else {
					fail("struct Go→mruby value", fmt.Sprintf("mruby got %s", mrubyOut))
				}
			}
		}
	}
}

func testBoolNil() {
	fmt.Println("\n── Bool / nil ───────────────────────────────────────────────")

	for _, c := range []struct {
		desc string
		rb   string
		want string
	}{
		{"true",  "true",  "f5"},
		{"false", "false", "f4"},
		{"nil",   "nil",   "f6"},
	} {
		wire, err := mrubyEncode(c.rb)
		if !check(c.desc, err) {
			continue
		}
		wantWire, _ := hex.DecodeString(c.want)
		if !bytes.Equal(wire, wantWire) {
			fail(c.desc+" wire", fmt.Sprintf("got %x want %x", wire, wantWire))
		} else {
			pass(c.desc)
		}
	}
}

func testUTF8Rejection() {
	fmt.Println("\n── Go strict decoder rejects invalid UTF-8 ─────────────────")

	// mruby encodes a binary string as major 2 (bytes).
	// The Go strict decoder must accept major 2 as bytes, not text.
	// A major 3 string with invalid UTF-8 must be rejected.
	invalidUTF8 := []byte{0x63, 0xFF, 0xFE, 0xFD} // major 3, len 3, invalid UTF-8
	var s string
	err := goDecode(invalidUTF8, &s)
	if err != nil {
		pass("Go rejects invalid UTF-8 text string")
	} else {
		fail("Go rejects invalid UTF-8 text string", "expected error, got nil")
	}
}

func testPreferredEncodingWireEquality() {
	fmt.Println("\n── Wire equality: mruby vs Go preferred encoding ────────────")

	// For values both sides can represent, wire bytes must be identical.
	// This is the core interop guarantee.
	cases := []struct {
		desc string
		rb   string
		go_  any
	}{
		{"int 0",     "0",    int64(0)},
		{"int 255",   "255",  int64(255)},
		{"int -1",    "-1",   int64(-1)},
		{"float 1.5", "1.5",  float64(1.5)},
		{"float 3.14","3.14", float64(3.14)},
		{"true",      "true", true},
		{"false",     "false",false},
		{"nil",       "nil",  nil},
		{"string",    `"hi"`, "hi"},
	}

	for _, c := range cases {
		mrubyWire, err := mrubyEncode(c.rb)
		if !check(c.desc+" mruby", err) {
			continue
		}
		goWire, err := goEncode(c.go_)
		if !check(c.desc+" go", err) {
			continue
		}
		if bytes.Equal(mrubyWire, goWire) {
			pass(c.desc)
		} else {
			fail(c.desc, fmt.Sprintf("mruby %x  go %x", mrubyWire, goWire))
		}
	}
}

// ── main ──────────────────────────────────────────────────────────────────────

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "Usage: %s <path-to-mruby-binary>\n", os.Args[0])
		os.Exit(1)
	}
	mrubyBin = os.Args[1]

	fmt.Println("=" + strings.Repeat("=", 59))
	fmt.Println("CBOR Interop Test: mruby-cbor vs fxamacker/cbor (Go)")
	fmt.Println("=" + strings.Repeat("=", 59))

	testBoolNil()
	testIntegerRoundtrips()
	testFloatRoundtrips()
	testStringRoundtrips()
	testContainerRoundtrips()
	testUTF8Rejection()
	testPreferredEncodingWireEquality()

	fmt.Println("\n" + strings.Repeat("=", 60))
	if failures == 0 {
		fmt.Printf("✓ All %d checks passed.\n", len(results))
	} else {
		fmt.Printf("✗ %d/%d checks failed.\n", failures, len(results))
	}
	fmt.Println(strings.Repeat("=", 60))

	if failures > 0 {
		os.Exit(1)
	}
}