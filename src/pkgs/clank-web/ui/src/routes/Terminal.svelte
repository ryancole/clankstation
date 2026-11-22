<script>
  import { Terminal } from '@xterm/xterm';
  import { FitAddon } from '@xterm/addon-fit';
  import '@xterm/xterm/css/xterm.css';

  // kind: login or install (taking over a task is out of the app for now)
  let { kind, task = '' } = $props();

  const TITLES = {
    login: 'Sign in to Claude',
    install: 'Set up Claude',
  };
  const backHref = '#/settings';

  let el;
  let screenEl;
  let term = null;
  let status = $state('connecting'); // connecting, open, reconnecting, ending, exited
  // iPhones give no paste menu inside the terminal: Paste reads the
  // clipboard, and if the browser won't allow that, a box to paste into.
  let pasteBox = $state(false);
  let pasteText = $state('');
  let pasteInput = $state();
  let exitCode = $state(0);
  let closedByYou = $state(false); // Close sends Ctrl-C: not a problem
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
    const keys = { Esc: '\x1b', Tab: '\t', Left: '\x1b[D', Up: '\x1b[A', Down: '\x1b[B', Right: '\x1b[C', Enter: '\r' };
    if (k === 'Ctrl') ctrl = !ctrl;
    else send(keys[k]);
  }

  async function paste() {
    try {
      const text = await navigator.clipboard.readText();
      if (text) {
        term?.paste(text);
        term?.focus();
        return;
      }
    } catch {
      /* not allowed: fall back to the box */
    }
    pasteBox = true;
    queueMicrotask(() => pasteInput?.focus());
  }

  function sendPasted(e) {
    e.preventDefault();
    if (pasteText) term?.paste(pasteText);
    pasteText = '';
    pasteBox = false;
    term?.focus();
  }

  function end() {
    closedByYou = true;
    status = 'ending';
    control({ type: 'end' });
  }

  $effect(() => {
    term = new Terminal({
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

    // Keep the screen (and the key row) above the on-screen keyboard: iOS
    // doesn't shrink a fixed element when the keyboard opens.
    const vv = window.visualViewport;
    const fitViewport = () => {
      if (!vv || !screenEl) return;
      screenEl.style.height = `${vv.height}px`;
      screenEl.style.top = `${vv.offsetTop}px`;
    };
    vv?.addEventListener('resize', fitViewport);
    vv?.addEventListener('scroll', fitViewport);
    fitViewport();

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
            if (exitCode === 0 || closedByYou) {
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
      vv?.removeEventListener('resize', fitViewport);
      vv?.removeEventListener('scroll', fitViewport);
      ws?.close();
      term.dispose();
      term = null;
    };
  });
</script>

<div class="screen" bind:this={screenEl}>
  <header>
    <a class="back" href={backHref} aria-label="Back (the session stays open)">
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"></path></svg>
    </a>
    <div class="title">
      <span class="name">{TITLES[kind] ?? 'Terminal'}</span>
      <span class="sub" role="status">
        {#if status === 'connecting'}Connecting…
        {:else if status === 'reconnecting'}Connection lost. Reconnecting…
        {:else if status === 'ending'}Closing…
        {:else if status === 'exited'}{closedByYou ? 'Closed.' : exitCode === 0 ? 'Finished.' : 'Ended with a problem. See the messages above.'}
        {:else if kind === 'login'}Follow Claude's own steps. The box never sees your sign-in.
        {:else}Running Claude's official installer.{/if}
      </span>
    </div>
    {#if status !== 'exited'}
      <button class="end" onclick={end} disabled={status === 'ending' || status === 'connecting'}>
        Close
      </button>
    {:else}
      <a class="end" href={backHref}>Back</a>
    {/if}
  </header>

  <div class="term" bind:this={el}></div>

  {#if pasteBox}
    <form class="paste-box" onsubmit={sendPasted}>
      <label for="paste-in">Paste here, then Send</label>
      <div class="paste-row">
        <input id="paste-in" bind:this={pasteInput} bind:value={pasteText}
          autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" />
        <button type="submit">Send</button>
        <button type="button" class="cancel" onclick={() => { pasteBox = false; pasteText = ''; }}>Cancel</button>
      </div>
    </form>
  {/if}

  {#if touch}
    <div class="keys" role="toolbar" aria-label="Extra keys">
      <button class="wide" onmousedown={(e) => e.preventDefault()} onclick={paste}>Paste</button>
      {#each ['Esc', 'Tab', 'Ctrl', 'Left', 'Up', 'Down', 'Right', 'Enter'] as k}
        <button class:on={k === 'Ctrl' && ctrl} aria-pressed={k === 'Ctrl' ? ctrl : undefined}
          aria-label={['Left', 'Up', 'Down', 'Right'].includes(k) ? `${k} arrow` : k}
          onmousedown={(e) => e.preventDefault()} onclick={() => key(k)}>
          {{ Left: '←', Up: '↑', Down: '↓', Right: '→', Enter: '↵' }[k] ?? k}
        </button>
      {/each}
    </div>
  {/if}
</div>

<style>
  .screen {
    position: fixed; top: 0; left: 0; right: 0; height: 100%; display: flex; flex-direction: column;
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
    display: grid; grid-template-columns: repeat(10, minmax(0, 1fr)); gap: 4px;
    padding: 8px; background: #1a1d23; border-top: 1px solid #262a31;
  }
  .keys button {
    height: 44px; border: 0; border-radius: 8px; background: #2b3038; color: #e6e8ec;
    font: inherit; font-size: 14px; font-weight: 600;
  }
  .keys button.on { background: #6b93f0; color: #0d1426; }
  .keys button.wide { grid-column: span 2; background: #6b93f0; color: #0d1426; }
  .paste-box {
    display: flex; flex-direction: column; gap: 6px; padding: 8px 10px;
    background: #1a1d23; border-top: 1px solid #262a31;
  }
  .paste-box label { font-size: 13px; color: #a9b0bb; }
  .paste-row { display: flex; gap: 6px; }
  .paste-row input {
    flex-grow: 1; min-width: 0; height: 44px; border-radius: 8px; border: 1px solid #3a3f49;
    background: #0f1115; color: #e6e8ec; padding: 0 10px; font-size: 16px;
  }
  .paste-row button {
    height: 44px; padding: 0 14px; border: 0; border-radius: 8px; font: inherit; font-size: 15px;
    font-weight: 600; background: #6b93f0; color: #0d1426;
  }
  .paste-row button.cancel { background: #2b3038; color: #e6e8ec; }
</style>
