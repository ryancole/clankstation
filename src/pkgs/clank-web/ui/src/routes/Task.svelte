<script>
  import { getTask, taskEvents, reply, stopTask } from '../lib/api.js';
  import { stateInfo, isActive, ago, duration } from '../lib/states.js';
  import { renderMarkdown } from '../lib/markdown.js';

  let { id } = $props();

  let task = $state(null);
  let missing = $state(false);
  let liveState = $state('');
  // Built from the event stream: one group per harness turn.
  let groups = $state([]);
  let plan = $state([]);

  async function load() {
    const t = await getTask(id);
    if (t === null) missing = true;
    else task = t;
  }

  let replyText = $state('');
  let busy = $state(''); // '', 'reply', 'stop'
  let actionError = $state('');

  async function sendReply(e) {
    e.preventDefault();
    if (busy || !replyText.trim()) return;
    busy = 'reply';
    actionError = '';
    try {
      await reply(id, replyText);
      replyText = '';
      liveState = 'running';
      await load();
      window.scrollTo({ top: 0, behavior: 'smooth' });
    } catch (err) {
      actionError = err.message;
    } finally {
      busy = '';
    }
  }

  async function stop() {
    if (busy) return;
    if (!confirm('Stop this task? Its work so far is kept, and you can tell Claude to keep going later.')) return;
    busy = 'stop';
    actionError = '';
    try {
      await stopTask(id);
      await load();
    } catch (err) {
      actionError = err.message;
    } finally {
      busy = '';
    }
  }

  const replyHint = $derived(
    {
      failed: 'Try again, or say what to do differently',
      stopped: 'For example: keep going',
      lost: 'For example: keep going',
    }[liveState || task?.state] ?? 'Tell Claude what to do next',
  );

  function onEvent(e) {
    if (e.type === 'state') {
      const was = liveState;
      liveState = e.state;
      if (was && was !== e.state) load();
      return;
    }
    if (e.type === 'turn' || groups.length === 0) {
      groups.push({ steps: [], messages: [], result: null });
      if (e.type === 'turn') return;
    }
    const g = groups[groups.length - 1];
    switch (e.type) {
      case 'message':
        g.messages.push(e.text);
        break;
      case 'step':
        g.steps.push({ id: e.step_id, label: e.label, detail: e.detail, error: false });
        break;
      case 'step_result': {
        const s = g.steps.find((x) => x.id === e.step_id);
        if (s && e.error) s.error = true;
        break;
      }
      case 'plan':
        plan = e.items ?? [];
        break;
      case 'result':
        g.result = e;
        break;
    }
  }

  $effect(() => {
    load();
    return taskEvents(id, onEvent);
  });

  const cur = $derived(liveState || task?.state || '');
  const info = $derived(task ? stateInfo({ ...task, state: cur }) : null);
  const active = $derived(isActive(cur));
  const current = $derived(groups[groups.length - 1]);
  const now = $derived(current?.steps.at(-1)?.label ?? '');
  const lastMessage = $derived(current?.messages.at(-1) ?? '');
  const allSteps = $derived(groups.flatMap((g) => g.steps));
  const lastResult = $derived(groups.findLast((g) => g.result)?.result ?? null);

  // History: each prompt from prompts.log, with the matching turn's result.
  // Take-over turns write no events, so they don't consume a group.
  const history = $derived.by(() => {
    if (!task) return [];
    let gi = 0;
    return task.turns.map((t) => {
      if (t.kind === 'attach') return { ...t, did: 'You worked with Claude in the terminal.' };
      const g = groups[gi++];
      return { ...t, did: g?.result?.summary ?? g?.messages.at(-1) ?? '' };
    });
  });

  // The question is shown on its own, so leave it off the summary's end.
  const summaryShown = $derived.by(() => {
    const s = task?.summary ?? '';
    const q = cur === 'needs_input' ? task?.question : '';
    const i = q ? s.lastIndexOf(q) : -1;
    return i >= 0 ? s.slice(0, i).trim() : s;
  });

  const changed = $derived(task?.files ?? []);
  const maxLines = $derived(Math.max(1, ...changed.map((f) => f.added + f.removed)));
  function bar(n) {
    return n ? Math.max(4, Math.round((n / maxLines) * 48)) : 0;
  }
  function time(iso) {
    const t = Date.parse(iso);
    return Number.isNaN(t) ? '' : new Date(t).toLocaleString(undefined, { hour: '2-digit', minute: '2-digit', day: 'numeric', month: 'short' });
  }
</script>

<main class="page">
  <div class="topbar">
    <a class="back" href="#/" aria-label="Back to your tasks">
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"></path></svg>
    </a>
  </div>

  {#if missing}
    <p class="empty">This task doesn't exist (any more).</p>
  {:else if !task}
    <p class="empty">Loading…</p>
  {:else}
    <header class="head">
      <div class="meta">
        <span class={`pill tone-${info.tone}`}>{info.label}</span>
        <span class="muted small">
          {task.project} ·
          {#if active}{duration(task.status?.started || task.created)}{:else}{ago(task.finished || task.created)}{/if}
        </span>
      </div>
      <h1>{task.title || 'Untitled task'}</h1>
      {#if info.sentence && cur !== 'needs_input'}<p class="sentence">{info.sentence}</p>{/if}
    </header>

    {#if active}
      {#if now}
        <div class="card now">
          <span class="dot" aria-hidden="true"></span>
          <div>
            <div class="label">Now</div>
            <div class="now-text">{now}</div>
          </div>
        </div>
      {/if}

      {#if plan.length}
        <section>
          <h2>Plan</h2>
          <ul class="plan">
            {#each plan as item}
              <li class={item.status}>
                {#if item.status === 'completed'}
                  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="var(--done-fg)" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" role="img" aria-label="Done"><path d="M5 12l5 5L20 7"></path></svg>
                {:else if item.status === 'in_progress'}
                  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="var(--accent)" stroke-width="2.4" role="img" aria-label="In progress"><circle cx="12" cy="12" r="8"></circle><circle cx="12" cy="12" r="3" fill="var(--accent)"></circle></svg>
                {:else}
                  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="var(--muted)" stroke-width="2" role="img" aria-label="Not started"><circle cx="12" cy="12" r="8"></circle></svg>
                {/if}
                <span>{item.text}</span>
              </li>
            {/each}
          </ul>
        </section>
      {/if}

      {#if lastMessage}
        <section>
          <h2>Claude says</h2>
          <div class="prose">{@html renderMarkdown(lastMessage)}</div>
        </section>
      {/if}

      {#if cur === 'running'}
        {#if actionError}<p class="error-box" role="alert">{actionError}</p>{/if}
        <div class="actions">
          <button class="btn" onclick={stop} disabled={!!busy}>{busy === 'stop' ? 'Stopping…' : 'Stop'}</button>
        </div>
      {/if}
    {:else}
      {#if task.question && cur === 'needs_input'}
        <div class="card question">
          <div class="label q">Claude asks</div>
          <div class="prose q-text">{@html renderMarkdown(task.question)}</div>
          {#if !task.archived}{@render replyForm('Your answer')}{/if}
        </div>
      {/if}

      {#if summaryShown}
        <section>
          <h2>Summary</h2>
          <div class="prose">{@html renderMarkdown(summaryShown)}</div>
        </section>
      {/if}

      <section>
        <h2>What changed</h2>
        {#if changed.length === 0}
          <p class="muted">No files were changed.</p>
        {:else}
          <a class="card files" href={`#/task/${encodeURIComponent(task.id)}/changes`}>
            <div class="files-head">
              <span>{changed.length === 1 ? '1 file changed' : `${changed.length} files changed`}</span>
              <span class="view">View</span>
            </div>
            {#each changed as f}
              <div class="file">
                <span class="mono path">
                  {f.path}
                  {#if f.status === 'added'}<span class="tag added">New file</span>{/if}
                  {#if f.status === 'deleted'}<span class="tag deleted">Deleted</span>{/if}
                </span>
                <span class="bars" role="img" aria-label={`${f.added} lines added, ${f.removed} removed`}>
                  {#if f.added}<span class="bar add" style={`width:${bar(f.added)}px`}></span>{/if}
                  {#if f.removed}<span class="bar del" style={`width:${bar(f.removed)}px`}></span>{/if}
                </span>
              </div>
            {/each}
          </a>
        {/if}
      </section>

      {#if cur !== 'needs_input' && !task.archived}
        <section class="card reply-card">
          {@render replyForm('Tell Claude what to do next')}
        </section>
      {/if}
    {/if}

    {#snippet replyForm(label)}
      <form class="reply" onsubmit={sendReply}>
        <label for="reply">{label}</label>
        <textarea id="reply" rows="3" bind:value={replyText} placeholder={replyHint}></textarea>
        {#if actionError}<p class="error-box" role="alert">{actionError}</p>{/if}
        <button class="btn primary small" type="submit" disabled={!!busy || !replyText.trim()}>
          {busy === 'reply' ? 'Sending…' : 'Send'}
        </button>
      </form>
    {/snippet}

    {#if history.length > 1 || (!active && history.length)}
      <section>
        <h2 class="muted">History</h2>
        <ol class="history">
          {#each history as h}
            <li>
              <div class="label">{h.kind === 'attach' ? 'You took over' : 'You asked'} · {time(h.time)}</div>
              {#if h.prompt}<div class="h-prompt">{h.prompt}</div>{/if}
              {#if h.did}
                <details>
                  <summary>Claude did</summary>
                  <div class="prose">{@html renderMarkdown(h.did)}</div>
                </details>
              {/if}
            </li>
          {/each}
        </ol>
      </section>
    {/if}

    <details class="details">
      <summary>Every step and details ({allSteps.length})</summary>
      <ol class="steps">
        {#each allSteps as s}
          <li class:error={s.error}>
            <span>{s.label}{#if s.error} <span class="warn">(had a problem)</span>{/if}</span>
            {#if s.detail}<code class="mono">{s.detail}</code>{/if}
          </li>
        {/each}
      </ol>
      <dl>
        <dt>Task</dt><dd class="mono">{task.id}</dd>
        <dt>Branch</dt><dd class="mono">clank/{task.id} (from {task.branch})</dd>
        <dt>Environment</dt><dd>{task.env || 'linux-default'}</dd>
        {#if lastResult?.duration_ms}<dt>Last run took</dt><dd>{Math.round(lastResult.duration_ms / 1000)} s</dd>{/if}
        {#if lastResult?.cost_usd}<dt>Last run cost</dt><dd>${lastResult.cost_usd.toFixed(2)} (estimate)</dd>{/if}
        {#if task.status}<dt>Exit code</dt><dd>{task.status.exit_code}</dd>{/if}
      </dl>
    </details>
  {/if}
</main>

<style>
  .head { display: flex; flex-direction: column; gap: 8px; margin-bottom: 18px; }
  .head h1 { margin: 0; font-size: 22px; line-height: 1.25; overflow-wrap: anywhere; }
  .meta { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .small { font-size: 13px; }
  .sentence { margin: 0; color: var(--text-2); font-size: 15px; }
  section { margin: 22px 0; }
  h2 { margin: 0 0 10px; font-size: 16px; font-weight: 600; }
  .label { font-size: 12px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; }

  .now { display: flex; gap: 14px; align-items: center; padding: 16px; }
  .dot { width: 10px; height: 10px; border-radius: 999px; background: var(--accent);
    box-shadow: 0 0 0 5px var(--working-bg); flex-shrink: 0; animation: pulse 1.6s ease-in-out infinite; }
  @keyframes pulse { 50% { box-shadow: 0 0 0 8px var(--working-bg); } }
  @media (prefers-reduced-motion: reduce) { .dot { animation: none; } }
  .now-text { font-size: 16px; font-weight: 500; overflow-wrap: anywhere; }

  .plan { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 10px; font-size: 15px; }
  .plan li { display: flex; gap: 10px; align-items: flex-start; }
  .plan svg { flex-shrink: 0; }
  .plan .completed span { color: var(--muted); text-decoration: line-through; }
  .plan .in_progress span { font-weight: 600; }

  .question { padding: 16px; border-color: var(--needs-border); display: flex; flex-direction: column; gap: 10px; }
  .q { color: var(--needs-fg); }
  .q-text { font-size: 18px; font-weight: 500; color: var(--text); }
  .question p { margin: 0; }

  .actions { display: flex; gap: 10px; margin: 22px 0; }
  .actions .btn { flex: 1 1 0; }
  .reply-card { padding: 16px; }
  .reply { display: flex; flex-direction: column; gap: 10px; }
  .reply label { font-size: 15px; font-weight: 600; }
  .reply .btn { align-self: flex-end; }

  .files { display: flex; flex-direction: column; text-decoration: none; color: inherit; }
  .files-head { display: flex; justify-content: space-between; padding: 14px 16px; border-bottom: 1px solid var(--border); font-weight: 600; }
  .view { color: var(--accent); }
  .file { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 11px 16px; font-size: 14px; }
  .path { overflow-wrap: anywhere; }
  .tag { font-family: inherit; font-size: 12px; margin-left: 6px; }
  .tag.added { color: var(--done-fg); }
  .tag.deleted { color: var(--bad-fg); }
  .bars { display: flex; gap: 2px; flex-shrink: 0; }
  .bar { height: 8px; border-radius: 2px; }
  .bar.add { background: var(--done-fg); }
  .bar.del { background: var(--bad-fg); }

  .history { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 14px; }
  .history li { border-left: 2px solid var(--border); padding-left: 14px; display: flex; flex-direction: column; gap: 4px; }
  .h-prompt { font-size: 14px; line-height: 1.45; white-space: pre-wrap; overflow-wrap: anywhere; }
  details summary { cursor: pointer; color: var(--accent); font-size: 14px; font-weight: 500; min-height: 32px; display: flex; align-items: center; }

  .details { margin-top: 28px; }
  .steps { margin: 8px 0 16px; padding-left: 22px; display: flex; flex-direction: column; gap: 8px; font-size: 14px; }
  .steps li { overflow-wrap: anywhere; }
  .steps code { display: block; margin-top: 2px; font-size: 12px; color: var(--muted); white-space: pre-wrap; }
  .warn { color: var(--bad-fg); }
  dl { display: grid; grid-template-columns: max-content 1fr; gap: 6px 14px; font-size: 13px; margin: 0; }
  dt { color: var(--muted); }
  dd { margin: 0; overflow-wrap: anywhere; }
</style>
