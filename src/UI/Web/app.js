/** Dashboard lifecycle: owns state, coordinates API calls and handles user
 * events. */
import { request, exportUrl } from './api.js';
import { setTranslations } from './localization.js';
import {
  element,
  showError,
  applyConfiguration,
  readFilters,
  renderDetails,
  renderDashboard
} from './view.js';

/**
 * Current backend configuration, assigned after loading and replaced when its
 * revision changes.
 * @type {import("./api.js").MonitorConfiguration|undefined}
 */
let configuration;

/**
 * Latest status snapshot; unavailable until the first successful status
 * request.
 * @type {import("./api.js").MonitorStatus|undefined}
 */
let state;

/**
 * Current selection object; replacing its identity invalidates outstanding
 * history responses.
 * @type {import("./api.js").Selection}
 */
let selection = {
  name: null,
  history: []
};

/**
 * Latest user-action failure key or fallback message; cleared after a
 * successful action.
 * @type {string}
 */
let actionError = '';

/**
 * Serializes user actions and prevents new polling attempts while an action is
 * in progress.
 * @type {boolean}
 */
let actionPending = false;

/**
 * Renders the module-owned dashboard state when a status snapshot is available.
 *
 * @returns {void} No return value.
 */
function render() {
  if (state) {
    renderDashboard(state, selection, actionPending, actionError);
  }
}

/**
 * Loads backend configuration, applies translations and clears the current
 * selection and history.
 *
 * @returns {Promise<void>} Resolves after configuration and presentation have
 * been updated.
 * @throws {Error} Rejects when configuration retrieval fails.
 */
async function loadConfiguration() {
  configuration = await request('/api/configuration');
  setTranslations(configuration);
  applyConfiguration(configuration);

  selection = {
    name: null,
    history: []
  };
}

/**
 * Loads history for the current selection, discarding results if that selection
 * has since been replaced.
 *
 * @returns {Promise<void>} Resolves after history is applied or skipped when no
 * check is selected.
 * @throws {Error} Rejects when history retrieval fails.
 */
async function loadHistory() {
  const currentSelection = selection;
  if (!currentSelection.name) {
    return;
  }

  const response = await request(
    `/api/history?name=${encodeURIComponent(currentSelection.name)}`
  );

  // Ignore a response if the user selected another check or reloaded
  // configuration.
  if (selection === currentSelection) {
    selection.history = response.results;
  }
}

/**
 * Loads monitor status, refreshes changed configuration and selected history,
 * then renders the dashboard.
 *
 * @returns {Promise<void>} Resolves after the dashboard refresh completes.
 * @throws {Error} Rejects when a required backend request fails.
 */
async function update() {
  state = await request('/api/status');

  if (!configuration || configuration.revision !== state.revision) {
    await loadConfiguration();
  }

  await loadHistory();
  render();
}

/**
 * Sends a serialized user action, refreshes status and displays failures
 * through the shared action error.
 *
 * @param {string} path - Same-origin mutation endpoint.
 * @param {Object} data - JSON action payload, including an empty object for
 * refresh.
 * @returns {Promise<void>} Resolves after the action is handled; skips actions
 * while busy or before configuration loads.
 */
async function performAction(path, data) {
  if (actionPending || !configuration) {
    return;
  }

  actionPending = true;
  try {
    await request(path, data, configuration.token);
    actionError = '';
    await update();
  } catch (error) {
    actionError = error.message;
    showError(actionError);
  } finally {
    actionPending = false;
    render();
  }
}

/**
 * Handles a delegated resource-button click, replacing selection and loading
 * its history.
 *
 * @param {MouseEvent} event - Click event from the checks table with an Element
 * target.
 * @returns {Promise<void>} Resolves after selection/history rendering, or
 * immediately for a non-resource click.
 */
async function selectCheck(event) {
  const button = event.target.closest('button[data-check-name]');
  if (!button) {
    return;
  }

  selection = {
    name: button.dataset.checkName,
    history: []
  };

  render();

  try {
    await loadHistory();
    renderDetails(state.checks, selection);
  } catch (error) {
    showError(error.message);
  }
}

/**
 * Requests a manual monitoring cycle through the shared action handler.
 *
 * @returns {Promise<void>} Completion of the action and ensuing status refresh.
 */
function refreshChecks() {
  return performAction('/api/refresh', {});
}

/**
 * Sends the pause checkbox state to the backend.
 *
 * @param {Event} event - Change event whose target is the pause
 * HTMLInputElement.
 * @returns {Promise<void>} Completion of the pause action and status refresh.
 */
function changePause(event) {
  return performAction('/api/pause', { paused: event.target.checked });
}

/**
 * Prevents form navigation and requests the PSD1 path entered in the
 * configuration field.
 *
 * @param {SubmitEvent} event - Configuration form submission to cancel.
 * @returns {Promise<void>} Completion of the configuration action and status
 * refresh.
 */
function openConfiguration(event) {
  event.preventDefault();
  return performAction('/api/configuration', { path: element('path').value });
}

/**
 * Requests a reload of the current backend configuration path, when available.
 *
 * @returns {Promise<void>|undefined} Action completion, or undefined before
 * configuration has loaded.
 */
function reloadConfiguration() {
  if (configuration) {
    return performAction('/api/configuration', { path: configuration.path });
  }
}

/**
 * Starts a CSV download using the current DOM filter values and the browser
 * download mechanism.
 *
 * @returns {void} No return value.
 */
function downloadExport() {
  const link = document.createElement('a');

  link.href = exportUrl(readFilters());
  link.download = 'monitoring.csv';
  link.click();
}

/**
 * Registers named dashboard handlers once at startup, including delegated
 * resource selection.
 *
 * @returns {void} No return value.
 */
function bindEvents() {
  element('checks').addEventListener('click', selectCheck);
  element('refresh').addEventListener('click', refreshChecks);
  element('pause').addEventListener('change', changePause);
  element('configuration').addEventListener('submit', openConfiguration);
  element('reload').addEventListener('click', reloadConfiguration);
  element('export').addEventListener('click', downloadExport);

  for (const id of ['search', 'group', 'incidents']) {
    element(id).addEventListener('input', render);
  }
}

/**
 * Refreshes idle dashboard state, reports connection failures and schedules
 * another poll after completion.
 *
 * @returns {Promise<void>} Resolves after this attempt and scheduling the next
 * one-second delay.
 */
async function poll() {
  try {
    if (!actionPending) {
      await update();
    }
  } catch {
    if (configuration) {
      showError('Web.Disconnected');
    } else {
      showError('Unable to connect to the local monitor.');
    }
  }

  setTimeout(poll, 1000);
}

bindEvents();
poll();
