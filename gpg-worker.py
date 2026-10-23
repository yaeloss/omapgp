#!/usr/bin/env python3
"""Bounded, disposable pipe worker; no payloads in argv, files, or logs.

The shell receives one bounded JSON result and a PINENTRY_LAUNCHED event.
Resource isolation is not a sandbox against other same-user processes.
"""
import json
import os
import resource
import selectors
import signal
import subprocess
import sys
import time

MAX_INPUT = 64 * 1024
MAX_OUTPUT = 256 * 1024
MAX_STDERR = 128 * 1024
MAX_LINE = 16 * 1024
TIMEOUT = 120
MEMORY_LIMIT = 256 * 1024 * 1024

# Options that would move GnuPG's machine-readable status lines next to (or
# into) its human-readable diagnostics. The worker owns that channel instead.
FORBIDDEN_ARGUMENTS = {"--status-fd", "--status-file"}


class WorkerError(Exception):
    def __init__(self, code):
        self.code = code


def limits():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_AS, (MEMORY_LIMIT, MEMORY_LIMIT))
    resource.setrlimit(resource.RLIMIT_CPU, (30, 30))


def interrupt(signum, frame):
    raise WorkerError("cancelled" if signum == signal.SIGTERM else "timeout")


def read_input(stream, deadline):
    """Check size before starting gpg, including callers other than QML."""
    data = bytearray()
    try:
        poll = selectors.DefaultSelector()
        poll.register(stream, selectors.EVENT_READ)
    except (OSError, ValueError):
        # Redirected files and /dev/null cannot be polled; read them plainly.
        while True:
            if time.monotonic() >= deadline:
                raise WorkerError("timeout")
            chunk = stream.read(8192)
            if not chunk:
                return data
            if len(data) + len(chunk) > MAX_INPUT:
                raise WorkerError("input-limit")
            data.extend(chunk)
    with poll:
        while time.monotonic() < deadline:
            if not poll.select(min(0.2, max(0, deadline - time.monotonic()))):
                continue
            chunk = os.read(stream.fileno(), 8192)
            if not chunk:
                return data
            if len(data) + len(chunk) > MAX_INPUT:
                raise WorkerError("input-limit")
            data.extend(chunk)
    raise WorkerError("timeout")


def run(command, payload, deadline, output_limit=MAX_OUTPUT, progress=None, status_pipe=False):
    """Multiplex pipes so neither stdin nor stderr can deadlock stdout.

    With `status_pipe`, GnuPG's machine-readable status lines get their own
    inherited descriptor, so text on stderr cannot impersonate a status line.
    """
    read_fd = write_fd = None
    if status_pipe:
        read_fd, write_fd = os.pipe()
        command = list(command) + ["--status-fd", str(write_fd)]
    try:
        child = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, start_new_session=True,
            pass_fds=() if write_fd is None else (write_fd,))
    except BaseException:
        if read_fd is not None:
            os.close(read_fd)
        raise
    finally:
        if write_fd is not None:
            os.close(write_fd)
    output, pending = bytearray(), bytearray()
    status = []
    stderr_size = 0
    sent = 0
    status_stream = None

    def status_line(line):
        if not line.startswith(b"[GNUPG:] "):
            return
        text = line.decode("utf-8", errors="replace")
        status.append(text)
        if text.startswith("[GNUPG:] PINENTRY_LAUNCHED ") and progress:
            progress()

    def collect(pipe, chunk, machine):
        nonlocal stderr_size, pending
        if machine:
            # Dedicated channel: every line is GnuPG status, already bounded.
            pending.extend(chunk)
            while b"\n" in pending:
                line, _, rest = pending.partition(b"\n")
                if len(line) > MAX_LINE:
                    raise WorkerError("status-limit")
                status_line(line.rstrip(b"\r"))
                pending = bytearray(rest)
            if len(pending) > MAX_LINE:
                raise WorkerError("status-limit")
            return
        stderr_size += len(chunk)
        if stderr_size > MAX_STDERR:
            raise WorkerError("status-limit")
        # Diagnostics are counted but never parsed or retained, so a log line
        # cannot overwrite or impersonate a partial status line.

    try:
        with selectors.DefaultSelector() as poll:
            for pipe in (child.stdin, child.stdout, child.stderr):
                os.set_blocking(pipe.fileno(), False)
            if payload:
                poll.register(child.stdin, selectors.EVENT_WRITE, "input")
            else:
                child.stdin.close()
            poll.register(child.stdout, selectors.EVENT_READ, "output")
            poll.register(child.stderr, selectors.EVENT_READ, "diagnostic")
            if read_fd is not None:
                status_stream = os.fdopen(read_fd, "rb", buffering=0)
                os.set_blocking(status_stream.fileno(), False)
                poll.register(status_stream, selectors.EVENT_READ, "status")
            while poll.get_map():
                if time.monotonic() >= deadline:
                    raise WorkerError("timeout")
                for key, mask in poll.select(0.1):
                    pipe = key.fileobj
                    if key.data == "input":
                        try:
                            sent += os.write(pipe.fileno(), memoryview(payload)[sent:sent + 8192])
                        except BrokenPipeError:
                            sent = len(payload)
                        if sent >= len(payload):
                            poll.unregister(pipe)
                            pipe.close()
                            payload.clear()
                        continue
                    chunk = os.read(pipe.fileno(), 8192)
                    if not chunk:
                        poll.unregister(pipe)
                        pipe.close()
                        continue
                    if key.data == "output":
                        if len(output) + len(chunk) > output_limit:
                            raise WorkerError("output-limit")
                        output.extend(chunk)
                    elif key.data == "status":
                        collect(pipe, chunk, machine=True)
                    else:
                        collect(pipe, chunk, machine=False)
            code = child.wait(timeout=max(0.01, deadline - time.monotonic()))
            if code and len(output) >= output_limit:
                raise WorkerError("output-limit")
            return {"exitCode": code, "stdout": output.decode("utf-8", errors="replace"),
                    "statusLines": status, "errorCode": ""}
    finally:
        payload.clear()
        if child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        child.wait()
        for pipe in (child.stdin, child.stdout, child.stderr):
            pipe.close()
        if status_stream is not None:
            status_stream.close()
        output.clear()
        pending.clear()


def main():
    # Never propagate the worker's CPU/address-space budgets to a long-lived
    # shared gpg-agent. Launch/check the agent before applying those budgets;
    # then forbid gpg from auto-starting one inside the limited subprocess.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGALRM, interrupt)
    signal.alarm(TIMEOUT + 1)
    deadline = time.monotonic() + TIMEOUT
    result = {"exitCode": -1, "stdout": "", "statusLines": [], "errorCode": "worker-failed"}
    try:
        args = sys.argv[1:]
        payload = read_input(sys.stdin.buffer, deadline)
        if args and args[0] == "gpg":
            args = args[1:]
            # Callers cannot move status next to stderr; the worker owns it.
            if any(arg.split("=", 1)[0] in FORBIDDEN_ARGUMENTS for arg in args):
                raise WorkerError("invalid-command")
            agent_command = ["/usr/bin/gpgconf"]
            if "--homedir" in args:
                index = args.index("--homedir")
                os.makedirs(args[index + 1], mode=0o700, exist_ok=True)
                agent_command += ["--homedir", args[index + 1]]
            agent = subprocess.run(agent_command + ["--launch", "gpg-agent"],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=5)
            if agent.returncode:
                raise WorkerError("agent-unavailable")
            limits()
            policy = ["--no-options", "--batch", "--no-tty", "--disable-dirmngr",
                      "--no-auto-key-retrieve", "--no-auto-key-import", "--no-encrypt-to",
                      "--no-groups", "--no-autostart", "--max-output", str(MAX_OUTPUT),
                      "--output", "-"]
            result = run(["/usr/bin/gpg"] + policy + args, payload, deadline,
                         progress=lambda: print("PINENTRY_LAUNCHED", file=sys.stderr, flush=True),
                         status_pipe=True)
        elif args in (["wl-paste", "--no-newline"], ["wl-paste", "--primary", "--no-newline"]):
            limits()
            result = run(["/usr/bin/wl-paste"] + args[1:], payload, deadline,
                         output_limit=MAX_INPUT)
        else:
            raise WorkerError("invalid-command")
    except WorkerError as exc:
        result = {"exitCode": -1, "stdout": "", "statusLines": [], "errorCode": exc.code}
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired, MemoryError):
        result = {"exitCode": -1, "stdout": "", "statusLines": [], "errorCode": "worker-failed"}
    finally:
        signal.alarm(0)
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
