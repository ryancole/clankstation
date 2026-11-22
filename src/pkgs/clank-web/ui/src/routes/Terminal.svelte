<script>
  import { Terminal } from '@xterm/xterm';
  import { FitAddon } from '@xterm/addon-fit';
  import '@xterm/xterm/css/xterm.css';

  // kind: attach (task = id), login, install
  let { kind, task = '' } = $props();

  const TITLES = {
    attach: "You're in control",
    login: 'Sign in to Claude',
    install: 'Set up Claude',
  };
  const backHref = kind === 'attach' ? `#/task/${encodeURIComponent(task)}` : '#/settings';

  let el;
  let status = $state('connecting'); // connecting, open, reconnecting, ending, exited
  let exitCode = $state(0);
  let ctrl = $state(false);
  let ws = null;

  const touch = typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches;
  const enc = new TextEncoder();

  function send(data) {
    if (ws?.readyState === WebSocket.OPEN) ws.send(enc.encode(data));
  }
  function control(msg) {
    if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
  }

  // The on-screen key row: Ctrl applies to the next key typed.
  function key(k) {
    const keys = { Esc: '\x1b', Tab: '\t', Left: '\x1b[D', Up: '\x1b[A', Down: '\x1b[B', Right: '\x1b[C' };
    if (k === 'Ctrl') ctrl = !ctrl;
    else send(keys[k]);
  }

  function end() {
    status = 'ending';
    control({ type: 'end' });
  }

  $effect(() => {
    const term = new Terminal({
      cursorBlink: true,
      fontFamily: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace',
      fontSize: touch ? 13 : 14,
      scrollback: 5000,
      theme: { background: '#0f1115', foreground: '#d5d9e0' },
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(el);
    fit.fit();
    term.focus();

    term.onData((d) => {
      if (ctrl && d.length === 1 && /[a-z@\[\\\]^_]/i.test(d)) {
        d = String.fromCharCode(d.toUpperCase().charCodeAt(0) & 31);
        ctrl = false;
      }
      send(d);
    });
    const sendSize = () => control({ type: 'resize', cols: term.cols, rows: term.rows });
    const ro = new ResizeObserver(() => {
      fit.fit();
      sendSize();
    });
    ro.observe(el);

    let stopped = false;
    let retry = null;
    let leaveTimer = null;
    const url = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/api/terminal/${kind}` +
      (task ? `?task=${encodeURIComponent(task)}` : '');

    function connect() {
      ws = new WebSocket(url);
      ws.binaryType = 'arraybuffer';
      ws.onopen = () => {
        // The box replays the screen so far; start from a clean one.
        term.reset();
        status = status === 'ending' ? 'ending' : 'open';
        sendSize();
      };
      ws.onmessage = (m) => {
        if (typeof m.data !== 'string') {
          term.write(new Uint8Array(m.data));
          return;
        }
        try {
          const c = JSON.parse(m.data);
          if (c.type === 'exit') {
            exitCode = c.code ?? 0;
            status = 'exited';
            stopped = true;
            if (kind === 'attach' || exitCode === 0) {
              leaveTimer = setTimeout(() => (location.hash = backHref), 1500);
            }
          }
        } catch {
          /* ignore */
        }
      };
      ws.onclose = () => {
        if (stopped) return;
        status = 'reconnecting';
        retry = setTimeout(connect, 2000);
      };
    }
    connect();

    return () => {
      stopped = true;
      clearTimeout(retry);
      clearTimeout(leaveTimer);
      ro.disconnect();
      ws?.close();
      term.dispose();
    };
  });
</script>

<div class="screen">
  <header>
    <a class="back" href={backHref} aria-label="Back (the session stays open)">
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"></path></svg>
    </a>
    <div class="title">
      <span class="name">{TITLES[kind] ?? 'Terminal'}</span>
      <span class="sub" role="status">
        {#if status === 'connecting'}Connecting…
        {:else if status === 'reconnecting'}Connection lost. Reconnecting…
        {:else if status === 'ending'}{kind === 'attach' ? 'Handing back…' : 'Closing…'}
        {:else if status === 'exited'}{exitCode === 0 ? 'Finished.' : 'Ended with a problem. See the messages above.'}
        {:else if kind === 'attach'}This is Claude Code's own screen. The automatic run is paused.
        {:else if kind === 'login'}Follow Claude's own steps. The box never sees your sign-in.
        {:else}Running Claude's official installer.{/if}
      </span>
    </div>
    {#if status !== 'exited'}
      <button class="end" onclick={end} disabled={status === 'ending' || status === 'connecting'}>
        {kind === 'attach' ? 'Done, hand back' : 'Close'}
      </button>
    {:else}
      <a class="end" href={backHref}>Back</a>
    {/if}
  </header>

  <div class="term" bind:this={el}></div>

  {#if touch}
    <div class="keys" role="toolbar" aria-label="Extra keys">
      {#each ['Esc', 'Tab', 'Ctrl', 'Left', 'Up', 'Down', 'Right'] as k}
        <button class:on={k === 'Ctrl' && ctrl} aria-pressed={k === 'Ctrl' ? ctrl : undefined}
          aria-label={k.length > 4 || ['Left', 'Up', 'Down'].includes(k) ? `${k} arrow` : k}
          onmousedown={(e) => e.preventDefault()} onclick={() => key(k)}>
          {{ Left: '←', Up: '↑', Down: '↓', Right: '→' }[k] ?? k}
        </button>
      {/each}
    </div>
  {/if}
</div>

<style>
  .screen {
    position: fixed; inset: 0; display: flex; flex-direction: column;
    background: #0f1115; color: #e6e8ec;
    padding-bottom: env(safe-area-inset-bottom);
  }
  header {
    display: flex; align-items: center; gap: 8px; padding: 8px 10px;
    border-bottom: 1px solid #262a31;
  }
  .back { color: #e6e8ec; width: 44px; height: 44px; display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0; }
  .title { display: flex; flex-direction: column; gap: 2px; min-width: 0; flex-grow: 1; }
  .name { font-size: 15px; font-weight: 600; }
  .sub { font-size: 12px; color: #a9b0bb; overflow: hidden; text-overflow: ellipsis; }
  .end {
    flex-shrink: 0; min-height: 44px; padding: 0 14px; border-radius: 12px; border: 0;
    background: #ffffff; color: #15181d; font: inherit; font-size: 15px; font-weight: 600;
    display: inline-flex; align-items: center; text-decoration: none; cursor: pointer;
  }
  .end:disabled { opacity: 0.6; cursor: default; }
  .term { flex-grow: 1; min-height: 0; padding: 6px 4px 0 8px; }
  .keys {
    display: grid; grid-template-columns: repeat(7, minmax(0, 1fr)); gap: 6px;
    padding: 8px; background: #1a1d23; border-top: 1px solid #262a31;
  }
  .keys button {
    height: 44px; border: 0; border-radius: 8px; background: #2b3038; color: #e6e8ec;
    font: inherit; font-size: 14px; font-weight: 600;
  }
  .keys button.on { background: #6b93f0; color: #0d1426; }
</style>
