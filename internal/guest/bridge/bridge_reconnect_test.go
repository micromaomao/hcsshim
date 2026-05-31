//go:build linux

package bridge

import (
	"context"
	"io"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Microsoft/hcsshim/internal/guest/prot"
)

func TestBridge_NotificationQueuedWhenDisconnected(t *testing.T) {
	b := New(nil, false)
	// Bridge starts disconnected (connected == false).
	b.publishNotification(&prot.ContainerNotification{
		MessageBase: prot.MessageBase{ContainerID: "c1"},
	})
	b.publishNotification(&prot.ContainerNotification{
		MessageBase: prot.MessageBase{ContainerID: "c2"},
	})

	b.notifyMu.Lock()
	if len(b.pendingNotifications) != 2 {
		t.Fatalf("expected 2 queued, got %d", len(b.pendingNotifications))
	}
	b.notifyMu.Unlock()
}

func TestBridge_DrainOnReconnect(t *testing.T) {
	b := New(nil, false)

	// Queue notifications while disconnected.
	b.publishNotification(&prot.ContainerNotification{
		MessageBase: prot.MessageBase{ContainerID: "c1"},
	})
	b.publishNotification(&prot.ContainerNotification{
		MessageBase: prot.MessageBase{ContainerID: "c2"},
	})

	// Simulate what ListenAndServe does: create channels, start writer,
	// then drain.
	b.responseChan = make(chan bridgeResponse, 4)

	b.drainPendingNotifications()

	// Collect drained notifications.
	var ids []string
	for i := 0; i < 2; i++ {
		select {
		case resp := <-b.responseChan:
			n := resp.response.(*prot.ContainerNotification)
			ids = append(ids, n.ContainerID)
		case <-time.After(time.Second):
			t.Fatalf("timed out waiting for notification %d", i)
		}
	}
	if len(ids) != 2 {
		t.Fatalf("expected 2 drained notifications, got %d", len(ids))
	}

	b.notifyMu.Lock()
	if len(b.pendingNotifications) != 0 {
		t.Fatalf("expected 0 pending after drain, got %d", len(b.pendingNotifications))
	}
	b.notifyMu.Unlock()
}

func TestBridge_DisconnectQueuesAfterDrain(t *testing.T) {
	b := New(nil, false)
	b.responseChan = make(chan bridgeResponse, 4)

	// Drain with nothing pending — just sets connected = true.
	b.drainPendingNotifications()

	// Send while connected — goes directly to responseChan.
	b.publishNotification(&prot.ContainerNotification{
		MessageBase: prot.MessageBase{ContainerID: "live"},
	})

	select {
	case resp := <-b.responseChan:
		n := resp.response.(*prot.ContainerNotification)
		if n.ContainerID != "live" {
			t.Fatalf("expected 'live', got %q", n.ContainerID)
		}
	default:
		t.Fatal("expected notification on responseChan")
	}

	// Disconnect — future notifications should queue.
	b.disconnectNotifications()

	b.publishNotification(&prot.ContainerNotification{
		MessageBase: prot.MessageBase{ContainerID: "queued"},
	})

	b.notifyMu.Lock()
	if len(b.pendingNotifications) != 1 {
		t.Fatalf("expected 1 queued after disconnect, got %d", len(b.pendingNotifications))
	}
	b.notifyMu.Unlock()

	// Nothing should be on responseChan.
	select {
	case <-b.responseChan:
		t.Fatal("should not have received on responseChan after disconnect")
	default:
	}
}

func TestBridge_FullReconnectCycle(t *testing.T) {
	b := New(nil, false)

	// --- Iteration 1: simulate ListenAndServe ---
	r1, w1 := io.Pipe()
	b.responseChan = make(chan bridgeResponse, 4)
	b.quitChan = make(chan bool)

	go func() {
		for range b.responseChan {
		}
	}() // drain writer

	b.drainPendingNotifications()

	// Send a notification while connected.
	b.publishNotification(&prot.ContainerNotification{
		MessageBase: prot.MessageBase{ContainerID: "iter1"},
	})

	// Simulate bridge drop — disconnect, close channels.
	b.disconnectNotifications()
	close(b.quitChan)
	close(b.responseChan)
	r1.Close()
	w1.Close()

	// --- Between iterations: container exits ---
	b.publishNotification(&prot.ContainerNotification{
		MessageBase: prot.MessageBase{ContainerID: "between"},
	})

	b.notifyMu.Lock()
	if len(b.pendingNotifications) != 1 || b.pendingNotifications[0].ContainerID != "between" {
		t.Fatalf("expected 'between' queued, got %v", b.pendingNotifications)
	}
	b.notifyMu.Unlock()

	// --- Iteration 2: reconnect ---
	b.responseChan = make(chan bridgeResponse, 4)
	b.quitChan = make(chan bool)

	b.drainPendingNotifications()

	select {
	case resp := <-b.responseChan:
		n := resp.response.(*prot.ContainerNotification)
		if n.ContainerID != "between" {
			t.Fatalf("expected 'between', got %q", n.ContainerID)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for drained notification")
	}
}

// TestBridge_ForceSequential_SerializesAcrossConnections verifies that, with
// ForceSequential enabled, a mutating request handler that is still in-flight
// from a previous connection blocks a mutating handler dispatched from a new
// (reconnected) connection. This guards against a malicious host dropping the
// vsock connection mid-request and reconnecting to run two mutating handlers
// concurrently against shared Host state, which would defeat the sequential
// confidential hardening.
func TestBridge_ForceSequential_SerializesAcrossConnections(t *testing.T) {
b := New(nil, false)
b.ForceSequential = true

started := make(chan struct{})
release := make(chan struct{})
var concurrent atomic.Int32
var maxConcurrent atomic.Int32

handleFn := func(*Request) {
n := concurrent.Add(1)
for {
old := maxConcurrent.Load()
if n <= old || maxConcurrent.CompareAndSwap(old, n) {
break
}
}
started <- struct{}{}
<-release
concurrent.Add(-1)
}

// A mutating (non-async) request type.
req := &Request{
	Context: context.Background(),
	Header:  &prot.MessageHeader{Type: prot.ComputeSystemModifySettingsV1},
}

// "Connection 1": dispatch a mutating request and wait until its handler is
// in-flight (holding b.sequentialMu).
go b.dispatchRequest(req, handleFn)
<-started

// "Connection 2" (reconnect): dispatch another mutating request while the
// first handler is still in-flight.
h2done := make(chan struct{})
go func() {
b.dispatchRequest(req, handleFn)
close(h2done)
}()

// The second handler must not start while the first holds the lock.
select {
case <-started:
t.Fatal("second handler ran concurrently with the first; cross-connection serialization defeated")
case <-time.After(200 * time.Millisecond):
}

// Let the first handler finish; the second may now proceed.
release <- struct{}{}
select {
case <-started:
case <-time.After(time.Second):
t.Fatal("second handler did not start after the first was released")
}
release <- struct{}{}

select {
case <-h2done:
case <-time.After(time.Second):
t.Fatal("second handler did not complete")
}

if got := maxConcurrent.Load(); got != 1 {
t.Fatalf("expected at most 1 concurrent handler, observed %d", got)
}
}
