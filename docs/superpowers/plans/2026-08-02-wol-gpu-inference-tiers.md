# Tiers 1–2 — Wake-on-LAN GPU Inference Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve large models from two suspended Debian GPU boxes, waking them on demand, behind the same Traefik ingress the rest of the homelab uses.

**Architecture:** A single Go binary (`wakegw`) on tau-ceti acts as both wake emitter and reverse proxy. Traefik `Endpoints` point at tau-ceti; `wakegw` health-checks the target box, sends a WoL magic packet if it is asleep, waits for ollama to answer, then proxies. Each Debian box suspends itself on idle via its own systemd timer — tau-ceti only ever wakes, never sleeps them.

**Tech Stack:** Go 1.24, systemd, `etherwake`, ollama on Debian (CUDA for the 1070 Ti, Vulkan/oneAPI for the Arc A750), Traefik `Endpoints` + `Ingress`, cert-manager.

**Spec:** `docs/superpowers/specs/2026-08-02-tiered-local-llm-design.md`

**Prerequisite:** `docs/superpowers/plans/2026-08-02-tier0-ollama-remediation.md` must be complete. This plan assumes Tier 0 serves FIM and does not touch it.

## Design revision vs the spec — read before starting

The spec described **two** components: a wake-proxy running in-cluster, and a separate wake emitter on tau-ceti. Mapping the files revealed that the in-cluster half is not worth its cost:

- This repo has **zero** custom-built images. Every workload pulls from a public registry. A Go service in-cluster would be the first, and would require a container build, a Gitea container-registry credential, an image pull secret, and a `.gitea/workflows/` CI pipeline — none of which exist today (`.gitea/workflows/` is absent; the Gitea registry endpoint returns 401, i.e. present but unconfigured).
- tau-ceti is **already** a required hop, is always on, and sits on both the home LAN (`192.168.1.119` on `vmbr2`) and can reach the cluster. Merging the proxy into the emitter costs one extra systemd service on a host that is getting one anyway.

**Revision:** `wakegw` runs only on tau-ceti and does both jobs. This removes three net-new patterns from the repo. The dependency chain shortens from five hops to four:

```
client → Traefik → wakegw (tau-ceti) → gaming PC
```

The accepted cost is unchanged from the spec: Proxmox host config is not GitOps-managed. Mitigation is the same — source and unit file live in `proxmox/wakegw/` in this repo, with a documented install procedure.

If you disagree with this revision, stop and rewrite the plan; do not partially apply it.

## Global Constraints

- Go 1.24 (verified locally as `go1.24.4`).
- `wakegw` listens on tau-ceti. One port per tier: **18434** → Tier 1 (A750), **18435** → Tier 2 (1070 Ti).
- Wake wait cap is **20s**. The boxes suspend rather than power off, so wake is ~3–5s. Exceeding the cap returns `503` with `Retry-After: 30` — never a hang.
- Boxes suspend **themselves** on idle. `wakegw` has no credentials on them and never issues a sleep command.
- OpenClaw MUST be pointed at ollama's native `/api/chat`, **not** `/v1`. The `/v1` streaming path does not correctly emit `tool_calls` delta chunks.
- Tier 1 (A750, 8 GB VRAM) models must fit in 8 GB: `qwen3:8b` Q4 (~5.2 GB) or `gemma3n:e4b` (~7.5 GB). **A 14B Q4 is ~9 GB and must not be placed here** — it would spill to system RAM and lose the bandwidth advantage that justifies the tier.
- Tier 2 (1070 Ti, 32 GB system RAM) runs `qwen3-coder:30b-a3b-q4_K_M` (19 GB) with expert offload.
- External-ingress resources follow the existing `vaultwarden.yaml` shape: headless `Service` + hard-coded `Endpoints` + `Ingress` with `cert-manager.io/cluster-issuer: cert-issuer` and the `websecure` entrypoint.
- All resources carry `app.kubernetes.io/name` and `app.kubernetes.io/part-of: external-ingress`.

## Values to fill in before starting

These are unknown at planning time. Substitute them everywhere they appear; do not leave the literal placeholders in any committed file.

| Placeholder | Meaning | How to obtain |
|---|---|---|
| `PC_A_IP` | 1070 Ti box (Tier 2) IPv4 | `ip -4 addr show` on the box |
| `PC_A_MAC` | 1070 Ti box NIC MAC | `ip link show` on the box |
| `PC_B_IP` | Arc A750 box (Tier 1) IPv4 | `ip -4 addr show` on the box |
| `PC_B_MAC` | Arc A750 box NIC MAC | `ip link show` on the box |

Assign both boxes **static DHCP reservations** before starting. `wakegw` targets a fixed IP; a lease change silently breaks health checks.

## File Structure

| File | Responsibility |
|---|---|
| `proxmox/wakegw/config.go` | Target definition and env parsing. No I/O. |
| `proxmox/wakegw/gateway.go` | Health check, wake-and-wait, reverse proxy. Dependencies injected for testing. |
| `proxmox/wakegw/gateway_test.go` | Unit tests for gateway logic. |
| `proxmox/wakegw/main.go` | Wiring: parse env, build gateways, serve. |
| `proxmox/wakegw/wakegw.service` | systemd unit for tau-ceti. |
| `proxmox/wakegw/README.md` | Install + troubleshooting runbook. |
| `proxmox/wakegw/autosuspend` | Idle-suspend script deployed to each Debian box. |
| `apps/external-ingress/manifests/ollama-tiers.yaml` | Service + Endpoints + Ingress for both tiers. |

---

### Task 1: `wakegw` core logic, test-first

**Files:**
- Create: `proxmox/wakegw/config.go`
- Create: `proxmox/wakegw/gateway.go`
- Test: `proxmox/wakegw/gateway_test.go`

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `type Target struct { Name, MAC, Upstream, Iface string; WaitCap time.Duration }`
  - `type Waker func(mac, iface string) error`
  - `type HealthCheck func(upstream string) bool`
  - `func NewGateway(t Target, wake Waker, health HealthCheck) *Gateway`
  - `func (g *Gateway) EnsureAwake() error` — returns `nil` if upstream is reachable (waking first if needed), `ErrWakeTimeout` if the cap elapsed.
  - `var ErrWakeTimeout = errors.New("...")`

  Task 2 wires these into an HTTP handler; Task 3 calls `NewGateway` from `main.go`.

- [ ] **Step 1: Initialise the module**

```bash
mkdir -p proxmox/wakegw
cd proxmox/wakegw
go mod init wakegw
go mod tidy
```

Expected: `proxmox/wakegw/go.mod` created declaring `go 1.24`.

- [ ] **Step 2: Write the failing test**

Create `proxmox/wakegw/gateway_test.go`. These four cases cover the behaviours that matter: don't wake a machine that is already awake; wake one that isn't; give up rather than hang; and don't fire a second packet while the first wake is still in progress.

```go
package main

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeBox models a suspended machine: health reports false until a magic
// packet is sent. Do NOT write health functions that flip based on a probe
// counter — a burst of concurrent callers can then race the counter past
// the threshold before any wake happens, making the test flaky.
func fakeBox() (Waker, HealthCheck, *int32) {
	var mu sync.Mutex
	var wakeCalls int32
	awake := false

	wake := func(mac, iface string) error {
		atomic.AddInt32(&wakeCalls, 1)
		mu.Lock()
		awake = true
		mu.Unlock()
		return nil
	}
	health := func(upstream string) bool {
		mu.Lock()
		defer mu.Unlock()
		return awake
	}
	return wake, health, &wakeCalls
}

func testTarget() Target {
	return Target{
		Name:     "test",
		MAC:      "aa:bb:cc:dd:ee:ff",
		Upstream: "127.0.0.1:11434",
		Iface:    "vmbr2",
		WaitCap:  200 * time.Millisecond,
	}
}

func TestEnsureAwakeSkipsWakeWhenHealthy(t *testing.T) {
	var wakeCalls int32
	wake := func(mac, iface string) error {
		atomic.AddInt32(&wakeCalls, 1)
		return nil
	}
	health := func(upstream string) bool { return true }

	g := NewGateway(testTarget(), wake, health)
	if err := g.EnsureAwake(); err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if got := atomic.LoadInt32(&wakeCalls); got != 0 {
		t.Fatalf("expected 0 wake calls for a healthy upstream, got %d", got)
	}
}

func TestEnsureAwakeWakesThenSucceeds(t *testing.T) {
	wake, health, wakeCalls := fakeBox()

	g := NewGateway(testTarget(), wake, health)
	if err := g.EnsureAwake(); err != nil {
		t.Fatalf("expected nil error after wake, got %v", err)
	}
	if got := atomic.LoadInt32(wakeCalls); got != 1 {
		t.Fatalf("expected exactly 1 wake call, got %d", got)
	}
}

func TestEnsureAwakeTimesOut(t *testing.T) {
	wake := func(mac, iface string) error { return nil }
	health := func(upstream string) bool { return false }

	g := NewGateway(testTarget(), wake, health)
	start := time.Now()
	err := g.EnsureAwake()
	if !errors.Is(err, ErrWakeTimeout) {
		t.Fatalf("expected ErrWakeTimeout, got %v", err)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("gave up too slowly: %v", elapsed)
	}
}

func TestConcurrentEnsureAwakeSendsOneWake(t *testing.T) {
	wake, health, wakeCalls := fakeBox()

	g := NewGateway(testTarget(), wake, health)
	done := make(chan error, 4)
	for i := 0; i < 4; i++ {
		go func() { done <- g.EnsureAwake() }()
	}
	for i := 0; i < 4; i++ {
		if err := <-done; err != nil {
			t.Fatalf("concurrent EnsureAwake failed: %v", err)
		}
	}
	if got := atomic.LoadInt32(wakeCalls); got != 1 {
		t.Fatalf("expected wake to be de-duplicated to 1 call, got %d", got)
	}
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd proxmox/wakegw && go test ./...
```

Expected: FAIL — `undefined: Target`, `undefined: NewGateway`, `undefined: ErrWakeTimeout`.

- [ ] **Step 4: Write `config.go`**

```go
package main

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

// Target describes one wake-on-LAN inference host.
type Target struct {
	Name     string        // human label, used in logs
	MAC      string        // NIC MAC, for the magic packet
	Upstream string        // host:port of ollama on that box
	Iface    string        // tau-ceti interface to broadcast from
	WaitCap  time.Duration // give up waiting after this
}

// TargetFromEnv builds a Target from PREFIX_-scoped environment variables,
// e.g. TIER1_MAC, TIER1_UPSTREAM, TIER1_IFACE, TIER1_WAIT_SECONDS.
func TargetFromEnv(prefix string) (Target, error) {
	mac := os.Getenv(prefix + "_MAC")
	if mac == "" {
		return Target{}, fmt.Errorf("%s_MAC is required", prefix)
	}
	upstream := os.Getenv(prefix + "_UPSTREAM")
	if upstream == "" {
		return Target{}, fmt.Errorf("%s_UPSTREAM is required", prefix)
	}

	iface := os.Getenv(prefix + "_IFACE")
	if iface == "" {
		iface = "vmbr2" // tau-ceti's untagged home-LAN bridge
	}

	wait := 20 * time.Second
	if v := os.Getenv(prefix + "_WAIT_SECONDS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return Target{}, fmt.Errorf("%s_WAIT_SECONDS: %w", prefix, err)
		}
		wait = time.Duration(n) * time.Second
	}

	return Target{
		Name:     prefix,
		MAC:      mac,
		Upstream: upstream,
		Iface:    iface,
		WaitCap:  wait,
	}, nil
}
```

- [ ] **Step 5: Write `gateway.go`**

```go
package main

import (
	"errors"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os/exec"
	"sync"
	"time"
)

// ErrWakeTimeout means the box did not answer within Target.WaitCap.
var ErrWakeTimeout = errors.New("wakegw: upstream did not come up within wait cap")

// Waker sends a wake-on-LAN magic packet.
type Waker func(mac, iface string) error

// HealthCheck reports whether ollama on the upstream is answering.
type HealthCheck func(upstream string) bool

// Gateway wakes a suspended host on demand and proxies to it.
type Gateway struct {
	target Target
	wake   Waker
	health HealthCheck
	proxy  *httputil.ReverseProxy

	// mu serialises wake attempts so a burst of concurrent requests
	// produces a single magic packet rather than one per request.
	mu sync.Mutex
}

// NewGateway builds a Gateway. wake and health are injected so the logic
// is testable without a real network or a real suspended machine.
func NewGateway(t Target, wake Waker, health HealthCheck) *Gateway {
	u := &url.URL{Scheme: "http", Host: t.Upstream}
	return &Gateway{
		target: t,
		wake:   wake,
		health: health,
		proxy:  httputil.NewSingleHostReverseProxy(u),
	}
}

// EnsureAwake returns nil once the upstream answers, waking it if needed.
func (g *Gateway) EnsureAwake() error {
	if g.health(g.target.Upstream) {
		return nil
	}

	g.mu.Lock()
	defer g.mu.Unlock()

	// Re-check: another goroutine may have woken it while we waited.
	if g.health(g.target.Upstream) {
		return nil
	}

	log.Printf("wakegw: %s is down, sending magic packet to %s via %s",
		g.target.Name, g.target.MAC, g.target.Iface)
	if err := g.wake(g.target.MAC, g.target.Iface); err != nil {
		return err
	}

	deadline := time.Now().Add(g.target.WaitCap)
	for time.Now().Before(deadline) {
		if g.health(g.target.Upstream) {
			log.Printf("wakegw: %s is up", g.target.Name)
			return nil
		}
		time.Sleep(250 * time.Millisecond)
	}
	return ErrWakeTimeout
}

// ServeHTTP wakes the box if necessary, then reverse-proxies the request.
func (g *Gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if err := g.EnsureAwake(); err != nil {
		if errors.Is(err, ErrWakeTimeout) {
			w.Header().Set("Retry-After", "30")
			http.Error(w, "inference host is waking, retry shortly",
				http.StatusServiceUnavailable)
			return
		}
		http.Error(w, "failed to wake inference host: "+err.Error(),
			http.StatusBadGateway)
		return
	}
	g.proxy.ServeHTTP(w, r)
}

// EtherWake sends a magic packet using the etherwake binary.
func EtherWake(mac, iface string) error {
	return exec.Command("etherwake", "-i", iface, mac).Run()
}

// TCPHealth reports whether the upstream accepts a TCP connection.
// A plain dial is used rather than an HTTP GET so that a box which is
// booting but not yet serving is correctly reported as not-ready.
func TCPHealth(upstream string) bool {
	conn, err := net.DialTimeout("tcp", upstream, 2*time.Second)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd proxmox/wakegw && go test ./... -v
```

Expected: PASS for all four tests — `TestEnsureAwakeSkipsWakeWhenHealthy`, `TestEnsureAwakeWakesThenSucceeds`, `TestEnsureAwakeTimesOut`, `TestConcurrentEnsureAwakeSendsOneWake`.

- [ ] **Step 7: Commit**

```bash
git add proxmox/wakegw/
git commit -m "feat(wakegw): wake-on-LAN gateway core logic

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 2: `wakegw` entrypoint and systemd unit

**Files:**
- Create: `proxmox/wakegw/main.go`
- Create: `proxmox/wakegw/wakegw.service`

**Interfaces:**
- Consumes: `Target`, `TargetFromEnv`, `NewGateway`, `EtherWake`, `TCPHealth` from Task 1.
- Produces: a `wakegw` binary serving Tier 1 on `:18434` and Tier 2 on `:18435`. Task 4's `Endpoints` target these ports.

- [ ] **Step 1: Write `main.go`**

```go
package main

import (
	"log"
	"net/http"
	"os"
	"sync"
)

type listener struct {
	addr   string
	prefix string
}

func main() {
	listeners := []listener{
		{addr: ":18434", prefix: "TIER1"},
		{addr: ":18435", prefix: "TIER2"},
	}

	var wg sync.WaitGroup
	started := 0

	for _, l := range listeners {
		target, err := TargetFromEnv(l.prefix)
		if err != nil {
			log.Printf("wakegw: skipping %s: %v", l.prefix, err)
			continue
		}

		gw := NewGateway(target, EtherWake, TCPHealth)
		mux := http.NewServeMux()
		mux.Handle("/", gw)
		// Liveness for the gateway itself. Deliberately does NOT wake the
		// box: Traefik must be able to probe wakegw without booting a PC.
		mux.HandleFunc("/wakegw/health", func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("ok"))
		})

		srv := &http.Server{Addr: l.addr, Handler: mux}
		log.Printf("wakegw: %s -> %s on %s", l.prefix, target.Upstream, l.addr)

		wg.Add(1)
		started++
		go func(s *http.Server, name string) {
			defer wg.Done()
			if err := s.ListenAndServe(); err != nil && err != http.ErrServerClosed {
				log.Printf("wakegw: %s listener failed: %v", name, err)
			}
		}(srv, l.prefix)
	}

	if started == 0 {
		log.Fatal("wakegw: no targets configured; set TIER1_MAC/TIER1_UPSTREAM " +
			"and/or TIER2_MAC/TIER2_UPSTREAM")
		os.Exit(1)
	}

	wg.Wait()
}
```

- [ ] **Step 2: Verify it builds and refuses to start unconfigured**

```bash
cd proxmox/wakegw && go build -o /tmp/wakegw . && env -i /tmp/wakegw
```

Expected: exits immediately with `wakegw: no targets configured...`. This proves misconfiguration fails loudly at boot rather than silently serving nothing.

- [ ] **Step 3: Verify it starts when configured**

```bash
cd proxmox/wakegw
TIER1_MAC=aa:bb:cc:dd:ee:ff TIER1_UPSTREAM=127.0.0.1:9 /tmp/wakegw &
sleep 1
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18434/wakegw/health
kill %1
```

Expected: `200`. The health endpoint answers without attempting a wake.

- [ ] **Step 4: Write the systemd unit**

Create `proxmox/wakegw/wakegw.service`:

```ini
[Unit]
Description=wakegw - wake-on-LAN inference gateway
Documentation=file:///opt/wakegw/README.md
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
ExecStart=/opt/wakegw/wakegw
EnvironmentFile=/etc/wakegw.env
Restart=always
RestartSec=5

# etherwake needs raw-socket access to broadcast the magic packet, but
# nothing else here does, so grant only that capability.
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 5: Commit**

```bash
git add proxmox/wakegw/main.go proxmox/wakegw/wakegw.service
git commit -m "feat(wakegw): entrypoint and systemd unit

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 3: Provision the two Debian boxes

**Files:**
- Create: `proxmox/wakegw/autosuspend`

**Interfaces:**
- Consumes: nothing from earlier tasks (independent of the Go work).
- Produces: ollama listening on `PC_A_IP:11434` and `PC_B_IP:11434`, each box suspending itself on idle and waking on WoL. Task 4 hard-codes these addresses.

Run every step on **both** boxes unless marked otherwise.

- [ ] **Step 1: Record the identifying values**

On each box:

```bash
ip -4 addr show scope global | grep inet
ip link show | grep -A1 'state UP' | grep link/ether
```

Record the IP and MAC into the placeholder table at the top of this plan. Then set a **static DHCP reservation** for each on the router.

- [ ] **Step 2: Enable wake-on-LAN persistently**

WoL is commonly disabled by default and does not survive reboot without a unit.

```bash
sudo apt-get update && sudo apt-get install -y ethtool
IFACE=$(ip route show default | awk '{print $5; exit}')
sudo ethtool -s "$IFACE" wol g
sudo ethtool "$IFACE" | grep -i wake-on
```

Expected: `Wake-on: g`

If it reports `Wake-on: d`, WoL is disabled in firmware — enable it in BIOS/UEFI (usually "Power On By PCI-E" or "Wake on LAN") before continuing. No amount of software configuration substitutes.

Make it persistent:

```bash
IFACE=$(ip route show default | awk '{print $5; exit}')
sudo tee /etc/systemd/system/wol@.service >/dev/null <<'EOF'
[Unit]
Description=Enable Wake-on-LAN for %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s %i wol g

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now "wol@${IFACE}.service"
```

- [ ] **Step 3: Verify suspend and wake actually work end-to-end**

Do this before installing anything else. If WoL does not work, the entire design is void and you need to know now.

On the box:

```bash
sudo systemctl suspend
```

From tau-ceti (`ssh root@192.168.1.119`), substituting the real MAC:

```bash
apt-get install -y etherwake
etherwake -i vmbr2 <PC_MAC>
```

Expected: the box wakes within ~5s and answers `ping`.

**If it does not wake:** check that the switch port stays powered during suspend, and that the box is suspending to S3/s2idle rather than powering off. Do not proceed until a magic packet reliably wakes the box.

- [ ] **Step 4: Install ollama**

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Expected: `ollama` systemd service installed and running.

- [ ] **Step 5: Bind ollama to the LAN**

By default ollama listens on `127.0.0.1` and will be unreachable from tau-ceti.

```bash
sudo systemctl edit ollama
```

Add:

```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_KEEP_ALIVE=15m"
```

Then:

```bash
sudo systemctl daemon-reload && sudo systemctl restart ollama
curl -s http://localhost:11434/ && echo
```

Expected: `Ollama is running`

- [ ] **Step 6: Verify GPU detection — 1070 Ti box (Tier 2) only**

```bash
sudo apt-get install -y nvidia-driver
sudo reboot
```

After reboot:

```bash
nvidia-smi
journalctl -u ollama | grep -iE "cuda|gpu" | tail -10
```

Expected: `nvidia-smi` lists the GTX 1070 Ti with 8192MiB; ollama logs report a CUDA library and the device. Pascal (compute 6.1) is supported by current CUDA builds.

- [ ] **Step 7: Verify GPU detection — Arc A750 box (Tier 1) only**

Arc needs a recent kernel and firmware. Debian stable may need backports.

```bash
sudo apt-get install -y firmware-misc-nonfree mesa-vulkan-drivers vulkan-tools
vulkaninfo --summary | grep -iE "deviceName|driverName"
journalctl -u ollama | grep -iE "vulkan|gpu|arc" | tail -10
```

Expected: `vulkaninfo` names the Arc A750; ollama logs report a Vulkan device.

**If ollama falls back to CPU:** the spec deliberately left the A750 backend open — Vulkan vs oneAPI/IPEX-LLM — to be decided by benchmark. Record the Vulkan result, then evaluate `intel-analytics/ipex-llm`'s ollama build as the alternative. Do not spend more than one attempt on Vulkan before trying the alternative.

- [ ] **Step 8: Pull each box's model**

On the **1070 Ti** box (Tier 2):

```bash
ollama pull qwen3-coder:30b-a3b-q4_K_M
```

On the **A750** box (Tier 1):

```bash
ollama pull qwen3:8b
ollama pull gemma3n:e4b
```

`gemma3n:e4b` is the optional per-layer-embeddings benchmark from the spec — the model that motivated this work. At ~7.5 GB it fits the A750's 8 GB VRAM.

- [ ] **Step 9: Verify Tier 2 expert offload actually engages**

The 30B model is 19 GB against 8 GB of VRAM. It must partially offload, and you need to confirm it does so without collapsing to pure CPU.

On the 1070 Ti box:

```bash
ollama run qwen3-coder:30b-a3b-q4_K_M --verbose "Write a Go function that reverses a slice." 2>&1 | tail -8
nvidia-smi --query-gpu=memory.used --format=csv
```

Expected: a completion at a usable rate, with `nvidia-smi` showing several GB of VRAM in use — proving layers are on the GPU, not all in system RAM. Record the `eval rate`.

- [ ] **Step 10: Install the idle-suspend script**

Create `proxmox/wakegw/autosuspend` in the repo:

```bash
#!/usr/bin/env bash
# Suspend this inference box when ollama has been idle.
# Installed at /usr/local/bin/autosuspend, driven by autosuspend.timer.
set -euo pipefail

IDLE_MINUTES="${IDLE_MINUTES:-20}"
STATE_FILE=/run/autosuspend.last-active

# A loaded model means work is in flight or recently finished.
if ollama ps 2>/dev/null | tail -n +2 | grep -q .; then
    date +%s > "$STATE_FILE"
    exit 0
fi

# An open connection to ollama also counts as active, covering the window
# between a request arriving and a model finishing load.
if ss -Htn state established '( sport = :11434 )' 2>/dev/null | grep -q .; then
    date +%s > "$STATE_FILE"
    exit 0
fi

if [[ ! -f "$STATE_FILE" ]]; then
    date +%s > "$STATE_FILE"
    exit 0
fi

last=$(cat "$STATE_FILE")
now=$(date +%s)
idle=$(( (now - last) / 60 ))

if (( idle >= IDLE_MINUTES )); then
    logger -t autosuspend "idle ${idle}m >= ${IDLE_MINUTES}m, suspending"
    systemctl suspend
fi
```

Deploy it to each box:

```bash
sudo install -m 0755 autosuspend /usr/local/bin/autosuspend

sudo tee /etc/systemd/system/autosuspend.service >/dev/null <<'EOF'
[Unit]
Description=Suspend inference box when ollama is idle

[Service]
Type=oneshot
Environment=IDLE_MINUTES=20
ExecStart=/usr/local/bin/autosuspend
EOF

sudo tee /etc/systemd/system/autosuspend.timer >/dev/null <<'EOF'
[Unit]
Description=Periodic idle check for inference box

[Timer]
OnBootSec=10min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now autosuspend.timer
```

Note the ordering constraint: `OLLAMA_KEEP_ALIVE=15m` (Step 5) is shorter than `IDLE_MINUTES=20`, so a model always unloads before the box is eligible to suspend. Do not raise keep-alive above the idle threshold or the box will never sleep.

- [ ] **Step 11: Verify the box suspends and is recoverable**

```bash
sudo systemctl start autosuspend.service
journalctl -t autosuspend -n 5
```

Then wait out the idle window and confirm the box suspends on its own, and that `etherwake` from tau-ceti brings it back (repeat Step 3's wake command).

- [ ] **Step 12: Commit**

```bash
git add proxmox/wakegw/autosuspend
git commit -m "feat(wakegw): idle-suspend script for inference boxes

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 4: Install `wakegw` on tau-ceti

**Files:**
- Create: `proxmox/wakegw/README.md`

**Interfaces:**
- Consumes: the `wakegw` binary and unit from Tasks 1–2; box addresses from Task 3.
- Produces: `wakegw` reachable at `192.168.1.119:18434` (Tier 1) and `192.168.1.119:18435` (Tier 2). Task 5's `Endpoints` point here.

- [ ] **Step 1: Build a static binary**

tau-ceti is Debian (Proxmox VE 9.2.4) on amd64. Build locally rather than installing a Go toolchain on the hypervisor.

```bash
cd proxmox/wakegw
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /tmp/wakegw .
file /tmp/wakegw
```

Expected: `ELF 64-bit LSB executable, x86-64, statically linked`

- [ ] **Step 2: Install onto tau-ceti**

```bash
ssh root@192.168.1.119 "apt-get update && apt-get install -y etherwake && mkdir -p /opt/wakegw"
scp /tmp/wakegw root@192.168.1.119:/opt/wakegw/wakegw
scp proxmox/wakegw/wakegw.service root@192.168.1.119:/etc/systemd/system/wakegw.service
ssh root@192.168.1.119 "chmod 0755 /opt/wakegw/wakegw"
```

- [ ] **Step 3: Write the environment file**

Substitute the real values from the placeholder table.

```bash
ssh root@192.168.1.119 "cat > /etc/wakegw.env <<'EOF'
TIER1_MAC=<PC_B_MAC>
TIER1_UPSTREAM=<PC_B_IP>:11434
TIER1_IFACE=vmbr2
TIER1_WAIT_SECONDS=20

TIER2_MAC=<PC_A_MAC>
TIER2_UPSTREAM=<PC_A_IP>:11434
TIER2_IFACE=vmbr2
TIER2_WAIT_SECONDS=20
EOF
chmod 0600 /etc/wakegw.env"
```

Note: Tier 1 is the **A750** box (`PC_B`), Tier 2 is the **1070 Ti** box (`PC_A`). Transposing these sends 30B requests to the box that cannot hold the model.

- [ ] **Step 4: Start and verify**

```bash
ssh root@192.168.1.119 "systemctl daemon-reload && systemctl enable --now wakegw && sleep 2 && systemctl is-active wakegw && journalctl -u wakegw -n 20 --no-pager"
```

Expected: `active`, and log lines `wakegw: TIER1 -> <PC_B_IP>:11434 on :18434` and `wakegw: TIER2 -> ...`.

- [ ] **Step 5: Verify the health endpoint does not wake anything**

With both boxes suspended:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://192.168.1.119:18434/wakegw/health
ping -c1 -W2 <PC_B_IP> >/dev/null 2>&1 && echo "BOX AWAKE (unexpected)" || echo "box still asleep (correct)"
```

Expected: `200`, then `box still asleep (correct)`. If the health probe wakes the box, it will never be allowed to sleep once Traefik starts probing.

- [ ] **Step 6: Verify the wake path end-to-end**

With the Tier 1 box suspended:

```bash
time curl -s http://192.168.1.119:18434/api/generate \
  -d '{"model":"qwen3:8b","prompt":"say hi","stream":false}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['response'][:60])"
```

Expected: a real completion, total time under ~25s (wake + load + generate). The box was asleep when the request arrived.

- [ ] **Step 7: Verify the timeout path returns 503, not a hang**

Temporarily point Tier 1 at an unreachable address:

```bash
ssh root@192.168.1.119 "sed -i 's/^TIER1_UPSTREAM=.*/TIER1_UPSTREAM=192.0.2.1:11434/' /etc/wakegw.env && systemctl restart wakegw"
time curl -s -o /dev/null -w "%{http_code} retry-after=%header{retry-after}\n" http://192.168.1.119:18434/api/tags
```

Expected: `503 retry-after=30` in a little over 20s — not an indefinite hang.

Restore the real value:

```bash
ssh root@192.168.1.119 "sed -i 's|^TIER1_UPSTREAM=.*|TIER1_UPSTREAM=<PC_B_IP>:11434|' /etc/wakegw.env && systemctl restart wakegw"
```

- [ ] **Step 8: Write the runbook**

Create `proxmox/wakegw/README.md`:

```markdown
# wakegw — wake-on-LAN inference gateway

Runs on **tau-ceti** (`192.168.1.119`). Wakes a suspended GPU box on demand
and reverse-proxies ollama traffic to it.

`client → Traefik → wakegw (tau-ceti) → gaming PC`

tau-ceti hosts this because it is the only always-on machine on the untagged
home LAN (`vmbr2`) that the cluster already depends on — WoL magic packets are
link-layer broadcasts and cannot cross from the cluster's VLAN 4.

## Layout

| Path | What |
|---|---|
| `/opt/wakegw/wakegw` | static binary |
| `/etc/wakegw.env` | target MACs/IPs (mode 0600) |
| `/etc/systemd/system/wakegw.service` | unit |

Ports: `18434` → Tier 1 (Arc A750), `18435` → Tier 2 (GTX 1070 Ti).

## This host is NOT GitOps-managed

Proxmox host config is hand-managed. tau-ceti was rebuilt from scratch on
2026-07-18 — **if it is rebuilt again, reinstall from this directory**, which
is the source of truth. Repeat Task 4 of
`docs/superpowers/plans/2026-08-02-wol-gpu-inference-tiers.md`.

## Rebuild and redeploy

```bash
cd proxmox/wakegw
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /tmp/wakegw .
scp /tmp/wakegw root@192.168.1.119:/opt/wakegw/wakegw
ssh root@192.168.1.119 "systemctl restart wakegw"
```

## Troubleshooting

| Symptom | Check |
|---|---|
| `503` on every request | Box not waking. `ethtool <iface> \| grep -i wake-on` on the box must read `g`. Check BIOS wake-on-LAN. |
| Box never sleeps | Something holds a connection to `:11434`. `ss -tn '( sport = :11434 )'`. Confirm `OLLAMA_KEEP_ALIVE` (15m) is below `IDLE_MINUTES` (20m). |
| Box sleeps mid-request | `IDLE_MINUTES` too low, or `autosuspend` is not seeing the connection. Check `journalctl -t autosuspend`. |
| Wakes but 502 | Box is up, ollama is not. `systemctl status ollama` on the box. |
| Health probe wakes the box | Traefik is probing `/` instead of `/wakegw/health`. |

`etherwake` needs `CAP_NET_RAW`, granted in the unit. Do not run wakegw as a
non-root user without it.
```

- [ ] **Step 9: Commit**

```bash
git add proxmox/wakegw/README.md
git commit -m "docs(wakegw): install and troubleshooting runbook

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 5: Expose both tiers through Traefik

**Files:**
- Create: `apps/external-ingress/manifests/ollama-tiers.yaml`
- Modify: `apps/external-ingress/manifests/kustomization.yaml`

**Interfaces:**
- Consumes: `wakegw` on `192.168.1.119:18434` / `:18435` from Task 4.
- Produces: `fast.ai.wrenspace.dev` (Tier 1) and `big.ai.wrenspace.dev` (Tier 2), TLS-terminated by Traefik.

- [ ] **Step 1: Read the existing pattern**

```bash
sed -n '1,40p' apps/external-ingress/manifests/vaultwarden.yaml
cat apps/external-ingress/manifests/kustomization.yaml
```

This is the shape to copy: headless `Service` (`clusterIP: None`) + hard-coded `Endpoints` + `Ingress`. Follow it rather than inventing a variant.

- [ ] **Step 2: Create the manifest**

Routing is **host-based**, one hostname per tier. Routing on the requested model name would be more ergonomic but is impossible — the model is in the JSON request body and Traefik cannot route on body content.

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: ollama-fast
  namespace: external-ingress
  labels:
    app.kubernetes.io/name: ollama-fast
    app.kubernetes.io/part-of: external-ingress
spec:
  ports:
    - name: http
      port: 80
      protocol: TCP
      targetPort: 18434
  clusterIP: None
  type: ClusterIP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: ollama-fast
  namespace: external-ingress
  labels:
    app.kubernetes.io/name: ollama-fast
    app.kubernetes.io/part-of: external-ingress
subsets:
  - addresses:
      # wakegw on tau-ceti, Tier 1 listener (Arc A750)
      - ip: 192.168.1.119
    ports:
      - name: http
        port: 18434
        protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: ollama-big
  namespace: external-ingress
  labels:
    app.kubernetes.io/name: ollama-big
    app.kubernetes.io/part-of: external-ingress
spec:
  ports:
    - name: http
      port: 80
      protocol: TCP
      targetPort: 18435
  clusterIP: None
  type: ClusterIP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: ollama-big
  namespace: external-ingress
  labels:
    app.kubernetes.io/name: ollama-big
    app.kubernetes.io/part-of: external-ingress
subsets:
  - addresses:
      # wakegw on tau-ceti, Tier 2 listener (GTX 1070 Ti)
      - ip: 192.168.1.119
    ports:
      - name: http
        port: 18435
        protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ollama-fast
  namespace: external-ingress
  labels:
    app.kubernetes.io/name: ollama-fast
    app.kubernetes.io/part-of: external-ingress
  annotations:
    cert-manager.io/cluster-issuer: cert-issuer
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  tls:
    - hosts:
        - fast.ai.wrenspace.dev
      secretName: ollama-fast-tls
  rules:
    - host: fast.ai.wrenspace.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ollama-fast
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ollama-big
  namespace: external-ingress
  labels:
    app.kubernetes.io/name: ollama-big
    app.kubernetes.io/part-of: external-ingress
  annotations:
    cert-manager.io/cluster-issuer: cert-issuer
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  tls:
    - hosts:
        - big.ai.wrenspace.dev
      secretName: ollama-big-tls
  rules:
    - host: big.ai.wrenspace.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ollama-big
                port:
                  number: 80
```

- [ ] **Step 3: Register it in the kustomization**

Add `- ollama-tiers.yaml` to the `resources:` list in `apps/external-ingress/manifests/kustomization.yaml`.

- [ ] **Step 4: Validate**

```bash
kubectl kustomize apps/external-ingress/manifests | kubeconform -summary -ignore-missing-schemas
```

Expected: `Invalid: 0, Errors: 0`.

- [ ] **Step 5: Commit, push, reconcile**

```bash
git add apps/external-ingress/manifests/ollama-tiers.yaml apps/external-ingress/manifests/kustomization.yaml
git commit -m "feat(external-ingress): expose WoL inference tiers

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
flux reconcile kustomization external-ingress -n flux-system --with-source
```

- [ ] **Step 6: Verify certificates issue**

```bash
kubectl get certificate -n external-ingress | grep ollama
```

Expected: both `ollama-fast-tls` and `ollama-big-tls` reach `READY=True`. This can take a minute or two.

- [ ] **Step 7: Verify end-to-end through Traefik**

With both boxes suspended:

```bash
time curl -s https://fast.ai.wrenspace.dev/api/generate \
  -d '{"model":"qwen3:8b","prompt":"say hi","stream":false}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['response'][:60])"
```

Expected: a completion. The full chain — TLS, Traefik, wakegw, magic packet, wake, ollama — worked from cold.

---

### Task 6: Configure clients and document

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: working tiers from Task 5.
- Produces: documented endpoints. No code interface.

- [ ] **Step 1: Verify tool calling on Tier 2 — the OpenClaw gate**

This is the requirement that motivated Tier 2 and the one most likely to fail. Use the **native `/api/chat`** endpoint; `/v1` does not correctly emit `tool_calls` delta chunks.

```bash
curl -s https://big.ai.wrenspace.dev/api/chat -d '{
  "model": "qwen3-coder:30b-a3b-q4_K_M",
  "messages": [{"role":"user","content":"What is the weather in Chicago?"}],
  "tools": [{
    "type": "function",
    "function": {
      "name": "get_weather",
      "description": "Get current weather for a city",
      "parameters": {
        "type": "object",
        "properties": {"city": {"type": "string"}},
        "required": ["city"]
      }
    }
  }],
  "stream": false
}' | python3 -c "
import sys, json
m = json.load(sys.stdin)['message']
tc = m.get('tool_calls')
assert tc, f'NO TOOL CALLS - got content instead: {m.get(\"content\", \"\")[:200]}'
print('tool_calls OK:', json.dumps(tc))
"
```

Expected: `tool_calls OK: [{"function": {"name": "get_weather", "arguments": {"city": "Chicago"}}}]`

**If this returns prose instead of `tool_calls`,** the model or its chat template is not emitting structured calls, and OpenClaw will not work against it. Report this rather than proceeding — it invalidates the Tier 2 premise.

- [ ] **Step 2: Verify the 64K context requirement**

OpenClaw requires ≥64K context. Confirm the box can actually allocate it.

```bash
curl -s https://big.ai.wrenspace.dev/api/generate -d '{
  "model": "qwen3-coder:30b-a3b-q4_K_M",
  "prompt": "Reply with the single word: ok",
  "stream": false,
  "options": {"num_ctx": 65536, "num_predict": 5}
}' | python3 -c "import sys,json; print(json.load(sys.stdin)['response'][:40])"
```

Expected: `ok` (or similar). Then confirm it did not silently fall back to CPU under the larger KV cache:

```bash
ssh <PC_A_IP> "nvidia-smi --query-gpu=memory.used --format=csv"
```

Expected: several GB still resident on the GPU.

- [ ] **Step 3: Point clients at the right tiers**

| Client | Endpoint | Notes |
|---|---|---|
| Editor FIM (Continue.dev) | `http://ollama.ollama.svc` or the Tier 0 ingress | Tier 0 — never a WoL tier; a 20s wake breaks autocomplete |
| open-webui chat | `https://fast.ai.wrenspace.dev` | Tier 1 |
| Aider / Cline | `https://fast.ai.wrenspace.dev` | Tier 1; move to `big` if tool calls prove unreliable |
| OpenClaw | `https://big.ai.wrenspace.dev/api/chat` | Tier 2; native endpoint, **not** `/v1` |
| CI / gitea-actions | `https://big.ai.wrenspace.dev` | Tier 2; latency-tolerant |

Configure each client accordingly. Do not point FIM at a WoL tier.

- [ ] **Step 4: Document in CLAUDE.md**

Add to the Hardware section, after the gallifrey row:

```markdown
### Inference tiers (added 2026-08-02)

Three tiers serve local LLMs. Tier 0 is in-cluster and always on; Tiers 1–2
are suspended Debian GPU boxes on the home LAN, woken on demand.

| Tier | Host | GPU | Model | Endpoint |
|---|---|---|---|---|
| 0 | kube-vm | Intel HD630 (shared with Jellyfin) | `qwen2.5-coder:1.5b-base` | in-cluster |
| 1 | Arc A750 box | Arc A750 8GB | `qwen3:8b`, `gemma3n:e4b` | `fast.ai.wrenspace.dev` |
| 2 | 1070 Ti box | GTX 1070 Ti 8GB | `qwen3-coder:30b-a3b` | `big.ai.wrenspace.dev` |

**`wakegw` on tau-ceti** (`/opt/wakegw`, see `proxmox/wakegw/README.md`) wakes
the boxes and proxies to them. It lives on tau-ceti because **WoL magic packets
are link-layer broadcasts and cannot cross from the cluster's VLAN 4 to the
untagged home LAN** — an in-cluster proxy physically cannot wake these machines.
tau-ceti was chosen over amphoreus and gallifrey because it already hosts
kube-vm, so it adds no new failure domain.

- Boxes suspend themselves (`autosuspend.timer`, 20m idle). `wakegw` only wakes.
- `OLLAMA_KEEP_ALIVE=15m` on the boxes must stay **below** `IDLE_MINUTES=20`, or
  a loaded model keeps the box awake forever.
- Traefik must probe `/wakegw/health`, not `/` — probing `/` wakes the box on
  every health check and it will never sleep.
- OpenClaw must use ollama's native `/api/chat`; `/v1` does not emit
  `tool_calls` delta chunks correctly.
- Tier 1 has 8GB VRAM: a 14B Q4 (~9GB) does **not** fit and belongs on Tier 2.
- `wakegw` config is NOT GitOps-managed. Source of truth is `proxmox/wakegw/`;
  reinstall from there if tau-ceti is ever rebuilt.
```

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: record WoL inference tiers and wakegw

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
```

---

## Rollback

Tiers 1–2 are purely additive; Tier 0 is untouched throughout.

```bash
git rm apps/external-ingress/manifests/ollama-tiers.yaml
# remove the ollama-tiers.yaml line from kustomization.yaml
git commit -m "revert: remove WoL inference tiers" && git push origin main
flux reconcile kustomization external-ingress -n flux-system --with-source
ssh root@192.168.1.119 "systemctl disable --now wakegw"
```

The Debian boxes keep ollama and their autosuspend timers; disable with
`sudo systemctl disable --now autosuspend.timer` if you want them to stay awake.

## Definition of Done

- [ ] `go test ./...` passes in `proxmox/wakegw/`
- [ ] `wakegw` active on tau-ceti, both listeners logged
- [ ] `/wakegw/health` returns 200 **without** waking a suspended box
- [ ] A cold request to `fast.ai.wrenspace.dev` wakes the A750 box and completes in <25s
- [ ] An unreachable upstream returns `503` + `Retry-After` in ~20s, never hangs
- [ ] Both boxes suspend on their own after 20m idle and wake reliably
- [ ] Tier 2 returns real `tool_calls` from `/api/chat` (the OpenClaw gate)
- [ ] Tier 2 serves a 64K-context request with the GPU still engaged
- [ ] Both TLS certificates `READY=True`
- [ ] `CLAUDE.md` and `proxmox/wakegw/README.md` record the VLAN constraint and the keep-alive/idle ordering
