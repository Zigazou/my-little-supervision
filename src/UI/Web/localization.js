/** Localized presentation text; English resource fallback is supplied by the
 * backend. */

/**
 * Active resource dictionary, including English fallback values merged by the
 * backend. Empty until setTranslations receives the first configuration.
 * @type {Object<string, string>}
 */
let strings = {};

/**
 * Locale used for date formatting; starts with the HTML language and follows
 * configuration.
 * @type {string}
 */
let language = document.documentElement.lang;

/**
 * Replaces module translations and date locale, and updates the document
 * language.
 *
 * @param {import("./api.js").MonitorConfiguration} configuration - Backend
 * configuration containing merged resources and the selected language.
 * @returns {void} No return value.
 */
export function setTranslations(configuration) {
  strings = configuration.strings;
  language = configuration.language;
  document.documentElement.lang = language;
}

/**
 * Looks up a translated resource, retaining its key when the value is missing
 * or empty.
 *
 * @param {string} key - Stable resource identifier, such as Status.Online.
 * @returns {string} Translated text or the original resource key.
 */
export function text(key) {
  if (strings[key]) {
    return strings[key];
  }

  return key;
}

/**
 * Replaces numbered placeholders in a resource string; the result remains plain
 * text.
 *
 * @param {string} key - Resource identifier whose text may contain {0}, {1},
 * and similar placeholders.
 * @param {...*} values - Replacement values in placeholder order; null,
 * undefined and missing values become empty text.
 * @returns {string} Translated string with placeholder values converted to
 * text.
 */
export function format(key, ...values) {
  return text(key).replace(
    /\{(\d+)\}/g,
    /**
     * Resolves one placeholder using the enclosing format call values.
     *
     * @param {string} match - Complete placeholder match; unused because index
     * selects the value.
     * @param {string} index - Captured decimal placeholder index.
     * @returns {*} Supplied value for string conversion, or empty text when
     * absent.
     */
    function replacePlaceholder(match, index) {
      const value = values[Number(index)];

      if (value === null || value === undefined) {
        return '';
      }

      return value;
    }
  );
}

/**
 * Formats a backend timestamp using the selected UI locale and the browser time
 * zone.
 *
 * @param {string|number|Date} value - ISO timestamp, milliseconds since the
 * Unix epoch, or Date accepted by the Date constructor.
 * @returns {string} Localized date and time, or the browser representation of
 * an invalid date.
 */
export function timestamp(value) {
  return new Date(value).toLocaleString(language);
}

/**
 * Formats a normalized check message using its safe diagnostic code.
 *
 * @param {import("./api.js").CheckResult} result - Check result containing the
 * Message resource suffix and Details.Code.
 * @returns {string} Localized plain-text message.
 */
export function resultMessage(result) {
  return format(`Message.${result.Message}`, result.Details.Code);
}

/**
 * Formats the last-check time while hiding synthetic timestamps for unchecked
 * or disabled checks.
 *
 * @param {import("./api.js").CheckResult} result - Check result containing
 * Status and Timestamp.
 * @returns {string} Localized timestamp, or an em dash for Unknown and Disabled
 * results.
 */
export function checkedTime(result) {
  if (result.Status === 'Unknown' || result.Status === 'Disabled') {
    return '—';
  }

  return timestamp(result.Timestamp);
}
