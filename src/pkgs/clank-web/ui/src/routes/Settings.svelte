<script>
  import { getClaude, getMe, getBox, checkForUpdates, updateBox } from '../lib/api.js';
  import { ago } from '../lib/states.js';
  import { pushSupport, currentSubscription, turnOn, turnOff, sendTest } from '../lib/push.js';

  let claude = $state(null);
  let error = $state('');
  let me = $state(null);

  $effect(() => {
    getClaude()
      .then((c) => (claude = c))
      .catch((e) => (error = e.message));
    getMe()
      .then((m) => (me = m))
      .catch(() => {});
  });

  // Notifications on this device.
  const support = pushSupport();
  let pushOn = $state(null); // null while checking
  let pushBusy = $state('');
  let pushMsg = $state('');
  let pushErr = $state('');

  $effect(() => {
    if (support !== 'ok') return;
    currentSubscription()
      .then((s) => (pushOn = Boolean(s) && Notification.permission === 'granted'))
      .catch(() => (pushOn = false));
  });

  async function togglePush() {
    pushErr = '';
    pushMsg = '';
    pushBusy = pushOn ? 'off' : 'on';
    try {
      if (pushOn) {
        await turnOff();
        pushOn = false;
      } else {
        await turnOn();
        pushOn = true;
        pushMsg = "You'll get a notification when a task is done or Claude has a question.";
      }
    } catch (e) {
      pushErr = e.message;
    } finally {
      pushBusy = '';
    }
  }

  async function testPush() {
    pushErr = '';
    pushMsg = '';
    pushBusy = 'test';
    try {
      await sendTest();
      pushMsg = 'Sent. It should show up in a few seconds.';
    } catch (e) {
      pushErr = e.message;
    } finally {
      pushBusy = '';
    }
  }

  // The box (S7). While it checks or updates, ask again every few seconds;
  // an update can restart the app, so a failed fetch means "restarting".
  let box = $state(null);
  let boxErr = $state('');
  let boxBusy = $state('');
  let unreachable = $state(false);

  async function loadBox() {
    try {
      box = await getBox();
      unreachable = false;
    } catch {
      unreachable = true;
    }
  }

  $effect(() => {
    loadBox();
    const t = setInterval(() => {
      if (box?.busy || unreachable) loadBox();
    }, 3000);
    return () => clearInterval(t);
  });

  async function boxAction(kind) {
    if (kind === 'update' && !confirm(
      'Update the box now? It downloads and builds the new version, which can take a while. ' +
      'The app may disconnect for a moment while it restarts.')) return;
    boxErr = '';
    boxBusy = kind;
    try {
      await (kind === 'update' ? updateBox() : checkForUpdates());
      await loadBox();
    } catch (e) {
      boxErr = e.message;
    } finally {
      boxBusy = '';
    }
  }

  function shortRev(rev) {
    if (!rev) return 'unknown';
    const dirty = rev.endsWith('-dirty');
    const r = /^[0-9a-f]{40}/.test(rev) ? rev.slice(0, 7) : rev.replace(/-dirty$/, '');
    return dirty ? `${r} (local changes)` : r;
  }

  function size(bytes) {
    const gb = bytes / 1e9;
    if (gb >= 1000) return `${(gb / 1000).toFixed(1)} TB`;
    return gb >= 10 ? `${Math.round(gb)} GB` : `${gb.toFixed(1)} GB`;
  }

  const newVersion = $derived(box?.check?.ok && !box.check.up_to_date && box.check.latest);

  const PLANS = { pro: 'Pro', max: 'Max', team: 'Team', enterprise: 'Enterprise' };
</script>

<main class="page">
  <div class="topbar">
    <a class="back" href="#/" aria-label="Back to your tasks">
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"></path></svg>
    </a>
    <h1>Settings</h1>
  </div>

  {#if me}
    <h2 class="section-title">You</h2>
    <div class="card group">
      <div class="row">
        <span class="text">
          <span class="label">{me.name || me.login}</span>
          <span class="muted small">{me.login === 'dev' ? 'No login on the dev VM' : `${me.login} · on ${me.node}`}</span>
        </span>
      </div>
    </div>
    <p class="note muted small">Your Tailscale account is your Clankstation login.</p>
  {/if}

  <h2 class="section-title">Claude</h2>
  <div class="card group">
    {#if error}
      <p class="row error-box">{error}</p>
    {:else if !claude}
      <p class="row muted">Checking Claude…</p>
    {:else if !claude.installed}
      <div class="row">
        <span class="text">
          <span class="label">Claude Code isn't set up yet</span>
          <span class="muted small">The box installs it with Anthropic's official installer.</span>
        </span>
        <a class="btn primary small" href="#/terminal/install">Set up Claude</a>
      </div>
    {:else}
      <div class="row">
        <span class="label">Claude Code</span>
        <span class="muted small">Installed · {claude.version}</span>
      </div>
      <div class="row">
        <span class="text">
          <span class="label">{claude.signed_in ? 'Signed in' : 'Not signed in'}</span>
          {#if claude.signed_in}
            <span class="small ok">
              {claude.method === 'claude.ai' ? 'With your Claude account' : 'With an API key'}{claude.plan ? ` · ${PLANS[claude.plan] ?? claude.plan}` : ''}
            </span>
          {:else}
            <span class="muted small">Tasks can't start until Claude is signed in.</span>
          {/if}
        </span>
        <a class={`btn small ${claude.signed_in ? '' : 'primary'}`} href="#/terminal/login">
          {claude.signed_in ? 'Sign in again' : 'Sign in'}
        </a>
      </div>
    {/if}
  </div>
  <p class="note muted small">
    Signing in opens Claude's own sign-in in a terminal. The box passes your typing along and never
    sees, keeps or reads your password or sign-in.
  </p>

  <h2 class="section-title">This device</h2>
  <div class="card group">
    {#if support === 'ios-install'}
      <p class="row muted">To get notifications on iPhone, add Clankstation to your home screen
        (Share, then Add to Home Screen) and open it from there.</p>
    {:else if support !== 'ok'}
      <p class="row muted">This browser can't show Clankstation's notifications.</p>
    {:else}
      <div class="row">
        <span class="text">
          <span class="label">Notifications</span>
          <span class="muted small">When a task is done or Claude has a question</span>
        </span>
        <button class={`btn small ${pushOn ? '' : 'primary'}`} onclick={togglePush}
          disabled={pushOn === null || !!pushBusy}>
          {pushBusy === 'on' ? 'Turning on…' : pushBusy === 'off' ? 'Turning off…' : pushOn ? 'Turn off' : 'Turn on'}
        </button>
      </div>
      {#if pushOn}
        <div class="row">
          <span class="label">Send a test notification</span>
          <button class="btn small" onclick={testPush} disabled={!!pushBusy}>
            {pushBusy === 'test' ? 'Sending…' : 'Test'}
          </button>
        </div>
      {/if}
    {/if}
  </div>
  {#if pushMsg}<p class="note small ok" role="status">{pushMsg}</p>{/if}
  {#if pushErr}<p class="error-box note" role="alert">{pushErr}</p>{/if}

  <h2 class="section-title">The box</h2>
  <div class="card group">
    {#if !box}
      <p class="row muted">{unreachable ? "Can't reach the box right now." : 'Checking the box…'}</p>
    {:else}
      <div class="row">
        <span class="label">Version</span>
        <span class="muted small mono">{shortRev(box.version.revision)}{box.version.nixos ? ` · NixOS ${box.version.nixos.split('.').slice(0, 2).join('.')}` : ''}</span>
      </div>
      {#if !box.updates}
        <p class="row muted small">Updates are off on this box.</p>
      {:else if box.busy === 'update'}
        <div class="row">
          <span class="text">
            <span class="label">Updating…</span>
            <span class="muted small">{unreachable
              ? 'The app is restarting. This page reconnects by itself.'
              : 'Downloading and building the new version. This can take a while; you can leave this page.'}</span>
          </span>
        </div>
      {:else}
        <div class="row">
          <span class="text">
            {#if box.busy === 'check'}
              <span class="label">Checking for updates…</span>
            {:else if newVersion}
              <span class="label">A new version is available</span>
              <span class="muted small mono">{shortRev(box.check.latest)}</span>
            {:else if box.check?.ok}
              <span class="label">Up to date</span>
              <span class="muted small">Checked {ago(box.check.finished)}</span>
            {:else}
              <span class="label">Updates</span>
              <span class="muted small">From Clankstation on GitHub</span>
            {/if}
          </span>
          {#if newVersion}
            <button class="btn small primary" onclick={() => boxAction('update')} disabled={!!boxBusy}>
              {boxBusy === 'update' ? 'Starting…' : 'Update now'}
            </button>
          {:else}
            <button class="btn small" onclick={() => boxAction('check')} disabled={!!boxBusy || !!box.busy}>
              {boxBusy === 'check' || box.busy === 'check' ? 'Checking…' : 'Check for updates'}
            </button>
          {/if}
        </div>
      {/if}
      {#each box.disks as d}
        <div class="row">
          <span class="text grow">
            <span class="label">{d.name}</span>
            <span class="bar" aria-hidden="true"><span style={`width: ${d.size ? Math.round(100 * (1 - d.free / d.size)) : 0}%`}></span></span>
          </span>
          <span class="muted small">{size(d.free)} free of {size(d.size)}</span>
        </div>
      {/each}
    {/if}
  </div>
  {#if box?.restart_needed && !box.busy}
    <p class="note warn small" role="status">Restart the box to finish the update: it brought a new system kernel.
      Over SSH: <span class="mono">sudo reboot</span></p>
  {/if}
  {#if box?.check && !box.check.ok && !box.busy}
    <p class="error-box note" role="alert">{box.check.message}</p>
  {/if}
  {#if box?.update?.finished || box?.update?.interrupted}
    {#if !box.busy}
      {#if box.update.ok}
        <p class="note small ok" role="status">{box.update.message} <span class="muted">({ago(box.update.finished)})</span></p>
      {:else}
        <p class="error-box note" role="alert">{box.update.message}</p>
      {/if}
      {#if box.update.log}
        <details class="note small">
          <summary class="muted">Details of the last update</summary>
          <pre class="log mono">{box.update.log}</pre>
        </details>
      {/if}
    {/if}
  {/if}
  {#if boxErr}<p class="error-box note" role="alert">{boxErr}</p>{/if}

  <a class="card row link projects" href="#/projects">
    <span class="label">Projects</span>
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 18l6-6-6-6"></path></svg>
  </a>
</main>

<style>
  .group { display: flex; flex-direction: column; }
  .row {
    display: flex; justify-content: space-between; align-items: center; gap: 12px;
    padding: 14px 16px; margin: 0; border-bottom: 1px solid var(--border);
  }
  .group .row:last-child { border-bottom: 0; }
  .text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .label { font-size: 16px; }
  .small { font-size: 13px; }
  .ok { color: var(--done-fg); font-weight: 500; }
  .note { margin: 8px 4px 0; line-height: 1.4; }
  .link { color: var(--text); text-decoration: none; border-bottom: 1px solid var(--border); }
  .btn { flex-shrink: 0; }
  .grow { flex: 1; }
  .bar { display: block; height: 6px; margin-top: 6px; border-radius: 3px; background: var(--sunken); overflow: hidden; max-width: 220px; }
  .bar > span { display: block; height: 100%; background: var(--muted); }
  .warn { color: var(--needs-fg); }
  .projects { margin-top: 12px; }
  .log { white-space: pre-wrap; overflow-wrap: anywhere; background: var(--sunken); padding: 10px 12px; border-radius: 10px; max-height: 320px; overflow-y: auto; }
</style>
