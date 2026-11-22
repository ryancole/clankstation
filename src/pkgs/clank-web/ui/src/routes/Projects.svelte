<script>
  import { listProjects, addProject, setPullRequests } from '../lib/api.js';
  import { ago } from '../lib/states.js';

  let projects = $state(null);
  let url = $state('');
  let name = $state('');
  let nameEdited = $state(false);
  let busy = $state(false);
  let error = $state('');
  let added = $state('');

  async function refresh() {
    try {
      projects = await listProjects();
    } catch {
      error = "Can't reach the box right now.";
    }
  }
  $effect(() => {
    refresh();
  });

  // Pull requests on GitHub, per project (S10).
  let prBusy = $state('');
  let prError = $state('');
  async function togglePRs(p) {
    prBusy = p.name;
    prError = '';
    try {
      await setPullRequests(p.name, !p.pull_requests);
      p.pull_requests = !p.pull_requests;
    } catch (err) {
      prError = err.message;
    } finally {
      prBusy = '';
    }
  }

  // Suggest a name from the address: .../My-Repo.git -> my-repo
  function suggest(u) {
    const last = u.trim().replace(/\/+$/, '').split(/[/:]/).pop() ?? '';
    return last.replace(/\.git$/i, '').toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^[-_]+|-+$/g, '');
  }
  function onUrl() {
    if (!nameEdited) name = suggest(url);
  }

  async function add(e) {
    e.preventDefault();
    if (busy) return;
    busy = true;
    error = '';
    added = '';
    try {
      await addProject(name.trim(), url.trim());
      added = name.trim();
      url = '';
      name = '';
      nameEdited = false;
      await refresh();
    } catch (err) {
      error = err.message;
    } finally {
      busy = false;
    }
  }
</script>

<main class="page">
  <div class="topbar">
    <a class="back" href="#/" aria-label="Back to your tasks">
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"></path></svg>
    </a>
    <h1>Projects</h1>
  </div>

  {#if projects === null && !error}
    <p class="empty">Loading…</p>
  {:else if projects && projects.length}
    <ul class="card list">
      {#each projects as p (p.name)}
        <li>
          <span class="p-name">{p.name}</span>
          <span class="muted small p-url">{p.url}</span>
          <span class="muted small">{p.last_used ? `Last task ${ago(p.last_used)}` : 'No tasks yet'}</span>
          {#if p.github || p.pull_requests}
            <label class="pr-toggle">
              <input type="checkbox" checked={p.pull_requests} disabled={prBusy === p.name}
                onchange={() => togglePRs(p)} />
              <span>Open a pull request on GitHub for each task</span>
            </label>
          {/if}
        </li>
      {/each}
    </ul>
    {#if prError}<p class="error-box" role="alert">{prError}</p>{/if}
  {/if}

  {#if added}
    <p class="ok" role="status">Added {added}. <a href="#/new">Give Claude a task in it</a></p>
  {/if}

  <form class="card add" onsubmit={add}>
    <h2>Add a project</h2>
    <div class="field">
      <label for="url">Where is the code?</label>
      <input id="url" type="text" inputmode="url" autocomplete="off" autocapitalize="off" spellcheck="false"
        placeholder="https://github.com/you/your-project" bind:value={url} oninput={onUrl} />
      <p class="hint">The address you'd use to clone it with git. The box makes its own copy.</p>
    </div>
    <div class="field">
      <label for="name">Name</label>
      <input id="name" type="text" autocomplete="off" autocapitalize="off" spellcheck="false"
        bind:value={name} oninput={() => (nameEdited = true)} />
      <p class="hint">Lowercase letters, digits, - and _.</p>
    </div>
    {#if error}<p class="error-box" role="alert">{error}</p>{/if}
    <button class="btn primary" type="submit" disabled={busy || !url.trim() || !name.trim()}>
      {busy ? 'Copying the code…' : 'Add project'}
    </button>
  </form>
</main>

<style>
  .list { list-style: none; margin: 0 0 20px; padding: 0; }
  .list li { display: flex; flex-direction: column; gap: 3px; padding: 14px 16px; border-bottom: 1px solid var(--border); }
  .list li:last-child { border-bottom: 0; }
  .p-name { font-size: 16px; font-weight: 600; }
  .p-url { overflow-wrap: anywhere; }
  .pr-toggle { display: flex; align-items: center; gap: 10px; margin-top: 8px; font-size: 14px; cursor: pointer; }
  .pr-toggle input { width: 18px; height: 18px; accent-color: var(--accent); flex-shrink: 0; }
  .small { font-size: 13px; }
  .add { display: flex; flex-direction: column; gap: 18px; padding: 18px 16px; }
  .add h2 { margin: 0; font-size: 18px; }
  .ok { background: var(--done-bg); color: var(--done-fg); border-radius: 12px; padding: 10px 14px; font-size: 14px; }
  .ok a { color: inherit; font-weight: 600; }
</style>
