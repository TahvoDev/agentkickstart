package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func newTestGate(t *testing.T) *gate {
	t.Helper()
	runDir = t.TempDir()
	libDir = t.TempDir()
	codeFile = filepath.Join(runDir, "setup-code")
	fpFile = filepath.Join(runDir, "gate-fingerprint")
	claimFile = filepath.Join(runDir, "claim.json")
	errFile = filepath.Join(runDir, "finalize-error")
	resultFile = filepath.Join(runDir, "finalize-result.json")
	claimedFile = filepath.Join(libDir, "claimed")
	checkpointFn = filepath.Join(runDir, "finalize-checkpoint")
	return &gate{fp: "AA:BB", urlStr: "https://1.2.3.4/", token: "tok", fails: map[string]*failRec{}}
}

func writeCode(t *testing.T, code string, ttl time.Duration) {
	t.Helper()
	line := code + "\n" + strconv.FormatInt(time.Now().Add(ttl).Unix(), 10) + "\n"
	if err := os.WriteFile(codeFile, []byte(line), 0o600); err != nil {
		t.Fatal(err)
	}
}

func postClaim(g *gate, ip, body string) int {
	req := httptest.NewRequest(http.MethodPost, "/claim", strings.NewReader(body))
	req.RemoteAddr = ip + ":40000"
	rr := httptest.NewRecorder()
	g.claimHandler(rr, req)
	return rr.Code
}

func TestClaimFlow(t *testing.T) {
	g := newTestGate(t)
	writeCode(t, "ABCD12", time.Minute)

	if c := postClaim(g, "10.0.0.1", `{"code":"ABCD12","password":"short","password2":"short"}`); c != http.StatusBadRequest {
		t.Fatalf("short password: got %d, want 400", c)
	}
	if c := postClaim(g, "10.0.0.1", `{"code":"ABCD12","password":"12345678","password2":"87654321"}`); c != http.StatusBadRequest {
		t.Fatalf("mismatch: got %d, want 400", c)
	}
	if c := postClaim(g, "10.0.0.2", `{"code":"WRONG","password":"12345678","password2":"12345678"}`); c != http.StatusForbidden {
		t.Fatalf("bad code: got %d, want 403", c)
	}
	// A bad code arms the per-IP backoff.
	if c := postClaim(g, "10.0.0.2", `{"code":"ABCD12","password":"12345678","password2":"12345678"}`); c != http.StatusTooManyRequests {
		t.Fatalf("backoff: got %d, want 429", c)
	}
	if c := postClaim(g, "10.0.0.3", `{"code":"ABCD12","email":"o@x","password":"12345678","password2":"12345678"}`); c != http.StatusAccepted {
		t.Fatalf("good claim: got %d, want 202", c)
	}
	fi, err := os.Stat(claimFile)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("claim.json mode = %o, want 600", fi.Mode().Perm())
	}
	if c := postClaim(g, "10.0.0.3", `{"code":"ABCD12","password":"12345678","password2":"12345678"}`); c != http.StatusConflict {
		t.Fatalf("second claim: got %d, want 409", c)
	}
}

func TestRetryAfterError(t *testing.T) {
	g := newTestGate(t)
	writeCode(t, "ABCD12", time.Minute)
	os.WriteFile(claimFile, []byte("{}"), 0o600)
	os.WriteFile(errFile, []byte("boom"), 0o600)
	if c := postClaim(g, "10.0.0.4", `{"code":"ABCD12","password":"12345678","password2":"12345678"}`); c != http.StatusAccepted {
		t.Fatalf("retry after error: got %d, want 202", c)
	}
	if _, err := os.Stat(errFile); err == nil {
		t.Fatal("stale finalize-error not cleared on retry")
	}
}

func TestExpiredCode(t *testing.T) {
	g := newTestGate(t)
	writeCode(t, "ABCD12", -time.Minute)
	if c := postClaim(g, "10.0.0.5", `{"code":"ABCD12","password":"12345678","password2":"12345678"}`); c != http.StatusForbidden {
		t.Fatalf("expired code: got %d, want 403", c)
	}
}

func TestStatusStates(t *testing.T) {
	g := newTestGate(t)
	if s := g.status(); s.State != "unclaimed" {
		t.Fatalf("state = %s, want unclaimed", s.State)
	}
	os.WriteFile(errFile, []byte("kaboom"), 0o600)
	if s := g.status(); s.State != "error" || s.Error != "kaboom" {
		t.Fatalf("state = %s/%s, want error/kaboom", s.State, s.Error)
	}
	os.Remove(errFile)
	os.WriteFile(claimedFile, []byte("x"), 0o644)
	if s := g.status(); s.State != "claimed" {
		t.Fatalf("state = %s, want claimed", s.State)
	}
	os.WriteFile(resultFile, []byte(`{"url":"https://x/","email":"e"}`), 0o640)
	if s := g.status(); s.State != "done" {
		t.Fatalf("state = %s, want done", s.State)
	}
}

func TestRootDoesNotLeakClaimCookie(t *testing.T) {
	g := newTestGate(t)
	rr := httptest.NewRecorder()
	g.rootHandler(rr, httptest.NewRequest(http.MethodGet, "/", nil))
	if c := rr.Result().Cookies(); len(c) != 0 {
		t.Fatalf("pre-claim root must not set cookies, got: %v", c)
	}
}

func TestSuccessRequiresCookie(t *testing.T) {
	g := newTestGate(t)
	os.WriteFile(claimedFile, []byte("x"), 0o644)
	os.WriteFile(resultFile, []byte(`{"url":"https://x/","email":"e","desktop_password":"d","paseo_password":"p","recovery_key":"12345-67890"}`), 0o640)

	rr := httptest.NewRecorder()
	g.successHandler(rr, httptest.NewRequest(http.MethodGet, "/success", nil))
	if rr.Code != http.StatusForbidden {
		t.Fatalf("no cookie: got %d, want 403", rr.Code)
	}

	req := httptest.NewRequest(http.MethodGet, "/success", nil)
	req.AddCookie(&http.Cookie{Name: "abclaim", Value: g.token})
	rr = httptest.NewRecorder()
	g.successHandler(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("with cookie: got %d, want 200", rr.Code)
	}
	if !strings.Contains(rr.Body.String(), `"desktop_password":"d"`) {
		t.Fatalf("unexpected body: %s", rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), `"recovery_key":"12345-67890"`) {
		t.Fatalf("recovery key missing from body: %s", rr.Body.String())
	}
	if _, err := os.Stat(resultFile); err == nil {
		t.Fatal("finalize-result.json was not removed after read")
	}
}
