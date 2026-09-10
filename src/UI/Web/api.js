/** JSON transport only; the caller owns configuration and the session token. */

/**
 * Normalized backend result. Status rows omit Success; history and journal
 * entries include it.
 * @typedef {Object} CheckResult
 * @property {string} Name - Unique configured resource name.
 * @property {string} Type - Probe type: Ping, Tcp or Http.
 * @property {string} Target - Display hostname, address or URL.
 * @property {string} Status - Normalized Unknown, Running, Online, Degraded,
 * Offline, Error or Disabled status.
 * @property {boolean} [Success] - Whether a completed history/journal result
 * succeeded.
 * @property {string} Message - Resource suffix resolved under Message.*.
 * @property {number} DurationMs - Total probe duration in milliseconds.
 * @property {string} Timestamp - UTC timestamp serialized by the backend.
 * @property {{Code: (string|number|null)}} Details - Safe diagnostic code, HTTP
 * status or null.
 */

/**
 * Presentation row returned by the status endpoint.
 * @typedef {CheckResult & {Group: string}} CheckRow
 */

/**
 * @typedef {Object} Filters
 * @property {string} group - Exact group name; empty selects every group.
 * @property {string} search - Literal case-insensitive search over names and
 * targets.
 * @property {boolean} incidents - Whether to include only degraded, offline and
 * error checks.
 */

/**
 * @typedef {Object} MonitorConfiguration
 * @property {string} path - Absolute active PSD1 path on the backend machine.
 * @property {string} language - Selected UI locale, such as en-US or fr-FR.
 * @property {Object<string, string>} strings - Merged localization resources
 * with English fallback.
 * @property {string} token - In-memory session CSRF token for JSON mutations;
 * never log it.
 * @property {number} revision - Configuration revision used to detect
 * replacement.
 * @property {string} logDirectory - Per-user log directory displayed in the
 * browser.
 */

/**
 * @typedef {Object} MonitorStatus
 * @property {boolean} paused - Whether automatic cycles are paused.
 * @property {boolean} running - Whether a monitoring cycle is in progress.
 * @property {boolean} pending - Whether configuration replacement is waiting
 * for active checks.
 * @property {string} nextRun - UTC timestamp of the next scheduled cycle.
 * @property {CheckRow[]} checks - Current rows in configuration order.
 * @property {number} revision - Active configuration revision.
 * @property {boolean} configurationFailed - Whether startup configuration
 * failed to load.
 * @property {boolean} loggingFailed - Whether a log write has failed during
 * this session.
 * @property {CheckResult[]} journal - Newest-first session journal, capped at
 * 300 entries.
 */

/**
 * @typedef {Object} Selection
 * @property {string|null} name - Selected resource name, or null when nothing
 * is selected.
 * @property {CheckResult[]} history - Newest-first history for that resource,
 * capped at 200 entries.
 */

/**
 * Requests JSON from the local backend, using GET by default or POST when data
 * is supplied.
 *
 * @param {string} path - Same-origin API path, including any encoded query
 * parameters.
 * @param {Object} [data] - JSON action payload; omit for a GET request.
 * @param {string} [token] - Session CSRF token, required when sending a POST
 * payload.
 * @returns {Promise<Object>} Decoded JSON response; the object shape depends on
 * the requested endpoint.
 * @throws {Error} Rejects on HTTP failure with a localization key, or
 * propagates fetch/JSON decoding errors.
 */
export async function request(path, data, token) {
  const options = { cache: 'no-store' };

  if (data !== undefined) {
    options.method = 'POST';
    options.headers = {
      'Content-Type': 'application/json',
      'X-CSRF-Token': token
    };
    options.body = JSON.stringify(data);
  }

  const response = await fetch(path, options);
  if (!response.ok) {
    let key = 'Error.Action';
    try {
      const failure = await response.json();
      if (failure.error) {
        key = failure.error;
      }
    } catch {
      console.log(
        'Non-JSON failures still reach the caller through the fallback error.'
      );
    }
    throw new Error(key);
  }

  return response.json();
}

/**
 * Builds the same-origin CSV download URL from the current filters.
 *
 * @param {Filters} filters - Group, literal search text and incident-only flag
 * to encode.
 * @returns {string} Relative export URL with URL-encoded query parameters.
 */
export function exportUrl(filters) {
  const query = new URLSearchParams({
    group: filters.group,
    search: filters.search,
    incidents: String(filters.incidents)
  });

  return `/api/export?${query}`;
}
