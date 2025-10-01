#!/usr/bin/env python3
"""
WebSocket server for amp.nvim (Vim port).
Bridges Vim (via stdin/stdout JSON-RPC) with WebSocket clients (Amp CLI).
"""

import asyncio
import json
import logging
import os
import sys
import secrets
import websockets
from pathlib import Path
from typing import Optional, Dict, Set
from urllib.parse import urlparse, parse_qs

# Setup logging
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.FileHandler(os.path.expanduser('~/amp_server.log'))
    ]
)


class AmpServer:
    def __init__(self):
        self.port: Optional[int] = None
        self.auth_token: str = secrets.token_urlsafe(24)
        self.lockfile_path: Optional[Path] = None
        self.ws_clients: Set[websockets.WebSocketServerProtocol] = set()
        self.request_counter = 0
        self.pending_requests: Dict[int, asyncio.Future] = {}
        
    def get_lockfile_dir(self) -> Path:
        """Get lockfile directory following amp repository pattern."""
        override = os.getenv("AMP_DATA_HOME")
        if override:
            return Path(override) / "amp" / "ide"
        
        xdg = os.getenv("XDG_DATA_HOME")
        if xdg:
            base = Path(xdg)
        else:
            base = Path.home() / ".local" / "share"
        
        return base / "amp" / "ide"
    
    def create_lockfile(self) -> None:
        """Create lockfile with port, auth token, and PID."""
        lock_dir = self.get_lockfile_dir()
        lock_dir.mkdir(parents=True, exist_ok=True)
        
        self.lockfile_path = lock_dir / f"{self.port}.json"
        
        lockfile_data = {
            "port": self.port,
            "authToken": self.auth_token,
            "pid": os.getpid(),
            "workspaceFolders": [os.getcwd()],
            "ideName": f"vim {sys.version_info.major}.{sys.version_info.minor}"
        }
        
        self.lockfile_path.write_text(json.dumps(lockfile_data))
    
    def delete_lockfile(self) -> None:
        """Delete lockfile on shutdown."""
        if self.lockfile_path and self.lockfile_path.exists():
            self.lockfile_path.unlink()
    
    async def handle_websocket(self, websocket):
        """Handle WebSocket client connection."""
        # Validate auth token from query params
        # In websockets v15+, use websocket.request.path (ServerConnection)
        try:
            if hasattr(websocket, 'request') and hasattr(websocket.request, 'path'):
                path = websocket.request.path
            elif hasattr(websocket, 'path'):
                path = websocket.path
            else:
                # Fallback: extract from request_uri
                path = websocket.request_uri if hasattr(websocket, 'request_uri') else '/'
            
            parsed = urlparse(path)
            query = parse_qs(parsed.query)
            # Amp CLI sends 'auth' parameter, not 'token'
            token = query.get('auth', [None])[0]
            
            if token != self.auth_token:
                logging.error(f"Auth failed: got '{token}', expected '{self.auth_token}'")
                await websocket.close(1008, "Invalid auth token")
                return
        except Exception as e:
            logging.error(f"Error parsing auth token: {e}")
            await websocket.close(1008, "Auth error")
            return
        
        self.ws_clients.add(websocket)
        await self.send_to_vim({"method": "clientConnected", "params": {}})
        
        try:
            async for message in websocket:
                await self.handle_ws_message(websocket, message)
        except websockets.exceptions.ConnectionClosed:
            pass
        finally:
            self.ws_clients.discard(websocket)
            await self.send_to_vim({"method": "clientDisconnected", "params": {}})
    
    async def handle_ws_message(self, websocket, message: str):
        """Handle message from WebSocket client."""
        try:
            data = json.loads(message)
            logging.debug(f"Received WS message: {message[:200]}")
            client_request = data.get("clientRequest")
            
            if not client_request:
                return
            
            request_id = client_request.get("id")
            
            # Handle ping
            if "ping" in client_request:
                response = {
                    "serverResponse": {
                        "id": request_id,
                        "ping": {"message": client_request["ping"].get("message", "")}
                    }
                }
                await websocket.send(json.dumps(response))
                return
            
            # Handle authenticate
            if "authenticate" in client_request:
                response = {
                    "serverResponse": {
                        "id": request_id,
                        "authenticate": {"authenticated": True}
                    }
                }
                await websocket.send(json.dumps(response))
                return
            
            # Forward readFile/editFile to Vim
            if "readFile" in client_request:
                # Convert uri to path for Vim, or pass through existing path
                read_req = client_request["readFile"]
                params = {}
                
                if "path" in read_req:
                    # Amp CLI sends path directly
                    params["path"] = read_req["path"]
                elif "uri" in read_req:
                    # Some clients send uri, convert to path
                    uri = read_req["uri"]
                    if uri.startswith("file://"):
                        params["path"] = uri[7:]
                    else:
                        params["path"] = uri
                
                result = await self.request_vim("readFile", params)
                
                # Add success flag if result has content
                if "content" in result:
                    result["success"] = True
                
                response = {
                    "serverResponse": {
                        "id": request_id,
                        "readFile": result
                    }
                }
                await websocket.send(json.dumps(response))
            
            elif "editFile" in client_request:
                # Convert uri to path for Vim, or pass through existing path
                edit_req = client_request["editFile"]
                params = {}
                
                if "path" in edit_req:
                    # Amp CLI sends path directly
                    params["path"] = edit_req["path"]
                elif "uri" in edit_req:
                    # Some clients send uri, convert to path
                    uri = edit_req["uri"]
                    if uri.startswith("file://"):
                        params["path"] = uri[7:]
                    else:
                        params["path"] = uri
                        
                if "fullContent" in edit_req:
                    params["fullContent"] = edit_req["fullContent"]
                
                result = await self.request_vim("editFile", params)
                response = {
                    "serverResponse": {
                        "id": request_id,
                        "editFile": result
                    }
                }
                await websocket.send(json.dumps(response))
                
        except json.JSONDecodeError:
            pass
        except Exception as e:
            logging.error(f"Error handling WebSocket message: {e}")
    
    async def request_vim(self, method: str, params: dict) -> dict:
        """Send request to Vim and wait for response."""
        self.request_counter += 1
        request_id = self.request_counter
        
        future = asyncio.Future()
        self.pending_requests[request_id] = future
        
        request = {
            "method": method,
            "params": params,
            "id": request_id
        }
        
        await self.send_to_vim(request)
        
        try:
            result = await asyncio.wait_for(future, timeout=30.0)
            return result
        except asyncio.TimeoutError:
            return {"success": False, "message": "Request timeout"}
        finally:
            self.pending_requests.pop(request_id, None)
    
    async def send_to_vim(self, message: dict):
        """Send JSON-RPC message to Vim via stdout."""
        line = json.dumps(message) + "\n"
        sys.stdout.write(line)
        sys.stdout.flush()
    
    async def handle_vim_message(self, line: str):
        """Handle message from Vim."""
        try:
            data = json.loads(line)
            
            # Vim's ch_sendexpr sends [seq_num, message] arrays
            if isinstance(data, list) and len(data) >= 2:
                data = data[1]  # Extract the actual message from [seq, msg]
            
            # Handle response to our request
            if "id" in data:
                request_id = data["id"]
                future = self.pending_requests.get(request_id)
                if future and not future.done():
                    if "result" in data:
                        future.set_result(data["result"])
                    elif "error" in data:
                        future.set_result({"success": False, "message": data["error"]["message"]})
                return
            
            # Handle broadcast notification
            if data.get("method") == "broadcast":
                server_notification = data.get("params", {}).get("serverNotification")
                if server_notification:
                    logging.info(f"Broadcasting to clients: {list(server_notification.keys())}")
                    message = {"serverNotification": server_notification}
                    await self.broadcast_to_ws_clients(json.dumps(message))
            
            # Handle stop request from Vim
            if data.get("method") == "stop":
                logging.info("Received stop request from Vim, shutting down")
                await self.shutdown()
                # Exit the process
                import os
                os._exit(0)
            
        except json.JSONDecodeError:
            pass
        except Exception as e:
            logging.error(f"Error handling Vim message: {e}")
    
    async def broadcast_to_ws_clients(self, message: str):
        """Broadcast message to all WebSocket clients."""
        if self.ws_clients:
            await asyncio.gather(
                *[client.send(message) for client in self.ws_clients],
                return_exceptions=True
            )
    
    async def read_stdin(self):
        """Read JSON-RPC messages from stdin."""
        # Always use thread-based reader for Vim compatibility
        # Vim's channel I/O doesn't work well with asyncio pipes
        loop = asyncio.get_event_loop()
        logging.info("Stdin reader: thread mode (Vim compatible)")
        
        import threading
        import select
        def stdin_reader():
            logging.debug("Thread: starting stdin loop")
            while True:
                try:
                    # Use select to check if data is available
                    if select.select([sys.stdin], [], [], 1.0)[0]:
                        line = sys.stdin.readline()
                        if not line:
                            # EOF on stdin - Vim closed the pipe
                            # Server should keep running for WebSocket clients
                            logging.info("Thread: stdin closed, continuing to serve WebSocket")
                            break
                        logging.debug(f"Thread: got line: {line[:80]}")
                        asyncio.run_coroutine_threadsafe(
                            self.handle_vim_message(line.strip()),
                            loop
                        )
                except Exception as e:
                    logging.error(f"Thread: stdin error: {e}")
                    break
        
        thread = threading.Thread(target=stdin_reader, daemon=True)
        thread.start()
        
        # Keep asyncio loop alive
        while True:
            await asyncio.sleep(1)
    
    async def start(self):
        """Start WebSocket server."""
        # Start server on random port
        server = await websockets.serve(
            self.handle_websocket,
            "127.0.0.1",
            0  # Let OS choose port
        )
        
        # Get assigned port
        self.port = server.sockets[0].getsockname()[1]
        
        # Create lockfile
        self.create_lockfile()
        
        # Notify Vim
        await self.send_to_vim({
            "method": "serverStarted",
            "params": {"port": self.port}
        })
        
        # Start stdin reader
        stdin_task = asyncio.create_task(self.read_stdin())
        
        # Keep server running
        await stdin_task
    
    async def shutdown(self):
        """Graceful shutdown."""
        # Close all WebSocket connections
        if self.ws_clients:
            await asyncio.gather(
                *[client.close() for client in self.ws_clients],
                return_exceptions=True
            )
        
        # Delete lockfile
        self.delete_lockfile()


async def main():
    server = AmpServer()
    
    try:
        await server.start()
    except KeyboardInterrupt:
        pass
    finally:
        await server.shutdown()


if __name__ == "__main__":
    asyncio.run(main())
