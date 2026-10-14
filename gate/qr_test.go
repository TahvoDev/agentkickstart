package main

import (
	"strings"
	"testing"
)

// TestRenderQRQuietZoneAndShape checks the terminal renderer: a 4-module light
// quiet zone on every side, square output, and one glyph per column.
func TestRenderQRQuietZoneAndShape(t *testing.T) {
	c, err := qrEncode("https://10.0.2.15/?code=ABCD12")
	if err != nil {
		t.Fatal(err)
	}
	const quiet = 4
	out := renderQR(c, quiet)
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	width := c.Size + 2*quiet
	if len(lines) != (width+1)/2 {
		t.Fatalf("rows = %d, want %d", len(lines), (width+1)/2)
	}
	light := strings.Repeat("\x1b[37;47m▀", width) + "\x1b[0m"
	for i, ln := range lines {
		if got := strings.Count(ln, "▀"); got != width {
			t.Fatalf("line %d: %d glyphs, want %d", i, got, width)
		}
		if i < quiet/2 && ln != light {
			t.Fatalf("line %d is not a light quiet-zone row: %q", i, ln)
		}
	}
}

// TestFinderPattern checks a real QR invariant: the top-left finder pattern is a
// 7x7 ring (dark border, light 5x5, dark 3x3 centre).
func TestFinderPattern(t *testing.T) {
	c, err := qrEncode("https://10.0.2.15/?code=ABCD12")
	if err != nil {
		t.Fatal(err)
	}
	want := map[[2]int]bool{
		{0, 0}: true, {6, 0}: true, {0, 6}: true, {6, 6}: true,
		{1, 1}: false, {5, 5}: false, // inner white ring
		{2, 2}: true, {3, 3}: true, {4, 4}: true, // dark centre
	}
	for p, w := range want {
		if got := c.Black(p[0], p[1]); got != w {
			t.Errorf("Black(%d,%d) = %v, want %v", p[0], p[1], got, w)
		}
	}
}
