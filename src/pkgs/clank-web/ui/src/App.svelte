<script>
  import Home from './routes/Home.svelte';
  import Task from './routes/Task.svelte';
  import Changes from './routes/Changes.svelte';
  import NewTask from './routes/NewTask.svelte';
  import Projects from './routes/Projects.svelte';
  import Settings from './routes/Settings.svelte';
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

  $effect(() => {
    const onHash = () => {
      route = parse(location.hash);
      window.scrollTo(0, 0);
    };
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  });
</script>

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
{:else}
  <Home />
{/if}
