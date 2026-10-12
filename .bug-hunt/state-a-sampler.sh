#!/bin/bash
# State A: NO PowerMateDriver running. Sample power assertions for ~2.5 min.
# Decisive test: do the phantom PowerMate UserIsActive tickles continue without the app?
echo "=== killing test app (PID from pgrep) ==="
pkill -f "PowerMateDriver" && echo killed || echo "no app was running"
sleep 5
echo "=== confirm dead ==="
pgrep -fl PowerMateDriver || echo "confirmed: no PowerMateDriver running"
echo "=== sampling every 15s x 10 (stay away from mouse/keyboard!) ==="
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 15
    echo "--- sample ${i} at $(date +%H:%M:%S) ---"
    pmset -g assertions | grep -iE "UserIsActive|BTStack" | head -5
done
echo "=== STATE A DONE ==="