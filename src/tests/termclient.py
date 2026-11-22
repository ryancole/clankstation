"""A scripted browser-terminal client for the S3 VM test.

usage: termclient.py URL STEP...
  e:TEXT   wait until the screen so far contains TEXT
  s:TEXT   type TEXT (Python escapes: \\r, \\x1b, ...)
  c:JSON   send a control message
  x:CODE   wait for {"type":"exit"} with this code
  q        disconnect
Prints the screen at the end; exits 1 on a timeout or a wrong exit code.
"""

import json
import sys
import time

from websockets.sync.client import connect

url, steps = sys.argv[1], sys.argv[2:]
screen = ""


def read_until(pred, timeout=60):
    global screen
    end = time.time() + timeout
    while time.time() < end:
        try:
            msg = ws.recv(timeout=max(0.1, end - time.time()))
        except TimeoutError:
            break
        if isinstance(msg, bytes):
            screen += msg.decode("utf-8", "replace")
            if pred(None):
                return None
        else:
            c = json.loads(msg)
            if pred(c):
                return c
    print(screen)
    sys.exit(f"timed out at step {step!r}")


ws = connect(url, open_timeout=30)
for step in steps:
    kind, _, arg = step.partition(":")
    if kind == "e":
        read_until(lambda c, a=arg: a in screen)
    elif kind == "s":
        ws.send(arg.encode().decode("unicode_escape").encode())
    elif kind == "c":
        ws.send(arg)
    elif kind == "x":
        c = read_until(lambda c: c is not None and c.get("type") == "exit")
        if c.get("code", 0) != int(arg):
            print(screen)
            sys.exit(f"exit code {c.get('code')}, wanted {arg}")
    elif kind == "q":
        ws.close()
        break
print(screen)
