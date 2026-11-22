<script>
  import { getClaude, getMe } from '../lib/api.js';
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
  <a class="card row link" href="#/projects">
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
</style>
