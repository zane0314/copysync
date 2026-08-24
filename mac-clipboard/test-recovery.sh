#!/bin/zsh
set -euo pipefail
root=${0:A:h}
source_file="$root/CopySync.m"
for token in webViewWebContentProcessDidTerminate didFailProvisionalNavigation didFailNavigation scheduleWebViewRecovery recoverWebView NSURLErrorCancelled WebKitPolicyChangeError; do
  rg -q --fixed-strings "$token" "$source_file"
done
clang -fobjc-arc -fsyntax-only "$source_file"
