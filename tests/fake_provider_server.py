#!/usr/bin/env python3
"""Local HTTP fixture for deterministic CLI and real-transport tests."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import time


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/slow":
            body = b"eventually"
            self.send_response(200)
            self.send_header("content-type", "text/plain")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.flush()
            time.sleep(0.25)
            try:
                self.wfile.write(body)
            except BrokenPipeError:
                pass
            return
        if self.path == "/stream":
            body = b"data: one\n\ndata: two\n"
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            return
        if self.path != "/health":
            self.send_error(404)
            return
        body = b"healthy"
        self.send_response(200)
        self.send_header("content-type", "text/plain")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        length = int(self.headers.get("content-length", "0"))
        request_body = self.rfile.read(length)

        if self.path == "/stream":
            body = b"data: one\n\ndata: two\n"
        elif self.path == "/openai/responses" and self.headers.get("authorization"):
            wants_tool = b'"tools"' in request_body and b'"function_call_output"' not in request_body
            if wants_tool and b'"stream":true' in request_body:
                body = b'data: {"type":"response.function_call_arguments.delta","item_id":"call_echo","delta":"{\\"value\\":\\"ok\\"}"}\n\ndata: {"type":"response.function_call_arguments.done","item_id":"call_echo","name":"echo","arguments":"{\\"value\\":\\"ok\\"}"}\n\ndata: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}\n\ndata: [DONE]\n'
            elif wants_tool:
                body = b'{"output":[{"type":"function_call","call_id":"call_echo","name":"echo","arguments":"{\\"value\\":\\"ok\\"}"}],"usage":{"input_tokens":1,"output_tokens":1}}'
            elif b'"stream":true' in request_body:
                body = b'data: {"type":"response.output_text.delta","delta":"pong"}\n\ndata: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}\n\ndata: [DONE]\n'
            else:
                body = b'{"output":[{"type":"message","content":[{"type":"output_text","text":"pong"}]}],"usage":{"input_tokens":1,"output_tokens":1}}'
        elif self.path == "/anthropic/messages" and self.headers.get("x-api-key"):
            wants_tool = b'"tools"' in request_body and b'"tool_result"' not in request_body
            if wants_tool and b'"stream":true' in request_body:
                body = b'data: {"type":"message_start","message":{"usage":{"input_tokens":1}}}\n\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call_echo","name":"echo"}}\n\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"value\\":\\"ok\\"}"}}\n\ndata: {"type":"content_block_stop","index":0}\n\ndata: {"type":"message_delta","usage":{"output_tokens":1}}\n'
            elif wants_tool:
                body = b'{"content":[{"type":"tool_use","id":"call_echo","name":"echo","input":{"value":"ok"}}],"usage":{"input_tokens":1,"output_tokens":1}}'
            elif b'"stream":true' in request_body:
                body = b'data: {"type":"message_start","message":{"usage":{"input_tokens":1}}}\n\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"pong"}}\n\ndata: {"type":"message_delta","usage":{"output_tokens":1}}\n'
            else:
                body = b'{"content":[{"type":"text","text":"pong"}],"usage":{"input_tokens":1,"output_tokens":1}}'
        elif (
            self.path == "/google/models/gemini-2.5-flash-lite:streamGenerateContent?alt=sse"
            and self.headers.get("x-goog-api-key")
        ):
            wants_tool = b'"functionDeclarations"' in request_body and b'"functionResponse"' not in request_body
            if wants_tool:
                body = b'data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"echo","args":{"value":"ok"},"id":"call_echo"}}]}}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1}}\n'
            else:
                body = b'data: {"candidates":[{"content":{"parts":[{"text":"pong"}]}}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1}}\n'
        elif (
            self.path == "/google/models/gemini-2.5-flash-lite:generateContent"
            and self.headers.get("x-goog-api-key")
        ):
            wants_tool = b'"functionDeclarations"' in request_body and b'"functionResponse"' not in request_body
            if wants_tool:
                body = b'{"candidates":[{"content":{"parts":[{"functionCall":{"name":"echo","args":{"value":"ok"},"id":"call_echo"}}]}}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1}}'
            else:
                body = b'{"candidates":[{"content":{"parts":[{"text":"pong"}]}}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1}}'
        else:
            self.send_error(404)
            return

        self.send_response(200)
        self.send_header("content-type", "text/event-stream" if b"data:" in body else "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass


host = os.environ.get("ZIGAI_FIXTURE_HOST", "127.0.0.1")
ThreadingHTTPServer((host, 18765), Handler).serve_forever()
