<script>
  import { listProjects, newTask, getClaude } from '../lib/api.js';

  let projects = $state(null);
  let project = $state('');
  let prompt = $state('');
  let busy = $state(false);
  let error = $state('');
  let claude = $state(null);

  $effect(() => {
    listProjects()
      .then((ps) => {
        projects = ps ?? [];
        if (!project && projects.length) project = projects[0].name;
      })
      .catch(() => (error = "Can't reach the box right now."));
    getClaude()
      .then((c) => (claude = c))
      .catch(() => {});
  });

  async function start(e) {
    e.preventDefault();
    if (busy) return;
    busy = true;
    error = '';
    try {
      const { id } = await newTask(project, prompt);
      location.hash = `#/task/${encodeURIComponent(id)}`;
    } catch (err) {
      error = err.message;
      busy = false;
    }
  }
</script>

<main class="page">
  <div class="topbar">
    <a class="back" href="#/" aria-label="Back to your tasks">
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"></path></svg>
    </a>
    <h1>New task</h1>
  </div>

  {#if claude && (!claude.installed || !claude.signed_in)}
    <p class="notice" role="alert">
      {claude.installed ? 'Claude is not signed in on the box yet.' : "Claude isn't set up on the box yet."}
      <a href="#/settings">{claude.installed ? 'Sign in' : 'Set it up'} in Settings</a>
    </p>
  {/if}

  {#if projects === null && !error}
    <p class="empty">Loading…</p>
  {:else if projects && projects.length === 0}
    <div class="empty">
      <p>Add a project first: the code Claude should work on.</p>
      <a class="btn primary" href="#/projects">Add a project</a>
    </div>
  {:else}
    <form onsubmit={start}>
      <fieldset class="field">
        <legend class="label-text">Which project?</legend>
        <div class="card choices">
          {#each projects ?? [] as p (p.name)}
            <label class="choice" class:on={project === p.name}>
              <input type="radio" name="project" value={p.name} bind:group={project} />
              <span class="choice-text">
                <span class="choice-name">{p.name}</span>
                {#if p === projects[0] && p.last_used}<span class="muted small">Used last</span>{/if}
              </span>
            </label>
          {/each}
          <a class="choice add" href="#/projects">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"></path></svg>
            Add a project
          </a>
        </div>
      </fieldset>

      <div class="field">
        <label for="prompt">What should Claude do?</label>
        <textarea id="prompt" rows="8" bind:value={prompt}
          placeholder="Describe what you want, like you'd tell a colleague. For example: Fix the typo on the About page and make the contact form send an email."></textarea>
        <p class="hint">You can close the app after starting. Come back here to see how it's going.</p>
      </div>

      {#if error}<p class="error-box" role="alert">{error}</p>{/if}

      <div class="bottom-bar">
        <button class="btn primary" type="submit" disabled={busy || !project || !prompt.trim()}>
          {busy ? 'Starting…' : 'Start'}
        </button>
      </div>
    </form>
  {/if}
</main>

<style>
  form { display: flex; flex-direction: column; gap: 22px; }
  fieldset { border: 0; margin: 0; padding: 0; min-width: 0; }
  legend { padding: 0; margin-bottom: 8px; }
  .choices { display: flex; flex-direction: column; overflow: hidden; }
  .choice {
    display: flex; align-items: center; gap: 12px; padding: 14px 16px; min-height: 52px;
    border-bottom: 1px solid var(--border); cursor: pointer; color: inherit; text-decoration: none;
  }
  .choice:last-child { border-bottom: 0; }
  .choice.on { background: var(--working-bg); }
  .choice input { width: 20px; height: 20px; margin: 0; accent-color: var(--accent); flex-shrink: 0; }
  .choice-text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .choice-name { font-size: 16px; font-weight: 600; overflow-wrap: anywhere; }
  .small { font-size: 13px; }
  .add { color: var(--accent); font-weight: 500; }
  .notice { background: var(--needs-bg); color: var(--needs-fg); border-radius: 12px; padding: 12px 14px; font-size: 15px; line-height: 1.4; margin: 0 0 16px; }
  .notice a { color: inherit; font-weight: 600; }
  .empty { display: flex; flex-direction: column; align-items: center; gap: 16px; }
  .empty p { margin: 0; }
</style>
