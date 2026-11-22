<script>
  // "Reconnecting…" while the box can't be reached, then "Connected" for a
  // moment (docs/gui.md 3.10).
  import { connection } from './connection.svelte.js';
</script>

<div class="wrap" role="status" aria-live="polite">
  {#if connection.status === 'reconnecting'}
    <div class="banner">
      <span class="spinner" aria-hidden="true"></span>
      Reconnecting…
    </div>
  {:else if connection.status === 'back'}
    <div class="banner back">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 6 9 17l-5-5"></path></svg>
      Connected
    </div>
  {/if}
</div>

<style>
  .wrap {
    position: fixed;
    top: calc(10px + env(safe-area-inset-top));
    left: 0;
    right: 0;
    display: flex;
    justify-content: center;
    pointer-events: none;
    z-index: 50;
  }
  .banner {
    display: inline-flex;
    align-items: center;
    gap: 10px;
    padding: 9px 16px;
    border-radius: 999px;
    background: var(--needs-bg);
    color: var(--needs-fg);
    border: 1px solid var(--needs-border);
    box-shadow: 0 4px 16px rgb(0 0 0 / 0.12);
    font-size: 14px;
    font-weight: 600;
    animation: drop 160ms ease-out;
  }
  .banner.back {
    background: var(--done-bg);
    color: var(--done-fg);
    border-color: transparent;
  }
  .spinner {
    width: 14px;
    height: 14px;
    border-radius: 50%;
    border: 2px solid currentColor;
    border-right-color: transparent;
    animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
  @keyframes drop { from { transform: translateY(-8px); opacity: 0; } }
  @media (prefers-reduced-motion: reduce) {
    .banner { animation: none; }
    .spinner { animation: pulse 1.6s ease-in-out infinite; border-right-color: currentColor; }
    @keyframes pulse { 50% { opacity: 0.3; } }
  }
</style>
