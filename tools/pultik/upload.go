package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"sync/atomic"
	"time"
)

// Upload bounds. An upload has no overall deadline: a 260 MB APK over a slow
// uplink legitimately outlasts any fixed one, and a retry restarts from zero,
// so a whole-upload timeout only throws away a slow upload that was still
// moving. Two narrower bounds catch a dead upload instead. They are variables
// so the tests can shrink them.
var (
	// uploadStallLimit fails an upload whose body has not moved for this long.
	uploadStallLimit = 60 * time.Second
	// uploadHeaderLimit is the transport's ResponseHeaderTimeout, the wait for
	// the server's answer. net/http starts it only once the body is written,
	// on HTTP/1.1 and HTTP/2 alike, so it never runs while bytes go out.
	uploadHeaderLimit = 5 * time.Minute
	// uploadProgressEvery paces the progress line; a shorter upload prints none.
	uploadProgressEvery = 5 * time.Second
	// progressOut is stderr, never uiOut: under --json stdout carries the
	// result object alone.
	progressOut io.Writer = os.Stderr
)

// errUploadStalled marks an upload the stall watchdog cancelled.
var errUploadStalled = errors.New("upload stalled")

// uploadMeter counts the bytes the transport pulls out of a request body. The
// transport pulls only as fast as the connection takes them, so a meter that
// stops moving is a connection that stopped moving.
type uploadMeter struct {
	total int64 // the request's ContentLength; 0 or less when unknown
	start time.Time
	sent  atomic.Int64
	moved atomic.Int64 // UnixNano of the last read that returned bytes
	eof   atomic.Bool
}

func newUploadMeter(total int64) *uploadMeter {
	m := &uploadMeter{total: total, start: time.Now()}
	m.moved.Store(m.start.UnixNano())
	return m
}

func (m *uploadMeter) wrap(body io.ReadCloser) io.ReadCloser {
	return &meteredBody{ReadCloser: body, meter: m}
}

// restart counts a resent body from zero.
func (m *uploadMeter) restart() {
	m.sent.Store(0)
	m.eof.Store(false)
	m.moved.Store(time.Now().UnixNano())
}

// finished reports whether the whole body has been handed to the transport.
func (m *uploadMeter) finished() bool {
	return m.eof.Load() || (m.total > 0 && m.sent.Load() >= m.total)
}

// watch prints progress to progressOut and cancels the upload with
// errUploadStalled once the body has not moved for uploadStallLimit. It
// returns when stop closes or the body is fully sent: from there the
// transport's ResponseHeaderTimeout owns the wait.
func (m *uploadMeter) watch(stop <-chan struct{}, cancel context.CancelCauseFunc) {
	ticker := time.NewTicker(min(uploadStallLimit/4, time.Second))
	defer ticker.Stop()
	lastPrint, lastSent, printed := m.start, int64(0), false
	for {
		select {
		case <-stop:
			return
		case now := <-ticker.C:
			if m.finished() {
				if printed {
					fmt.Fprintf(progressOut, "%s  ↑ %s sent in %s, waiting for the server%s\n",
						dim, m.sentLabel(m.sent.Load()), now.Sub(m.start).Round(time.Second), reset)
				}
				return
			}
			if now.Sub(time.Unix(0, m.moved.Load())) >= uploadStallLimit {
				sent := m.sent.Load()
				average := float64(sent) / now.Sub(m.start).Seconds()
				cancel(fmt.Errorf("%w: no bytes moved for %s, %s sent at %s average",
					errUploadStalled, uploadStallLimit, m.sentLabel(sent), rateLabel(average)))
				return
			}
			if now.Sub(lastPrint) >= uploadProgressEvery {
				// The rate since the last line, not since the start: it is the
				// uplink as it is now, so it also drives the time left.
				sent := m.sent.Load()
				rate := float64(sent-lastSent) / now.Sub(lastPrint).Seconds()
				fmt.Fprintf(progressOut, "%s  ↑ %s%s\n", dim, m.progressLabel(sent, rate), reset)
				lastPrint, lastSent, printed = now, sent, true
			}
		}
	}
}

const bytesPerMB = 1 << 20

func (m *uploadMeter) sentLabel(sent int64) string {
	if m.total > 0 {
		return fmt.Sprintf("%.1f of %.1f MB", float64(sent)/bytesPerMB, float64(m.total)/bytesPerMB)
	}
	return fmt.Sprintf("%.1f MB", float64(sent)/bytesPerMB)
}

// rateLabel prints a rate given in bytes per second.
func rateLabel(rate float64) string {
	return fmt.Sprintf("%.2f MB/s", rate/bytesPerMB)
}

func (m *uploadMeter) progressLabel(sent int64, rate float64) string {
	label := m.sentLabel(sent) + " · " + rateLabel(rate)
	if rate > 0 && m.total > sent {
		left := time.Duration(float64(m.total-sent) / rate * float64(time.Second))
		label += " · " + left.Round(time.Second).String() + " left"
	}
	return label
}

// meteredBody is a request body that feeds its meter.
type meteredBody struct {
	io.ReadCloser
	meter *uploadMeter
}

func (b *meteredBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	if n > 0 {
		b.meter.sent.Add(int64(n))
		b.meter.moved.Store(time.Now().UnixNano())
	}
	if errors.Is(err, io.EOF) {
		b.meter.eof.Store(true)
	}
	return n, err
}
