<script lang="ts">
  import { onMount } from 'svelte';
  import { slide } from 'svelte/transition';
  import { get } from 'svelte/store';
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import { initClipboard, settingsOpen, settingsData } from './stores/clipboard';
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

<!-- Native window decorations are provided by the OS (decorations: true in
     tauri.conf.json); we no longer draw our own title bar. The zoom layer
     scales the whole UI with transform: scale() so it works cross-platform
     (the old `zoom` CSS property is Chromium-only and failed on Linux/macOS). -->
<div class="app-root">
  <div
    class="zoom-layer"
    style="transform: scale({$settingsData.zoom_level}); width: {$settingsData.zoom_level === 1 ? '100%' : (100 / $settingsData.zoom_level) + '%'}; height: {$settingsData.zoom_level === 1 ? '100vh' : (100 / $settingsData.zoom_level) + 'vh'}; transform-origin: top left;"
  >
    <main class="content-area">
      {#if $settingsOpen}
        <div class="settings-wrapper" in:slide={{duration: 150, axis: "x"}} out:slide={{duration: 100, axis: "x"}}>
          <SettingsPanel />
        </div>
      {:else}
        <HistoryList />
      {/if}
    </main>
    <StatusBar />
  </div>
</div>

<svelte:window onkeydown={handleKeydown} />
<Toast />

<style>
  .app-root {
    width: 100%;
    height: 100vh;
    overflow: hidden;
    background: var(--bg-primary);
  }
  .zoom-layer {
    display: flex;
    flex-direction: column;
    height: 100vh;
  }
  .content-area {
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .settings-wrapper {
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }
</style>
