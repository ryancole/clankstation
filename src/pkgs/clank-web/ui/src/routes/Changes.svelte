<script>
  import ChangesView from '../lib/ChangesView.svelte';

  let { id } = $props();
</script>

<main class="page changes-page">
  <div class="topbar">
    <a class="back" href={`#/task/${encodeURIComponent(id)}`} aria-label="Back to the task">
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"></path></svg>
    </a>
    <h1>What changed</h1>
  </div>

  <ChangesView {id} />
</main>

<style>
  /* On a PC the file list sits beside the changes, so the page can be wider. */
  @media (min-width: 900px) { .changes-page { max-width: 1400px; } }
</style>
