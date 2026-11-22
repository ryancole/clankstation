<script>
  import { getChanges } from '../lib/api.js';

  let { id } = $props();

  let files = $state(null);
  let index = $state(0);

  $effect(() => {
    getChanges(id).then((f) => (files = f ?? []));
  });

  const file = $derived(files?.[index]);

  // Patch lines as rows: hunk headers become "…" separators.
  const rows = $derived.by(() => {
    if (!file?.patch) return [];
    return file.patch.replace(/\n$/, '').split('\n').map((l) => {
      if (l.startsWith('@@')) return { kind: 'hunk', text: '' };
      if (l.startsWith('+')) return { kind: 'add', text: l.slice(1) };
      if (l.startsWith('-')) return { kind: 'del', text: l.slice(1) };
      if (l.startsWith('\\')) return { kind: 'note', text: l };
      return { kind: 'ctx', text: l.slice(1) };
    });
  });

  function label(f) {
    if (f.status === 'added') return `${f.path} (new file)`;
    if (f.status === 'deleted') return `${f.path} (deleted)`;
    return `${f.path} (+${f.added} −${f.removed})`;
  }
</script>

<main class="page">
  <div class="topbar">
    <a class="back" href={`#/task/${encodeURIComponent(id)}`} aria-label="Back to the task">
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"></path></svg>
    </a>
    <h1>What changed</h1>
  </div>

  {#if files === null}
    <p class="empty">Loading…</p>
  {:else if files.length === 0}
    <p class="empty">No files were changed.</p>
  {:else}
    <div class="picker">
      <label for="file" class="muted">File {index + 1} of {files.length}</label>
      <select id="file" class="mono" bind:value={index}>
        {#each files as f, i}<option value={i}>{label(f)}</option>{/each}
      </select>
    </div>

    <div class="card diff mono">
      {#if file.binary}
        <p class="note-row">This file isn't text, so its changes can't be shown.</p>
      {:else if file.status === 'deleted' && rows.length === 0}
        <p class="note-row">This file was deleted.</p>
      {:else}
        {#each rows as r}
          {#if r.kind === 'hunk'}
            <div class="hunk">…</div>
          {:else if r.kind === 'note'}
            <div class="hunk">{r.text}</div>
          {:else}
            <div class={`line ${r.kind}`}><span class="sign" aria-label={r.kind === 'add' ? 'added' : r.kind === 'del' ? 'removed' : undefined}>{r.kind === 'add' ? '+' : r.kind === 'del' ? '−' : ' '}</span>{r.text}</div>
          {/if}
        {/each}
      {/if}
    </div>

    <div class="nav">
      <button disabled={index === 0} onclick={() => (index -= 1)}>Previous file</button>
      <button disabled={index === files.length - 1} onclick={() => (index += 1)}>Next file</button>
    </div>
  {/if}
</main>

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
</style>
