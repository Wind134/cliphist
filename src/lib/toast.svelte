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
    border-radius: 8px;
    box-shadow: 0 6px 20px rgba(0,0,0,0.12);
    font-size: 13px;
    color: var(--text-primary);
    z-index: 1000;
    animation: toast-in 0.25s cubic-bezier(0.16, 1, 0.3, 1);
    pointer-events: none;
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
  }
  @keyframes toast-in {
    from { opacity: 0; transform: translateX(-50%) translateY(12px) scale(0.96); }
    to { opacity: 1; transform: translateX(-50%) translateY(0) scale(1); }
  }
</style>
