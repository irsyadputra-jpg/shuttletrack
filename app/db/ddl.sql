-- ShuttleTrack: Complete DDL (PostgreSQL)
-- Recommended PG version: 12+
-- Run as a superuser once to create extensions

-- === 0. Extensions ===
CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- gen_random_uuid()
-- If pgcrypto not allowed, use: CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- === 1. Schema ===
CREATE SCHEMA IF NOT EXISTS tracker AUTHORIZATION CURRENT_USER;
SET search_path = tracker, public;

-- === 2. ENUM TYPES ===
CREATE TYPE tracker.session_type AS ENUM ('badminton','pt','hiit','recovery','other');
CREATE TYPE tracker.drill_category AS ENUM (
  'footwork',
  'defense',
  'attack',
  'drive_rally',
  'net_front',
  'multi_shuttle',
  'tactical',
  'conditioning',
  'other'
);
CREATE TYPE tracker.exercise_category AS ENUM (
  'technical','strength','plyometric','agility','core','conditioning','mobility','other'
);
CREATE TYPE tracker.metric_period AS ENUM ('daily','weekly','monthly');

-- === 3. Utility trigger function: updated_at timestamp ===
CREATE OR REPLACE FUNCTION tracker.trigger_set_timestamp()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- === 4. Users ===
CREATE TABLE tracker.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL UNIQUE,
  display_name text,
  password_hash text,       -- optional if using server-side auth; can be NULL if using external auth
  height_cm integer,
  birth_date date,
  gender text,
  target_weight_kg numeric(6,2),
  target_body_fat_pct numeric(5,2),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER users_set_timestamp
BEFORE UPDATE ON tracker.users
FOR EACH ROW EXECUTE PROCEDURE tracker.trigger_set_timestamp();

-- === 5. Drills (master list created by user) ===
CREATE TABLE tracker.drills (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES tracker.users(id) ON DELETE CASCADE,
  category tracker.drill_category NOT NULL,
  name text NOT NULL,
  focus text,                     -- short description of objective
  variants jsonb DEFAULT '[]'::jsonb,  -- array of variant names
  purpose text,                   -- intent/goal
  duration_min integer,           -- suggested duration in minutes
  intensity smallint CHECK (intensity BETWEEN 1 AND 5),
  is_favorite boolean DEFAULT false,
  archived boolean DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, category, name)
);

CREATE INDEX idx_drills_user_category ON tracker.drills (user_id, category);
CREATE TRIGGER drills_set_timestamp
BEFORE UPDATE ON tracker.drills
FOR EACH ROW EXECUTE PROCEDURE tracker.trigger_set_timestamp();

-- === 6. Training Sessions (per-session logs) ===
CREATE TABLE tracker.training_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES tracker.users(id) ON DELETE CASCADE,
  session_date date NOT NULL,                -- calendar date of session
  start_ts timestamptz,                      -- optional precise start
  end_ts timestamptz,                        -- optional precise end
  session_type tracker.session_type NOT NULL DEFAULT 'badminton',
  duration_minutes integer,                  -- total duration (if provided)
  intensity smallint CHECK (intensity BETWEEN 1 AND 10),
  energy_level smallint CHECK (energy_level BETWEEN 1 AND 5),
  sleep_hours numeric(4,2),
  mood smallint CHECK (mood BETWEEN 1 AND 5),
  notes text,
  exercises jsonb DEFAULT '[]'::jsonb,       -- fallback free-form list
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_sessions_user_date ON tracker.training_sessions (user_id, session_date DESC);
CREATE INDEX idx_sessions_date ON tracker.training_sessions (session_date);
CREATE TRIGGER training_sessions_set_timestamp
BEFORE UPDATE ON tracker.training_sessions
FOR EACH ROW EXECUTE PROCEDURE tracker.trigger_set_timestamp();

-- === 7. Session Exercises (normalized details per session) ===
CREATE TABLE tracker.session_exercises (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES tracker.training_sessions(id) ON DELETE CASCADE,
  drill_id uuid REFERENCES tracker.drills(id) ON DELETE SET NULL,  -- optional link to a master drill
  seq smallint NOT NULL,                     -- order in session
  category tracker.exercise_category NOT NULL,
  name text NOT NULL,                        -- e.g. 'Box Jump', 'Shadow Footwork 4-way'
  reps integer,
  sets integer,
  load_kg numeric(6,2),
  duration_sec integer,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_exercises_session ON tracker.session_exercises (session_id);
CREATE INDEX idx_exercises_drill ON tracker.session_exercises (drill_id);
CREATE INDEX idx_exercises_category ON tracker.session_exercises (category);

-- === 8. Drill Sessions (instances when a master drill is performed) ===
-- (Optional; links a master drill with session and stores variant-specific metrics)
CREATE TABLE tracker.drill_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES tracker.training_sessions(id) ON DELETE CASCADE,
  drill_id uuid NOT NULL REFERENCES tracker.drills(id) ON DELETE CASCADE,
  variant text,                  -- which variant was performed
  duration_min integer,
  intensity smallint CHECK (intensity BETWEEN 1 AND 5),
  repetitions integer,
  performance_score numeric(5,2), -- optional user/PT evaluation (0-100)
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_drill_sessions_user ON tracker.drill_sessions (drill_id);
CREATE INDEX idx_drill_sessions_session ON tracker.drill_sessions (session_id);

-- === 9. Weekly Metrics ===
CREATE TABLE tracker.weekly_metrics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES tracker.users(id) ON DELETE CASCADE,
  week_start date NOT NULL,                  -- ISO week start (Monday)
  period tracker.metric_period NOT NULL DEFAULT 'weekly',
  weight_kg numeric(6,2),
  body_fat_pct numeric(5,2),
  lean_mass_kg numeric(6,2),
  vertical_jump_cm numeric(6,2),
  shuttle_run_4x10_sec numeric(6,2),
  plank_seconds integer,
  reaction_time_sec numeric(6,4),
  vo2_estimate numeric(6,2),
  rally_endurance_min numeric(6,2),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, week_start)
);

CREATE INDEX idx_weekly_user_week ON tracker.weekly_metrics (user_id, week_start DESC);
CREATE TRIGGER weekly_metrics_set_timestamp
BEFORE UPDATE ON tracker.weekly_metrics
FOR EACH ROW EXECUTE PROCEDURE tracker.trigger_set_timestamp();

-- === 10. Wearable Samples (aggregated) ===
CREATE TABLE tracker.wearable_samples (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES tracker.users(id) ON DELETE CASCADE,
  recorded_at timestamptz NOT NULL,
  sample_type text NOT NULL,                 -- e.g. 'heart_rate','steps','sleep','hrv'
  value jsonb NOT NULL,                      -- flexible payload e.g. {"avg":72,"max":120}
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_wearable_user_time ON tracker.wearable_samples (user_id, recorded_at DESC);
CREATE INDEX idx_wearable_type ON tracker.wearable_samples (sample_type);

-- === 11. Nutrition Logs ===
CREATE TABLE tracker.nutrition_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES tracker.users(id) ON DELETE CASCADE,
  log_date date NOT NULL,
  calories integer,
  protein_g numeric(7,2),
  carbs_g numeric(7,2),
  fat_g numeric(7,2),
  mealblend boolean DEFAULT FALSE,
  calorloss boolean DEFAULT FALSE,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, log_date)
);

CREATE INDEX idx_nutrition_user_date ON tracker.nutrition_logs (user_id, log_date DESC);

-- === 12. Hydration Logs ===
CREATE TABLE tracker.hydration_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES tracker.users(id) ON DELETE CASCADE,
  log_date date NOT NULL,
  liters numeric(5,2) DEFAULT 0,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, log_date)
);

CREATE INDEX idx_hydration_user_date ON tracker.hydration_logs (user_id, log_date DESC);

-- === 13. Achievements (badges) ===
CREATE TABLE tracker.achievements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES tracker.users(id) ON DELETE CASCADE,
  badge_key text NOT NULL,                   -- internal id, e.g. 'streak_10'
  title text NOT NULL,
  description text,
  date_earned timestamptz NOT NULL DEFAULT now(),
  metadata jsonb DEFAULT '{}'::jsonb,
  UNIQUE (user_id, badge_key)
);

CREATE INDEX idx_achievements_user ON tracker.achievements (user_id, date_earned DESC);

-- === 14. Streaks ===
CREATE TABLE tracker.streaks (
  user_id uuid PRIMARY KEY REFERENCES tracker.users(id) ON DELETE CASCADE,
  current_streak integer NOT NULL DEFAULT 0,
  longest_streak integer NOT NULL DEFAULT 0,
  last_active_date date
);

-- === 15. Reminders ===
CREATE TABLE tracker.reminders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES tracker.users(id) ON DELETE CASCADE,
  title text NOT NULL,
  description text,
  remind_at timestamptz NOT NULL,
  repeat_rule text,   -- RFC5545 rrule string OR simple ('daily','weekly') etc.
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_reminders_user_time ON tracker.reminders (user_id, remind_at);
CREATE TRIGGER reminders_set_timestamp
BEFORE UPDATE ON tracker.reminders
FOR EACH ROW EXECUTE PROCEDURE tracker.trigger_set_timestamp();

-- === 16. Audit Log (lightweight) ===
CREATE TABLE tracker.audit_log (
  id bigserial PRIMARY KEY,
  table_name text NOT NULL,
  record_id uuid,
  action text NOT NULL,   -- INSERT/UPDATE/DELETE
  changed_by uuid,        -- user id (nullable for system)
  changed_at timestamptz NOT NULL DEFAULT now(),
  payload jsonb
);

CREATE INDEX idx_audit_table ON tracker.audit_log (table_name, changed_at DESC);

-- === 17. Materialized Views / Convenience Views ===
-- Materialized: weekly summary for fast dashboard reads
CREATE MATERIALIZED VIEW IF NOT EXISTS tracker.mv_weekly_summary AS
SELECT
  w.user_id,
  w.week_start,
  w.weight_kg,
  w.body_fat_pct,
  w.vertical_jump_cm,
  w.shuttle_run_4x10_sec,
  w.plank_seconds,
  w.reaction_time_sec,
  w.created_at as metrics_created_at
FROM tracker.weekly_metrics w;

-- To refresh: REFRESH MATERIALIZED VIEW CONCURRENTLY tracker.mv_weekly_summary;

-- === 18. Functions: recalc_streaks (simple implementation) ===
CREATE OR REPLACE FUNCTION tracker.recalc_streaks(p_user_id uuid)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  last_date date := NULL;
  cur_streak int := 0;
  long_streak int := 0;
  r record;
BEGIN
  -- iterate session dates in descending order
  FOR r IN
    SELECT session_date
    FROM tracker.training_sessions
    WHERE user_id = p_user_id
    GROUP BY session_date
    ORDER BY session_date DESC
  LOOP
    IF last_date IS NULL THEN
      last_date := r.session_date;
      cur_streak := 1;
      long_streak := GREATEST(long_streak, cur_streak);
    ELSE
      IF (last_date - r.session_date) = 1 THEN
        cur_streak := cur_streak + 1;
        last_date := r.session_date;
        long_streak := GREATEST(long_streak, cur_streak);
      ELSE
        EXIT; -- streak broken
      END IF;
    END IF;
  END LOOP;

  INSERT INTO tracker.streaks (user_id, current_streak, longest_streak, last_active_date)
  VALUES (p_user_id, cur_streak, long_streak, last_date)
  ON CONFLICT (user_id) DO UPDATE
    SET current_streak = EXCLUDED.current_streak,
        longest_streak = GREATEST(tracker.streaks.longest_streak, EXCLUDED.longest_streak),
        last_active_date = EXCLUDED.last_active_date;
END;
$$;

-- === 19. Trigger: notify after new session (lightweight) ===
CREATE OR REPLACE FUNCTION tracker.trigger_after_session()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- Notify background worker; payload is user_id
  PERFORM pg_notify('tracker_new_session', NEW.user_id::text);
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_after_session
AFTER INSERT ON tracker.training_sessions
FOR EACH ROW EXECUTE PROCEDURE tracker.trigger_after_session();

-- === 20. Example trigger to insert audit_log records (generic) ===
CREATE OR REPLACE FUNCTION tracker.audit_trigger_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_payload jsonb;
BEGIN
  IF (TG_OP = 'DELETE') THEN
    v_payload := to_jsonb(OLD);
  ELSE
    v_payload := to_jsonb(NEW);
  END IF;

  INSERT INTO tracker.audit_log(table_name, record_id, action, changed_by, payload)
  VALUES (TG_TABLE_NAME, COALESCE(NEW.id, OLD.id)::uuid, TG_OP, NULL, v_payload);

  RETURN NULL;
END;
$$;

-- Attach audit trigger to key tables (optional; uncomment as needed)
-- CREATE TRIGGER audit_users AFTER INSERT OR UPDATE OR DELETE ON tracker.users FOR EACH ROW EXECUTE PROCEDURE tracker.audit_trigger_fn();
-- CREATE TRIGGER audit_sessions AFTER INSERT OR UPDATE OR DELETE ON tracker.training_sessions FOR EACH ROW EXECUTE PROCEDURE tracker.audit_trigger_fn();

-- === 21. Useful Indexes & Performance helpers ===
-- Index for recent sessions with start_ts
CREATE INDEX IF NOT EXISTS idx_sessions_user_recent ON tracker.training_sessions (user_id, start_ts DESC) WHERE start_ts IS NOT NULL;

-- GIN index for JSONB search on drills.variants or training_sessions.exercises
CREATE INDEX IF NOT EXISTS idx_drills_variants_gin ON tracker.drills USING gin (variants jsonb_path_ops);
CREATE INDEX IF NOT EXISTS idx_sessions_exercises_gin ON tracker.training_sessions USING gin (exercises jsonb_path_ops);

-- Index on weekly_metrics for dashboard queries
CREATE INDEX IF NOT EXISTS idx_weekly_user_recent2 ON tracker.weekly_metrics (user_id, week_start DESC);

-- === 22. Maintenance / Retention Helper function (example) ===
-- Function to purge wearable_samples older than N days (call from cron)
CREATE OR REPLACE FUNCTION tracker.purge_wearable_older_than(days integer)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  cnt integer := 0;
BEGIN
  DELETE FROM tracker.wearable_samples WHERE recorded_at < now() - (days || ' days')::interval
  RETURNING 1 INTO cnt;
  RETURN COALESCE(cnt, 0);
END;
$$;

-- === End of DDL ===