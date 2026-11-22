<script>
  import { listTasks } from '../lib/api.js';
  import { stateInfo, ago } from '../lib/states.js';

  let tasks = $state(null);
  let error = $state('');
  let showOlder = $state(false);

  async function refresh() {
    try {
      tasks = await listTasks();
      error = '';
    } catch {
      error = "Can't reach the box right now. Retrying…";
    }
  }

  $effect(() => {
    refresh();
    const t = setInterval(refresh, 3000);
    return () => clearInterval(t);
  });

  const WEEK = 7 * 86400 * 1000;
  const groups = $derived.by(() => {
    const g = { needs: [], working: [], done: [], older: [] };
    for (const t of tasks ?? []) {
      const info = stateInfo(t);
      if (info.group === 'done') {
        const when = Date.parse(t.finished || t.created);
        (Date.now() - when > WEEK ? g.older : g.done).push(t);
      } else {
        g[info.group].push(t);
      }
    }
    return g;
  });

  function when(t) {
    const info = stateInfo(t);
    if (info.group === 'working') return `started ${ago(t.created)}`;
    return ago(t.finished || t.created);
  }
</script>

<main class="page">
  <div class="topbar">
    <h1 class="title">Your tasks</h1>
    <a class="projects-link" href="#/projects">Projects</a>
  </div>

  {#if error}<p class="notice">{error}</p>{/if}

  {#snippet card(t)}
    {@const info = stateInfo(t)}
    <a class="card task" href={`#/task/${encodeURIComponent(t.id)}`}>
      <div class="row">
        <span class={`pill tone-${info.tone}`}>{info.label}</span>
        <span class="when">{when(t)}</span>
      </div>
      <div class="name">{t.title || 'Untitled task'}</div>
      {#if t.activity}
        <div class="activity">{t.state === 'needs_input' ? `“${t.activity}”` : t.activity}</div>
      {/if}
      <div class="project">{t.project}</div>
    </a>
  {/snippet}

  {#if tasks === null && !error}
    <p class="empty">Loading…</p>
  {:else if tasks && tasks.length === 0}
    <p class="empty">Nothing yet. Give Claude its first task with <strong>New task</strong>.</p>
  {:else if tasks}
    {#if groups.needs.length}
      <h2 class="section-title">Needs you</h2>
      <div class="list">{#each groups.needs as t (t.id)}{@render card(t)}{/each}</div>
    {/if}
    {#if groups.working.length}
      <h2 class="section-title">Working</h2>
      <div class="list">{#each groups.working as t (t.id)}{@render card(t)}{/each}</div>
    {/if}
    {#if groups.done.length || groups.older.length}
      <h2 class="section-title">Done</h2>
      <div class="list">
        {#each groups.done as t (t.id)}{@render card(t)}{/each}
        {#if showOlder}
          {#each groups.older as t (t.id)}{@render card(t)}{/each}
        {:else if groups.older.length}
          <button class="older" onclick={() => (showOlder = true)}>Show older ({groups.older.length})</button>
        {/if}
      </div>
    {/if}
  {/if}

  <div class="bottom-bar">
    <a class="btn primary" href="#/new">
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"></path></svg>
      New task
    </a>
  </div>
</main>

<style>
  .title { font-size: 28px; flex-grow: 1; }
  .projects-link {
    min-height: 44px; display: inline-flex; align-items: center; padding: 0 8px;
    font-size: 15px; font-weight: 500; text-decoration: none;
  }
  main { min-height: 100vh; display: flex; flex-direction: column; }
  .bottom-bar { margin-top: auto; }
  .list { display: flex; flex-direction: column; gap: 10px; }
  .task {
    display: flex; flex-direction: column; gap: 6px; padding: 14px 16px;
    text-decoration: none; color: inherit;
  }
  .task:hover { border-color: var(--border-strong); }
  .row { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
  .when, .project { font-size: 12px; color: var(--muted); }
  .name { font-size: 16px; font-weight: 600; line-height: 1.3; overflow-wrap: anywhere;
    display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .activity { font-size: 14px; color: var(--text-2); line-height: 1.4; overflow-wrap: anywhere;
    display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .notice { background: var(--needs-bg); color: var(--needs-fg); padding: 10px 14px; border-radius: 12px; font-size: 14px; }
  .older {
    min-height: 44px; border: 1px solid var(--border-strong); background: var(--surface);
    color: var(--text); border-radius: 12px; font: inherit; font-weight: 600; cursor: pointer;
  }
</style>
