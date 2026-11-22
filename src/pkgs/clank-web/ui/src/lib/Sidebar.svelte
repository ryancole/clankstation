<script>
  // The task list that stays on the left on a PC (docs/gui.md 3.8).
  import { listTasks } from './api.js';
  import { stateInfo } from './states.js';
  import { groupTasks, when, pollTasks } from './taskList.js';

  let { route } = $props();

  let tasks = $state(null);
  let showOlder = $state(false);

  // Can't reach the box: the connection banner says so (App.svelte).
  $effect(() => pollTasks(listTasks, (t) => (tasks = t), () => {}));

  const groups = $derived(groupTasks(tasks));
  const selected = $derived(route.page === 'task' || route.page === 'changes' ? route.id : '');
</script>

<aside class="sidebar" aria-label="Your tasks">
  <div class="brand">
    <a href="#/" class="name">Clankstation</a>
  </div>
  <a class="btn primary new" href="#/new" class:current={route.page === 'new'}>
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"></path></svg>
    New task
  </a>

  <nav class="tasks">
    {#snippet row(t)}
      {@const info = stateInfo(t)}
      <a class="row" class:selected={t.id === selected} href={`#/task/${encodeURIComponent(t.id)}`}
        aria-current={t.id === selected ? 'page' : undefined}>
        <span class="line1">
          <span class="title">{t.title || 'Untitled task'}</span>
          <span class="when">{when(t)}</span>
        </span>
        <span class="line2">
          <span class={`pill tone-${info.tone}`}>{info.label}</span>
          <span class="project">{t.project}</span>
        </span>
        {#if t.activity}
          <span class="activity">{t.state === 'needs_input' ? `“${t.activity}”` : t.activity}</span>
        {/if}
      </a>
    {/snippet}

    {#if tasks === null}
      <p class="empty-list">Loading…</p>
    {:else if tasks && tasks.length === 0}
      <p class="empty-list">Nothing yet. Give Claude its first task with <strong>New task</strong>.</p>
    {:else if tasks}
      {#if groups.needs.length}
        <h2 class="group">Needs you</h2>
        {#each groups.needs as t (t.id)}{@render row(t)}{/each}
      {/if}
      {#if groups.working.length}
        <h2 class="group">Working</h2>
        {#each groups.working as t (t.id)}{@render row(t)}{/each}
      {/if}
      {#if groups.done.length || groups.older.length}
        <h2 class="group">Done</h2>
        {#each groups.done as t (t.id)}{@render row(t)}{/each}
        {#if showOlder}
          {#each groups.older as t (t.id)}{@render row(t)}{/each}
        {:else if groups.older.length}
          <button class="older" onclick={() => (showOlder = true)}>Show older ({groups.older.length})</button>
        {/if}
      {/if}
    {/if}
  </nav>

  <div class="foot">
    <a href="#/projects" class:current={route.page === 'projects'}>Projects</a>
    <a href="#/settings" class:current={route.page === 'settings'}>Settings</a>
  </div>
</aside>

<style>
  .sidebar {
    position: sticky; top: 0; height: 100vh; display: flex; flex-direction: column;
    background: var(--surface); border-right: 1px solid var(--border);
  }
  .brand { padding: 18px 18px 12px; }
  .name { font-size: 17px; font-weight: 700; color: var(--text); text-decoration: none; }
  .new { margin: 0 14px 10px; min-height: 44px; font-size: 15px; }
  .tasks { flex: 1 1 auto; overflow-y: auto; padding: 0 8px 12px; }
  .group {
    margin: 16px 10px 6px; font-size: 12px; font-weight: 600;
    letter-spacing: 0.04em; text-transform: uppercase; color: var(--muted);
  }
  .row {
    display: flex; flex-direction: column; gap: 5px; padding: 10px 10px;
    border-radius: 10px; color: inherit; text-decoration: none;
  }
  .row:hover { background: var(--sunken); }
  .row.selected { background: var(--working-bg); }
  .line1, .line2 { display: flex; align-items: baseline; gap: 8px; min-width: 0; }
  .line2 { align-items: center; }
  .title {
    flex: 1 1 auto; min-width: 0; font-size: 14px; font-weight: 600; line-height: 1.3;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .when, .project { font-size: 12px; color: var(--muted); white-space: nowrap; }
  .project { overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .pill { font-size: 11px; padding: 2px 8px; }
  .activity {
    font-size: 13px; color: var(--text-2); line-height: 1.35; overflow-wrap: anywhere;
    display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
  }
  .empty-list { padding: 16px 10px; color: var(--muted); font-size: 14px; line-height: 1.4; }
  .older {
    width: calc(100% - 12px); margin: 6px; min-height: 36px; border: 1px solid var(--border-strong);
    background: var(--surface); color: var(--text); border-radius: 10px; font: inherit; font-size: 14px; font-weight: 600; cursor: pointer;
  }
  .foot { display: flex; gap: 4px; padding: 10px 8px; border-top: 1px solid var(--border); }
  .foot a {
    flex: 1 1 0; text-align: center; padding: 9px 8px; border-radius: 10px;
    color: var(--text-2); text-decoration: none; font-size: 14px; font-weight: 600;
  }
  .foot a:hover { background: var(--sunken); }
  .foot a.current { background: var(--working-bg); color: var(--working-fg); }
</style>
