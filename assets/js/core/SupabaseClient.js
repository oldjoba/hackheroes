/*
  Project: Hack Heroes
  File: SupabaseClient.js
  Description: Boots the Supabase client for the classroom layer.
  License: GNU AGPLv3
  -----------------------------------------------------------
  Loads config/supabase.json and creates a single shared client.

  Exposes:
    window.xaSupabaseReady  - Promise that resolves to the client (or null
                              if Supabase is not configured).
    window.xaSupabase       - the client, once ready (may be null).
    window.xaSupabaseConfigured() -> boolean

  Must be loaded AFTER the supabase-js UMD bundle, e.g.:
    <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
    <script src="assets/js/core/SupabaseClient.js"></script>

  The anon key is public by design; security is enforced server-side by RLS.
*/

window.xaSupabase = null;

window.xaSupabaseReady = (async function () {
  try {
    const cfg = await fetch('config/supabase.json').then((r) => r.json());

    const url = cfg && cfg.url;
    const anonKey = cfg && cfg.anonKey;

    const looksPlaceholder =
      !url ||
      !anonKey ||
      url.includes('YOUR_PROJECT_REF') ||
      anonKey.includes('YOUR_SUPABASE_ANON');

    if (looksPlaceholder) {
      console.warn(
        '[HackHeroes] Supabase is not configured. ' +
          'Classroom features (teacher dashboard, class join, live leaderboard) are disabled. ' +
          'Fill in config/supabase.json to enable them.'
      );
      window.xaSupabase = null;
      return null;
    }

    if (!window.supabase || typeof window.supabase.createClient !== 'function') {
      console.error(
        '[HackHeroes] supabase-js was not loaded. Add the CDN script before SupabaseClient.js.'
      );
      window.xaSupabase = null;
      return null;
    }

    const client = window.supabase.createClient(url, anonKey, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        // separate storage key avoids clashing with the game's 'state' key
        storageKey: 'hh_sb_auth'
      }
    });

    window.xaSupabase = client;
    return client;
  } catch (err) {
    console.error('[HackHeroes] Failed to initialise Supabase client:', err);
    window.xaSupabase = null;
    return null;
  }
})();

/**
 * Quick synchronous check for whether the client is ready and configured.
 * @returns {boolean}
 */
window.xaSupabaseConfigured = function () {
  return !!window.xaSupabase;
};
