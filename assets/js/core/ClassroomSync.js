/*
  Project: Hack Heroes
  File: ClassroomSync.js
  Description: Classroom layer for Hack Heroes. Adds teacher accounts,
               classes, challenge assignments, student join-by-code, and
               live progress sync to Supabase.
  License: GNU AGPLv3
  -----------------------------------------------------------
  Requires (loaded BEFORE this file):
    - https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2
    - assets/js/core/SupabaseClient.js   (window.xaSupabaseReady)
    - assets/js/core/functions.js        (xaCompareAnswer)
    - assets/js/core/StorageHandler.js   (class StorageHandler)

  Exposes:
    - window.ClassroomSync          (the API object)
    - window.SyncingStorageHandler  (StorageHandler subclass that mirrors
                                     progress to Supabase when in a class)

  Design notes:
    - localStorage stays the offline source of truth for challenge state.
      Supabase is a mirror used for cross-device tracking + leaderboards.
    - Students authenticate anonymously (no PII, no password).
    - All access control is enforced server-side by Postgres RLS.
*/

(function () {
  'use strict';

  const SESSION_KEY = 'hh_class_session'; // { studentId, classId, className, nickname }

  // --- small helpers --------------------------------------------------

  async function client() {
    // Resolves the shared client (or null if Supabase isn't configured).
    return await window.xaSupabaseReady;
  }

  function readSession() {
    try {
      return JSON.parse(localStorage.getItem(SESSION_KEY)) || null;
    } catch (e) {
      return null;
    }
  }

  function writeSession(session) {
    localStorage.setItem(SESSION_KEY, JSON.stringify(session));
  }

  // Word lists for friendly join codes, e.g. "BRAVE-FOX-42".
  const CODE_ADJECTIVES = [
    'BRAVE', 'CYBER', 'NINJA', 'SECRET', 'SUPER', 'MIGHTY', 'SWIFT',
    'CLEVER', 'BOLD', 'SHARP', 'LUCKY', 'COSMIC', 'TURBO', 'EPIC'
  ];
  const CODE_NOUNS = [
    'FOX', 'HAWK', 'WOLF', 'OWL', 'BYTE', 'CODE', 'TIGER', 'EAGLE',
    'PANDA', 'ROBOT', 'COMET', 'PIXEL', 'LASER', 'PHANTOM'
  ];

  // --- the API --------------------------------------------------------

  const ClassroomSync = {
    SESSION_KEY,

    // ============================================================
    // Session (student "in class" state)
    // ============================================================

    /** @returns {object|null} the active class session, or null. */
    getSession() {
      return readSession();
    },

    /** @returns {boolean} true if a class session is active. */
    isInClass() {
      return !!readSession();
    },

    /** Clears the local class session (leave class). Does not delete data. */
    clearSession() {
      localStorage.removeItem(SESSION_KEY);
    },

    /** Generates a friendly join code like "BRAVE-FOX-42". */
    generateJoinCode() {
      const a = CODE_ADJECTIVES[Math.floor(Math.random() * CODE_ADJECTIVES.length)];
      const n = CODE_NOUNS[Math.floor(Math.random() * CODE_NOUNS.length)];
      const num = Math.floor(10 + Math.random() * 90); // 10-99
      return `${a}-${n}-${num}`;
    },

    // ============================================================
    // Student flow
    // ============================================================

    /** Ensures the student has an anonymous Supabase identity. */
    async ensureAnonAuth() {
      const sb = await client();
      if (!sb) throw new Error('Classroom features are not configured.');
      const { data } = await sb.auth.getSession();
      if (data && data.session) return data.session;
      const { data: anon, error } = await sb.auth.signInAnonymously();
      if (error) throw error;
      return anon.session;
    },

    /**
     * Joins a class by code, creating/updating the student record.
     * Stores the session locally and returns it.
     * @param {string} code
     * @param {string} nickname
     */
    async joinClass(code, nickname) {
      const sb = await client();
      if (!sb) throw new Error('Classroom features are not configured.');
      await this.ensureAnonAuth();

      const { data, error } = await sb.rpc('join_class', {
        p_code: code,
        p_nickname: nickname
      });
      if (error) throw error;
      // RPC returns a single-row table.
      const row = Array.isArray(data) ? data[0] : data;
      if (!row) throw new Error('Could not join the class. Check the code and try again.');

      // IMPORTANT (shared/classroom devices): challenge progress is stored in a
      // single localStorage key shared by everyone on this device. If a DIFFERENT
      // student now joins (or the same student joins a different class), wipe that
      // local state so they don't inherit the previous player's cached answers —
      // which would make challenges look already-solved ("win without playing")
      // and the game behave oddly.
      try {
        const prev = readSession();
        const sameStudentSameClass =
          prev && prev.studentId === row.student_id && prev.classId === row.class_id;
        if (!sameStudentSameClass) {
          localStorage.removeItem('state'); // StorageHandler's key
        }
      } catch (e) { /* localStorage may be unavailable; non-fatal */ }

      const session = {
        studentId: row.student_id,
        classId: row.class_id,
        className: row.class_name,
        nickname: nickname.trim().slice(0, 24)
      };
      writeSession(session);
      return session;
    },

    /**
     * Returns the challenge ids assigned to a class (ordered).
     * @param {string} classId
     * @returns {Promise<string[]>}
     */
    async getAssignments(classId) {
      const sb = await client();
      if (!sb) return [];
      const { data, error } = await sb
        .from('assignments')
        .select('challenge_id, sort_order')
        .eq('class_id', classId)
        .order('sort_order', { ascending: true });
      if (error) {
        console.warn('[HackHeroes] getAssignments failed:', error.message);
        return [];
      }
      return (data || []).map((r) => r.challenge_id);
    },

    /**
     * Returns the set of challenge ids the CURRENT student has completed in a
     * class, as a Set<string>. Used to drive the one-at-a-time class flow.
     */
    async getMyCompleted(classId) {
      const sb = await client();
      const done = new Set();
      if (!sb) return done;
      const session = this.getSession();
      if (!session || !session.studentId) return done;
      const { data, error } = await sb
        .from('progress')
        .select('challenge_id, completed')
        .eq('class_id', classId)
        .eq('student_id', session.studentId);
      if (error) {
        console.warn('[HackHeroes] getMyCompleted failed:', error.message);
        return done;
      }
      (data || []).forEach((r) => { if (r.completed) done.add(r.challenge_id); });
      return done;
    },

    /**
     * Given the current challenge id, work out the class "sequence" position
     * and the next UNFINISHED assigned challenge.
     * Returns { inClass, total, position, doneCount, nextId, allDone }.
     */
    async getClassFlow(currentChallengeId) {
      const out = { inClass:false, total:0, position:0, doneCount:0, nextId:null, allDone:false };
      if (!this.isInClass()) return out;
      const session = this.getSession();
      const assigned = await this.getAssignments(session.classId);
      if (!assigned.length) return out;
      const done = await this.getMyCompleted(session.classId);
      out.inClass = true;
      out.total = assigned.length;
      out.doneCount = done.size;
      // 1-based position of the current challenge in the assigned order (if present)
      const idx = assigned.indexOf(currentChallengeId);
      out.position = idx >= 0 ? idx + 1 : 0;
      // Next unfinished challenge: prefer the first unfinished AFTER the current
      // one, else the first unfinished anywhere.
      const after = assigned.slice(idx + 1).find((id) => !done.has(id));
      const anyUnfinished = assigned.find((id) => !done.has(id) && id !== currentChallengeId);
      out.nextId = after || anyUnfinished || null;
      out.allDone = assigned.every((id) => done.has(id));
      return out;
    },

    // ============================================================
    // Engine hook: push progress to Supabase (debounced)
    // ============================================================

    _pushTimers: {}, // challengeId -> timeout handle

    /**
     * Mirrors a student's progress for one challenge to Supabase.
     * Completion is computed by reusing xaCompareAnswer with the full
     * challenge object. Debounced per-challenge to coalesce keystrokes.
     *
     * @param {object} challenge - full challenge JSON (has id + answers)
     * @param {{hintsUsed:number, answer:string}} state
     */
    pushProgress(challenge, state) {
      const session = readSession();
      if (!session || !challenge || !challenge.id) return;

      const id = challenge.id;
      clearTimeout(this._pushTimers[id]);
      this._pushTimers[id] = setTimeout(() => {
        this._pushProgressNow(challenge, state, session).catch((e) =>
          console.warn('[HackHeroes] progress sync failed:', e.message || e)
        );
      }, 400);
    },

    async _pushProgressNow(challenge, state, session) {
      const sb = await client();
      if (!sb) return;

      let completed = false;
      const answer = (state && state.answer) || '';
      if (answer) {
        try {
          completed = await xaCompareAnswer(challenge, answer);
        } catch (e) {
          completed = false;
        }
      }

      const now = new Date().toISOString();
      const row = {
        student_id: session.studentId,
        class_id: session.classId,
        challenge_id: challenge.id,
        hints_used: (state && state.hintsUsed) || 0,
        completed: completed,
        completed_at: completed ? now : null,
        updated_at: now
      };

      const { error } = await sb
        .from('progress')
        .upsert(row, { onConflict: 'student_id,challenge_id' });
      if (error) throw error;
    },

    // ============================================================
    // Teacher flow
    // ============================================================

    /** Returns the current teacher's auth user, or null. */
    async currentTeacher() {
      const sb = await client();
      if (!sb) return null;
      const { data } = await sb.auth.getUser();
      const user = data && data.user;
      // Anonymous students also have a user; teachers have an email.
      if (user && user.email) return user;
      return null;
    },

    async teacherSignUp(email, password, displayName) {
      const sb = await client();
      if (!sb) throw new Error('Classroom features are not configured.');
      const { data, error } = await sb.auth.signUp({ email, password });
      if (error) throw error;
      // Ensure a teachers row exists (id = auth user id).
      if (data && data.user) {
        await sb.from('teachers').upsert(
          { id: data.user.id, display_name: displayName || email },
          { onConflict: 'id' }
        );
      }
      return data;
    },

    async teacherSignIn(email, password) {
      const sb = await client();
      if (!sb) throw new Error('Classroom features are not configured.');
      const { data, error } = await sb.auth.signInWithPassword({ email, password });
      if (error) throw error;
      // Make sure the teachers row exists (handles accounts created before
      // the row was inserted, e.g. via email confirmation flows).
      if (data && data.user) {
        await sb.from('teachers').upsert(
          { id: data.user.id, display_name: data.user.email },
          { onConflict: 'id', ignoreDuplicates: true }
        );
      }
      return data;
    },

    async teacherSignOut() {
      const sb = await client();
      if (!sb) return;
      await sb.auth.signOut();
    },

    /**
     * Creates a class with a unique join code.
     * @param {string} name
     */
    async createClass(name, prize) {
      const sb = await client();
      if (!sb) throw new Error('Classroom features are not configured.');
      const teacher = await this.currentTeacher();
      if (!teacher) throw new Error('Please sign in first.');

      const prizeVal = (prize && prize.trim()) ? prize.trim() : null;

      // Try a few codes in case of a rare collision on the unique index.
      let lastError = null;
      for (let attempt = 0; attempt < 5; attempt++) {
        const code = this.generateJoinCode();
        const { data, error } = await sb
          .from('classes')
          .insert({ teacher_id: teacher.id, name: name.trim(), join_code: code, prize: prizeVal })
          .select()
          .single();
        if (!error) return data;
        lastError = error;
        // 23505 = unique_violation -> retry with a new code
        if (error.code !== '23505') break;
      }
      throw lastError || new Error('Could not create class.');
    },

    /** Sets (or clears) the winner prize for a class the teacher owns. */
    async setPrize(classId, prize) {
      const sb = await client();
      if (!sb) throw new Error('Classroom features are not configured.');
      const prizeVal = (prize && prize.trim()) ? prize.trim() : null;
      const { error } = await sb
        .from('classes')
        .update({ prize: prizeVal })
        .eq('id', classId);
      if (error) throw error;
      return prizeVal;
    },

    /** Lists the signed-in teacher's classes (newest first). */
    async listClasses() {
      const sb = await client();
      if (!sb) return [];
      const { data, error } = await sb
        .from('classes')
        .select('*')
        .order('created_at', { ascending: false });
      if (error) {
        console.warn('[HackHeroes] listClasses failed:', error.message);
        return [];
      }
      return data || [];
    },

    /**
     * Replaces the set of assigned challenges for a class.
     * @param {string} classId
     * @param {string[]} challengeIds - ordered list of challenge ids
     */
    async setAssignments(classId, challengeIds) {
      const sb = await client();
      if (!sb) throw new Error('Classroom features are not configured.');

      // Simple + safe: clear existing, then insert the new set.
      const del = await sb.from('assignments').delete().eq('class_id', classId);
      if (del.error) throw del.error;

      if (!challengeIds || challengeIds.length === 0) return [];

      const rows = challengeIds.map((cid, i) => ({
        class_id: classId,
        challenge_id: cid,
        sort_order: i
      }));
      const { data, error } = await sb.from('assignments').insert(rows).select();
      if (error) throw error;
      return data;
    },

    /** Lists assigned challenge ids for a class (teacher view). */
    async listAssignmentIds(classId) {
      return this.getAssignments(classId);
    }
  };

  window.ClassroomSync = ClassroomSync;

  // ============================================================
  // SyncingStorageHandler
  // A drop-in StorageHandler that also mirrors writes to Supabase
  // when a class session is active. StorageHandler.js is untouched.
  // ============================================================

  if (typeof StorageHandler === 'function') {
    class SyncingStorageHandler extends StorageHandler {
      /**
       * @param {object} challenge - the full challenge JSON object
       *        (must include id + answers so completion can be computed).
       */
      constructor(challenge) {
        super(challenge.id);
        this._challenge = challenge;
      }

      _sync() {
        if (!ClassroomSync.isInClass()) return;
        const data = this.getChallengeData();
        ClassroomSync.pushProgress(this._challenge, {
          hintsUsed: (data.hintsRead || []).length,
          answer: data.answer || ''
        });
      }

      setAnswer(answer) {
        super.setAnswer(answer);
        this._sync();
      }

      setHintsRead(hintsArray) {
        super.setHintsRead(hintsArray);
        this._sync();
      }

      addHintRead(hintNumber) {
        super.addHintRead(hintNumber);
        this._sync();
      }
    }

    window.SyncingStorageHandler = SyncingStorageHandler;
  } else {
    console.warn(
      '[HackHeroes] StorageHandler not found; SyncingStorageHandler not created. ' +
        'Load StorageHandler.js before ClassroomSync.js.'
    );
  }
})();
