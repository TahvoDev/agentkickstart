// Command agentbox-gate is the permanent TLS front door for an agentbox.
//
// While the box is unclaimed it serves the one-time browser claim UI. Once the
// box is claimed it reverse-proxies the local Agent Vault UI/API, so the whole
// management surface is reachable over one HTTPS origin (no mixed content).
//
// It also has a --qr subcommand that renders a URL as a QR code on the text
// console, used by `agentbox setup`.
//
// Everything the gate needs is on the shared filesystem (a few markers and the
// current one-time code); it holds no state of its own beyond an in-memory cert
// and a small per-IP backoff map.
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io/fs"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"rsc.io/qr"
)

const version = "0.1.0"

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

var (
	runDir   = envOr("AGENTBOX_RUN_DIR", "/run/agentbox")
	libDir   = envOr("AGENTBOX_LIB_DIR", "/var/lib/agentbox")
	port     = envOr("AGENTBOX_GATE_PORT", "443")
	vaultURL = envOr("AGENTBOX_VAULT_URL", "http://127.0.0.1:14331")
)

var (
	codeFile    = filepath.Join(runDir, "setup-code")
	fpFile      = filepath.Join(runDir, "gate-fingerprint")
	claimFile   = filepath.Join(runDir, "claim.json")
	errFile     = filepath.Join(runDir, "finalize-error")
	resultFile  = filepath.Join(runDir, "finalize-result.json")
	claimedFile = filepath.Join(libDir, "claimed")
	// The checkpoint tracks finalize progress within a single claim attempt. It
	// lives on tmpfs (/run) alongside the rest of the live run state, so a reboot
	// after a partial finalize starts clean instead of resuming a stale run.
	checkpointFn = filepath.Join(runDir, "finalize-checkpoint")
)

// ---------------------------------------------------------------------------
// state helpers (all filesystem-backed, so a gate restart loses nothing)

func exists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func readTrim(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func readErr() string { return readTrim(errFile) }

func claimed() bool { return exists(claimedFile) }

func lastStep() string {
	b, err := os.ReadFile(checkpointFn)
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	return lines[len(lines)-1]
}

// readCode returns the current one-time code and its expiry. An empty expiry
// means "no TTL recorded"; a zero time means the code has expired.
func readCode() (code string, expiry time.Time, ok bool) {
	b, err := os.ReadFile(codeFile)
	if err != nil {
		return "", time.Time{}, false
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	code = strings.TrimSpace(lines[0])
	if code == "" {
		return "", time.Time{}, false
	}
	if len(lines) > 1 {
		if n, err := strconv.ParseInt(strings.TrimSpace(lines[1]), 10, 64); err == nil {
			expiry = time.Unix(n, 0)
		}
	}
	return code, expiry, true
}

// ---------------------------------------------------------------------------
// certificate

func formatFingerprint(sum []byte) string {
	parts := make([]string, len(sum))
	for i, b := range sum {
		parts[i] = strings.ToUpper(hex.EncodeToString([]byte{b}))
	}
	return strings.Join(parts, ":")
}

func isTailscale(ip net.IP) bool {
	v4 := ip.To4()
	if v4 == nil {
		return false
	}
	return v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127
}

// listenIPs are the addresses the gate binds: every global unicast local
// address except Tailscale's CGNAT range (so we don't fight tailscaled for
// :443), plus loopback for local health checks.
func listenIPs() []net.IP {
	out := []net.IP{net.ParseIP("127.0.0.1")}
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return out
	}
	for _, a := range addrs {
		n, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		ip := n.IP
		if !ip.IsGlobalUnicast() || ip.IsLoopback() || isTailscale(ip) {
			continue
		}
		out = append(out, ip)
	}
	return out
}

func genCert() (tls.Certificate, string, []net.IP, []string, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, "", nil, nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, "", nil, nil, err
	}

	host, _ := os.Hostname()
	dns := uniq([]string{"agentbox.local", "agentbox", host, host + ".local"})
	ips := listenIPs()

	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "agentbox", Organization: []string{"agentbox"}},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(2, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              dns,
		IPAddresses:           ips,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		return tls.Certificate{}, "", nil, nil, err
	}
	sum := sha256.Sum256(der)
	leaf, _ := x509.ParseCertificate(der)
	cert := tls.Certificate{Certificate: [][]byte{der}, PrivateKey: priv, Leaf: leaf}
	return cert, formatFingerprint(sum[:]), ips, dns, nil
}

func uniq(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if s == "" || seen[s] {
			continue
		}
		seen[s] = true
		out = append(out, s)
	}
	return out
}

// ---------------------------------------------------------------------------
// per-IP exponential backoff on bad codes

type failRec struct {
	next time.Time
}

type gate struct {
	fp      string
	urlStr  string
	token   string
	proxy   *httputil.ReverseProxy
	mu      sync.Mutex
	fails   map[string]*failRec
	result  *resultData
	resOnce sync.Mutex
}

type resultData struct {
	URL             string `json:"url"`
	Email           string `json:"email"`
	DesktopPassword string `json:"desktop_password"`
	PaseoPassword   string `json:"paseo_password"`
	// RecoveryKey is the LUKS recovery key generated at install (if any).
	RecoveryKey string `json:"recovery_key,omitempty"`
}

// blocked returns how long the caller must wait, or 0.
func (g *gate) blocked(ip string) time.Duration {
	g.mu.Lock()
	defer g.mu.Unlock()
	r := g.fails[ip]
	if r == nil {
		return 0
	}
	if d := time.Until(r.next); d > 0 {
		return d
	}
	return 0
}

func (g *gate) fail(ip string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	r := g.fails[ip]
	if r == nil {
		r = &failRec{}
		g.fails[ip] = r
	}
	// Count consecutive failures by tightening the next deadline: 2s, 4s, ...
	// capped at 5 minutes.
	n := 1
	if d := time.Until(r.next); d > 0 {
		n = int(d.Seconds()/2) + 1
	}
	d := time.Duration(1<<uint(n)) * time.Second
	if d > 5*time.Minute || d <= 0 {
		d = 5 * time.Minute
	}
	r.next = time.Now().Add(d)
}

func (g *gate) reset(ip string) {
	g.mu.Lock()
	delete(g.fails, ip)
	g.mu.Unlock()
}

// ---------------------------------------------------------------------------
// HTTP

type statusResp struct {
	State       string `json:"state"`
	Step        string `json:"step,omitempty"`
	Error       string `json:"error,omitempty"`
	Fingerprint string `json:"fingerprint"`
	URL         string `json:"url"`
}

func (g *gate) status() statusResp {
	st := statusResp{State: "unclaimed", Fingerprint: g.fp, URL: g.urlStr}
	switch {
	case claimed():
		// The box is claimed. If this gate process still holds the one-time
		// success payload (fresh claim), show it; otherwise it was consumed
		// (e.g. after a reboot) and the state is simply "claimed".
		if g.getResult() != nil {
			st.State = "done"
		} else {
			st.State = "claimed"
		}
	case readErr() != "":
		st.State, st.Error = "error", readErr()
	}
	st.Step = lastStep()
	return st
}

// getResult lazily reads finalize-result.json once, caches it in memory and
// removes the file so the secrets don't linger on the (tmpfs) disk.
func (g *gate) getResult() *resultData {
	g.resOnce.Lock()
	defer g.resOnce.Unlock()
	if g.result != nil {
		return g.result
	}
	b, err := os.ReadFile(resultFile)
	if err != nil {
		return nil
	}
	var r resultData
	if json.Unmarshal(b, &r) != nil {
		return nil
	}
	g.result = &r
	os.Remove(resultFile)
	return g.result
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (g *gate) health(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	fmt.Fprintln(w, "ok")
}

func (g *gate) statusHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(g.status())
}

func (g *gate) successHandler(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie("abclaim"); err != nil || subtle.ConstantTimeCompare([]byte(c.Value), []byte(g.token)) != 1 {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	res := g.getResult()
	if res == nil {
		http.Error(w, "not ready", http.StatusConflict)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(res)
}

type claimReq struct {
	Code      string `json:"code"`
	Email     string `json:"email"`
	Password  string `json:"password"`
	Password2 string `json:"password2"`
}

func (g *gate) claimHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if claimed() {
		http.Error(w, "already claimed", http.StatusConflict)
		return
	}
	ip := clientIP(r)
	if d := g.blocked(ip); d > 0 {
		w.Header().Set("Retry-After", strconv.Itoa(int(d.Seconds())+1))
		http.Error(w, fmt.Sprintf("too many bad codes; try again in %ds", int(d.Seconds())+1), http.StatusTooManyRequests)
		return
	}

	var req claimReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	// Password policy is checked here so a malformed claim fails before we
	// touch the filesystem and triggers finalize.
	if len(req.Password) < 8 {
		http.Error(w, "password must be at least 8 characters", http.StatusBadRequest)
		return
	}
	if req.Password != req.Password2 {
		http.Error(w, "passwords do not match", http.StatusBadRequest)
		return
	}
	req.Email = strings.TrimSpace(req.Email)
	if req.Email == "" {
		req.Email = "owner@agentbox.local"
	}

	code, expiry, ok := readCode()
	if !ok {
		http.Error(w, "the box is not ready for a claim yet", http.StatusServiceUnavailable)
		return
	}
	if !expiry.IsZero() && time.Now().After(expiry) {
		http.Error(w, "the one-time code has expired; run 'agentbox setup-code' on the console", http.StatusForbidden)
		return
	}
	if subtle.ConstantTimeCompare([]byte(req.Code), []byte(code)) != 1 {
		g.fail(ip)
		http.Error(w, "wrong one-time code", http.StatusForbidden)
		return
	}
	g.reset(ip)

	payload, _ := json.Marshal(map[string]any{
		"email":    req.Email,
		"password": req.Password,
		"ts":       time.Now().Unix(),
	})
	if err := writeClaim(payload); err != nil {
		if errors.Is(err, fs.ErrExist) {
			http.Error(w, "a claim is already in progress", http.StatusConflict)
			return
		}
		log.Printf("writing claim: %v", err)
		http.Error(w, "could not record the claim", http.StatusInternalServerError)
		return
	}
	// A fresh attempt clears any stale finalize error/result.
	os.Remove(errFile)
	os.Remove(resultFile)

	// The claim cookie is only ever issued in response to a successful claim, so
	// /success can't be read before the claim actually happened. HttpOnly: the
	// page's JS never needs to read it.
	http.SetCookie(w, &http.Cookie{
		Name:     "abclaim",
		Value:    g.token,
		Path:     "/",
		Secure:   true,
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
	})
	w.WriteHeader(http.StatusAccepted)
	fmt.Fprintln(w, "accepted")
}

// writeClaim creates claim.json with O_EXCL. On a retry after a failed finalize
// the caller has already cleared the error file, so we remove the stale claim
// and recreate it.
func writeClaim(payload []byte) error {
	f, err := os.OpenFile(claimFile, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if errors.Is(err, fs.ErrExist) && readErr() != "" {
		os.Remove(claimFile)
		f, err = os.OpenFile(claimFile, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	}
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(payload)
	return err
}

func (g *gate) rootHandler(w http.ResponseWriter, r *http.Request) {
	if claimed() {
		g.proxy.ServeHTTP(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	page := strings.ReplaceAll(claimPage, "{{FP}}", html.EscapeString(g.fp))
	fmt.Fprint(w, page)
}

func (g *gate) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", g.health)
	mux.HandleFunc("/status", g.statusHandler)
	mux.HandleFunc("/success", g.successHandler)
	mux.HandleFunc("/claim", g.claimHandler)
	mux.HandleFunc("/", g.rootHandler)
	return mux
}

// ---------------------------------------------------------------------------
// serve

func gateURL() string {
	ips := listenIPs()
	host := "127.0.0.1"
	for _, ip := range ips {
		if ip.To4() != nil && !ip.IsLoopback() {
			host = ip.String()
			break
		}
	}
	if port == "443" {
		return "https://" + host + "/"
	}
	return "https://" + net.JoinHostPort(host, port) + "/"
}

func serve() error {
	log.SetPrefix("agentbox-gate: ")
	if err := os.MkdirAll(runDir, 0o770); err != nil {
		return err
	}

	cert, fp, ips, dns, err := genCert()
	if err != nil {
		return fmt.Errorf("generating certificate: %w", err)
	}
	if err := os.WriteFile(fpFile, []byte(fp+"\n"), 0o644); err != nil {
		log.Printf("writing fingerprint: %v", err)
	}
	log.Printf("cert SHA256 %s", fp)
	log.Printf("SANs: %s %v", strings.Join(dns, " "), ips)

	tokenBytes := make([]byte, 16)
	rand.Read(tokenBytes)
	g := &gate{
		fp:     fp,
		urlStr: gateURL(),
		token:  hex.EncodeToString(tokenBytes),
		fails:  map[string]*failRec{},
	}

	u, err := url.Parse(vaultURL)
	if err != nil {
		return err
	}
	proxy := httputil.NewSingleHostReverseProxy(u)
	proxy.FlushInterval = 100 * time.Millisecond
	director := proxy.Director
	proxy.Director = func(r *http.Request) {
		director(r)
		r.Host = u.Host
		// Drop any client-supplied X-Forwarded-* so a caller can't spoof its
		// origin/proto to the vault; set only what we actually know.
		for _, h := range []string{"X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto"} {
			r.Header.Del(h)
		}
		r.Header.Set("X-Forwarded-Proto", "https")
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("vault proxy: %v", err)
		http.Error(w, "the vault isn't answering yet — retrying is safe", http.StatusBadGateway)
	}
	g.proxy = proxy

	tlsCfg := &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}
	addrs := uniqIPs(listenIPs())
	var listeners []net.Listener
	for _, ip := range addrs {
		ln, err := net.Listen("tcp", net.JoinHostPort(ip.String(), port))
		if err != nil {
			log.Printf("listen %s:%s: %v", ip, port, err)
			continue
		}
		listeners = append(listeners, tls.NewListener(ln, tlsCfg))
	}
	if len(listeners) == 0 {
		ln, err := net.Listen("tcp", ":"+port)
		if err != nil {
			return fmt.Errorf("listen :%s: %w", port, err)
		}
		listeners = append(listeners, tls.NewListener(ln, tlsCfg))
	}

	srv := &http.Server{Handler: g.routes(), ReadHeaderTimeout: 10 * time.Second}
	errCh := make(chan error, len(listeners))
	for _, ln := range listeners {
		go func(l net.Listener) { errCh <- srv.Serve(l) }(ln)
	}
	log.Printf("listening on :%s (%d listeners), vault=%s", port, len(listeners), vaultURL)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	select {
	case s := <-sig:
		log.Printf("got %s, shutting down", s)
		return nil
	case err := <-errCh:
		return err
	}
}

func uniqIPs(in []net.IP) []net.IP {
	seen := map[string]bool{}
	var out []net.IP
	for _, ip := range in {
		if ip == nil || seen[ip.String()] {
			continue
		}
		seen[ip.String()] = true
		out = append(out, ip)
	}
	return out
}

// ---------------------------------------------------------------------------
// QR

func renderQR(c *qr.Code, quiet int) string {
	n := c.Size
	total := n + 2*quiet
	var b strings.Builder
	mod := func(x, y int) bool {
		if x < 0 || y < 0 || x >= n || y >= n {
			return false
		}
		return c.Black(x, y)
	}
	for y := 0; y < total; y += 2 {
		for x := 0; x < total; x++ {
			fg := 37 // white foreground (light top module)
			if mod(x-quiet, y-quiet) {
				fg = 30 // black foreground (dark top module)
			}
			bg := 47 // white background (light bottom module)
			if mod(x-quiet, y+1-quiet) {
				bg = 40 // black background (dark bottom module)
			}
			fmt.Fprintf(&b, "\x1b[%d;%dm▀", fg, bg)
		}
		b.WriteString("\x1b[0m\n")
	}
	return b.String()
}

func qrEncode(text string) (*qr.Code, error) {
	return qr.Encode(text, qr.M)
}

func qrCmd(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: agentbox-gate --qr <url> | --qr-png <url> <file>")
		return 2
	}
	if args[0] == "--qr-png" {
		if len(args) < 3 {
			fmt.Fprintln(os.Stderr, "usage: agentbox-gate --qr-png <url> <file>")
			return 2
		}
		c, err := qrEncode(args[1])
		if err != nil {
			fmt.Fprintf(os.Stderr, "agentbox-gate: %v\n", err)
			return 1
		}
		if err := os.WriteFile(args[2], c.PNG(), 0o644); err != nil {
			fmt.Fprintf(os.Stderr, "agentbox-gate: %v\n", err)
			return 1
		}
		return 0
	}
	c, err := qrEncode(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "agentbox-gate: %v\n", err)
		return 1
	}
	fmt.Print(renderQR(c, 4))
	return 0
}

func usage() {
	fmt.Fprint(os.Stderr, `agentbox-gate - TLS claim UI + Agent Vault reverse proxy

  agentbox-gate                       run the gate (TLS on :443)
  agentbox-gate --qr <url>            render <url> as a QR code on the terminal
  agentbox-gate --qr-png <url> <file> write <url> as a PNG QR code
  agentbox-gate --version             print version

Environment: AGENTBOX_RUN_DIR, AGENTBOX_LIB_DIR, AGENTBOX_GATE_PORT,
             AGENTBOX_VAULT_URL
`)
}

func main() {
	log.SetFlags(0)
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--qr":
			os.Exit(qrCmd(os.Args[2:]))
		case "--qr-png":
			os.Exit(qrCmd(os.Args[1:]))
		case "--version":
			fmt.Println(version)
		case "-h", "--help":
			usage()
		default:
			fmt.Fprintf(os.Stderr, "unknown argument: %s\n", os.Args[1])
			usage()
			os.Exit(2)
		}
		return
	}
	if err := serve(); err != nil {
		log.Fatal(err)
	}
}
