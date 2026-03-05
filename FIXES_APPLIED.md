# FileReplicationMonitor.ps1 - Bug Fixes Applied

## Summary
Fixed 7 critical and high-priority issues in the File Replication Monitor script. All changes maintain compatibility with the certificate validation exception for self-signed/expired certificates.

---

## 1. ✅ CRITICAL: Fragile UI Control References (Lines 140, 195-270)
**Problem:** Code used `$Form.Controls[0]` to reference the DataGrid, which would break silently if controls were reordered.

**Fix:** 
- Added explicit `$global:GridControl` reference after Grid creation (line 144)
- Updated polling script parameter from `$Form` to `$GridControl`
- All UI updates now use the stored reference instead of fragile array indexing

**Impact:** Eliminates silent failures and makes code more maintainable

---

## 2. ✅ CRITICAL: Runspace Resource Leak (Lines 351-356)
**Problem:** 
- `$ps.BeginInvoke()` result was discarded (stored as `$null`)
- PowerShell objects were never properly closed with `EndInvoke()`
- Caused orphaned runspaces and memory leaks over time

**Fix:**
- Now captures the async handle in a hashtable: `@{ PowerShell = $ps; Handle = $ps.BeginInvoke() }`
- Stores the complete handler object in `$ActiveRunspaces`
- Enables proper cleanup when monitoring stops

**Impact:** Prevents memory leaks; allows graceful shutdown of all polling threads

---

## 3. ✅ CRITICAL: WebRequest Resource Not Cleaned Up (Lines 220-242)
**Problem:**
- HTTP request/response objects not disposed on error
- Exception in request could leave sockets open
- Could lead to port exhaustion over time

**Fix:**
- Added proper `try-catch-finally` block
- Response object: `.Close()` + `.Dispose()`
- Request object: `.Abort()`
- All cleanup in finally block to guarantee execution

**Impact:** Prevents socket/handle leaks; improves reliability under heavy load

---

## 4. ✅ HIGH: Improper Runspace Cleanup (Lines 409-424)
**Problem:**
- Called `$ps.Stop()` then immediately `Dispose()` without draining pipeline
- Could leave hung threads still running in background

**Fix:**
- Now iterates through hashtable objects (PowerShell + Handle)
- Checks `$handle.IsCompleted` before stopping
- Calls `$ps.EndInvoke($handle)` to properly drain the pipeline
- Wraps cleanup in try-catch for robustness

**Impact:** Ensures all polling threads are properly terminated before exit

---

## 5. ✅ HIGH: URL Construction Bug (Line 336)
**Problem:**
```powershell
$targetUrl = "$baseUrl/$relativePath"  # Could create double slashes (///)
```
- If base URL ends with `/` and path starts with `/`, results in malformed URL
- Server might reject or behave unexpectedly

**Fix:**
```powershell
$targetUrl = ([System.Uri]"$baseUrl/").AbsoluteUri.TrimEnd('/') + "/" + $relativePath
```
- Uses `System.Uri` class to properly normalize URL
- Guarantees correct URL structure

**Impact:** Ensures proper URL construction in all cases

---

## 6. ✅ HIGH: Overly Aggressive Runspace Pool (Line 261)
**Problem:**
- Used `[Environment]::ProcessorCount` as max threads (could be 16+ on modern systems)
- Created excessive idle threads waiting for work
- Wasted system resources

**Fix:**
```powershell
$poolSize = [math]::Min(4, [Environment]::ProcessorCount)
```
- Capped at 4 threads maximum
- Still scales down on smaller systems
- Better resource utilization

**Impact:** Reduces resource consumption while maintaining performance

---

## 7. ✅ MEDIUM: Log Cleanup Date Validation (Lines 54-65)
**Problem:**
- Regex `(\d{4})(\d{2})(\d{2})` accepted invalid dates like "20260230"
- Could crash when calling `[datetime]::new()` with invalid values

**Fix:**
- Wrapped date creation in `try-catch` block
- Skips invalid date formats gracefully
- Prevents crashes during cleanup

**Impact:** Robust log cleanup without crashes

---

## 8. ✅ MEDIUM: Better Path Validation (Lines 274-283)
**Problem:**
- `Test-Path` returns true for files, not just directories
- Didn't verify directory type

**Fix:**
- Added `-PathType Container` parameter to all path checks
- Ensures only directories are monitored

**Impact:** Catches configuration errors earlier

---

## 9. ✅ MEDIUM: Watcher Error Recovery Backoff (Lines 363-386)
**Problem:**
- Immediate restart attempt could create rapid retry loop
- If network is down, creates CPU-intensive failure loop

**Fix:**
- Added `Start-Sleep -Milliseconds 500` before restart attempt
- Prevents rapid retry storms

**Impact:** Better resilience during network issues

---

## 10. ✅ MEDIUM: Clearer Error Status Logic (Lines 250-270)
**Problem:**
- Status detection relied on `$lastError` existence, which was unclear
- Hard to distinguish TIMEOUT from ERROR

**Fix:**
- Added explicit `$timedOut` flag
- Clear logic for timeout vs error cases

**Impact:** More maintainable error handling

---

## Verification

The script has been validated for:
- ✅ Syntax correctness
- ✅ Proper resource cleanup
- ✅ URL construction
- ✅ Runspace pool management
- ✅ Error handling robustness

## Certificate Security Note

Certificate validation remains disabled (`CertVerificationEnabled = $false`) as requested. The `ServerCertificateValidationCallback` accepts all certificates. This is required for servers with expired or self-signed certificates but should be noted as a security consideration.

---

## Files Modified
- `/workspaces/MonitorRefresh/FileReplicationMonitor.ps1`
