<script>
  import Home from './routes/Home.svelte';
  import Task from './routes/Task.svelte';
  import Changes from './routes/Changes.svelte';
  import NewTask from './routes/NewTask.svelte';
  import Projects from './routes/Projects.svelte';
  import Settings from './routes/Settings.svelte';
  import Sidebar from './lib/Sidebar.svelte';
  import ConnectionBanner from './lib/ConnectionBanner.svelte';
  import { MediaQuery } from 'svelte/reactivity';
  // The terminal (xterm.js) is most of the app's size: load it when opened.
  const loadTerminal = () => import('./routes/Terminal.svelte');

  // Hash routes: #/  #/new  #/projects  #/settings  #/task/<id>
  // #/task/<id>/changes  #/terminal/login|install
  function parse(hash) {
    const parts = hash.replace(/^#\/?/, '').split('/').filter(Boolean).map(decodeURIComponent);
    if (parts[0] === 'task' && parts[1]) {
      return { page: parts[2] === 'changes' ? 'changes' : 'task', id: parts[1] };
    }
    if (parts[0] === 'new' || parts[0] === 'projects' || parts[0] === 'settings') return { page: parts[0] };
    if (parts[0] === 'terminal' && ['login', 'install'].includes(parts[1])) {
      return { page: 'terminal', kind: parts[1], id: '' };
    }
    return { page: 'home' };
  }

  let route = $state(parse(location.hash));
  // A PC-wide window: the task list stays on the left (docs/gui.md 3.8).
  const wide = new MediaQuery('min-width: 900px', false);

  $effect(() => {
    const onHash = () => {
      route = parse(location.hash);
      window.scrollTo(0, 0);
    };
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  });
</script>

{#snippet page()}
{#if route.page === 'task'}
  {#key route.id}<Task id={route.id} />{/key}
{:else if route.page === 'new'}
  <NewTask />
{:else if route.page === 'projects'}
  <Projects />
{:else if route.page === 'settings'}
  <Settings />
{:else if route.page === 'terminal'}
  {#key `${route.kind}/${route.id}`}
    {#await loadTerminal() then m}<m.default kind={route.kind} task={route.id} />{/await}
  {/key}
{:else if route.page === 'changes'}
  {#key route.id}<Changes id={route.id} />{/key}
{:else if wide.current}
  <main class="page pick">
    <p>Pick a task on the left, or start a new one.</p>
    <a class="btn primary" href="#/new">New task</a>
  </main>
{:else}
  <Home />
{/if}
{/snippet}

<ConnectionBanner />

{#if wide.current && route.page !== 'terminal'}
  <div class="shell">
    <Sidebar {route} />
    <div class="main">{@render page()}</div>
  </div>
{:else}
  {@render page()}
{/if}

<style>
  .shell { display: grid; grid-template-columns: 300px minmax(0, 1fr); min-height: 100vh; }
  .main { min-width: 0; }
  .pick { min-height: 100vh; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 18px; color: var(--muted); font-size: 16px; }
  .pick p { margin: 0; }
</style>
