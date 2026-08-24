# CopySync macOS WebView Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automatic recovery for terminated or failed macOS WKWebView navigation, release `2.2 (build 35)`, and replace the installed CopySync app with a signed, verified build.

**Architecture:** Keep the existing WKWebView and route all recovery callbacks through one delayed, deduplicated reload method. Preserve cookies, the data store, and the native message bridge. Use one source-level regression script plus a real WebContent termination fault injection.

**Tech Stack:** Objective-C ARC, AppKit, WebKit, zsh, clang, codesign, hdiutil, ditto.

## Global Constraints

- Modify only the macOS client, Mac update metadata, and their tests/artifacts.
- Version must be `2.2`; build must be `35`.
- Keep bundle identifier `com.example.copysync` and minimum macOS version `13.0`.
- Keep the existing `CopySync Local Signing` identity so TCC permissions survive replacement.
- Do not modify or deploy the web backend or Android client.
- Do not push GitHub or deploy the update server.

---

### Task 1: WebView recovery and regression check

**Files:**
- Create: `mac-clipboard/test-recovery.sh`
- Modify: `mac-clipboard/CopySync.m:44-82`
- Modify: `mac-clipboard/CopySync.m:1172-1175`

**Interfaces:**
- Consumes: existing global `Site`, `self.webView`, and `setStatusOK:message:`.
- Produces: `scheduleWebViewRecovery:`, `recoverWebView`, and three `WKNavigationDelegate` failure/termination callbacks.

- [ ] **Step 1: Write the failing source regression check**

Create this executable zsh script:

```zsh
#!/bin/zsh
set -euo pipefail
root=${0:A:h}
source_file="$root/CopySync.m"
for token in webViewWebContentProcessDidTerminate didFailProvisionalNavigation didFailNavigation scheduleWebViewRecovery recoverWebView NSURLErrorCancelled WKErrorFrameLoadInterruptedByPolicyChange; do
  rg -q --fixed-strings "$token" "$source_file"
done
clang -fobjc-arc -fsyntax-only "$source_file" -framework Cocoa -framework ApplicationServices -framework Carbon -framework ServiceManagement -framework UserNotifications -framework WebKit
```

- [ ] **Step 2: Run the check and confirm the pre-fix failure**

Run: `zsh mac-clipboard/test-recovery.sh`

Expected: nonzero exit because the recovery selectors do not exist yet.

- [ ] **Step 3: Implement the minimum shared recovery path**

Add these properties and methods:

```objc
@property (assign) BOOL webRecoveryScheduled;
@property (assign) BOOL webRecoveryInProgress;

- (void)scheduleWebViewRecovery:(NSError *)error {
    if (error && (([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) ||
                  ([error.domain isEqualToString:WKErrorDomain] && error.code == WKErrorFrameLoadInterruptedByPolicyChange))) return;
    if (self.webRecoveryScheduled) return;
    self.webRecoveryScheduled = YES;
    [self setStatusOK:NO message:@"页面连接中断，正在恢复"];
    [self performSelector:@selector(recoverWebView) withObject:nil afterDelay:1.0];
}

- (void)recoverWebView {
    self.webRecoveryScheduled = NO;
    self.webRecoveryInProgress = YES;
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:Site]
                                             cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                         timeoutInterval:30];
    [self.webView loadRequest:request];
}
```

Add these delegate behaviors:

```objc
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error;
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error;
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView;
```

Use these callback bodies and keep the existing JavaScript injection after the new prologue:

```objc
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (webView == self.webView) [self scheduleWebViewRecovery:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (webView == self.webView) [self scheduleWebViewRecovery:error];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    if (webView == self.webView) [self scheduleWebViewRecovery:nil];
}

// First lines inside the existing didFinishNavigation:
BOOL recovered = self.webRecoveryInProgress;
[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(recoverWebView) object:nil];
self.webRecoveryScheduled = NO;
self.webRecoveryInProgress = NO;
if (recovered) [self setStatusOK:YES message:@"页面已恢复"];
```

- [ ] **Step 4: Run the regression check**

Run: `zsh mac-clipboard/test-recovery.sh`

Expected: exit 0, all static assertions present, Objective-C syntax check succeeds.

### Task 2: Version, signed artifacts, and update manifest

**Files:**
- Modify: `mac-clipboard/Info.plist:11-12`
- Modify: `updates/mac.json`
- Generate locally: `mac-clipboard/build-2.0/CopySync.app`
- Generate locally: `mac-clipboard/build-2.0/CopySync-2.0.dmg`
- Generate locally: `updates/CopySync-Mac-latest.zip`

**Interfaces:**
- Consumes: Task 1 source, the local `AppIcon.icns`, and keychain identity `CopySync Local Signing`.
- Produces: signed `2.2 (35)` app, DMG, ZIP, and matching SHA-256 manifest.

- [ ] **Step 1: Update version metadata**

Set `CFBundleShortVersionString` to `2.2` and `CFBundleVersion` to `35`. Set `updates/mac.json` version/build to the same values and replace notes with a concise description of automatic WebView recovery.

- [ ] **Step 2: Supply the existing icon and build**

If `mac-clipboard/AppIcon.icns` is absent, copy it from `<source-project>/mac-clipboard/AppIcon.icns`. Verify `CopySync Local Signing` exists, then run `zsh mac-clipboard/build-dmg.sh`.

Expected: exit 0 and both app and DMG exist.

- [ ] **Step 3: Verify signature and versions**

Run `codesign --verify --deep --strict --verbose=2 mac-clipboard/build-2.0/CopySync.app`, inspect `codesign -dv --verbose=4`, and inspect both version keys with `plutil`.

Expected: strict verification succeeds, authority is `CopySync Local Signing`, version is `2.2`, build is `35`.

- [ ] **Step 4: Create ZIP and update its checksum**

Use `ditto -c -k --sequesterRsrc --keepParent mac-clipboard/build-2.0/CopySync.app updates/CopySync-Mac-latest.zip`. Calculate SHA-256 with `shasum -a 256` and write the exact digest to `updates/mac.json`.

- [ ] **Step 5: Verify packaged truth**

Extract the ZIP to a new `mktemp -d` directory, verify its embedded app signature and `2.2 (35)` metadata, and confirm the manifest digest exactly equals the ZIP digest.

### Task 3: Safe replacement and live fault injection

**Files:**
- Replace: `/Applications/CopySync.app`
- Temporary backup: an explicit `mktemp -d` directory outside `/Applications`

**Interfaces:**
- Consumes: Task 2 signed app.
- Produces: running `/Applications/CopySync.app` version `2.2 (35)` with verified automatic WebContent recovery.

- [ ] **Step 1: Stop and back up the current app**

Create a temporary directory with `mktemp -d /tmp/copysync-backup.XXXXXX`, request normal termination using `osascript`, and wait with bounded polling until the CopySync process exits. Validate that the generated directory starts with `/tmp/copysync-backup.` and that `/Applications/CopySync.app/Contents/MacOS/CopySync` exists, then move the current app to the explicit path `$backup_dir/CopySync.app`. Do not use recursive deletion on `/Applications`.

- [ ] **Step 2: Replace and launch**

Copy the signed build into `/Applications/CopySync.app` with `ditto`, verify the executable exists, and launch it with `open -a CopySync`.

- [ ] **Step 3: Verify installed state**

Verify the installed signature, `2.2 (35)` metadata, running process, and successful HTTPS response from `https://copy-direct.example.com/?app=mac`.

- [ ] **Step 4: Inject WebContent termination**

Resolve the WebContent PID associated with the running CopySync instance using process inspection. Only when the target is unambiguous, send normal `TERM` to that one WebContent PID. Confirm CopySync itself remains running, a replacement WebContent process appears, and the app remains open for at least five seconds after recovery.

- [ ] **Step 5: Handle verification outcome**

If any replacement or live verification fails, stop the new app and restore the backup using `ditto`. If all checks pass, keep the temporary backup path in the handoff until the parent agent finishes final review; do not delete it automatically.
