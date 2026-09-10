/** DOM rendering only. Monitor state and selection are supplied by app.js. */
/** @typedef {import('./api.js').CheckResult} CheckResult */
/** @typedef {import('./api.js').CheckRow} CheckRow */
/** @typedef {import('./api.js').MonitorStatus} MonitorStatus */
/** @typedef {import('./api.js').Selection} Selection */

import {
  text,
  format,
  timestamp,
  resultMessage,
  checkedTime
} from './localization.js';

/**
 * Finds a dashboard element by its HTML identifier.
 *
 * @param {string} id - Element identifier in index.html.
 * @returns {HTMLElement|null} Matching element or null; rendering callers
 * expect the dashboard markup to exist.
 */
export function element(id) {
  return document.getElementById(id);
}

/**
 * Displays a translated error as plain text, or hides and clears the alert for
 * an empty key.
 *
 * @param {string} key - Error resource key or fallback message; an empty string
 * clears the alert.
 * @returns {void} No return value.
 */
export function showError(key) {
  const error = element('error');

  error.textContent = '';
  error.hidden = true;

  if (key) {
    error.textContent = text(key);
    error.hidden = false;
  }
}

/**
 * Applies translated labels, accessibility text and configuration/log paths to
 * the DOM.
 *
 * @param {import("./api.js").MonitorConfiguration} configuration - Loaded
 * configuration; setTranslations must have been called first.
 * @returns {void} No return value.
 */
export function applyConfiguration(configuration) {
  for (const node of document.querySelectorAll('[data-text]')) {
    node.textContent = text(node.dataset.text);
  }

  document.querySelector('nav').setAttribute(
    'aria-label',
    text('Web.Actions')
  );

  document.querySelector('.filters').setAttribute(
    'aria-label',
    text('Web.Filters')
  );

  element('path').value = configuration.path;
  element('logPath').textContent = format(
    'Web.LogPath',
    configuration.logDirectory
  );
}

/**
 * Reads the currently selected group, literal search text and incident
 * checkbox.
 *
 * @returns {import("./api.js").Filters} New filter object representing the
 * current DOM controls.
 */
export function readFilters() {
  return {
    group: element('group').value,
    search: element('search').value,
    incidents: element('incidents').checked
  };
}

/**
 * Determines whether a check belongs in the incident-only filter.
 *
 * @param {CheckResult} result - Result whose normalized Status is inspected.
 * @returns {boolean} True for Degraded, Offline or Error results.
 */
function isIncident(result) {
  return ['Degraded', 'Offline', 'Error'].includes(result.Status);
}

/**
 * Selects rows by group, case-insensitive literal search and incident flag
 * without mutating input.
 *
 * @param {CheckRow[]} checks - Configured check rows from the current status
 * snapshot.
 * @param {import("./api.js").Filters} filters - Filter criteria read from the
 * dashboard controls.
 * @returns {CheckRow[]} Matching row references in their original order.
 */
function filterChecks(checks, filters) {
  const matches = [];
  const search = filters.search.toLocaleLowerCase();

  for (const check of checks) {
    if (filters.group && check.Group !== filters.group) {
      continue;
    }

    if (!`${check.Name} ${check.Target}`.toLocaleLowerCase().includes(search)) {
      continue;
    }

    if (filters.incidents && !isIncident(check)) {
      continue;
    }

    matches.push(check);
  }

  return matches;
}

/**
 * Appends a text-only table cell and optionally assigns its presentation class.
 *
 * @param {HTMLTableRowElement} row - Parent row to mutate.
 * @param {string|number} value - Value assigned as cell text, never interpreted
 * as HTML.
 * @param {string} [className] - Optional CSS class names for the cell.
 * @returns {HTMLTableCellElement} Newly appended cell, available for further
 * child insertion.
 */
function appendCell(row, value, className) {
  const cell = document.createElement('td');

  cell.textContent = value;

  if (className) {
    cell.className = className;
  }

  row.append(cell);

  return cell;
}

/**
 * Updates sorted group options only when needed, preserving a still-valid selected group.
 *
 * @param {CheckRow[]} checks - Configured check rows from the current status snapshot.
 * @returns {void} No return value.
 */
function renderGroups(checks) {
  const uniqueGroups = new Set();

  for (const check of checks) {
    uniqueGroups.add(check.Group);
  }

  const groups = [...uniqueGroups].sort();
  const options = [new Option(text('Label.All'), '')];

  for (const group of groups) {
    options.push(new Option(group, group));
  }

  const select = element('group');
  let changed = select.options.length !== options.length;

  for (
    let index = 0;
    !changed && index < options.length;
    index++
  ) {
    changed = select.options[index].text !==
      options[index].text ||
      select.options[index].value !== options[index].value;
  }

  if (!changed) {
    return;
  }

  // Keep the dropdown stable during polling, including its selected filter.
  const previousGroup = select.value;

  select.replaceChildren(...options);

  if (uniqueGroups.has(previousGroup)) {
    select.value = previousGroup;
  } else {
    select.value = '';
  }
}

/**
 * Builds a resource row with protocol columns and a button for delegated
 * selection.
 *
 * @param {CheckRow} result - Resource identity, normalized result and protocol
 * diagnostic code.
 * @param {string|null} selectedName - Currently selected resource name, or
 * null.
 * @returns {HTMLTableRowElement} Detached row ready to append to the checks
 * table.
 */
function createCheckRow(result, selectedName) {
  const row = document.createElement('tr');

  if (result.Name === selectedName) {
    row.className = 'selected';
  }

  const button = document.createElement('button');

  button.textContent = result.Name;
  button.dataset.checkName = result.Name;
  button.setAttribute('aria-pressed', String(result.Name === selectedName));

  appendCell(row, '').append(button);
  appendCell(row, result.Type);
  appendCell(row, result.Target);
  appendCell(row, text(`Status.${result.Status}`), `status ${result.Status}`);

  let ping = '—';
  let service = '—';
  let http = '—';

  if (result.Status !== 'Unknown' && result.Status !== 'Disabled') {
    if (result.Type === 'Ping') {
      ping = `${result.DurationMs} ms`;
    } else if (result.Type === 'Tcp') {
      service = text(`Status.${result.Status}`);
    } else if (
      result.Type === 'Http' &&
      Number.isInteger(result.Details.Code)
    ) {
      http = result.Details.Code;
    }
  }

  appendCell(row, ping);
  appendCell(row, service);
  appendCell(row, http);
  appendCell(row, checkedTime(result));

  return row;
}

/**
 * Replaces filtered table rows while preserving focus on the same visible
 * resource button.
 *
 * @param {CheckRow[]} checks - Configured check rows from the current status
 * snapshot.
 * @param {string|null} selectedName - Resource name to mark selected, or null.
 * @returns {void} No return value.
 */
function renderChecks(checks, selectedName) {
  const focusedName = document.activeElement?.dataset.checkName;
  const fragment = document.createDocumentFragment();

  for (const check of filterChecks(checks, readFilters())) {
    fragment.append(createCheckRow(check, selectedName));
  }

  element('checks').replaceChildren(fragment);

  // Replacing rows must not lose a keyboard user's focused resource button.
  if (focusedName) {
    for (const button of element('checks').querySelectorAll('button')) {
      if (button.dataset.checkName === focusedName) {
        button.focus({ preventScroll: true });

        break;
      }
    }
  }
}

/**
 * Calculates the rounded success percentage from bounded session samples.
 *
 * @param {CheckResult[]} history - History entries whose Success flags include
 * successful degraded checks.
 * @returns {string} Whole-number percentage, or an em dash when no history
 * exists.
 */
function successRate(history) {
  if (history.length === 0) {
    return '—';
  }

  let successful = 0;
  for (const result of history) {
    if (result.Success) {
      successful++;
    }
  }
  return `${Math.round(successful / history.length * 100)}%`;
}

/**
 * Rebuilds details and history for the selected resource, or shows the selection prompt.
 *
 * @param {CheckRow[]} checks - Configured check rows from the current status snapshot.
 * @param {Selection} selection - Selected check name and its current session history.
 * @returns {void} No return value.
 */
export function renderDetails(checks, selection) {
  let selected;
  for (const check of checks) {
    if (check.Name === selection.name) {
      selected = check;

      break;
    }
  }

  element('history').replaceChildren();
  if (!selected) {
    element('details').textContent = text('Label.Select');

    return;
  }

  let note = '';
  if (selected.Type === 'Ping') {
    note = text('Label.PingNote');
  }

  element('details').textContent = format(
    'Label.Details',
    selected.Target,
    selected.Type,
    checkedTime(selected),
    selected.DurationMs,
    text(`Status.${selected.Status}`),
    resultMessage(selected),
    successRate(selection.history),
    note
  );

  const fragment = document.createDocumentFragment();
  for (const result of selection.history) {
    const row = document.createElement('tr');
    appendCell(row, timestamp(result.Timestamp));
    appendCell(row, text(`Status.${result.Status}`));
    appendCell(row, result.DurationMs);
    appendCell(row, resultMessage(result));
    fragment.append(row);
  }

  element('history').append(fragment);
}

/**
 * Displays total, online, degraded and offline/error counts across all configured checks.
 *
 * @param {CheckRow[]} checks - Configured check rows from the current status snapshot.
 * @returns {void} No return value.
 */
function renderSummary(checks) {
  let online = 0;
  let degraded = 0;
  let incidents = 0;

  for (const check of checks) {
    if (check.Status === 'Online') {
      online++;
    } else if (check.Status === 'Degraded') {
      degraded++;
    } else if (check.Status === 'Offline' || check.Status === 'Error') {
      incidents++;
    }
  }

  element('summary').textContent = format(
    'Label.Summary',
    checks.length,
    online,
    degraded,
    incidents
  );
}

/**
 * Displays scheduling activity and synchronizes pause/refresh control states.
 *
 * @param {MonitorStatus} state - Snapshot containing pending, running, paused
 * and nextRun scheduling values.
 * @param {boolean} actionPending - Whether a user action is in progress and
 * controls must be disabled.
 * @returns {void} No return value.
 */
function renderActivity(state, actionPending) {
  let activity;
  if (state.pending) {
    activity = text('Web.ConfigurationPending');
  } else if (state.running) {
    activity = text('Label.Running');
  } else if (state.paused) {
    activity = text('Label.Paused');
  } else {
    activity = format('Label.Ready', timestamp(state.nextRun));
  }

  element('activity').textContent = activity;
  element('pause').checked = state.paused;
  element('pause').disabled = actionPending || state.pending;
  element('refresh').disabled = actionPending || state.running || state.pending;
}

/**
 * Replaces the session journal with localized plain-text entries in backend
 * order.
 *
 * @param {CheckResult[]} journal - Bounded result list from the current monitor
 * snapshot.
 * @returns {void} No return value.
 */
function renderJournal(journal) {
  const lines = [];
  for (const result of journal) {
    lines.push(`${timestamp(result.Timestamp)}  ${result.Name}  ${text(`Status.${result.Status}`)}  ${resultMessage(result)}`);
  }

  element('journal').textContent = lines.join('\n');
}

/**
 * Renders the full dashboard and prioritizes action errors over configuration
 * and logging errors.
 *
 * @param {MonitorStatus} state - Current backend snapshot; renderGroups runs
 * before filters are read.
 * @param {Selection} selection - Selected check name and its current session
 * history.
 * @param {boolean} actionPending - Whether a user action is still being
 * handled.
 * @param {string} actionError - Latest action error key or fallback message;
 * empty when no action error exists.
 * @returns {void} No return value.
 */
export function renderDashboard(state, selection, actionPending, actionError) {
  renderGroups(state.checks);
  renderChecks(state.checks, selection.name);
  renderSummary(state.checks);
  renderActivity(state, actionPending);
  renderJournal(state.journal);
  renderDetails(state.checks, selection);

  if (actionError) {
    showError(actionError);
  } else if (state.configurationFailed) {
    showError('Error.Configuration');
  } else if (state.loggingFailed) {
    showError('Error.Logging');
  } else {
    showError('');
  }
}
