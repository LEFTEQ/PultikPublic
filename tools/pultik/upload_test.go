package main

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// shrinkUploadLimits scales the upload bounds down for one test and returns
// the buffer the progress lines land in.
func shrinkUploadLimits(t *testing.T, stall, header, progress time.Duration) *bytes.Buffer {
	t.Helper()
	prevStall, prevHeader, prevProgress, prevOut := uploadStallLimit, uploadHeaderLimit, uploadProgressEvery, progressOut
	var out bytes.Buffer
	uploadStallLimit, uploadHeaderLimit, uploadProgressEvery, progressOut = stall, header, progress, &out
	t.Cleanup(func() {
		uploadStallLimit, uploadHeaderLimit, uploadProgressEvery, progressOut = prevStall, prevHeader, prevProgress, prevOut
	})
	return &out
}

// pacedReader hands out at most chunk bytes per read, each after a pause:
// an uplink that is slow but never stops.
type pacedReader struct {
	left, chunk int
	pause       time.Duration
}

func (r *pacedReader) Read(p []byte) (int, error) {
	if r.left == 0 {
		return 0, io.EOF
	}
	time.Sleep(r.pause)
	n := min(len(p), r.chunk, r.left)
	clear(p[:n])
	r.left -= n
	return n, nil
}

// zeroReader is an endless body.
type zeroReader struct{}

func (zeroReader) Read(p []byte) (int, error) {
	clear(p)
	return len(p), nil
}

func TestUploadSlowButSteadySucceeds(t *testing.T) {
	// The whole upload outlasts both bounds; no single pause reaches the stall bound.
	out := shrinkUploadLimits(t, 300*time.Millisecond, 300*time.Millisecond, 100*time.Millisecond)
	const size = 256 << 10
	received := make(chan int64, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n, _ := io.Copy(io.Discard, r.Body)
		received <- n
		w.WriteHeader(http.StatusCreated)
	}))
	defer server.Close()
	req, err := http.NewRequest(http.MethodPut, server.URL, &pacedReader{left: size, chunk: 32 << 10, pause: 80 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	req.ContentLength = size
	start := time.Now()
	if err := doUpload(req); err != nil {
		t.Fatalf("slow upload failed after %s: %v", time.Since(start), err)
	}
	if elapsed := time.Since(start); elapsed < uploadStallLimit {
		t.Fatalf("upload took %s, too fast to prove there is no overall deadline", elapsed)
	}
	if n := <-received; n != size {
		t.Fatalf("server received %d bytes, want %d", n, size)
	}
	if progress := out.String(); !strings.Contains(progress, "MB/s") || !strings.Contains(progress, "left") {
		t.Fatalf("no progress line on progressOut: %q", progress)
	}
}

func TestUploadStalledFailsWithTheStallError(t *testing.T) {
	shrinkUploadLimits(t, 300*time.Millisecond, 10*time.Second, time.Minute)
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// The uplink dies after a kilobyte: the server stops reading.
		_, _ = io.CopyN(io.Discard, r.Body, 1<<10)
		<-release
	}))
	defer server.Close()
	defer close(release)
	// Far more than both loopback socket buffers hold, so the client has to block.
	const size = 64 << 20
	req, err := http.NewRequest(http.MethodPut, server.URL, io.LimitReader(zeroReader{}, size))
	if err != nil {
		t.Fatal(err)
	}
	req.ContentLength = size
	start := time.Now()
	err = doUpload(req)
	if !errors.Is(err, errUploadStalled) {
		t.Fatalf("err = %v, want the stall error", err)
	}
	if !strings.Contains(err.Error(), "of 64.0 MB sent at") || !strings.Contains(err.Error(), "MB/s") {
		t.Fatalf("stall error names neither MB sent nor rate: %v", err)
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("stall took %s to surface", elapsed)
	}
}

func TestUploadServerThatNeverAnswersHitsTheHeaderTimeout(t *testing.T) {
	shrinkUploadLimits(t, 10*time.Second, 300*time.Millisecond, time.Minute)
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		<-release
	}))
	defer server.Close()
	defer close(release)
	req, err := http.NewRequest(http.MethodPut, server.URL, strings.NewReader("fixture artifact"))
	if err != nil {
		t.Fatal(err)
	}
	err = doUpload(req)
	if err == nil || errors.Is(err, errUploadStalled) {
		t.Fatalf("err = %v, want the header timeout", err)
	}
	if !strings.Contains(err.Error(), "timeout awaiting response headers") || !strings.Contains(err.Error(), "did not answer within 300ms") {
		t.Fatalf("err = %v, want the header timeout after the whole body", err)
	}
}
