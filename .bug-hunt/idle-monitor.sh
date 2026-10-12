#!/bin/bash
# Idle monitor: watch power assertions for ~3 minutes without user input.
# Goal: see if the running PowerMateDriver keeps UserIsActive / BTStack assertions alive.
pmset -g | grep -E " sleep|womp|tcpkeepalive"
echo "=== 3-min idle monitor starting (don't touch the mouse or PowerMate) ==="
for i in 1 2 3 4 5 6; do
    sleep 30
    echo "--- t+${i}x30s ---"
    pmset -g assertions | grep -iE "UserIsActive|BTStack" | head -4
done
echo "=== app log growth (phantom events?) ==="
wc -l /tmp/claude-501/pmtest/app-run.log
grep -c "Menu: title" /tmp/claude-501/pmtest/app-run.log