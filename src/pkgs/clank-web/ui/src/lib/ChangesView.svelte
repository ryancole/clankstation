<script>
  // A task's changes, file by file (docs/gui.md 3.4, and 3.8 on a PC).
  // variant 'page': the Changes page. On a phone, a file picker and wrapped
  // lines; on a PC, the files listed beside the changes, lines that scroll
  // sideways, and a side-by-side switch.
  // variant 'pane': the third pane beside a task page.
  import { getChanges } from './api.js';
  import { MediaQuery } from 'svelte/reactivity';

  let { id, variant = 'page', version = '' } = $props();

  const wideQuery = new MediaQuery('min-width: 900px', false);
  const wide = $derived(variant === 'pane' || wideQuery.current);

  let files = $state(null);
  let index = $state(0);

  $effect(() => {
    version; // fetch again when the task's turn ends
    let gone = false;
    getChanges(id).then((f) => {
      if (gone) return;
      files = f ?? [];
      if (index >= files.length) index = 0;
    });
    return () => (gone = true);
  });

  const MODE_KEY = 'clank.changes.mode';
  function readMode() {
    try {
      return localStorage.getItem(MODE_KEY) === 'split' ? 'split' : 'unified';
    } catch {
      return 'unified';
    }
  }
  let mode = $state(readMode());
  function setMode(m) {
    mode = m;
    try {
      localStorage.setItem(MODE_KEY, m);
    } catch {
      /* not kept on this device */
    }
  }
  const split = $derived(variant === 'page' && wide && mode === 'split');

  const file = $derived(files?.[index]);

  // Patch lines as rows with line numbers; hunk headers become "…" separators.
  const rows = $derived.by(() => {
    if (!file?.patch) return [];
    let a = 0;
    let b = 0;
    return file.patch.replace(/\n$/, '').split('\n').map((l) => {
      if (l.startsWith('@@')) {
        const m = /^@@ -(\d+)(?:,\d+)? \+(\d+)/.exec(l);
        if (m) {
          a = Number(m[1]);
          b = Number(m[2]);
        }
        return { kind: 'hunk', text: '' };
      }
      if (l.startsWith('+')) return { kind: 'add', text: l.slice(1), b: b++ };
      if (l.startsWith('-')) return { kind: 'del', text: l.slice(1), a: a++ };
      if (l.startsWith('\\')) return { kind: 'note', text: l };
      return { kind: 'ctx', text: l.slice(1), a: a++, b: b++ };
    });
  });

  // Side by side: unchanged lines on both sides, removed lines on the left
  // paired with the added lines that replaced them on the right.
  const pairs = $derived.by(() => {
    if (!split) return [];
    const out = [];
    let dels = [];
    let adds = [];
    const flush = () => {
      for (let i = 0; i < Math.max(dels.length, adds.length); i++) {
        out.push({ left: dels[i] ?? null, right: adds[i] ?? null });
      }
      dels = [];
      adds = [];
    };
    for (const r of rows) {
      if (r.kind === 'del') {
        if (adds.length) flush();
        dels.push(r);
      } else if (r.kind === 'add') adds.push(r);
      else {
        flush();
        if (r.kind === 'ctx') out.push({ left: r, right: r });
        else out.push({ sep: r });
      }
    }
    flush();
    return out;
  });

  function label(f) {
    if (f.status === 'added') return `${f.path} (new file)`;
    if (f.status === 'deleted') return `${f.path} (deleted)`;
    return `${f.path} (+${f.added} −${f.removed})`;
  }
  function base(p) {
    return p.slice(p.lastIndexOf('/') + 1);
  }
  function dir(p) {
    const i = p.lastIndexOf('/');
    return i > 0 ? p.slice(0, i) : '';
  }
  const sign = (k) => (k === 'add' ? '+' : k === 'del' ? '−' : ' ');
  const signLabel = (k) => (k === 'add' ? 'added' : k === 'del' ? 'removed' : undefined);
</script>

{#snippet fileList()}
  <ul class="filelist" aria-label="Changed files">
    {#each files as f, i}
      <li>
        <button class:on={i === index} onclick={() => (index = i)} aria-current={i === index ? 'true' : undefined}>
          <span class="fname mono">{base(f.path)}</span>
          <span class="fmeta">
            {#if dir(f.path)}<span class="fdir mono">{dir(f.path)}</span>{/if}
            {#if f.status === 'added'}<span class="tag added">New</span>
            {:else if f.status === 'deleted'}<span class="tag deleted">Deleted</span>
            {:else}<span class="counts"><span class="plus">+{f.added}</span> <span class="minus">−{f.removed}</span></span>{/if}
          </span>
        </button>
      </li>
    {/each}
  </ul>
{/snippet}

{#snippet line(r, side)}
  {#if !r}
    <div class="line empty"><span class="num"></span><span class="sign"> </span> </div>
  {:else}
    <div class={`line ${r.kind}`}>
      {#if wide}
        {#if side === 'both'}<span class="num">{r.a ?? ''}</span><span class="num">{r.b ?? ''}</span>
        {:else}<span class="num">{side === 'left' ? r.a : r.b}</span>{/if}
      {/if}
      <span class="sign" aria-label={signLabel(r.kind)}>{sign(r.kind)}</span>{r.text}
    </div>
  {/if}
{/snippet}

{#snippet diff()}
  {#if file.binary}
    <div class="card diff"><p class="note-row">This file isn't text, so its changes can't be shown.</p></div>
  {:else if file.status === 'deleted' && rows.length === 0}
    <div class="card diff"><p class="note-row">This file was deleted.</p></div>
  {:else if split}
    <div class="card diff split mono">
      {#each ['left', 'right'] as side}
        <div class="side" aria-label={side === 'left' ? 'Before' : 'After'}>
          <div class="rows">
            {#each pairs as p}
              {#if p.sep}
                <div class="hunk">{p.sep.kind === 'note' ? p.sep.text : '…'}</div>
              {:else}
                {@render line(p[side], side)}
              {/if}
            {/each}
          </div>
        </div>
      {/each}
    </div>
  {:else}
    <div class="card diff mono" class:scroll={wide}>
      <div class="rows">
        {#each rows as r}
          {#if r.kind === 'hunk'}
            <div class="hunk">…</div>
          {:else if r.kind === 'note'}
            <div class="hunk">{r.text}</div>
          {:else}
            {@render line(r, 'both')}
          {/if}
        {/each}
      </div>
    </div>
  {/if}
{/snippet}

{#if files === null}
  <p class="empty">Loading…</p>
{:else if files.length === 0}
  <p class="empty">No files were changed.</p>
{:else if variant === 'pane'}
  <div class="pane">
    {@render fileList()}
    <div class="file-head mono">{file.path}</div>
    {@render diff()}
  </div>
{:else if wide}
  <div class="wide">
    <div class="side-list">
      <div class="count muted">{files.length === 1 ? '1 file changed' : `${files.length} files changed`}</div>
      {@render fileList()}
    </div>
    <div class="main-diff">
      <div class="toolbar">
        <span class="file-head mono">{file.path}</span>
        <div class="switch" role="group" aria-label="How to show changes">
          <button class:on={mode === 'unified'} aria-pressed={mode === 'unified'} onclick={() => setMode('unified')}>One column</button>
          <button class:on={mode === 'split'} aria-pressed={mode === 'split'} onclick={() => setMode('split')}>Side by side</button>
        </div>
      </div>
      {@render diff()}
    </div>
  </div>
{:else}
  <div class="picker">
    <label for="file" class="muted">File {index + 1} of {files.length}</label>
    <select id="file" class="mono" bind:value={index}>
      {#each files as f, i}<option value={i}>{label(f)}</option>{/each}
    </select>
  </div>

  {@render diff()}

  <div class="nav">
    <button disabled={index === 0} onclick={() => (index -= 1)}>Previous file</button>
    <button disabled={index === files.length - 1} onclick={() => (index += 1)}>Next file</button>
  </div>
{/if}

<style>
  .picker { display: flex; flex-direction: column; gap: 6px; margin-bottom: 12px; font-size: 13px; }
  select {
    height: 48px; border: 1px solid var(--border-strong); border-radius: 12px; padding: 0 12px;
    font-size: 15px; background: var(--surface); color: var(--text); max-width: 100%;
  }
  .diff { overflow: hidden; font-size: 13px; line-height: 1.55; }
  .line { padding: 1px 12px 1px 4px; white-space: pre-wrap; overflow-wrap: anywhere; color: var(--text-2); display: flex; }
  .sign { width: 18px; flex-shrink: 0; text-align: center; user-select: none; }
  .add { background: var(--add-bg); color: var(--add-fg); }
  .del { background: var(--del-bg); color: var(--del-fg); }
  .hunk { padding: 6px 12px; background: var(--sunken); color: var(--muted); font-family: inherit; font-size: 12px; }
  .note-row { padding: 16px; margin: 0; font-family: Inter, system-ui, sans-serif; color: var(--muted); }
  .nav { display: flex; gap: 10px; margin-top: 14px; }
  .nav button {
    flex: 1 1 0; height: 52px; border-radius: 14px; border: 1px solid var(--border-strong);
    background: var(--surface); color: var(--text); font: inherit; font-size: 16px; font-weight: 600; cursor: pointer;
  }
  .nav button:disabled { color: var(--muted); border-color: var(--border); cursor: default; }

  /* Wide: lines keep their shape and scroll sideways. */
  .scroll, .side { overflow-x: auto; }
  .scroll .rows, .side .rows { width: max-content; min-width: 100%; }
  .scroll .line, .side .line { white-space: pre; overflow-wrap: normal; }
  .num {
    width: 44px; flex-shrink: 0; padding-right: 8px; text-align: right; color: var(--muted);
    opacity: 0.8; user-select: none; font-size: 12px;
  }
  .line.empty { background: var(--sunken); }
  .split { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); }
  .split .side + .side { border-left: 1px solid var(--border); }

  .wide { display: grid; grid-template-columns: 240px minmax(0, 1fr); gap: 16px; align-items: start; }
  .side-list { position: sticky; top: 16px; max-height: calc(100vh - 32px); overflow-y: auto; }
  .count { font-size: 13px; padding: 0 8px 8px; }
  .toolbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 10px; flex-wrap: wrap; }
  .file-head { font-size: 13px; font-weight: 600; overflow-wrap: anywhere; }
  .switch { display: inline-flex; border: 1px solid var(--border-strong); border-radius: 10px; overflow: hidden; flex-shrink: 0; }
  .switch button {
    border: 0; background: var(--surface); color: var(--text-2); font: inherit; font-size: 13px;
    font-weight: 600; padding: 7px 12px; cursor: pointer;
  }
  .switch button + button { border-left: 1px solid var(--border-strong); }
  .switch button.on { background: var(--working-bg); color: var(--working-fg); }

  .filelist { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
  .filelist button {
    width: 100%; display: flex; flex-direction: column; gap: 2px; text-align: left; padding: 7px 8px;
    border: 0; border-radius: 8px; background: transparent; color: var(--text); font: inherit; cursor: pointer;
  }
  .filelist button:hover { background: var(--sunken); }
  .filelist button.on { background: var(--working-bg); }
  .fname { font-size: 13px; font-weight: 600; overflow-wrap: anywhere; }
  .fmeta { display: flex; gap: 8px; font-size: 12px; color: var(--muted); min-width: 0; }
  .fdir { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
  .counts { white-space: nowrap; margin-left: auto; }
  .plus, .tag.added { color: var(--done-fg); }
  .minus, .tag.deleted { color: var(--bad-fg); }
  .tag { margin-left: auto; white-space: nowrap; }

  .pane { display: flex; flex-direction: column; gap: 10px; }
  .pane .filelist { max-height: 30vh; overflow-y: auto; }
  .pane .file-head { padding: 4px 4px 0; }
</style>
