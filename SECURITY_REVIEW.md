# Security Review: merge-msrc-to-main_unsquashed branch

**Reviewer**: Copilot (automated)  
**Date**: 2026-03-04  
**Scope**: Security-focused review of commit `046b2d6e7` ("Various enforcement
fixes") and `9c1941bb4` ("Enforce OCI spec does not contain any LinuxDevices"),
rebased on top of commits from `main` (commits 1-28 in the range-diff). Also
reviewing the WCOW gcs-sidecar code for analogous gaps.

---

## Summary

The changes introduce significant security hardening for LCOW confidential
containers (GCS). The changes also address several classes of security issues
that could allow a compromised host to bypass the security policy. Overall
assessment: **the LCOW changes are well-designed and thorough**. However, there
are several **findings in the WCOW gcs-sidecar code** that suffer from analogous
(or additional) security problems.

---

## 1. LCOW Security Changes Review (uvm.go, rego, securitypolicyenforcer)

### 1.1 Container ID Validation (GOOD)

The introduction of `checkValidContainerID` with regex `[0-9a-fA-F]{64}` is
correct and prevents path traversal via malformed container/sandbox IDs that are
used in filesystem paths (e.g. `guestpath.LCOWRootPrefixInUVM + "/" +
containerID`). The check is applied at all entry points:
- `CreateContainer` (container ID, virtual pod ID, sandbox ID)
- `modifyHostSettings` (container ID)
- `modifyContainerSettings` (container ID)
- `modifyCombinedLayers` (container ID)
- `DeleteContainerState` (container ID)

**No issues found.**

### 1.2 Container Settings Validation (GOOD)

`checkContainerSettings` correctly enforces that:
- OCIBundlePath matches the expected path for the container
- Root.Path matches expected rootfs location
- ScratchDirPath matches expected patterns (shared or non-shared)
- OCISpecification.Hooks is nil

**No issues found.** This prevents the host from injecting arbitrary OCI hooks
or pointing the container rootfs/scratch at unexpected locations.

### 1.3 Mount Path Enforcement in Rego (GOOD)

The `anchor_pattern` function is a good improvement - it ensures all regex
patterns used in Rego policy matching are properly anchored with `^` and `$` to
prevent partial match bypasses. This is applied consistently to:
- `mount_device` mount path regex
- `env_ok` for re2 patterns
- `idName_ok` for re2 patterns
- `mountSource_ok` for sandbox and hugepages mounts
- `plan9_mount` pattern

**No issues found.**

### 1.4 Read-Write Device Mount/Unmount Separation (GOOD)

The separation of RO and RW device tracking (`devices` vs `rw_devices` in Rego
metadata) and the corresponding `rw_mount_device`/`rw_unmount_device`
enforcement points prevent confusion between read-only (verity-hashed) and
read-write (scratch) mounts. The unmount code properly checks that the device
type matches (e.g. can't use `unmount_device` on an `rw_devices` entry).

**No issues found.**

### 1.5 Revertable Sections (GOOD)

The `RevertableSectionHandle` mechanism ensures that policy enforcer state
(Rego metadata) is rolled back if a mount/unmount operation fails partway
through. This prevents state desynchronization between the policy enforcer and
actual filesystem state. The `commitOrRollbackPolicyRevSection` helper is used
consistently in:
- `modifyMappedVirtualDisk`
- `modifyMappedDirectory`
- `modifyMappedVPMemDevice`
- `modifyCombinedLayers`

The mutex ensures only one revertable section can be active at a time.

**No issues found.**

### 1.6 mountsBroken Flag (GOOD)

If a real unmount fails after the policy enforcer has already committed the
unmount, the `mountsBroken` flag permanently blocks all further mount/unmount
and container creation operations. This is a correct fail-closed approach.

**No issues found.**

### 1.7 Fragment Loading Security (GOOD)

The two-phase fragment loading (first check issuer/feed, then load code and
check SVN) is a security improvement. Previously, the fragment Rego code was
loaded before any validation, which could potentially allow the fragment to
influence the policy evaluation. The namespace validation with reserved
namespace blocking (`framework`, `api`, `policy`, `metadata`) is also good.

The `input.fragment_loaded` guards in the error reporting rego rules prevent
spurious error messages when the fragment hasn't been loaded yet.

**No issues found.**

### 1.8 LinuxDevices Enforcement (GOOD - commit 9c1941b)

The new `devices_ok` check in `create_container` rego rule ensures that the OCI
spec does not contain unexpected Linux device entries. The Go code in `uvm.go`
clones the devices list before `ApplyAnnotationsToSpec` adds dynamically
discovered devices (like `/dev/sev-guest` and privileged `/dev/*`), so only the
user-specified devices are checked. Currently, only an empty devices list is
allowed (`devices_ok([], input.devices)`), which correctly prevents any
user-specified device injection.

**No issues found.**

### 1.9 hostMounts Initialization Timing (GOOD)

Previously `hostMounts` was always initialized. Now it's `nil` until
`SetConfidentialOptions` is called and a security policy is actually set. This
is correct because:
1. Before policy is set, `ClosedDoorSecurityPolicyEnforcer` denies all
   operations anyway
2. After policy is set, `hostMounts` is initialized to track state

**No issues found.**

### 1.10 Overlay In-Use Check (GOOD)

`IsOverlayInUse` prevents the host from unmounting an overlay that is still used
by a running container. This prevents a TOCTOU issue where the host could unmount
layers out from under a running container.

**No issues found.**

### 1.11 SCSI Mount Option Enforcement (GOOD)

For confidential containers, the only allowed SCSI mount option is `"ro"`, and
it must be consistent with the `ReadOnly` field. This prevents the host from
specifying unexpected mount options that could weaken security (e.g. `nosuid`
removal).

Also, `mvd.Filesystem` is enforced to be `""` or `"ext4"` for read-only mounts.

**No issues found.**

### 1.12 Plan9 ShareName Validation (GOOD)

`ValidateShareName` ensures share names are numeric-only (`^[0-9]+$`), matching
what a legitimate hcsshim host generates. This prevents injection of arbitrary
plan9 mount options via crafted share names.

**No issues found.**

### 1.13 Existence Check Before Unmount (GOOD)

The unmount path checks (`checkExists`) for SCSI and VPMem devices are performed
**after** policy enforcement. The comment correctly explains why: if the check
were done before policy enforcement, the host could use the sidecar as an oracle
to probe for path existence.

**No issues found.**

---

## 2. Compatibility with Rebased Commits

### 2.1 "Enforce cgroup limits at pod level" (commit 3)

This commit adds pod-level cgroup management. It does not interact with the
security policy enforcement changes and has no security implications that would
conflict.

**No issues.**

### 2.2 "rego: Allow SIGTERM/SIGKILL for init process" (commit 4)

This commit relaxes signal policy. The "Various enforcement fixes" commit does
not change signal enforcement logic, so there is no conflict.

**No issues.**

### 2.3 "Move common confidential options" (commit 6)

This refactors the `SecurityOptions` and `ConfidentialOptions` structs. The
security changes in this branch correctly use the new structure (e.g.
`h.securityOptions.PolicyEnforcer` and `h.securityOptions.SetConfidentialOptions`).

**No issues.**

### 2.4 "C-WCOW: Enforce hashes on already mounted CIMs" (commit 12)

This adds hash verification for CIMs already mounted from previous containers.
It's WCOW-specific and does not conflict with LCOW changes.

**No issues.**

### 2.5 "WCOW: restore support for client-mounted roots" (commit 15)

This is a WCOW change that does not interact with the LCOW security changes.

**No issues.**

### 2.6 "CWCOW: Misc fixes" (commit 24)

WCOW-specific fixes that don't interact with LCOW enforcement.

**No issues.**

### 2.7 "support both cimfs and cimwriter dlls" (commit 19)

This is a WCOW CIM-related change. No interaction with LCOW security.

**No issues.**

### 2.8 Other rebased commits

Dependency bumps, CI changes, and unrelated feature work. No security interaction.

---

## 3. WCOW GCS Sidecar Security Review

The WCOW gcs-sidecar (`internal/gcs-sidecar/`) acts as a security enforcement
proxy between the (potentially compromised) host shim and the inbox Windows GCS.
Comparing it with the LCOW hardening, there are several security concerns:

### 3.1 **FINDING: No Container ID Validation** (MEDIUM)

**File**: `internal/gcs-sidecar/handlers.go`, line 81

The LCOW code validates container IDs with `checkValidContainerID` to prevent
path traversal. The WCOW sidecar does not perform any such validation on
`containerID` values received from the host. While WCOW container paths may
differ in structure, the container IDs are still used in security-sensitive
contexts (policy enforcement, container tracking maps).

A malicious host could potentially supply crafted container IDs to the sidecar
to confuse the container tracking state or exploit string-based lookups.

**Recommendation**: Add container ID format validation in the WCOW sidecar,
similar to the LCOW `checkValidContainerID` check.

### 3.2 **FINDING: No Revertable Sections for Policy State** (LOW-MEDIUM)

**File**: `internal/gcs-sidecar/handlers.go`, various locations

The LCOW code introduced `RevertableSectionHandle` to ensure Rego metadata is
rolled back when mount operations fail. The WCOW sidecar does not use revertable
sections when calling policy enforcement methods like:
- `EnforceVerifiedCIMsPolicy` (line 650)
- `EnforceScratchMountPolicy` (line 791)
- `EnforceScratchUnmountPolicy` (line 811)
- `EnforceCreateContainerPolicyV2` (line 87)

If a mount operation fails after policy enforcement succeeds, the Rego metadata
state could become inconsistent with reality (e.g., policy thinks a device is
mounted, but it actually isn't).

**Recommendation**: Implement revertable sections in the WCOW sidecar for any
sequence where policy enforcement precedes an operation that could fail, similar
to the LCOW code.

### 3.3 **FINDING: No mountsBroken Equivalent** (LOW-MEDIUM)

**File**: `internal/gcs-sidecar/host.go`

The LCOW code introduces a `mountsBroken` flag to permanently block operations
when an unmount fails after policy state has been committed. The WCOW sidecar
has no such fail-closed mechanism. If a CIM unmount (`cimfs.Unmount` at line
685) or scratch operation fails, the sidecar continues to process requests with
potentially inconsistent policy state.

**Recommendation**: Add a similar fail-closed mechanism to the WCOW sidecar.

### 3.4 **FINDING: `shutdownForced` Bypasses Policy** (MEDIUM)

**File**: `internal/gcs-sidecar/handlers.go`, line 211

`shutdownGraceful` correctly enforces `EnforceShutdownContainerPolicy`, but
`shutdownForced` does NOT enforce any policy - it directly forwards the request
to GCS. This means a compromised host could force-kill any container without
policy approval.

For LCOW, both graceful and forced shutdown go through the same `Shutdown`
method, which calls `EnforceShutdownContainerPolicy`.

**Recommendation**: `shutdownForced` should also enforce
`EnforceShutdownContainerPolicy` before forwarding.

### 3.5 **FINDING: `dumpStacks` Does Not Enforce Policy** (LOW)

**File**: `internal/gcs-sidecar/handlers.go`, line 441

The `dumpStacks` handler does not call `EnforceDumpStacksPolicy`, unlike the
LCOW code. While dump stacks is less security-critical than other operations,
policy should still be consulted.

**Recommendation**: Call `EnforceDumpStacksPolicy` in the `dumpStacks` handler.

### 3.6 **FINDING: `EnforceCreateContainerPolicyV2` Called with `nil` opts** (LOW-MEDIUM)

**File**: `internal/gcs-sidecar/handlers.go`, line 87

```go
_, _, _, err := b.hostState.securityOptions.PolicyEnforcer.EnforceCreateContainerPolicyV2(
    req.ctx, containerID, spec.Process.Args, spec.Process.Env, spec.Process.Cwd,
    spec.Mounts, user, nil)
```

The `opts` parameter is `nil`, which means the Rego enforcer receives no sandbox
ID, no privileged flag, no capabilities, no seccomp profile SHA, and no Linux
devices info. While some of these are Linux-specific, the lack of a sandbox ID
means the Rego policy cannot properly scope containers to their sandbox.

For the Windows `create_container` input (see `securitypolicyenforcer_rego.go`
line 773), only `containerID`, `argList`, `envList`, `workingDir`, and `user`
are sent — which is intentionally simplified for WCOW. However, passing `nil`
opts means any future `opts` field that becomes relevant for WCOW would be
silently ignored.

**Recommendation**: Pass a non-nil `CreateContainerOptions` struct with relevant
WCOW fields filled in, even if many fields are empty/irrelevant for Windows.
This future-proofs the code.

### 3.7 **FINDING: `EnforceExecInContainerPolicyV2` Called with `nil` opts** (LOW)

**File**: `internal/gcs-sidecar/handlers.go`, line 278-286

Same pattern as 3.6 — `opts` is `nil` for `EnforceExecInContainerPolicyV2`.

**Recommendation**: Pass a non-nil `ExecOptions` struct.

### 3.8 **FINDING: CIM Block Mount Does Not Validate Volume GUID** (LOW)

**File**: `internal/gcs-sidecar/handlers.go`, line 656

The volume GUID received from `wcowBlockCimMounts.VolumeGUID` is used as a key
in maps without any validation of its format or value. While GUID parsing
provides some structure enforcement, the sidecar does not verify that the
volume GUID is expected or within an allowed set.

**Recommendation**: Consider validating that volume GUIDs match expected
patterns.

### 3.9 **FINDING: Race Condition in signalProcess** (LOW)

**File**: `internal/gcs-sidecar/handlers.go`, line 348-391

In `signalProcess`, when `rawOpts` is `nil`, the request is forwarded without
any policy enforcement at all. This means if the signal options are omitted from
the request, the signal goes through unchecked.

Additionally, the process lookup (`c.GetProcess(r.ProcessID)`) may be racy if
the exec response hasn't been processed yet (the exec uses a 5-second timeout
channel).

**Recommendation**: Enforce signal policy even when `rawOpts` is nil, and
consider what the default signal behavior should be.

### 3.10 **FINDING: Container Removal Without Lifecycle Check** (LOW-MEDIUM)

**File**: `internal/gcs-sidecar/handlers.go`, line 455-471

`deleteContainerState` removes the container from the sidecar's tracking map
and forwards to GCS. The LCOW code (`DeleteContainerState`) checks that:
1. The container is terminated before allowing deletion
2. No overlay mounts are still active

The WCOW sidecar performs none of these checks. A compromised host could delete
container state while the container is still running, potentially enabling
subsequent policy bypasses (e.g., the container no longer appears in the
tracking map, so exec-in-container lookups fail and fall through).

**Recommendation**: Add lifecycle checks before allowing container state deletion
in the WCOW sidecar.

---

## 4. Potential Improvements (Not Vulnerabilities)

### 4.1 `checkExists` Returns (error, bool) Instead of Idiomatic (bool, error)

**File**: `internal/guest/runtime/hcsv2/uvm.go`, line 383

```go
func checkExists(path string) (error, bool) {
```

This is non-idiomatic Go. The convention is `(bool, error)`. While not a
security issue, it increases the likelihood of misuse.

### 4.2 `osType` Detection in Rego Policy Creation

**File**: `pkg/securitypolicy/securitypolicyenforcer_rego.go`, line 120-128

The `osType` used to create the rego policy is determined elsewhere
(search for uses of `newRegoPolicy`). This is fine but worth noting that the
OS type determines which input fields are sent to the Rego engine, and an
incorrect OS type could lead to policy bypass.

---

## 5. Virtual Pod Mechanism Security Review

The virtual pod mechanism allows multiple Kubernetes pods to share a single UVM.
It is annotation-driven (`io.microsoft.cri.virtual-pod-id`) and was introduced
after the enforcement fixes were written.

### 5.1 Container ID Validation for Virtual Pod IDs (GOOD)

Virtual pod IDs are validated with `checkValidContainerID` at container creation
time (uvm.go line 380-383), requiring the same `[0-9a-fA-F]{64}` format as
regular container IDs. This prevents path traversal attacks via the
`virtualPodID` annotation.

**No issues found.**

### 5.2 Path Generation (GOOD, WITH NOTE)

`VirtualPodRootDir` (`internal/guest/spec/spec.go` line 96-102) includes a
sanitization check:
```go
sanitizedID := filepath.Clean(virtualSandboxID)
if filepath.IsAbs(sanitizedID) || strings.Contains(sanitizedID, "..") {
    return ""
}
```
This is a defense-in-depth measure. Combined with the container ID regex
validation, path traversal via virtual pod IDs is prevented.

Virtual pod paths are under `/run/gcs/c/virtual-pods/<virtualPodID>/` rather
than the standard `/run/gcs/c/<sandboxID>/`. The path functions
(`VirtualPodMountsDir`, `VirtualPodTmpfsMountsDir`,
`VirtualPodHugePagesMountsDir`) all derive from `VirtualPodRootDir` and cannot
escape the intended directory.

**No issues found.**

### 5.3 **FINDING: Policy Sandbox Dir Mismatch with Virtual Pods** (LOW-MEDIUM)

When `EnforceCreateContainerPolicyV2` is called (uvm.go line 601-619), the
`SandboxID` field in `CreateContainerOptions` is set to the regular `sandboxID`
(line 602), which for virtual pod workload containers comes from the
`io.kubernetes.cri.sandbox-id` annotation (line 521-522).

The Rego policy enforcer builds `sandboxDir` and `hugePagesDir` from this
sandbox ID using `SandboxMountsDir(opts.SandboxID)` (securitypolicyenforcer_rego.go
line 753-754), which generates paths like `/run/gcs/c/<sandboxID>/sandboxMounts`.

However, the actual sandbox mounts in the UVM are placed at
`/run/gcs/c/virtual-pods/<virtualPodID>/sandboxMounts` when virtual pods are
active (via `VirtualPodAwareSandboxMountsDir` in workload_container.go line 60).

This means **the Rego policy's `sandboxDir` input does not match the actual
mount source paths** for virtual pod containers. The policy might fail to match
expected sandbox mount patterns, or (more concerning) might inadvertently match
against a different sandbox's mount directory.

In practice, this may cause sandbox mount policy validation to fail (deny valid
mounts) rather than pass (allow invalid mounts), since the pattern mismatch
would make the Rego `mountSource_ok` rule unable to find matching paths. However,
this warrants verification, because if the `sandboxPrefix` replacement logic in
Rego is flexible enough, it might match unintended paths.

**Recommendation**: Verify that the `sandboxDir` input to Rego correctly reflects
the virtual pod's actual mount directory, or confirm that the mount source
rewriting happens before policy evaluation and the policy sees the final paths.

### 5.4 Virtual Pod CRI Type Override (GOOD, WITH NOTE)

When `isVirtualPod && id == virtualPodID` (line 390), the container is forced to
`criType = "sandbox"`. This is driven entirely by the host-provided annotations.
In a confidential context, this means the host can make any container appear as a
sandbox by setting `VirtualPodID == containerID`.

However, this only affects the GCS's own processing flow (sandbox path setup vs
workload path setup) — the actual policy enforcement still validates the
container's spec, mounts, and args against the security policy. The container
is still subject to `checkContainerSettings`, `EnforceCreateContainerPolicyV2`,
etc. A sandbox container has a restricted set of operations (it runs the
"sandbox pause" spec), so treating a container as a sandbox would restrict, not
expand, what is allowed.

**No issues found**, but note that this mechanism is inherently trust-dependent
on the policy properly differentiating sandbox vs workload container specs.

### 5.5 Virtual Pod Cgroup Resource Control (INFORMATIONAL)

`CreateVirtualPod` accepts `pSpec.Linux.Resources` from the OCI spec provided by
the host (uvm.go line 1809-1810) and passes it directly to the cgroup
controller. The host can control the resource limits (memory, CPU) of the
virtual pod's cgroup. This is by design — the host already controls resource
allocation to the UVM. Setting pod-level cgroup limits is a restriction on the
pod, not an escape mechanism.

The cgroup path uses the validated `virtualSandboxID` (uvm.go line 1805):
```go
cgroupPath := path.Join(parentPath, virtualSandboxID)
```
Since `virtualSandboxID` is validated as `[0-9a-fA-F]{64}`, there is no path
traversal risk here.

**No issues found.**

### 5.6 Virtual Pod Cleanup (GOOD)

`RemoveContainerFromVirtualPod` (line 1884) and `cleanupVirtualPod` (line 1920)
properly clean up state. The cleanup of the last container triggers cgroup
deletion and network namespace removal. This is called from `RemoveContainer`
(line 167).

**No issues found.**

---

## 6. BlockDev Device Security Review

The blockdev mechanism allows SCSI devices to be exposed to containers as raw
block devices (symlinks to `/dev/sdX`) rather than mounted filesystems. It is
identified by the `blockdev://` mount prefix.

### 6.1 BlockDev Mount Flow

The host sends an `LCOWMappedVirtualDisk` request with `BlockDev: true`. In
`modifyMappedVirtualDisk` (uvm.go), this is processed the same as any SCSI
device, flowing through:
1. Policy enforcement (`EnforceDeviceMountPolicy` or `EnforceRWDeviceMountPolicy`)
2. `hostMounts` state tracking (`AddRODevice` / `AddRWDevice`)
3. `scsi.Mount()` — which, for BlockDev, creates a symlink instead of mounting

### 6.2 **FINDING: BlockDev Not Expressible in Security Policy — FIX APPLIED** (MEDIUM)

The fundamental security concern with BlockDev mounts is that the security
policy framework has **no way to express whether block device mounts are
allowed**. While the SCSI mount path does go through `EnforceDeviceMountPolicy`
/ `EnforceRWDeviceMountPolicy`, these checks validate the mount path — not
whether the mount creates a symlink to a raw block device vs. mounting a
filesystem.

When `BlockDev=true`:

1. `scsi.Mount()` creates a **symlink** from the mount path to the SCSI device
   (or its verity device) instead of mounting a filesystem. The host controls
   SCSI devices and their content, and we can't prevent the host from attaching
   SCSI devices.

2. `updateBlockDeviceMounts()` (called during container creation) strips the
   `blockdev://` prefix from mount destinations, resolves the symlink, and adds
   **device cgroup rules** to `spec.Linux.Resources.Devices`. These device
   cgroup rules are **not checked by `EnforceCreateContainerPolicyV2`** — only
   `spec.Linux.Devices` (device nodes) are checked via `extraLinuxDevices`.

3. After `updateBlockDeviceMounts` strips the `blockdev://` prefix, the mount
   looks like a regular bind mount to the policy enforcer. The policy has no way
   to distinguish a blockdev mount from a regular mount.

This means the host could use the blockdev mechanism to:
- Create arbitrary symlinks inside the UVM (via `scsi.Mount` with `BlockDev=true`)
- Expose raw block devices to containers with full read/write access
- The container would get device cgroup rules allowing access to the block device

**Fix applied**: Two defense-in-depth checks added:

1. In `modifyMappedVirtualDisk`: Reject `BlockDev=true` early when
   `h.HasSecurityPolicy()` is true, preventing the symlink from being created
   in the first place.

2. In `CreateContainer`: Reject any OCI spec mounts with `blockdev://`
   destination prefix when `h.HasSecurityPolicy()` is true, preventing the
   device cgroup rule addition and mount path rewriting even if a symlink
   somehow existed.

### 6.3 BlockDev Verity Path (INFORMATIONAL)

When `ReadOnly` and `VerityInfo` is set, the verity dm target IS created before
the BlockDev symlink check (scsi.go lines 154-168 run before line 172). So the
symlink would point to the verity device rather than the raw device. This is
correct behavior but is now moot since blockdev is rejected entirely when
security policy is active.

### 6.4 BlockDev Unmount, Device Cgroup, and Host Mounts (INFORMATIONAL)

The following subsections from the previous review are now moot since blockdev is
rejected entirely when security policy is active:

- **Unmount behavior**: `scsi.Unmount` with `BlockDev=true` calls
  `os.RemoveAll(target)` to remove the symlink. No longer reachable with policy.

- **Device cgroup integration**: `updateBlockDeviceMounts` adds device cgroup
  rules to `spec.Linux.Resources.Devices`. These were not policy-checked. No
  longer reachable with policy.

- **Host mounts tracking**: BlockDev SCSI devices went through the same
  `hostMounts` tracking as regular mounts. No longer reachable with policy.

Without a security policy, blockdev continues to work as before — this is the
non-confidential case where the host is trusted.

---

## 7. Overall Assessment

| Area | Rating |
|------|--------|
| LCOW enforcement fixes (uvm.go) | ✅ Well-designed, no issues found |
| Rego policy changes (framework.rego) | ✅ Correct and thorough |
| Policy enforcer interface changes | ✅ Clean extension |
| Compatibility with rebased commits | ✅ No conflicts |
| WCOW gcs-sidecar security | ⚠️ Several gaps identified |
| Virtual pod mechanism | ✅ Mostly good, one policy sandboxDir mismatch (5.3) |
| BlockDev device mechanism | ⚠️ Policy gap found and fixed (6.2) |

The LCOW changes are solid and address a comprehensive set of security concerns.
The WCOW gcs-sidecar code would benefit from similar hardening, particularly
around container ID validation, revertable sections, the mountsBroken fail-closed
mechanism, and lifecycle checks.

The virtual pod mechanism is generally well-handled. The main concern is the
`sandboxDir` input to the Rego policy not reflecting the actual virtual pod mount
directory (Finding 5.3), which should be verified.

The blockdev mechanism was found to have a policy gap: there was no way to
express block device mounts in the security policy, and the device cgroup rules
added by `updateBlockDeviceMounts` bypassed policy checking. A fix was applied to
reject blockdev mounts entirely when a security policy is active (Finding 6.2).
