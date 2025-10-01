#!/bin/bash
set -e

SESSION="amp_test"
LOG_DIR="/tmp/amp_test_logs"
WORKSPACE="/home/pasky/src/amp.nvim"
TEST_FILE="$WORKSPACE/test_file.txt"

rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

# Clean up old sessions
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Clean logs and lockfiles
rm -f ~/amp_server.log ~/amp_vim_callbacks.log
rm -rf ~/.local/share/amp/ide/*.json

# Create a test file
echo "Test content line 1" > "$TEST_FILE"
echo "Test content line 2" >> "$TEST_FILE"
echo "Test content line 3" >> "$TEST_FILE"

echo "=== Starting tmux test session ==="

# Create tmux session with vim
tmux new-session -d -s "$SESSION" -x 120 -y 40 -c "$WORKSPACE"

# Start vim with the test file
tmux send-keys -t "$SESSION" "vim -u NONE -N '$TEST_FILE'" Enter
sleep 1
tmux send-keys -t "$SESSION" ":set runtimepath+=$WORKSPACE" Enter
sleep 0.5
tmux send-keys -t "$SESSION" ":runtime plugin/amp.vim" Enter
sleep 0.5

# Capture initial state
tmux capture-pane -t "$SESSION" -p > "$LOG_DIR/01_initial.txt"

# Start the server
echo "=== [1/7] Starting AmpStart ==="
tmux send-keys -t "$SESSION" ":AmpStart" Enter
sleep 3

# Capture after start
tmux capture-pane -t "$SESSION" -p > "$LOG_DIR/02_after_start.txt"

# Check status
echo "=== [2/7] Checking AmpStatus ==="
tmux send-keys -t "$SESSION" ":AmpStatus" Enter
sleep 1

# Capture after status
tmux capture-pane -t "$SESSION" -p > "$LOG_DIR/03_after_status.txt"

# Test 1: Send a simple ping to check connection
echo "=== [3/7] Testing WebSocket connection with netcat ==="
PORT=$(grep -oP '"port":\s*\K\d+' ~/.local/share/amp/ide/*.json | head -1)
AUTH=$(grep -oP '"authToken":\s*"\K[^"]+' ~/.local/share/amp/ide/*.json | head -1)

if [ -z "$PORT" ] || [ -z "$AUTH" ]; then
    echo "ERROR: Could not find port or auth token in lockfile"
    cat ~/.local/share/amp/ide/*.json
    exit 1
fi

echo "Port: $PORT, Auth: ${AUTH:0:10}..."

# Create WebSocket test client
cat > "$LOG_DIR/ws_test.py" << 'PYTHON_EOF'
#!/usr/bin/env python3
import asyncio
import json
import sys
import websockets

async def test_connection(port, auth):
    uri = f"ws://127.0.0.1:{port}/?auth={auth}"
    print(f"Connecting to {uri[:50]}...", file=sys.stderr)
    
    try:
        async with websockets.connect(uri) as ws:
            print("Connected!", file=sys.stderr)
            
            # Test 1: Send ping
            ping_msg = {
                "clientRequest": {
                    "id": 1,
                    "ping": {"message": "test"}
                }
            }
            await ws.send(json.dumps(ping_msg))
            print("Sent ping", file=sys.stderr)
            
            response = await asyncio.wait_for(ws.recv(), timeout=5.0)
            print(f"Got response: {response}", file=sys.stderr)
            resp_data = json.loads(response)
            
            if "serverResponse" in resp_data and "ping" in resp_data["serverResponse"]:
                print("✓ Ping test passed", file=sys.stderr)
            else:
                print("✗ Ping test failed", file=sys.stderr)
                return False
            
            # Test 2: Authenticate
            auth_msg = {
                "clientRequest": {
                    "id": 2,
                    "authenticate": {}
                }
            }
            await ws.send(json.dumps(auth_msg))
            print("Sent authenticate", file=sys.stderr)
            
            response = await asyncio.wait_for(ws.recv(), timeout=5.0)
            print(f"Got auth response: {response}", file=sys.stderr)
            resp_data = json.loads(response)
            
            if "serverResponse" in resp_data and "authenticate" in resp_data["serverResponse"]:
                print("✓ Auth test passed", file=sys.stderr)
            else:
                print("✗ Auth test failed", file=sys.stderr)
                return False
            
            # Test 3: Try to read the current file
            read_msg = {
                "clientRequest": {
                    "id": 3,
                    "readFile": {
                        "uri": f"file://{sys.argv[3]}"
                    }
                }
            }
            await ws.send(json.dumps(read_msg))
            print("Sent readFile request", file=sys.stderr)
            
            response = await asyncio.wait_for(ws.recv(), timeout=10.0)
            print(f"Got readFile response: {response[:200]}", file=sys.stderr)
            resp_data = json.loads(response)
            
            if "serverResponse" in resp_data and "readFile" in resp_data["serverResponse"]:
                file_data = resp_data["serverResponse"]["readFile"]
                if file_data.get("success") and "Test content" in file_data.get("content", ""):
                    print("✓ ReadFile test passed", file=sys.stderr)
                    print(f"File content snippet: {file_data.get('content', '')[:100]}", file=sys.stderr)
                else:
                    print("✗ ReadFile test failed", file=sys.stderr)
                    print(f"Response: {file_data}", file=sys.stderr)
                    return False
            else:
                print("✗ ReadFile response format incorrect", file=sys.stderr)
                return False
            
            # Test 4: EditFile - modify the file content
            new_content = "Modified by test line 1\nModified by test line 2\nNew line 3\n"
            edit_msg = {
                "clientRequest": {
                    "id": 4,
                    "editFile": {
                        "uri": f"file://{sys.argv[3]}",
                        "fullContent": new_content
                    }
                }
            }
            await ws.send(json.dumps(edit_msg))
            print("Sent editFile request", file=sys.stderr)
            
            response = await asyncio.wait_for(ws.recv(), timeout=10.0)
            print(f"Got editFile response: {response[:200]}", file=sys.stderr)
            resp_data = json.loads(response)
            
            if "serverResponse" in resp_data and "editFile" in resp_data["serverResponse"]:
                edit_data = resp_data["serverResponse"]["editFile"]
                if edit_data.get("success"):
                    print("✓ EditFile test passed", file=sys.stderr)
                else:
                    print("✗ EditFile test failed", file=sys.stderr)
                    print(f"Response: {edit_data}", file=sys.stderr)
                    return False
            else:
                print("✗ EditFile response format incorrect", file=sys.stderr)
                return False
            
            # Test 5: Read file again to verify edit worked
            await ws.send(json.dumps({
                "clientRequest": {
                    "id": 5,
                    "readFile": {
                        "uri": f"file://{sys.argv[3]}"
                    }
                }
            }))
            print("Sent readFile (verify) request", file=sys.stderr)
            
            response = await asyncio.wait_for(ws.recv(), timeout=10.0)
            resp_data = json.loads(response)
            
            if "serverResponse" in resp_data and "readFile" in resp_data["serverResponse"]:
                file_data = resp_data["serverResponse"]["readFile"]
                content = file_data.get("content", "")
                if file_data.get("success") and "Modified by test" in content and "New line 3" in content:
                    print("✓ EditFile verification passed - content was written correctly", file=sys.stderr)
                    print(f"Verified content: {content[:100]}", file=sys.stderr)
                else:
                    print("✗ EditFile verification failed - content doesn't match", file=sys.stderr)
                    print(f"Expected 'Modified by test', got: {content[:100]}", file=sys.stderr)
                    return False
            else:
                print("✗ ReadFile verification failed", file=sys.stderr)
                return False
            
            print("\n=== All tests passed! ===", file=sys.stderr)
            return True
            
    except asyncio.TimeoutError:
        print("ERROR: Timeout waiting for response", file=sys.stderr)
        return False
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    port = int(sys.argv[1])
    auth = sys.argv[2]
    result = asyncio.run(test_connection(port, auth))
    sys.exit(0 if result else 1)
PYTHON_EOF

chmod +x "$LOG_DIR/ws_test.py"

# Run WebSocket test
python3 "$LOG_DIR/ws_test.py" "$PORT" "$AUTH" "$TEST_FILE" 2>&1 | tee "$LOG_DIR/ws_test_output.txt"
WS_TEST_RESULT=$?

# Capture vim state after WebSocket test
sleep 2
tmux capture-pane -t "$SESSION" -p > "$LOG_DIR/04_after_ws_test.txt"

# Test 4: Real interactive Amp CLI edit test
echo "=== [4/8] Testing real interactive Amp CLI ==="

# Reset test file
cat > "$TEST_FILE" << 'EOF'
Line one original
Line two original
Line three original
EOF

# Reload in Vim
tmux send-keys -t "$SESSION" Escape
sleep 0.5
tmux send-keys -t "$SESSION" ":e!" Enter
sleep 1
tmux send-keys -t "$SESSION" "gg" Enter
sleep 0.5

# Split window and start Amp CLI
tmux split-window -t "$SESSION" -h -c "$WORKSPACE"
sleep 0.5

# Start Amp CLI interactively
tmux send-keys -t "$SESSION:0.1" "npx --yes @sourcegraph/amp@latest --ide" Enter
sleep 8

# Wait for CLI to be ready (look for the input prompt)
echo "Waiting for Amp CLI to be ready..."
sleep 2

# Type the command interactively using send-keys
tmux send-keys -t "$SESSION:0.1" "In the file test_file.txt, change line 1 to say: EDITED BY AMP CLI" Enter
echo "Waiting for Amp to process command (this takes time)..."
sleep 35

# Capture CLI pane
tmux capture-pane -t "$SESSION:0.1" -p > "$LOG_DIR/amp_cli_pane.txt"

# Kill CLI
tmux send-keys -t "$SESSION:0.1" C-c
sleep 1
tmux kill-pane -t "$SESSION:0.1" 2>/dev/null || true

# Back to Vim pane - check buffer WITHOUT reload
sleep 1
tmux send-keys -t "$SESSION" "gg" Enter
sleep 0.5
tmux capture-pane -t "$SESSION" -p > "$LOG_DIR/05_vim_after_amp.txt"

# Check results
BUFFER_EDIT_RESULT=1
FILE_EDITED=0
BUFFER_EDITED=0

if grep -qi "EDITED BY AMP CLI" "$TEST_FILE" 2>/dev/null; then
    FILE_EDITED=1
    echo "✓ Amp CLI edited file on disk"
else
    echo "✗ File not edited on disk"
fi

if grep -qi "EDITED BY AMP CLI" "$LOG_DIR/05_vim_after_amp.txt" 2>/dev/null; then
    BUFFER_EDITED=1
    echo "✓ Edit visible in Vim buffer (editFile protocol working!)"
else
    echo "✗ Edit NOT visible in Vim buffer"
fi

if [ $FILE_EDITED -eq 1 ] && [ $BUFFER_EDITED -eq 1 ]; then
    BUFFER_EDIT_RESULT=0
    echo "✓ Amp CLI end-to-end test PASSED"
else
    BUFFER_EDIT_RESULT=1
    echo "✗ Amp CLI end-to-end test FAILED"
fi

# Test 5: Selection tracking
echo "=== [5/8] Testing selection tracking ==="
tmux send-keys -t "$SESSION" "gg"  # Go to first line
sleep 0.5
tmux send-keys -t "$SESSION" "V"   # Visual line mode
sleep 0.5
tmux send-keys -t "$SESSION" "j"   # Select two lines
sleep 1

tmux capture-pane -t "$SESSION" -p > "$LOG_DIR/06_after_selection.txt"

# Test 6: File switching
echo "=== [6/8] Testing file switching ==="
tmux send-keys -t "$SESSION" Escape
sleep 0.5
tmux send-keys -t "$SESSION" ":e README.md" Enter
sleep 1

tmux capture-pane -t "$SESSION" -p > "$LOG_DIR/07_after_file_switch.txt"

# Check messages in vim
echo "=== [7/8] Checking Vim messages ==="
tmux send-keys -t "$SESSION" ":messages" Enter
sleep 1
tmux capture-pane -t "$SESSION" -p > "$LOG_DIR/08_messages.txt"

# Final check was already done in step 4 above
echo ""
echo "Edit tests completed"

# Stop server
echo "=== [8/8] Stopping server ==="
tmux send-keys -t "$SESSION" ":AmpStop" Enter
sleep 1
tmux capture-pane -t "$SESSION" -p > "$LOG_DIR/08_after_stop.txt"

# Quit vim
tmux send-keys -t "$SESSION" ":qa!" Enter
sleep 1

# Kill session
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Save test file content for reporting
cp "$TEST_FILE" "$LOG_DIR/test_file_final.txt" 2>/dev/null || true

# Cleanup test file
rm -f "$TEST_FILE"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                     TEST RESULTS                           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check WebSocket test result
if [ $WS_TEST_RESULT -eq 0 ]; then
    echo "✓ WebSocket Communication Test: PASSED"
else
    echo "✗ WebSocket Communication Test: FAILED"
fi

# Check Amp CLI result
if [ $BUFFER_EDIT_RESULT -eq 0 ]; then
    echo "✓ Amp CLI Edit Test: PASSED"
else
    echo "✗ Amp CLI Edit Test: FAILED"
fi

echo ""
echo "=== Vim output after AmpStart ==="
tail -15 "$LOG_DIR/02_after_start.txt"

echo ""
echo "=== Vim output after AmpStatus ==="
tail -10 "$LOG_DIR/03_after_status.txt"

echo ""
echo "=== WebSocket Test Output ==="
cat "$LOG_DIR/ws_test_output.txt"

echo ""
echo "=== Vim Callback Log ==="
if [ -f ~/amp_vim_callbacks.log ]; then
    echo "Callbacks received: $(wc -l < ~/amp_vim_callbacks.log) lines"
    tail -30 ~/amp_vim_callbacks.log
else
    echo "✗ No callbacks received from Python server"
fi

echo ""
echo "=== Python Server Log (last 40 lines) ==="
if [ -f ~/amp_server.log ]; then
    tail -40 ~/amp_server.log
else
    echo "✗ No server log found"
fi

echo ""
echo "=== Lockfile Contents ==="
if [ -d ~/.local/share/amp/ide/ ] && [ -n "$(ls -A ~/.local/share/amp/ide/ 2>/dev/null)" ]; then
    cat ~/.local/share/amp/ide/*.json 2>/dev/null | python3 -m json.tool
else
    echo "No lockfiles (may have been cleaned up)"
fi

echo ""
echo "=== Test File Content After Amp Edit ==="
cat "$LOG_DIR/test_file_final.txt" 2>/dev/null || echo "Test file not found"

echo ""
echo "=== Vim Buffer After Amp CLI Edit (first 10 lines) ==="
head -10 "$LOG_DIR/05_vim_after_amp.txt" 2>/dev/null || echo "Buffer capture not found"

echo ""
echo "=== Amp CLI Pane Output (last 20 lines) ==="
tail -20 "$LOG_DIR/amp_cli_pane.txt" 2>/dev/null || echo "No CLI output"

echo ""
echo "=== Summary ==="
echo "Full logs saved to: $LOG_DIR"
if [ $WS_TEST_RESULT -eq 0 ] && [ $BUFFER_EDIT_RESULT -eq 0 ]; then
    echo "✓ OVERALL: ALL TESTS PASSED (including real Amp CLI)"
    exit 0
else
    echo "✗ OVERALL: SOME TESTS FAILED"
    [ $WS_TEST_RESULT -ne 0 ] && echo "  - WebSocket tests failed"
    [ $BUFFER_EDIT_RESULT -ne 0 ] && echo "  - Amp CLI edit test failed"
    exit 1
fi
