<script lang="ts">
  import { onMount } from 'svelte';
  import { get } from 'svelte/store';
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import { initClipboard, settingsOpen, settingsData } from './stores/clipboard';
  import Titlebar from './lib/titlebar.svelte';
  import HistoryList from './lib/history-list.svelte';
  import SettingsPanel from './lib/settings-panel.svelte';
  import StatusBar from './lib/statusbar.svelte';
  import Toast from './lib/toast.svelte';

  const appWindow = getCurrentWindow();

  onMount(() => {
    initClipboard();
  });

  function handleKeydown(e: KeyboardEvent) {
    if (e.key !== 'Escape') return;
    // If an input (search box) is focused, let the input handler blur it
    if (document.activeElement?.tagName === 'INPUT') return;
    // If settings panel is open, let its own Escape handler close it
    if (get(settingsOpen)) return;
    // Otherwise hide/close the app (respecting close-to-tray setting)
    if (get(settingsData).close_to_tray) {
      appWindow.hide();
    } else {
      appWindow.close();
    }
  }
</script>

<div class="window">
  <Titlebar />
  {#if $settingsOpen}
    <SettingsPanel />
  {:else}
    <HistoryList />
  {/if}
  <StatusBar />
</div>

<svelte:window onkeydown={handleKeydown} />
<Toast />

<style>
  .window {
    display: flex;
    flex-direction: column;
    height: 100vh;
    background: var(--bg-primary);
    overflow: hidden;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.15);
  }
</style>
