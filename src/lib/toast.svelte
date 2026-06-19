<script lang="ts">
  import { toastMessage } from '../stores/clipboard';
</script>

{#if $toastMessage}
  <div class="toast">
    {$toastMessage}
  </div>
{/if}

<style>
  .toast {
    position: fixed;
    bottom: 40px;
    left: 50%;
    transform: translateX(-50%);
    padding: 8px 16px;
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: 6px;
    box-shadow: 0 4px 16px rgba(0,0,0,0.15);
    font-size: 13px;
    color: var(--text-primary);
    z-index: 1000;
    animation: toast-in 0.2s ease-out;
    pointer-events: none;
  }
  @keyframes toast-in {
    from { opacity: 0; transform: translateX(-50%) translateY(10px); }
    to { opacity: 1; transform: translateX(-50%) translateY(0); }
  }
</style>
