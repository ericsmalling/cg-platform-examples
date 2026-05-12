// Package main implements cgr-oidc-proxy: a small reverse proxy in front of
// cgr.dev that authenticates outbound requests with a short-lived Chainguard
// registry token derived from a projected k8s ServiceAccount JWT.
//
// Inbound callers (Harbor's proxy-cache, kubelet via containerd mirror)
// connect with no credentials. The proxy reads the SA JWT from a token-file,
// exchanges it at Chainguard's STS for a Chainguard registry bearer, caches
// the result with TTL, and refreshes ~60s before expiry. The outbound HTTP
// transport uses go-containerregistry's transport.New, which performs the
// per-scope WWW-Authenticate Bearer challenge dance against cgr.dev.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"math"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"chainguard.dev/sdk/sts"
	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	"github.com/google/go-containerregistry/pkg/v1/remote/transport"
)

const (
	// Chainguard's STS issuer and the audience cgr.dev expects.
	stsIssuer    = "https://issuer.enforce.dev"
	stsAudience  = "cgr.dev"
	upstreamHost = "cgr.dev"

	// refreshLead is how far ahead of expiry to proactively refresh.
	refreshLead = 60 * time.Second
	// minRefresh is a floor on how often we refresh to avoid hammering STS
	// if the issuer hands back tokens with very short expiry.
	minRefresh = 30 * time.Second

	// Inbound HTTP bounds. The proxy is read-only (proxies /v2/* to cgr.dev),
	// so callers shouldn't send bodies. Headers fit well under 16 KiB in
	// practice; the caps below tolerate unusual but legitimate Accept lists.
	maxHeaderBytes = 32 * 1024
	maxBodyBytes   = 64 * 1024
	writeTimeout   = 60 * time.Second
	idleTimeout    = 60 * time.Second
)

// verboseErrors, when true, logs raw underlying error strings. Off by
// default — error class is always logged via classifyErr, but the raw
// SDK error may carry sensitive bytes from the failing request/response.
var verboseErrors bool

func main() {
	var (
		listen    string
		tokenFile string
		identity  string
	)
	flag.StringVar(&listen, "listen", ":5000", "address to listen on")
	flag.StringVar(&tokenFile, "token-file", "/var/run/secrets/cgr/token", "path to projected SA JWT")
	flag.StringVar(&identity, "identity", os.Getenv("CGR_IDENTITY"), "Chainguard identity UIDP to assume (env CGR_IDENTITY)")
	flag.BoolVar(&verboseErrors, "verbose-errors", false, "log raw error strings (may include sensitive content from SDK errors); off by default")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	if identity == "" {
		logger.Error("missing required --identity flag (or CGR_IDENTITY env)")
		os.Exit(2)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()

	auth := newCgrAuthenticator(tokenFile, identity)

	// Kick the first exchange synchronously so /healthz turns green ASAP and
	// callers don't see a slow first request. A failure here is non-fatal —
	// the background refresher will retry.
	if _, err := auth.token(ctx); err != nil {
		logger.Warn("initial token exchange failed; will retry", "class", classifyErr(err), "err", redact(err))
	}

	go auth.run(ctx)

	rp, err := newReverseProxy(auth, logger)
	if err != nil {
		logger.Error("building reverse proxy", "class", classifyErr(err), "err", redact(err))
		os.Exit(1)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if auth.healthy() {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("ok"))
			return
		}
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte("no valid token"))
	})
	mux.Handle("/", rp)

	// Per-request access logging + panic recovery + inbound body cap.
	handler := accessLog(logger, http.MaxBytesHandler(mux, maxBodyBytes))

	srv := &http.Server{
		Addr:              listen,
		Handler:           handler,
		ReadHeaderTimeout: 15 * time.Second,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
		MaxHeaderBytes:    maxHeaderBytes,
	}

	go func() {
		logger.Info("cgr-oidc-proxy listening",
			"addr", listen,
			"identity_prefix", identityPrefix(identity))
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server error", "class", classifyErr(err), "err", redact(err))
		}
	}()

	<-ctx.Done()
	logger.Info("shutting down")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()
	_ = srv.Shutdown(shutdownCtx)
}

// accessLog wraps an http.Handler to emit one structured INFO record per
// request: method, path, status, duration, and remote addr (host only).
// Also catches handler panics so a misbehaving downstream doesn't take down
// the server.
func accessLog(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		defer func() {
			if p := recover(); p != nil {
				logger.Error("handler panic",
					"path", r.URL.Path,
					"method", r.Method,
					"panic", fmt.Sprint(p),
					"stack", string(debug.Stack()))
				if !rec.wroteHeader {
					http.Error(rec.ResponseWriter, "internal error", http.StatusInternalServerError)
				}
				rec.status = http.StatusInternalServerError
			}
			remote := r.RemoteAddr
			if host, _, err := net.SplitHostPort(remote); err == nil {
				remote = host
			}
			logger.Info("request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", rec.status,
				"duration_ms", time.Since(start).Milliseconds(),
				"remote", remote)
		}()
		next.ServeHTTP(rec, r)
	})
}

// statusRecorder captures the response status code for the access log.
// http.MaxBytesHandler wraps the writer, so we sit outside that — every
// WriteHeader call passes through us first.
type statusRecorder struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (r *statusRecorder) WriteHeader(s int) {
	if r.wroteHeader {
		return
	}
	r.wroteHeader = true
	r.status = s
	r.ResponseWriter.WriteHeader(s)
}

// newReverseProxy builds a single-host reverse proxy targeting cgr.dev. The
// Transport is a lazy wrapper around go-containerregistry's transport.New —
// constructing transport.New eagerly would fail and crash the process if the
// SA token isn't readable yet (kubelet briefly lags pod start), so we defer
// it to the first request and rebuild on each failure.
func newReverseProxy(auth *cgrAuthenticator, logger *slog.Logger) (http.Handler, error) {
	target, _ := url.Parse("https://" + upstreamHost)

	rt, err := newLazyTransport(auth, logger)
	if err != nil {
		return nil, err
	}

	rp := httputil.NewSingleHostReverseProxy(target)
	rp.Transport = rt
	defaultDirector := rp.Director
	rp.Director = func(req *http.Request) {
		defaultDirector(req)
		// SingleHostReverseProxy preserves the inbound Host by default; rewrite
		// it so cgr.dev's vhosting and TLS SNI work.
		req.Host = upstreamHost
		// Strip any inbound credential so caller creds never leak upstream.
		req.Header.Del("Authorization")
	}
	rp.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		// Verbose details stay in the proxy's logs. Clients only see a
		// generic message — upstream errors can carry header values or
		// auth-realm internals that we don't want to echo back.
		logger.Error("proxy error",
			"path", r.URL.Path,
			"class", classifyErr(err),
			"err", redact(err))
		http.Error(w, "upstream error", http.StatusBadGateway)
	}
	return rp, nil
}

// lazyTransport wraps go-containerregistry's transport.New so that the
// initial /v2/ ping (which calls Authorization() once) is deferred until
// the first inbound request — and retried on subsequent requests if it
// fails. The successful transport is cached in an atomic pointer for a
// lock-free fast path; the cold-build path is mutex-guarded so concurrent
// first-callers dedupe rather than racing to build redundantly.
type lazyTransport struct {
	auth   *cgrAuthenticator
	logger *slog.Logger
	reg    name.Registry

	rt atomic.Pointer[http.RoundTripper]
	mu sync.Mutex // guards the cold-build path only
}

func newLazyTransport(auth *cgrAuthenticator, logger *slog.Logger) (*lazyTransport, error) {
	reg, err := name.NewRegistry(upstreamHost)
	if err != nil {
		return nil, fmt.Errorf("registry: %w", err)
	}
	return &lazyTransport{auth: auth, logger: logger, reg: reg}, nil
}

func (l *lazyTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	rt, err := l.get()
	if err != nil {
		return nil, fmt.Errorf("auth transport not ready: %w", err)
	}
	return rt.RoundTrip(req)
}

func (l *lazyTransport) get() (http.RoundTripper, error) {
	// Fast path: once built, lock-free read.
	if rt := l.rt.Load(); rt != nil {
		return *rt, nil
	}
	// Slow path: dedupe concurrent first callers under the lock.
	l.mu.Lock()
	defer l.mu.Unlock()
	if rt := l.rt.Load(); rt != nil {
		return *rt, nil
	}
	rt, err := transport.New(l.reg, l.auth, http.DefaultTransport, nil)
	if err != nil {
		return nil, err
	}
	l.rt.Store(&rt)
	return rt, nil
}

// cgrAuthenticator implements authn.Authenticator. It reads a projected SA JWT
// from disk on every refresh (kubelet rotates the file in place), exchanges
// it at Chainguard's STS, and caches the resulting Chainguard registry token.
type cgrAuthenticator struct {
	tokenFile string
	identity  string
	exch      sts.Exchanger
	logger    *slog.Logger

	mu      sync.RWMutex
	cached  string    // Chainguard registry token (NOT the SA JWT).
	expires time.Time // wall-clock expiry of the cached token.
}

func newCgrAuthenticator(tokenFile, identity string) *cgrAuthenticator {
	return &cgrAuthenticator{
		tokenFile: tokenFile,
		identity:  identity,
		exch:      sts.New(stsIssuer, stsAudience, sts.WithIdentity(identity)),
		logger:    slog.Default(),
	}
}

// Authorization implements authn.Authenticator. go-containerregistry's
// transport.New uses this credential as basic-auth in its Bearer challenge.
// cgr.dev accepts username "_token" with the Chainguard token as password,
// matching the convention used by chainguard.dev/sdk/auth/ggcr.
func (a *cgrAuthenticator) Authorization() (*authn.AuthConfig, error) {
	tok, err := a.token(context.Background())
	if err != nil {
		return nil, err
	}
	return &authn.AuthConfig{Username: "_token", Password: tok}, nil
}

// token returns a valid cached Chainguard token, refreshing if necessary.
func (a *cgrAuthenticator) token(ctx context.Context) (string, error) {
	a.mu.RLock()
	if a.cached != "" && time.Now().Before(a.expires.Add(-refreshLead)) {
		t := a.cached
		a.mu.RUnlock()
		return t, nil
	}
	a.mu.RUnlock()
	return a.refresh(ctx)
}

// refresh performs one STS exchange and updates the cache. Callers should
// serialise via the background goroutine in steady state; this is also safe
// to call directly (e.g. from Authorization on a cold cache).
func (a *cgrAuthenticator) refresh(ctx context.Context) (string, error) {
	jwt, err := os.ReadFile(a.tokenFile)
	if err != nil {
		return "", fmt.Errorf("reading token file %q: %w", a.tokenFile, err)
	}
	pair, err := a.exch.Exchange(ctx, string(trimSpace(jwt)))
	if err != nil {
		return "", fmt.Errorf("STS exchange: %w", err)
	}
	expiry := pair.Expiry
	if expiry.IsZero() {
		// Defensive default if STS doesn't report an expiry.
		expiry = time.Now().Add(30 * time.Minute)
	}

	a.mu.Lock()
	a.cached = pair.AccessToken
	a.expires = expiry
	a.mu.Unlock()

	a.logger.Info("token refreshed",
		"identity_prefix", identityPrefix(a.identity),
		"expires_at", expiry.Format(time.RFC3339),
		"ttl_seconds", int(time.Until(expiry).Seconds()))
	return pair.AccessToken, nil
}

// run is the background refresh loop. It sleeps until ~refreshLead before the
// current token's expiry, then refreshes. On STS failure it backs off
// exponentially up to a cap and retries. Refresh runs through refreshSafely
// so an SDK panic never silently stops renewals.
func (a *cgrAuthenticator) run(ctx context.Context) {
	var attempt int
	for {
		var wait time.Duration
		a.mu.RLock()
		exp := a.expires
		hasCached := a.cached != ""
		a.mu.RUnlock()

		switch {
		case !hasCached:
			// Initial exchange failed; retry with backoff immediately.
			wait = backoff(attempt)
		default:
			wait = time.Until(exp.Add(-refreshLead))
			if wait < minRefresh {
				wait = minRefresh
			}
		}

		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}

		if err := a.refreshSafely(ctx); err != nil {
			attempt++
			a.logger.Error("token refresh failed",
				"class", classifyErr(err),
				"err", redact(err),
				"attempt", attempt,
				"next_retry", backoff(attempt).String())
			continue
		}
		attempt = 0
	}
}

// refreshSafely wraps refresh in a panic recovery so the background loop
// survives any panic from the STS SDK or downstream code paths.
func (a *cgrAuthenticator) refreshSafely(ctx context.Context) (err error) {
	defer func() {
		if p := recover(); p != nil {
			a.logger.Error("token refresh panic recovered",
				"panic", fmt.Sprint(p),
				"stack", string(debug.Stack()))
			err = fmt.Errorf("token refresh panic: %v", p)
		}
	}()
	_, err = a.refresh(ctx)
	return
}

// healthy reports whether a non-expired token is cached.
func (a *cgrAuthenticator) healthy() bool {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.cached != "" && time.Now().Before(a.expires)
}

// classifyErr returns a short, fixed-vocabulary string describing the kind
// of error. Always safe to log — never carries user data or token bytes.
func classifyErr(err error) string {
	if err == nil {
		return "none"
	}
	s := err.Error()
	switch {
	case strings.Contains(s, "STS exchange"):
		return "sts_exchange"
	case strings.Contains(s, "reading token file"):
		return "token_file_read"
	case strings.Contains(s, "auth transport not ready"):
		return "transport_not_ready"
	case strings.Contains(s, "registry:"):
		return "registry_parse"
	case strings.Contains(s, "token refresh panic"):
		return "refresh_panic"
	case errors.Is(err, context.DeadlineExceeded):
		return "deadline"
	case errors.Is(err, context.Canceled):
		return "canceled"
	default:
		return "unknown"
	}
}

// redact returns the raw error string only when --verbose-errors is on.
// Otherwise it returns a placeholder. classifyErr's class string is always
// logged separately and is safe to share.
func redact(err error) string {
	if err == nil {
		return ""
	}
	if verboseErrors {
		return err.Error()
	}
	return "(redacted; pass --verbose-errors to log raw)"
}

// identityPrefix returns the first 8 characters of a UIDP for log correlation
// without disclosing the full identifier. The UIDP itself isn't a secret, but
// reducing pre-image disclosure makes targeted reconnaissance harder.
func identityPrefix(id string) string {
	if len(id) <= 8 {
		return id
	}
	return id[:8] + "..."
}

// backoff returns an exponential backoff with a 60s ceiling.
func backoff(attempt int) time.Duration {
	if attempt < 0 {
		attempt = 0
	}
	d := time.Duration(math.Pow(2, math.Min(float64(attempt), 6))) * time.Second
	if d > 60*time.Second {
		d = 60 * time.Second
	}
	return d
}

// trimSpace strips trailing whitespace/newline from the JWT file. kubelet
// writes the projected token without a trailing newline, but be defensive.
func trimSpace(b []byte) []byte {
	for len(b) > 0 {
		c := b[len(b)-1]
		if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
			b = b[:len(b)-1]
			continue
		}
		break
	}
	for len(b) > 0 {
		c := b[0]
		if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
			b = b[1:]
			continue
		}
		break
	}
	return b
}
