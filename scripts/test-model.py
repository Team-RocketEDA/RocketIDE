#!/usr/bin/env python3
"""TEST ONLY, for CI: a scripted stand-in for the Meta Model API, so the Live build page can be seen working without a
key. It "builds" a small counter one file at a time. It isn't a model, it never runs in normal use, and nothing it
produces is a sample run. Usage: test-model.py <port>
"""
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

COUNTER = """module counter #(parameter W = 8) (
  input  wire         clk,
  input  wire         rst_n,
  input  wire         en,
  output reg  [W-1:0] count
);
  always @(posedge clk or negedge rst_n)
    if (!rst_n) count <= 0;
    else if (en) count <= count + 1;
endmodule
"""
TOP = """module counter_top (
  input  wire       clk,
  input  wire       rst_n,
  input  wire       en,
  output wire [7:0] count,
  output wire       tick
);
  counter #(.W(8)) u_counter (.clk(clk), .rst_n(rst_n), .en(en), .count(count));
  tick_detect u_tick (.clk(clk), .value(count), .tick(tick));
endmodule

module tick_detect (
  input  wire       clk,
  input  wire [7:0] value,
  output reg        tick
);
  always @(posedge clk) tick <= value == 8'hff;
endmodule
"""
STEPS = [
    ("write", {"filePath": "{project}/README.md", "content": "# Counter\n\nAn 8-bit counter with enable and reset.\n"}),
    ("write", {"filePath": "{project}/src/counter.v", "content": COUNTER}),
    ("write", {"filePath": "{project}/src/counter_top.v", "content": TOP}),
    ("write", {"filePath": "{project}/design/rc.cir", "content": "* A filter on the output\n.subckt rc in out gnd\nR1 in out 1k\nC1 out gnd 100n\n.ends rc\n"}),
]
DELAY = 6


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def send_json(self, data):
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.send_json({"data": [{"id": "muse-spark-1.3"}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request.get("messages", [])
        text = json.dumps(messages)
        project = re.search(r"Working directory: ([^\s\\\"]+)", text)
        done = sum(1 for message in messages if message.get("role") == "tool")
        model = request.get("model")
        if not request.get("tools"):
            chunks = [{"delta": {"content": "Counter project"}}]
        elif done < len(STEPS):
            time.sleep(DELAY)
            tool, arguments = STEPS[done]
            arguments = {key: value.replace("{project}", project.group(1) if project else ".") for key, value in arguments.items()}
            chunks = [{"delta": {"tool_calls": [{"index": 0, "id": f"call_{done}", "type": "function", "function": {"name": tool, "arguments": json.dumps(arguments)}}]}}]
        else:
            chunks = [{"delta": {"content": "TEST MODEL: finished writing the scripted files."}}]
        finish = "tool_calls" if "tool_calls" in chunks[0]["delta"] else "stop"
        events = [{"id": "test", "object": "chat.completion.chunk", "model": model, "choices": [{"index": 0, **chunk, "finish_reason": None}]} for chunk in chunks]
        events.append({"id": "test", "object": "chat.completion.chunk", "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]})
        body = ("".join(f"data: {json.dumps(event)}\n\n" for event in events) + "data: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
