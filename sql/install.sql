CREATE SCHEMA IF NOT EXISTS pgit;

CREATE TABLE IF NOT EXISTS pgit.meta (
  key   text PRIMARY KEY,
  value text NOT NULL
);

INSERT INTO pgit.meta (key, value) VALUES
  ('canon_version', '1'),
  ('hash_algo', 'sha256'),
  ('chunk_target', '64')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION pgit.setting(k text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT value FROM pgit.meta WHERE key = k
$$;

CREATE OR REPLACE FUNCTION pgit.hash(v bytea) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$
  SELECT sha256(v)
$$;

CREATE OR REPLACE FUNCTION pgit.hash(v text) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$
  SELECT sha256(convert_to(v, 'UTF8'))
$$;

CREATE OR REPLACE FUNCTION pgit.base_type(t oid) RETURNS oid
LANGUAGE plpgsql STABLE AS $$
DECLARE
  cur oid := t;
  bt  oid;
BEGIN
  LOOP
    SELECT typbasetype INTO bt FROM pg_type WHERE oid = cur;
    EXIT WHEN bt IS NULL OR bt = 0;
    cur := bt;
  END LOOP;
  RETURN cur;
END $$;

CREATE OR REPLACE FUNCTION pgit.canon_numeric(v numeric) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN v IS NULL      THEN NULL
    WHEN v::text = 'NaN' THEN 'NaN'
    ELSE trim_scale(v)::text
  END
$$;

CREATE OR REPLACE FUNCTION pgit.canon_float(v float8) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN v IS NULL                  THEN NULL
    WHEN v::text = 'NaN'            THEN 'NaN'
    WHEN v::text = 'Infinity'       THEN 'Infinity'
    WHEN v::text = '-Infinity'      THEN '-Infinity'
    WHEN v = 0::float8              THEN '0'
    ELSE v::text
  END
$$;

CREATE OR REPLACE FUNCTION pgit.canon_ts(v timestamptz) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN v IS NULL                       THEN NULL
    WHEN v = 'infinity'::timestamptz     THEN 'infinity'
    WHEN v = '-infinity'::timestamptz    THEN '-infinity'
    ELSE to_char(v AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
  END
$$;

CREATE OR REPLACE FUNCTION pgit.canon_tsn(v timestamp) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN v IS NULL                    THEN NULL
    WHEN v = 'infinity'::timestamp    THEN 'infinity'
    WHEN v = '-infinity'::timestamp   THEN '-infinity'
    ELSE to_char(v, 'YYYY-MM-DD"T"HH24:MI:SS.US')
  END
$$;

CREATE OR REPLACE FUNCTION pgit.canon_date(v date) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN v IS NULL                 THEN NULL
    WHEN v = 'infinity'::date      THEN 'infinity'
    WHEN v = '-infinity'::date     THEN '-infinity'
    ELSE to_char(v, 'YYYY-MM-DD')
  END
$$;

CREATE OR REPLACE FUNCTION pgit.canon_expr(col text, typid oid) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  b oid  := pgit.base_type(typid);
  k char;
BEGIN
  SELECT typtype INTO k FROM pg_type WHERE oid = b;

  IF k = 'e' THEN
    RETURN format('%I::text', col);
  END IF;

  RETURN CASE b
    WHEN 'numeric'::regtype::oid     THEN format('pgit.canon_numeric(%I)', col)
    WHEN 'float4'::regtype::oid      THEN format('pgit.canon_float(%I::float8)', col)
    WHEN 'float8'::regtype::oid      THEN format('pgit.canon_float(%I)', col)
    WHEN 'timestamptz'::regtype::oid THEN format('pgit.canon_ts(%I)', col)
    WHEN 'timestamp'::regtype::oid   THEN format('pgit.canon_tsn(%I)', col)
    WHEN 'date'::regtype::oid        THEN format('pgit.canon_date(%I)', col)
    WHEN 'bool'::regtype::oid        THEN format('CASE WHEN %I THEN ''t'' ELSE ''f'' END', col)
    WHEN 'bytea'::regtype::oid       THEN format('encode(%I, ''hex'')', col)
    WHEN 'text'::regtype::oid        THEN format('normalize(%I, NFC)', col)
    WHEN 'varchar'::regtype::oid     THEN format('normalize(%I::text, NFC)', col)
    WHEN 'bpchar'::regtype::oid      THEN format('normalize(%I::text, NFC)', col)
    ELSE format('%I::text', col)
  END;
END $$;

CREATE OR REPLACE FUNCTION pgit.canon_field_expr(col text, typid oid) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT format(
    '%L || ''='' || CASE WHEN (%s) IS NULL THEN ''~'' ELSE ''#'' || length(%s)::text || '':'' || (%s) END || ''|''',
    col, e.expr, e.expr, e.expr
  )
  FROM (SELECT pgit.canon_expr(col, typid) AS expr) e
$$;

CREATE OR REPLACE FUNCTION pgit.row_canon_expr(tbl regclass) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT string_agg(pgit.canon_field_expr(a.attname, a.atttypid), ' || ' ORDER BY a.attname)
  FROM pg_attribute a
  WHERE a.attrelid = tbl AND a.attnum > 0 AND NOT a.attisdropped
$$;

CREATE OR REPLACE FUNCTION pgit.pk_canon_expr(tbl regclass) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  e text;
BEGIN
  SELECT string_agg(pgit.canon_field_expr(a.attname, a.atttypid), ' || ' ORDER BY a.attname)
  INTO e
  FROM pg_index i
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
  WHERE i.indrelid = tbl AND i.indisprimary AND NOT a.attisdropped;

  IF e IS NULL THEN
    RAISE EXCEPTION 'pgit: table % has no primary key', tbl::text;
  END IF;

  RETURN e;
END $$;
DROP FUNCTION IF EXISTS pgit.row_hashes(regclass);
DROP FUNCTION IF EXISTS pgit.write_tree(regclass);
DROP FUNCTION IF EXISTS pgit.tree_root(regclass);

CREATE OR REPLACE FUNCTION pgit.row_hashes_sql(tbl regclass) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT format(
    'SELECT convert_to(%s, ''UTF8'') AS key_bytes, pgit.hash(%s) AS hash, to_jsonb(t) AS image FROM %s t',
    pgit.pk_canon_expr(tbl), pgit.row_canon_expr(tbl), tbl::text
  )
$$;

CREATE OR REPLACE FUNCTION pgit.row_hashes(tbl regclass)
RETURNS TABLE (key_bytes bytea, hash bytea, image jsonb)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN QUERY EXECUTE pgit.row_hashes_sql(tbl);
END $$;

CREATE OR REPLACE FUNCTION pgit.is_boundary(key_bytes bytea, target int DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT ('x' || encode(substring(pgit.hash(key_bytes) FROM 1 FOR 3), 'hex'))::bit(24)::int
         % COALESCE(target, pgit.setting('chunk_target')::int) = 0
$$;

CREATE OR REPLACE FUNCTION pgit.chunk_stats(tbl regclass)
RETURNS TABLE (rows bigint, chunks bigint)
LANGUAGE sql STABLE AS $$
  WITH lvl AS (SELECT key_bytes FROM pgit.row_hashes(tbl)),
  marked AS (
    SELECT COALESCE(
      SUM(CASE WHEN pgit.is_boundary(key_bytes) THEN 1 ELSE 0 END)
        OVER (ORDER BY key_bytes ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS chunk
    FROM lvl
  )
  SELECT count(*)::bigint, count(DISTINCT chunk)::bigint FROM marked
$$;

CREATE TABLE IF NOT EXISTS pgit.nodes (
  hash    bytea PRIMARY KEY,
  level   int   NOT NULL,
  entries jsonb NOT NULL
);

CREATE TABLE IF NOT EXISTS pgit.trees (
  commit_sha bytea NOT NULL,
  tbl        text  NOT NULL,
  root_hash  bytea NOT NULL,
  PRIMARY KEY (commit_sha, tbl)
);

ALTER TABLE pgit.nodes ADD COLUMN IF NOT EXISTS base_hash bytea;
ALTER TABLE pgit.nodes ADD COLUMN IF NOT EXISTS delta jsonb;
ALTER TABLE pgit.nodes ADD COLUMN IF NOT EXISTS seq bigserial;
ALTER TABLE pgit.nodes ALTER COLUMN entries DROP NOT NULL;

CREATE INDEX IF NOT EXISTS nodes_base_idx ON pgit.nodes (base_hash);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'nodes_stored_or_delta') THEN
    ALTER TABLE pgit.nodes ADD CONSTRAINT nodes_stored_or_delta
      CHECK (entries IS NOT NULL OR (base_hash IS NOT NULL AND delta IS NOT NULL));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgit.apply_delta(base jsonb, d jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(jsonb_agg(e ORDER BY e ->> 'k'), '[]'::jsonb)
  FROM (
    SELECT b AS e FROM jsonb_array_elements(base) b
    WHERE b ->> 'k' NOT IN (SELECT jsonb_array_elements_text(COALESCE(d -> 'del', '[]'::jsonb)))
      AND b ->> 'k' NOT IN (SELECT x ->> 'k' FROM jsonb_array_elements(COALESCE(d -> 'set', '[]'::jsonb)) x)
    UNION ALL
    SELECT x FROM jsonb_array_elements(COALESCE(d -> 'set', '[]'::jsonb)) x
  ) q
$$;

CREATE OR REPLACE FUNCTION pgit.make_delta(base jsonb, target jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'del', (SELECT COALESCE(jsonb_agg(b ->> 'k'), '[]'::jsonb)
            FROM jsonb_array_elements(base) b
            WHERE b ->> 'k' NOT IN (SELECT t ->> 'k' FROM jsonb_array_elements(target) t)),
    'set', (SELECT COALESCE(jsonb_agg(t), '[]'::jsonb)
            FROM jsonb_array_elements(target) t
            WHERE t NOT IN (SELECT b FROM jsonb_array_elements(base) b)))
$$;

CREATE OR REPLACE FUNCTION pgit.entries_of(h bytea) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  chain bytea[] := '{}';
  cur   bytea   := h;
  acc   jsonb;
  nxt   bytea;
  dl    jsonb;
  i     int;
BEGIN
  LOOP
    SELECT n.entries, n.base_hash INTO acc, nxt FROM pgit.nodes n WHERE n.hash = cur;
    IF NOT FOUND THEN RETURN NULL; END IF;
    EXIT WHEN acc IS NOT NULL;
    chain := chain || cur;
    cur := nxt;
  END LOOP;

  IF array_length(chain, 1) IS NULL THEN RETURN acc; END IF;

  FOR i IN REVERSE array_length(chain, 1)..1 LOOP
    SELECT n.delta INTO dl FROM pgit.nodes n WHERE n.hash = chain[i];
    acc := pgit.apply_delta(acc, dl);
  END LOOP;

  RETURN acc;
END $$;

CREATE TABLE IF NOT EXISTS pgit.tracked (
  tbl     regclass PRIMARY KEY,
  pk_cols text[]   NOT NULL
);

CREATE TABLE IF NOT EXISTS pgit.changes (
  id     bigserial PRIMARY KEY,
  txid   bigint      NOT NULL,
  tbl    text        NOT NULL,
  pk     jsonb       NOT NULL,
  op     text        NOT NULL CHECK (op IN ('INSERT', 'UPDATE', 'DELETE')),
  before jsonb,
  after  jsonb,
  actor  text,
  source text        NOT NULL,
  at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS changes_txid_idx ON pgit.changes (txid);
CREATE INDEX IF NOT EXISTS changes_tbl_pk_idx ON pgit.changes (tbl, (pk::text));

CREATE OR REPLACE FUNCTION pgit.actor() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT current_setting('pgit.actor', true)
$$;

CREATE OR REPLACE FUNCTION pgit.source() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(current_setting('pgit.source', true), ''), 'raw-sql')
$$;

CREATE OR REPLACE FUNCTION pgit.pk_of(rec jsonb, cols text[]) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_object_agg(k, rec -> k) FROM unnest(cols) k
$$;

CREATE OR REPLACE FUNCTION pgit.journal() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  b    jsonb := to_jsonb(OLD);
  a    jsonb := to_jsonb(NEW);
  cols text[];
BEGIN
  SELECT pk_cols INTO cols FROM pgit.tracked WHERE tbl = TG_RELID::regclass;

  INSERT INTO pgit.changes (txid, tbl, pk, op, before, after, actor, source)
  VALUES (txid_current(), TG_TABLE_NAME, pgit.pk_of(COALESCE(a, b), cols),
          TG_OP, b, a, pgit.actor(), pgit.source());

  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION pgit.journal_truncate() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  cols text[];
BEGIN
  SELECT pk_cols INTO cols FROM pgit.tracked WHERE tbl = TG_RELID::regclass;

  EXECUTE format(
    'INSERT INTO pgit.changes (txid, tbl, pk, op, before, after, actor, source)
     SELECT txid_current(), %L, pgit.pk_of(to_jsonb(t), %L::text[]), ''DELETE'',
            to_jsonb(t), NULL, pgit.actor(), pgit.source()
     FROM %s t',
    TG_TABLE_NAME, cols, TG_RELID::regclass::text
  );

  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION pgit.pk_columns(tbl regclass) RETURNS text[]
LANGUAGE sql STABLE AS $$
  SELECT array_agg(a.attname ORDER BY a.attname)
  FROM pg_index i
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
  WHERE i.indrelid = tbl AND i.indisprimary AND NOT a.attisdropped
$$;

DROP FUNCTION IF EXISTS pgit.track(regclass);
DROP FUNCTION IF EXISTS pgit.untrack(regclass);

CREATE OR REPLACE FUNCTION pgit.track(target regclass) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  cols text[] := pgit.pk_columns(target);
BEGIN
  IF cols IS NULL THEN
    RAISE EXCEPTION 'pgit: table % has no primary key', target::text;
  END IF;

  INSERT INTO pgit.tracked (tbl, pk_cols) VALUES (target, cols)
  ON CONFLICT (tbl) DO UPDATE SET pk_cols = EXCLUDED.pk_cols;

  EXECUTE format('DROP TRIGGER IF EXISTS pgit_journal ON %s', target::text);
  EXECUTE format('DROP TRIGGER IF EXISTS pgit_journal_ins ON %s', target::text);
  EXECUTE format('DROP TRIGGER IF EXISTS pgit_journal_upd ON %s', target::text);
  EXECUTE format('DROP TRIGGER IF EXISTS pgit_journal_del ON %s', target::text);

  EXECUTE format(
    'CREATE TRIGGER pgit_journal_ins AFTER INSERT ON %s
     REFERENCING NEW TABLE AS newrows
     FOR EACH STATEMENT EXECUTE FUNCTION pgit.journal_stmt()', target::text);
  EXECUTE format(
    'CREATE TRIGGER pgit_journal_upd AFTER UPDATE ON %s
     REFERENCING OLD TABLE AS oldrows NEW TABLE AS newrows
     FOR EACH STATEMENT EXECUTE FUNCTION pgit.journal_stmt()', target::text);
  EXECUTE format(
    'CREATE TRIGGER pgit_journal_del AFTER DELETE ON %s
     REFERENCING OLD TABLE AS oldrows
     FOR EACH STATEMENT EXECUTE FUNCTION pgit.journal_stmt()', target::text);

  EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER pgit_journal_ins', target::text);
  EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER pgit_journal_upd', target::text);
  EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER pgit_journal_del', target::text);

  EXECUTE format('DROP TRIGGER IF EXISTS pgit_journal_truncate ON %s', target::text);
  EXECUTE format(
    'CREATE TRIGGER pgit_journal_truncate BEFORE TRUNCATE ON %s
     FOR EACH STATEMENT EXECUTE FUNCTION pgit.journal_truncate()', target::text);

  PERFORM pgit.ensure_key_index(target);
END $$;

CREATE OR REPLACE FUNCTION pgit.untrack(target regclass) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('DROP TRIGGER IF EXISTS pgit_journal_ins ON %s', target::text);
  EXECUTE format('DROP TRIGGER IF EXISTS pgit_journal_upd ON %s', target::text);
  EXECUTE format('DROP TRIGGER IF EXISTS pgit_journal_del ON %s', target::text);
  EXECUTE format('DROP TRIGGER IF EXISTS pgit_journal_truncate ON %s', target::text);
  DELETE FROM pgit.tracked WHERE tbl = target;
END $$;

INSERT INTO pgit.meta (key, value) VALUES ('head', 'main')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS pgit.commits (
  sha        bytea PRIMARY KEY,
  parent_sha bytea REFERENCES pgit.commits(sha),
  author     text,
  message    text        NOT NULL,
  at         timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS pgit.refs (
  name text  PRIMARY KEY,
  sha  bytea NOT NULL REFERENCES pgit.commits(sha)
);

CREATE OR REPLACE FUNCTION pgit.head() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(pgit.setting('head'), 'main')
$$;

CREATE OR REPLACE FUNCTION pgit.resolve(ref_name text) RETURNS bytea
LANGUAGE sql STABLE AS $$
  SELECT sha FROM pgit.refs WHERE name = ref_name
$$;

CREATE OR REPLACE FUNCTION pgit.tree_summary() RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  parts text[] := '{}';
  r     record;
BEGIN
  FOR r IN SELECT tbl FROM pgit.tracked ORDER BY tbl::text LOOP
    parts := parts || (r.tbl::text || ':' || encode(pgit.write_tree(r.tbl), 'hex'));
  END LOOP;
  RETURN array_to_string(parts, E'\n');
END $$;

CREATE OR REPLACE FUNCTION pgit.commit_sha(
  parent bytea, who text, msg text, ts timestamptz, trees text
) RETURNS bytea
LANGUAGE sql STABLE AS $$
  SELECT pgit.hash(
    COALESCE(encode(parent, 'hex'), '') || E'\n' ||
    COALESCE(who, '') || E'\n' ||
    msg || E'\n' ||
    to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || E'\n' ||
    trees
  )
$$;

CREATE OR REPLACE FUNCTION pgit.advance_ref(ref_name text, expected bytea, next_sha bytea)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  IF expected IS NULL THEN
    INSERT INTO pgit.refs (name, sha) VALUES (ref_name, next_sha)
    ON CONFLICT (name) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n = 0 THEN
      RAISE EXCEPTION 'pgit: ref % already exists, refusing to create it', ref_name;
    END IF;
  ELSE
    UPDATE pgit.refs SET sha = next_sha WHERE name = ref_name AND sha = expected;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n = 0 THEN
      RAISE EXCEPTION 'pgit: ref % moved under us', ref_name;
    END IF;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgit.commit(msg text, who text DEFAULT NULL, ts timestamptz DEFAULT now())
RETURNS bytea LANGUAGE plpgsql AS $$
DECLARE
  branch  text  := pgit.head();
  parent  bytea := pgit.resolve(pgit.head());
  summary text;
  roots   jsonb;
  author  text  := COALESCE(who, pgit.actor());
  new_sha bytea;
BEGIN
  roots   := pgit.snapshot_trees(parent);
  summary := pgit.roots_summary(roots);
  new_sha := pgit.commit_sha(parent, author, msg, ts, summary);

  INSERT INTO pgit.commits (sha, parent_sha, author, message, at)
  VALUES (new_sha, parent, author, msg, ts)
  ON CONFLICT (sha) DO NOTHING;

  INSERT INTO pgit.trees (commit_sha, tbl, root_hash)
  SELECT new_sha, e.key, decode(e.value, 'hex') FROM jsonb_each_text(roots) e
  ON CONFLICT DO NOTHING;

  PERFORM pgit.record_schemas(new_sha);

  UPDATE pgit.changes SET commit_sha = new_sha WHERE commit_sha IS NULL;

  PERFORM pgit.advance_ref(branch, parent, new_sha);

  RETURN new_sha;
END $$;


CREATE OR REPLACE FUNCTION pgit.ensure_scratch() RETURNS void
LANGUAGE plpgsql SET client_min_messages = warning AS $$
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS pgit_lvl   (key_bytes bytea, hash bytea, image jsonb);
  CREATE TEMP TABLE IF NOT EXISTS pgit_nxt   (key_bytes bytea, hash bytea, image jsonb);
  CREATE TEMP TABLE IF NOT EXISTS pgit_grp   (key_bytes bytea, hash bytea, entries jsonb);
  CREATE TEMP TABLE IF NOT EXISTS pgit_built (key_bytes bytea, hash bytea);
  CREATE TEMP TABLE IF NOT EXISTS pgit_new   (key_bytes bytea, hash bytea);
  CREATE TEMP TABLE IF NOT EXISTS pgit_l1    (k text, h text, nk text, rn bigint);
  CREATE TEMP TABLE IF NOT EXISTS pgit_l1hit (rn bigint);
  CREATE TEMP TABLE IF NOT EXISTS pgit_old   (k text, h text, nk text, rn bigint);
  CREATE TEMP TABLE IF NOT EXISTS pgit_hit   (rn bigint);
END $$;

CREATE OR REPLACE FUNCTION pgit.write_tree(target regclass) RETURNS bytea
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  n bigint;
BEGIN
  PERFORM pgit.ensure_scratch();
  TRUNCATE pgit_lvl;
  INSERT INTO pgit_lvl SELECT * FROM pgit.row_hashes(target);

  SELECT count(*) INTO n FROM pgit_lvl;
  IF n = 0 THEN RETURN pgit.hash(''::bytea); END IF;

  PERFORM pgit.build_one_level(0, true);

  TRUNCATE pgit_lvl;
  INSERT INTO pgit_lvl SELECT b.key_bytes, b.hash, NULL::jsonb FROM pgit_built b;

  RETURN pgit.build_up(1);
END $$;

CREATE OR REPLACE FUNCTION pgit.tree_root(target regclass) RETURNS bytea
LANGUAGE sql AS $$
  SELECT pgit.write_tree(target)
$$;

CREATE OR REPLACE FUNCTION pgit.leaves(h bytea)
RETURNS TABLE (k text, rh text, v jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  lvl int := pgit.node_level(h);
  e   jsonb;
BEGIN
  IF lvl IS NULL THEN RETURN; END IF;

  IF lvl = 0 THEN
    RETURN QUERY
      SELECT x ->> 'k', x ->> 'h', x -> 'v'
      FROM pgit.nodes n, jsonb_array_elements(pgit.entries_of(n.hash)) x
      WHERE n.hash = h;
    RETURN;
  END IF;

  FOR e IN SELECT x FROM pgit.nodes n, jsonb_array_elements(pgit.entries_of(n.hash)) x WHERE n.hash = h LOOP
    RETURN QUERY SELECT * FROM pgit.leaves(decode(e ->> 'h', 'hex'));
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION pgit.diff_leaves(a bytea, b bytea)
RETURNS TABLE (side text, k text, rh text, v jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  lvl int;
  r   record;
BEGIN
  IF a IS NOT DISTINCT FROM b THEN RETURN; END IF;

  IF a IS NULL THEN
    RETURN QUERY SELECT 'b'::text, l.k, l.rh, l.v FROM pgit.leaves(b) l;
    RETURN;
  END IF;

  IF b IS NULL THEN
    RETURN QUERY SELECT 'a'::text, l.k, l.rh, l.v FROM pgit.leaves(a) l;
    RETURN;
  END IF;

  IF pgit.node_level(a) IS DISTINCT FROM pgit.node_level(b) THEN
    RETURN QUERY SELECT 'a'::text, l.k, l.rh, l.v FROM pgit.leaves(a) l;
    RETURN QUERY SELECT 'b'::text, l.k, l.rh, l.v FROM pgit.leaves(b) l;
    RETURN;
  END IF;

  lvl := COALESCE(pgit.node_level(a), pgit.node_level(b));
  IF lvl IS NULL THEN RETURN; END IF;

  IF lvl = 0 THEN
    RETURN QUERY SELECT 'a'::text, l.k, l.rh, l.v FROM pgit.leaves(a) l;
    RETURN QUERY SELECT 'b'::text, l.k, l.rh, l.v FROM pgit.leaves(b) l;
    RETURN;
  END IF;

  FOR r IN
    WITH ae AS (
      SELECT e.k, e.ch, lead(e.k) OVER (ORDER BY e.k) AS nk FROM pgit.node_entries(a) e
    ),
    be AS (
      SELECT e.k, e.ch, lead(e.k) OVER (ORDER BY e.k) AS nk FROM pgit.node_entries(b) e
    ),
    paired AS (
      SELECT ae.ch AS ach, be.ch AS bch
      FROM ae LEFT JOIN be
        ON ae.k < COALESCE(be.nk, 'g') AND be.k < COALESCE(ae.nk, 'g')
      UNION
      SELECT ae.ch AS ach, be.ch AS bch
      FROM be LEFT JOIN ae
        ON ae.k < COALESCE(be.nk, 'g') AND be.k < COALESCE(ae.nk, 'g')
    )
    SELECT DISTINCT paired.ach, paired.bch FROM paired
    WHERE paired.ach IS DISTINCT FROM paired.bch
  LOOP
    RETURN QUERY SELECT * FROM pgit.diff_leaves(decode(r.ach, 'hex'), decode(r.bch, 'hex'));
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION pgit.node_items(h bytea)
RETURNS TABLE (k text, ch text, v jsonb)
LANGUAGE sql STABLE AS $$
  SELECT x ->> 'k', x ->> 'h', x -> 'v'
  FROM pgit.nodes n, jsonb_array_elements(pgit.entries_of(n.hash)) x
  WHERE n.hash = h
$$;

CREATE OR REPLACE FUNCTION pgit.lookup(root bytea, key_hex text)
RETURNS TABLE (rh text, v jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  cur bytea := root;
  lvl int;
BEGIN
  LOOP
    lvl := pgit.node_level(cur);
    IF lvl IS NULL THEN RETURN; END IF;

    IF lvl = 0 THEN
      RETURN QUERY SELECT i.ch, i.v FROM pgit.node_items(cur) i WHERE i.k = key_hex;
      RETURN;
    END IF;

    SELECT decode(i.ch, 'hex') INTO cur
    FROM pgit.node_items(cur) i
    WHERE i.k <= key_hex
    ORDER BY i.k DESC
    LIMIT 1;

    IF cur IS NULL THEN RETURN; END IF;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION pgit.diff_tree(a bytea, b bytea)
RETURNS TABLE (k text, op text, before jsonb, after jsonb)
LANGUAGE sql STABLE AS $$
  WITH candidates AS (SELECT DISTINCT d.k FROM pgit.diff_leaves(a, b) d)
  SELECT c.k,
         CASE WHEN la.rh IS NULL THEN 'INSERT'
              WHEN lb.rh IS NULL THEN 'DELETE'
              ELSE 'UPDATE' END,
         la.v, lb.v
  FROM candidates c
  LEFT JOIN LATERAL pgit.lookup(a, c.k) la ON true
  LEFT JOIN LATERAL pgit.lookup(b, c.k) lb ON true
  WHERE la.rh IS DISTINCT FROM lb.rh
$$;

CREATE OR REPLACE FUNCTION pgit.row_matches(tbl_name text, image jsonb, want text)
RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE
  cols text[];
BEGIN
  IF want IS NULL THEN RETURN true; END IF;

  SELECT pk_cols INTO cols FROM pgit.tracked WHERE tbl::text = tbl_name;
  IF cols IS NULL THEN RETURN false; END IF;

  IF array_length(cols, 1) <> 1 THEN
    RAISE EXCEPTION 'pgit: a row pathspec needs a single column primary key, but % has %',
      tbl_name, array_to_string(cols, ',');
  END IF;

  RETURN image ->> cols[1] = want;
END $$;

DROP FUNCTION IF EXISTS pgit.diff(bytea, bytea);

CREATE OR REPLACE FUNCTION pgit.diff(a_sha bytea, b_sha bytea, pathspec text DEFAULT NULL)
RETURNS TABLE (tbl text, k text, op text, before jsonb, after jsonb)
LANGUAGE sql STABLE AS $$
  WITH spec AS (
    SELECT NULLIF(split_part(split_part(pathspec, ':', 1), '.', 1), '') AS want_tbl,
           NULLIF(split_part(split_part(pathspec, ':', 1), '.', 2), '') AS want_col,
           NULLIF(split_part(pathspec, ':', 2), '')                     AS want_row
  ),
  tables AS (
    SELECT t.tbl FROM pgit.trees t WHERE t.commit_sha = a_sha
    UNION
    SELECT t.tbl FROM pgit.trees t WHERE t.commit_sha = b_sha
  ),
  wanted AS (
    SELECT tables.tbl FROM tables, spec
    WHERE spec.want_tbl IS NULL OR tables.tbl = spec.want_tbl
  ),
  raw AS (
    SELECT w.tbl, d.k, d.op, d.before, d.after
    FROM wanted w
    CROSS JOIN LATERAL pgit.diff_tree(
      (SELECT root_hash FROM pgit.trees WHERE commit_sha = a_sha AND pgit.trees.tbl = w.tbl),
      (SELECT root_hash FROM pgit.trees WHERE commit_sha = b_sha AND pgit.trees.tbl = w.tbl)
    ) d
  )
  SELECT raw.tbl, raw.k, raw.op,
         CASE WHEN spec.want_col IS NULL OR raw.before IS NULL THEN raw.before
              ELSE jsonb_build_object(spec.want_col, raw.before -> spec.want_col) END,
         CASE WHEN spec.want_col IS NULL OR raw.after IS NULL THEN raw.after
              ELSE jsonb_build_object(spec.want_col, raw.after -> spec.want_col) END
  FROM raw, spec
  WHERE pgit.row_matches(raw.tbl, COALESCE(raw.before, raw.after), spec.want_row)
    AND (spec.want_col IS NULL
         OR COALESCE(raw.before -> spec.want_col, 'null'::jsonb)
            IS DISTINCT FROM COALESCE(raw.after -> spec.want_col, 'null'::jsonb))
$$;

CREATE OR REPLACE FUNCTION pgit.diff_stat(a_sha bytea, b_sha bytea, pathspec text DEFAULT NULL)
RETURNS TABLE (tbl text, inserted bigint, updated bigint, deleted bigint)
LANGUAGE sql STABLE AS $$
  SELECT d.tbl,
         count(*) FILTER (WHERE d.op = 'INSERT'),
         count(*) FILTER (WHERE d.op = 'UPDATE'),
         count(*) FILTER (WHERE d.op = 'DELETE')
  FROM pgit.diff(a_sha, b_sha, pathspec) d
  GROUP BY d.tbl
  ORDER BY d.tbl
$$;

CREATE OR REPLACE FUNCTION pgit.diff_numstat(a_sha bytea, b_sha bytea, pathspec text DEFAULT NULL)
RETURNS TABLE (added bigint, removed bigint, tbl text)
LANGUAGE sql STABLE AS $$
  SELECT count(*) FILTER (WHERE d.op IN ('INSERT', 'UPDATE')),
         count(*) FILTER (WHERE d.op IN ('DELETE', 'UPDATE')),
         d.tbl
  FROM pgit.diff(a_sha, b_sha, pathspec) d
  GROUP BY d.tbl
  ORDER BY d.tbl
$$;

CREATE OR REPLACE FUNCTION pgit.diff_shortstat(a_sha bytea, b_sha bytea, pathspec text DEFAULT NULL)
RETURNS TABLE (tables bigint, insertions bigint, deletions bigint)
LANGUAGE sql STABLE AS $$
  SELECT count(DISTINCT d.tbl),
         count(*) FILTER (WHERE d.op IN ('INSERT', 'UPDATE')),
         count(*) FILTER (WHERE d.op IN ('DELETE', 'UPDATE'))
  FROM pgit.diff(a_sha, b_sha, pathspec) d
$$;

CREATE OR REPLACE FUNCTION pgit.diff_name_only(a_sha bytea, b_sha bytea, pathspec text DEFAULT NULL)
RETURNS TABLE (tbl text)
LANGUAGE sql STABLE AS $$
  SELECT DISTINCT d.tbl FROM pgit.diff(a_sha, b_sha, pathspec) d ORDER BY 1
$$;

CREATE OR REPLACE FUNCTION pgit.diff_name_status(a_sha bytea, b_sha bytea, pathspec text DEFAULT NULL)
RETURNS TABLE (status text, tbl text)
LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN NOT EXISTS (SELECT 1 FROM pgit.trees t
                            WHERE t.commit_sha = a_sha AND t.tbl = c.tbl) THEN 'A'
           WHEN NOT EXISTS (SELECT 1 FROM pgit.trees t
                            WHERE t.commit_sha = b_sha AND t.tbl = c.tbl) THEN 'D'
           ELSE 'M'
         END,
         c.tbl
  FROM (SELECT DISTINCT d.tbl FROM pgit.diff(a_sha, b_sha, pathspec) d) c
  ORDER BY c.tbl
$$;

CREATE OR REPLACE FUNCTION pgit.node_level(h bytea) RETURNS int
LANGUAGE sql STABLE AS $$
  SELECT level FROM pgit.nodes WHERE hash = h
$$;

CREATE OR REPLACE FUNCTION pgit.node_entries(h bytea)
RETURNS TABLE (k text, ch text)
LANGUAGE sql STABLE AS $$
  SELECT x ->> 'k', x ->> 'h'
  FROM pgit.nodes n, jsonb_array_elements(pgit.entries_of(n.hash)) x
  WHERE n.hash = h
$$;

CREATE OR REPLACE FUNCTION pgit.all_columns(tbl regclass) RETURNS text[]
LANGUAGE sql STABLE AS $$
  SELECT array_agg(a.attname ORDER BY a.attnum)
  FROM pg_attribute a
  WHERE a.attrelid = tbl AND a.attnum > 0 AND NOT a.attisdropped
$$;

DROP FUNCTION IF EXISTS pgit.apply_diff(regclass, bytea, bytea);

CREATE OR REPLACE FUNCTION pgit.apply_diff(
  target regclass, a_sha bytea, b_sha bytea, source text DEFAULT NULL
) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r        record;
  applied  int    := 0;
  pk       text[] := pgit.pk_columns(target);
  cols     text[] := pgit.all_columns(target);
  src      text   := COALESCE(source, target::text);
  a        bytea;
  b        bytea;
  pk_pred  text;
  set_cols text;
  set_vals text;
BEGIN
  SELECT root_hash INTO a FROM pgit.trees WHERE commit_sha = a_sha AND tbl = src;
  SELECT root_hash INTO b FROM pgit.trees WHERE commit_sha = b_sha AND tbl = src;

  SELECT string_agg(format('t.%I = s.%I', c, c), ' AND ') INTO pk_pred FROM unnest(pk) c;
  SELECT string_agg(format('%I', c), ', ') INTO set_cols FROM unnest(cols) c;
  SELECT string_agg(format('s.%I', c), ', ') INTO set_vals FROM unnest(cols) c;

  FOR r IN SELECT * FROM pgit.diff_tree(a, b) LOOP
    IF r.op = 'INSERT' THEN
      EXECUTE format(
        'INSERT INTO %s SELECT * FROM jsonb_populate_record(NULL::%s, $1)',
        target::text, target::text) USING r.after;
    ELSIF r.op = 'DELETE' THEN
      EXECUTE format(
        'DELETE FROM %s t USING jsonb_populate_record(NULL::%s, $1) s WHERE %s',
        target::text, target::text, pk_pred) USING r.before;
    ELSE
      EXECUTE format(
        'UPDATE %s t SET (%s) = (%s) FROM jsonb_populate_record(NULL::%s, $1) s WHERE %s',
        target::text, set_cols, set_vals, target::text, pk_pred) USING r.after;
    END IF;
    applied := applied + 1;
  END LOOP;

  RETURN applied;
END $$;

ALTER TABLE pgit.changes ADD COLUMN IF NOT EXISTS commit_sha bytea;
CREATE INDEX IF NOT EXISTS changes_commit_idx ON pgit.changes (commit_sha);

CREATE OR REPLACE FUNCTION pgit.ancestry(from_sha bytea, to_sha bytea) RETURNS bytea[]
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE w AS (
    SELECT c.sha, c.parent_sha FROM pgit.commits c WHERE c.sha = to_sha
    UNION ALL
    SELECT c.sha, c.parent_sha
    FROM w JOIN pgit.commits c ON c.sha = w.parent_sha
    WHERE w.sha IS DISTINCT FROM from_sha
  )
  SELECT array_agg(sha) FROM w WHERE sha IS DISTINCT FROM from_sha
$$;

CREATE OR REPLACE FUNCTION pgit.diff_journal(a_sha bytea, b_sha bytea)
RETURNS TABLE (tbl text, k text, op text, before jsonb, after jsonb)
LANGUAGE sql STABLE AS $$
  WITH path AS (SELECT unnest(pgit.ancestry(a_sha, b_sha)) AS sha),
  touched AS (
    SELECT c.tbl, c.pk::text AS k, c.before, c.after, c.id
    FROM pgit.changes c JOIN path p ON p.sha = c.commit_sha
  ),
  coalesced AS (
    SELECT touched.tbl, touched.k,
           (array_agg(touched.before ORDER BY touched.id))[1]      AS first_before,
           (array_agg(touched.after  ORDER BY touched.id DESC))[1] AS last_after
    FROM touched GROUP BY touched.tbl, touched.k
  )
  SELECT coalesced.tbl, coalesced.k,
         CASE
           WHEN first_before IS NULL THEN 'INSERT'
           WHEN last_after  IS NULL THEN 'DELETE'
           ELSE 'UPDATE'
         END,
         first_before, last_after
  FROM coalesced
  WHERE first_before IS DISTINCT FROM last_after
$$;

CREATE OR REPLACE FUNCTION pgit.live_hash(target regclass, key_hex text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT encode(r.hash, 'hex')
  FROM pgit.row_hashes(target) r
  WHERE encode(r.key_bytes, 'hex') = key_hex
$$;

CREATE OR REPLACE FUNCTION pgit.revert(target_sha bytea) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  parent    bytea;
  r         record;
  applied   int := 0;
  conflicts bigint;
  found_it  boolean;
BEGIN
  SELECT true, c.parent_sha INTO found_it, parent
  FROM pgit.commits c WHERE c.sha = target_sha;

  IF NOT COALESCE(found_it, false) THEN
    RAISE EXCEPTION 'pgit: unknown commit %', encode(target_sha, 'hex');
  END IF;

  FOR r IN SELECT DISTINCT t.tbl FROM pgit.trees t WHERE t.commit_sha = target_sha LOOP
    SELECT count(*) INTO conflicts
    FROM pgit.diff(parent, target_sha, r.tbl) d
    WHERE pgit.live_hash(r.tbl::regclass, d.k) IS DISTINCT FROM
          (SELECT lo.rh FROM pgit.lookup(
             (SELECT t2.root_hash FROM pgit.trees t2
              WHERE t2.commit_sha = target_sha AND t2.tbl = r.tbl), d.k) lo);

    IF conflicts > 0 THEN
      RAISE EXCEPTION 'pgit: % row(s) in % changed since commit %, refusing to revert',
        conflicts, r.tbl, encode(target_sha, 'hex');
    END IF;
  END LOOP;

  PERFORM set_config('session_replication_role', 'replica', true);
  SET CONSTRAINTS ALL DEFERRED;

  FOR r IN SELECT DISTINCT t.tbl FROM pgit.trees t WHERE t.commit_sha = target_sha LOOP
    applied := applied + pgit.apply_diff(r.tbl::regclass, target_sha, parent, r.tbl);
  END LOOP;

  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM set_config('session_replication_role', 'origin', true);

  RETURN applied;
END $$;

CREATE OR REPLACE FUNCTION pgit.blame(tbl_name text, key_value text)
RETURNS TABLE (col text, commit_sha bytea, actor text, at timestamptz, value jsonb)
LANGUAGE sql STABLE AS $$
  WITH touching AS (
    SELECT c.id, c.op, c.before, c.after, c.commit_sha, c.actor, c.at
    FROM pgit.changes c
    WHERE c.tbl = tbl_name
      AND pgit.row_matches(tbl_name, COALESCE(c.after, c.before), key_value)
  ),
  cols AS (
    SELECT DISTINCT j.key AS col
    FROM touching t, LATERAL jsonb_object_keys(COALESCE(t.after, t.before)) AS j(key)
  ),
  attributed AS (
    SELECT cols.col, t.id, t.commit_sha, t.actor, t.at, t.after -> cols.col AS value
    FROM cols CROSS JOIN touching t
    WHERE t.op = 'INSERT'
       OR COALESCE(t.before -> cols.col, 'null'::jsonb)
          IS DISTINCT FROM COALESCE(t.after -> cols.col, 'null'::jsonb)
  )
  SELECT DISTINCT ON (a.col) a.col, a.commit_sha, a.actor, a.at, a.value
  FROM attributed a
  ORDER BY a.col, a.id DESC
$$;

CREATE OR REPLACE FUNCTION pgit.short_sha(v bytea) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT substring(encode(v, 'hex') FROM 1 FOR 7)
$$;

CREATE OR REPLACE FUNCTION pgit.log(start_sha bytea DEFAULT NULL, pathspec text DEFAULT NULL)
RETURNS TABLE (depth int, sha bytea, parent_sha bytea, author text, message text, at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE walk AS (
    SELECT 0 AS depth, c.sha, c.parent_sha, c.author, c.message, c.at
    FROM pgit.commits c
    WHERE c.sha = COALESCE(start_sha, pgit.resolve(pgit.head()))
    UNION ALL
    SELECT w.depth + 1, c.sha, c.parent_sha, c.author, c.message, c.at
    FROM walk w
    JOIN pgit.commits c ON c.sha = w.parent_sha
  )
  SELECT w.depth, w.sha, w.parent_sha, w.author, w.message, w.at
  FROM walk w
  WHERE pathspec IS NULL
     OR EXISTS (SELECT 1 FROM pgit.diff(w.parent_sha, w.sha, pathspec))
  ORDER BY w.depth
$$;

CREATE OR REPLACE FUNCTION pgit.show(target_sha bytea, pathspec text DEFAULT NULL)
RETURNS TABLE (tbl text, k text, op text, before jsonb, after jsonb)
LANGUAGE sql STABLE AS $$
  SELECT d.tbl, d.k, d.op, d.before, d.after
  FROM pgit.diff(
    (SELECT c.parent_sha FROM pgit.commits c WHERE c.sha = target_sha),
    target_sha,
    pathspec
  ) d
$$;

CREATE OR REPLACE FUNCTION pgit.is_dirty() RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
  h bytea := pgit.resolve(pgit.head());
  r record;
BEGIN
  IF h IS NULL THEN
    RETURN EXISTS (SELECT 1 FROM pgit.changes);
  END IF;

  FOR r IN SELECT t.tbl FROM pgit.tracked t LOOP
    IF pgit.write_tree(r.tbl) IS DISTINCT FROM
       (SELECT t2.root_hash FROM pgit.trees t2
        WHERE t2.commit_sha = h AND t2.tbl = r.tbl::text) THEN
      RETURN true;
    END IF;
  END LOOP;

  RETURN false;
END $$;

CREATE OR REPLACE FUNCTION pgit.branch(branch_name text, at_sha bytea DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  target bytea := COALESCE(at_sha, pgit.resolve(pgit.head()));
BEGIN
  IF target IS NULL THEN
    RAISE EXCEPTION 'pgit: nothing committed yet, cannot branch';
  END IF;

  IF EXISTS (SELECT 1 FROM pgit.refs r WHERE r.name = branch_name) THEN
    RAISE EXCEPTION 'pgit: branch % already exists', branch_name;
  END IF;

  INSERT INTO pgit.refs (name, sha) VALUES (branch_name, target);
END $$;

CREATE OR REPLACE FUNCTION pgit.branches()
RETURNS TABLE (name text, sha bytea, is_head boolean)
LANGUAGE sql STABLE AS $$
  SELECT r.name, r.sha, r.name = pgit.head() FROM pgit.refs r ORDER BY r.name
$$;

CREATE OR REPLACE FUNCTION pgit.checkout(branch_name text, force boolean DEFAULT false) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  cur     bytea := pgit.resolve(pgit.head());
  tgt     bytea := pgit.resolve(branch_name);
  r       record;
  applied int := 0;
BEGIN
  IF tgt IS NULL THEN
    RAISE EXCEPTION 'pgit: unknown branch %', branch_name;
  END IF;

  PERFORM pgit.assert_live_schema(tgt);

  IF NOT force AND pgit.is_dirty() THEN
    RAISE EXCEPTION 'pgit: uncommitted changes present, refusing to checkout %', branch_name;
  END IF;

  PERFORM set_config('session_replication_role', 'replica', true);
  SET CONSTRAINTS ALL DEFERRED;

  FOR r IN SELECT DISTINCT t.tbl FROM pgit.trees t WHERE t.commit_sha IN (cur, tgt) LOOP
    applied := applied + pgit.apply_diff(r.tbl::regclass, cur, tgt, r.tbl);
  END LOOP;

  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM set_config('session_replication_role', 'origin', true);

  DELETE FROM pgit.changes WHERE commit_sha IS NULL;
  UPDATE pgit.meta SET value = branch_name WHERE key = 'head';

  RETURN applied;
END $$;

CREATE OR REPLACE FUNCTION pgit.delete_branch(branch_name text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF branch_name = pgit.head() THEN
    RAISE EXCEPTION 'pgit: cannot delete %, it is the checked out branch', branch_name;
  END IF;

  DELETE FROM pgit.refs r WHERE r.name = branch_name;
END $$;

ALTER TABLE pgit.commits ADD COLUMN IF NOT EXISTS parent2_sha bytea REFERENCES pgit.commits(sha);
CREATE SEQUENCE IF NOT EXISTS pgit.merge_seq;

CREATE TABLE IF NOT EXISTS pgit.conflicts (
  id       bigserial PRIMARY KEY,
  merge_id bigint NOT NULL,
  tbl      text   NOT NULL,
  k        text   NOT NULL,
  col      text,
  base     jsonb,
  ours     jsonb,
  theirs   jsonb
);

CREATE OR REPLACE FUNCTION pgit.ancestors(from_sha bytea)
RETURNS TABLE (a bytea)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE w AS (
    SELECT c.sha, c.parent_sha, c.parent2_sha FROM pgit.commits c WHERE c.sha = from_sha
    UNION
    SELECT c.sha, c.parent_sha, c.parent2_sha
    FROM w JOIN pgit.commits c ON c.sha IN (w.parent_sha, w.parent2_sha)
  )
  SELECT w.sha FROM w
$$;

CREATE OR REPLACE FUNCTION pgit.merge_base(a_sha bytea, b_sha bytea) RETURNS bytea
LANGUAGE plpgsql STABLE AS $$
DECLARE
  n   int;
  res bytea;
BEGIN
  WITH common AS (
    SELECT x.a AS s FROM pgit.ancestors(a_sha) x
    INTERSECT
    SELECT y.a FROM pgit.ancestors(b_sha) y
  ),
  best AS (
    SELECT c.s FROM common c
    WHERE NOT EXISTS (
      SELECT 1 FROM common c2
      WHERE c2.s <> c.s AND c.s IN (SELECT z.a FROM pgit.ancestors(c2.s) z)
    )
  )
  SELECT count(*), min(b.s) INTO n, res FROM best b;

  IF n = 0 THEN
    RAISE EXCEPTION 'pgit: the two commits share no history';
  END IF;

  IF n > 1 THEN
    RAISE EXCEPTION 'pgit: % merge bases (criss-cross history), refusing to guess', n;
  END IF;

  RETURN res;
END $$;

CREATE OR REPLACE FUNCTION pgit.merge_plan(base_sha bytea, our_sha bytea, their_sha bytea)
RETURNS TABLE (tbl text, k text, action text, merged jsonb, conflict_col text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  t     record;
  key   record;
  broot bytea; oroot bytea; troot bytea;
  bimg  jsonb; oimg  jsonb; timg  jsonb;
  col   text;  bv jsonb; ov jsonb; tv jsonb;
  out_img jsonb; hit boolean; cc text;
BEGIN
  FOR t IN
    SELECT DISTINCT x.tbl AS name FROM pgit.trees x
    WHERE x.commit_sha IN (base_sha, our_sha, their_sha)
  LOOP
    SELECT x.root_hash INTO broot FROM pgit.trees x WHERE x.commit_sha = base_sha  AND x.tbl = t.name;
    SELECT x.root_hash INTO oroot FROM pgit.trees x WHERE x.commit_sha = our_sha   AND x.tbl = t.name;
    SELECT x.root_hash INTO troot FROM pgit.trees x WHERE x.commit_sha = their_sha AND x.tbl = t.name;

    FOR key IN
      SELECT d.k AS kk FROM pgit.diff_tree(broot, oroot) d
      UNION
      SELECT d.k AS kk FROM pgit.diff_tree(broot, troot) d
    LOOP
      SELECT l.v INTO bimg FROM pgit.lookup(broot, key.kk) l;
      SELECT l.v INTO oimg FROM pgit.lookup(oroot, key.kk) l;
      SELECT l.v INTO timg FROM pgit.lookup(troot, key.kk) l;

      IF oimg IS NOT DISTINCT FROM timg THEN CONTINUE; END IF;

      IF oimg IS NOT DISTINCT FROM bimg THEN
        tbl := t.name; k := key.kk;
        action := CASE WHEN timg IS NULL THEN 'delete' ELSE 'upsert' END;
        merged := COALESCE(timg, oimg);
        conflict_col := NULL;
        RETURN NEXT;
        CONTINUE;
      END IF;

      IF timg IS NOT DISTINCT FROM bimg THEN CONTINUE; END IF;

      IF oimg IS NULL OR timg IS NULL THEN
        tbl := t.name; k := key.kk; action := 'conflict';
        merged := NULL; conflict_col := NULL;
        RETURN NEXT;
        CONTINUE;
      END IF;

      out_img := oimg; hit := false; cc := NULL;

      FOR col IN SELECT jsonb_object_keys(COALESCE(bimg, oimg)) LOOP
        bv := bimg -> col; ov := oimg -> col; tv := timg -> col;
        IF ov IS NOT DISTINCT FROM tv THEN
          CONTINUE;
        ELSIF ov IS NOT DISTINCT FROM bv THEN
          out_img := jsonb_set(out_img, ARRAY[col], COALESCE(tv, 'null'::jsonb));
        ELSIF tv IS NOT DISTINCT FROM bv THEN
          CONTINUE;
        ELSE
          hit := true; cc := col; EXIT;
        END IF;
      END LOOP;

      tbl := t.name; k := key.kk;
      IF hit THEN
        action := 'conflict'; merged := NULL; conflict_col := cc;
      ELSE
        action := 'upsert'; merged := out_img; conflict_col := NULL;
      END IF;
      RETURN NEXT;
    END LOOP;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION pgit.apply_row(target regclass, action text, img jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  pk       text[] := pgit.pk_columns(target);
  cols     text[] := pgit.all_columns(target);
  pk_pred  text; set_cols text; set_vals text;
  touched  int;
BEGIN
  SELECT string_agg(format('t.%I = s.%I', c, c), ' AND ') INTO pk_pred FROM unnest(pk) c;
  SELECT string_agg(format('%I', c), ', ')  INTO set_cols FROM unnest(cols) c;
  SELECT string_agg(format('s.%I', c), ', ') INTO set_vals FROM unnest(cols) c;

  IF action = 'delete' THEN
    EXECUTE format('DELETE FROM %s t USING jsonb_populate_record(NULL::%s, $1) s WHERE %s',
                   target::text, target::text, pk_pred) USING img;
    RETURN;
  END IF;

  EXECUTE format('UPDATE %s t SET (%s) = (%s) FROM jsonb_populate_record(NULL::%s, $1) s WHERE %s',
                 target::text, set_cols, set_vals, target::text, pk_pred) USING img;
  GET DIAGNOSTICS touched = ROW_COUNT;

  IF touched = 0 THEN
    EXECUTE format('INSERT INTO %s SELECT * FROM jsonb_populate_record(NULL::%s, $1)',
                   target::text, target::text) USING img;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgit.merge(branch_name text, msg text DEFAULT NULL) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  ours    bytea := pgit.resolve(pgit.head());
  theirs  bytea := pgit.resolve(branch_name);
  base    bytea;
  p       record;
  r       record;
  n       int := 0;
  mid     bigint;
  summary text;
  roots   jsonb;
  new_sha bytea;
  ts      timestamptz := now();
  who     text := COALESCE(pgit.actor(), 'merge');
BEGIN
  IF theirs IS NULL THEN
    RAISE EXCEPTION 'pgit: unknown branch %', branch_name;
  END IF;

  base := pgit.merge_base(ours, theirs);

  IF base = theirs THEN
    RETURN 0;
  END IF;

  IF base = ours THEN
    SET CONSTRAINTS ALL DEFERRED;
    FOR r IN SELECT DISTINCT x.tbl FROM pgit.trees x WHERE x.commit_sha IN (ours, theirs) LOOP
      PERFORM pgit.apply_diff(r.tbl::regclass, ours, theirs, r.tbl);
    END LOOP;
    SET CONSTRAINTS ALL IMMEDIATE;
    PERFORM pgit.advance_ref(pgit.head(), ours, theirs);
    DELETE FROM pgit.changes WHERE commit_sha IS NULL;
    RETURN 0;
  END IF;

  PERFORM pgit.assert_same_schema(ours, theirs);

  SELECT count(*) INTO n FROM pgit.merge_plan(base, ours, theirs) mp WHERE mp.action = 'conflict';

  IF n > 0 THEN
    mid := nextval('pgit.merge_seq');
    INSERT INTO pgit.conflicts (merge_id, tbl, k, col, base, ours, theirs)
    SELECT mid, mp.tbl, mp.k, mp.conflict_col,
      (SELECT l.v FROM pgit.lookup((SELECT x.root_hash FROM pgit.trees x
                                    WHERE x.commit_sha = base AND x.tbl = mp.tbl), mp.k) l),
      (SELECT l.v FROM pgit.lookup((SELECT x.root_hash FROM pgit.trees x
                                    WHERE x.commit_sha = ours AND x.tbl = mp.tbl), mp.k) l),
      (SELECT l.v FROM pgit.lookup((SELECT x.root_hash FROM pgit.trees x
                                    WHERE x.commit_sha = theirs AND x.tbl = mp.tbl), mp.k) l)
    FROM pgit.merge_plan(base, ours, theirs) mp
    WHERE mp.action = 'conflict';
    RETURN n;
  END IF;

  SET CONSTRAINTS ALL DEFERRED;
  FOR p IN SELECT * FROM pgit.merge_plan(base, ours, theirs) LOOP
    PERFORM pgit.apply_row(p.tbl::regclass, p.action, p.merged);
  END LOOP;
  SET CONSTRAINTS ALL IMMEDIATE;

  roots   := pgit.snapshot_trees(ours);
  summary := pgit.roots_summary(roots);
  new_sha := pgit.hash(encode(ours, 'hex') || E'\n' || encode(theirs, 'hex') || E'\n' ||
                       COALESCE(msg, 'merge ' || branch_name) || E'\n' ||
                       to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || E'\n' ||
                       summary);

  INSERT INTO pgit.commits (sha, parent_sha, parent2_sha, author, message, at)
  VALUES (new_sha, ours, theirs, who, COALESCE(msg, 'merge ' || branch_name), ts)
  ON CONFLICT (sha) DO NOTHING;

  INSERT INTO pgit.trees (commit_sha, tbl, root_hash)
  SELECT new_sha, e.key, decode(e.value, 'hex') FROM jsonb_each_text(roots) e
  ON CONFLICT DO NOTHING;

  PERFORM pgit.record_schemas(new_sha);

  UPDATE pgit.changes SET commit_sha = new_sha WHERE commit_sha IS NULL;
  PERFORM pgit.advance_ref(pgit.head(), ours, new_sha);

  RETURN 0;
END $$;

CREATE TABLE IF NOT EXISTS pgit.rebase_state (
  branch       text  PRIMARY KEY,
  original_sha bytea NOT NULL,
  onto_sha     bytea NOT NULL
);

CREATE OR REPLACE FUNCTION pgit.record_conflicts(base_sha bytea, our_sha bytea, their_sha bytea)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  mid bigint := nextval('pgit.merge_seq');
  n   int;
BEGIN
  INSERT INTO pgit.conflicts (merge_id, tbl, k, col, base, ours, theirs)
  SELECT mid, mp.tbl, mp.k, mp.conflict_col,
    (SELECT l.v FROM pgit.lookup((SELECT x.root_hash FROM pgit.trees x
                                  WHERE x.commit_sha = base_sha AND x.tbl = mp.tbl), mp.k) l),
    (SELECT l.v FROM pgit.lookup((SELECT x.root_hash FROM pgit.trees x
                                  WHERE x.commit_sha = our_sha AND x.tbl = mp.tbl), mp.k) l),
    (SELECT l.v FROM pgit.lookup((SELECT x.root_hash FROM pgit.trees x
                                  WHERE x.commit_sha = their_sha AND x.tbl = mp.tbl), mp.k) l)
  FROM pgit.merge_plan(base_sha, our_sha, their_sha) mp
  WHERE mp.action = 'conflict';

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION pgit.cherry_pick(target_sha bytea, msg text DEFAULT NULL) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  ours    bytea := pgit.resolve(pgit.head());
  base    bytea;
  who     text;
  m       text;
  p       record;
  n       int;
  summary text;
  roots   jsonb;
  new_sha bytea;
  ts      timestamptz := clock_timestamp();
BEGIN
  SELECT c.parent_sha, c.author, c.message INTO base, who, m
  FROM pgit.commits c WHERE c.sha = target_sha;

  IF who IS NULL AND m IS NULL THEN
    RAISE EXCEPTION 'pgit: unknown commit %', encode(target_sha, 'hex');
  END IF;

  PERFORM pgit.assert_same_schema(target_sha, ours);

  SELECT count(*) INTO n FROM pgit.merge_plan(base, ours, target_sha) mp
  WHERE mp.action = 'conflict';

  IF n > 0 THEN
    PERFORM pgit.record_conflicts(base, ours, target_sha);
    RETURN n;
  END IF;

  SET CONSTRAINTS ALL DEFERRED;
  FOR p IN SELECT * FROM pgit.merge_plan(base, ours, target_sha) LOOP
    PERFORM pgit.apply_row(p.tbl::regclass, p.action, p.merged);
  END LOOP;
  SET CONSTRAINTS ALL IMMEDIATE;

  roots   := pgit.snapshot_trees(ours);
  summary := pgit.roots_summary(roots);
  new_sha := pgit.commit_sha(ours, who, COALESCE(msg, m), ts, summary);

  INSERT INTO pgit.commits (sha, parent_sha, author, message, at)
  VALUES (new_sha, ours, who, COALESCE(msg, m), ts)
  ON CONFLICT (sha) DO NOTHING;

  INSERT INTO pgit.trees (commit_sha, tbl, root_hash)
  SELECT new_sha, e.key, decode(e.value, 'hex') FROM jsonb_each_text(roots) e
  ON CONFLICT DO NOTHING;

  PERFORM pgit.record_schemas(new_sha);

  UPDATE pgit.changes SET commit_sha = new_sha WHERE commit_sha IS NULL;
  PERFORM pgit.advance_ref(pgit.head(), ours, new_sha);

  RETURN 0;
END $$;

CREATE OR REPLACE FUNCTION pgit.materialise(from_sha bytea, to_sha bytea) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r       record;
  applied int := 0;
BEGIN
  SET CONSTRAINTS ALL DEFERRED;
  FOR r IN SELECT DISTINCT x.tbl FROM pgit.trees x WHERE x.commit_sha IN (from_sha, to_sha) LOOP
    applied := applied + pgit.apply_diff(r.tbl::regclass, from_sha, to_sha, r.tbl);
  END LOOP;
  SET CONSTRAINTS ALL IMMEDIATE;
  DELETE FROM pgit.changes WHERE commit_sha IS NULL;
  RETURN applied;
END $$;

CREATE OR REPLACE FUNCTION pgit.rebase(onto_branch text) RETURNS int
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  cur_branch text := pgit.head();
  ours   bytea := pgit.resolve(cur_branch);
  onto   bytea := pgit.resolve(onto_branch);
  base   bytea;
  r      record;
  n      int;
BEGIN
  IF onto IS NULL THEN
    RAISE EXCEPTION 'pgit: unknown branch %', onto_branch;
  END IF;

  base := pgit.merge_base(ours, onto);

  IF base = onto THEN
    RETURN 0;
  END IF;

  DROP TABLE IF EXISTS pgit_replay;
  CREATE TEMP TABLE pgit_replay ON COMMIT DROP AS
    SELECT l.depth, l.sha FROM pgit.log(ours) l
    WHERE l.sha NOT IN (SELECT a.a FROM pgit.ancestors(base) a);

  INSERT INTO pgit.rebase_state (branch, original_sha, onto_sha)
  VALUES (cur_branch, ours, onto)
  ON CONFLICT (branch) DO UPDATE SET original_sha = EXCLUDED.original_sha, onto_sha = EXCLUDED.onto_sha;

  PERFORM pgit.materialise(ours, onto);
  PERFORM pgit.advance_ref(cur_branch, ours, onto);

  FOR r IN SELECT sha FROM pgit_replay ORDER BY depth DESC LOOP
    n := pgit.cherry_pick(r.sha);
    IF n > 0 THEN
      RETURN n;
    END IF;
  END LOOP;

  DELETE FROM pgit.rebase_state s WHERE s.branch = cur_branch;
  RETURN 0;
END $$;

CREATE OR REPLACE FUNCTION pgit.rebase_abort() RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  st record;
BEGIN
  SELECT * INTO st FROM pgit.rebase_state s WHERE s.branch = pgit.head();

  IF st IS NULL THEN
    RAISE EXCEPTION 'pgit: no rebase in progress on %', pgit.head();
  END IF;

  PERFORM pgit.materialise(pgit.resolve(pgit.head()), st.original_sha);
  UPDATE pgit.refs SET sha = st.original_sha WHERE name = st.branch;
  DELETE FROM pgit.conflicts;
  DELETE FROM pgit.rebase_state s WHERE s.branch = st.branch;
END $$;

CREATE TABLE IF NOT EXISTS pgit.schemas (
  commit_sha  bytea NOT NULL,
  tbl         text  NOT NULL,
  fingerprint bytea NOT NULL,
  columns     jsonb NOT NULL,
  PRIMARY KEY (commit_sha, tbl)
);

CREATE OR REPLACE FUNCTION pgit.schema_columns(target regclass) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_agg(jsonb_build_object('name', a.attname,
                                      'type', format_type(a.atttypid, a.atttypmod))
                   ORDER BY a.attname)
  FROM pg_attribute a
  WHERE a.attrelid = target AND a.attnum > 0 AND NOT a.attisdropped
$$;

CREATE OR REPLACE FUNCTION pgit.schema_fingerprint(target regclass) RETURNS bytea
LANGUAGE sql STABLE AS $$
  SELECT pgit.hash(pgit.schema_columns(target)::text)
$$;

CREATE OR REPLACE FUNCTION pgit.record_schemas(new_sha bytea) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO pgit.schemas (commit_sha, tbl, fingerprint, columns)
  SELECT new_sha, x.tbl::text, pgit.schema_fingerprint(x.tbl), pgit.schema_columns(x.tbl)
  FROM pgit.tracked x
  ON CONFLICT DO NOTHING
$$;

CREATE OR REPLACE FUNCTION pgit.assert_same_schema(a_sha bytea, b_sha bytea) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
  bad record;
BEGIN
  SELECT sa.tbl, sa.columns AS acols, sb.columns AS bcols
  INTO bad
  FROM pgit.schemas sa
  JOIN pgit.schemas sb ON sb.tbl = sa.tbl AND sb.commit_sha = b_sha
  WHERE sa.commit_sha = a_sha AND sa.fingerprint <> sb.fingerprint
  LIMIT 1;

  IF bad.tbl IS NOT NULL THEN
    RAISE EXCEPTION 'pgit: table % has a different shape in the two commits, refusing to replay across a schema change (% versus %)',
      bad.tbl, bad.acols::text, bad.bcols::text;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgit.key_index_name(target regclass) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT 'pgit_key_' || target::oid::text
$$;

CREATE OR REPLACE FUNCTION pgit.ensure_key_index(target regclass) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %s (((%s) COLLATE "C"))',
                 pgit.key_index_name(target), target::text, pgit.pk_canon_expr(target));
EXCEPTION WHEN others THEN
  RAISE NOTICE 'pgit: no key index on % (%), range reads will scan', target::text, SQLERRM;
END $$;

CREATE OR REPLACE FUNCTION pgit.row_hashes_range(target regclass, lo bytea, hi bytea)
RETURNS TABLE (key_bytes bytea, hash bytea, image jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  pk text := pgit.pk_canon_expr(target);
BEGIN
  RETURN QUERY EXECUTE format(
    'SELECT convert_to(%s, ''UTF8''), pgit.hash(%s), to_jsonb(t)
     FROM %s t
     WHERE (%s) COLLATE "C" >= $1
       AND ($2 IS NULL OR (%s) COLLATE "C" < $2)',
    pk, pgit.row_canon_expr(target), target::text, pk, pk)
  USING convert_from(lo, 'UTF8'),
        CASE WHEN hi IS NULL THEN NULL ELSE convert_from(hi, 'UTF8') END;
END $$;

CREATE OR REPLACE FUNCTION pgit.leaf_list(root bytea)
RETURNS TABLE (k text, h text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  lvl int := pgit.node_level(root);
  e   jsonb;
BEGIN
  IF lvl IS NULL THEN RETURN; END IF;

  IF lvl = 0 THEN
    RETURN QUERY
      SELECT (SELECT min(x ->> 'k') FROM pgit.nodes n, jsonb_array_elements(pgit.entries_of(n.hash)) x
              WHERE n.hash = root),
             encode(root, 'hex');
    RETURN;
  END IF;

  IF lvl = 1 THEN
    RETURN QUERY SELECT i.k, i.ch FROM pgit.node_items(root) i ORDER BY i.k;
    RETURN;
  END IF;

  FOR e IN SELECT x FROM pgit.nodes n, jsonb_array_elements(pgit.entries_of(n.hash)) x
           WHERE n.hash = root ORDER BY x ->> 'k' LOOP
    RETURN QUERY SELECT * FROM pgit.leaf_list(decode(e ->> 'h', 'hex'));
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION pgit.build_up(lvl int) RETURNS bytea
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  n     bigint;
  depth int := lvl;
BEGIN
  PERFORM pgit.ensure_scratch();

  LOOP
    SELECT count(*) INTO n FROM pgit_lvl;
    IF n = 0 THEN RETURN pgit.hash(''::bytea); END IF;
    IF n = 1 THEN RETURN (SELECT hash FROM pgit_lvl); END IF;
    IF depth > 40 THEN RAISE EXCEPTION 'pgit: tree depth exceeded'; END IF;

    TRUNCATE pgit_grp;
    INSERT INTO pgit_grp
      WITH marked AS (
        SELECT key_bytes, hash, image,
               COALESCE(
                 SUM(CASE WHEN pgit.is_boundary(key_bytes) THEN 1 ELSE 0 END)
                   OVER (ORDER BY key_bytes ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS chunk
        FROM pgit_lvl
      )
      SELECT min(key_bytes),
             pgit.hash(string_agg(hash, ''::bytea ORDER BY key_bytes)),
             jsonb_agg(
               CASE WHEN depth = 0
                 THEN jsonb_build_object('k', encode(key_bytes, 'hex'), 'h', encode(hash, 'hex'), 'v', image)
                 ELSE jsonb_build_object('k', encode(key_bytes, 'hex'), 'h', encode(hash, 'hex'))
               END ORDER BY key_bytes)
      FROM marked GROUP BY chunk;

    INSERT INTO pgit.nodes (hash, level, entries)
    SELECT g.hash, depth, g.entries FROM pgit_grp g
    ON CONFLICT (hash) DO NOTHING;

    TRUNCATE pgit_lvl;
    INSERT INTO pgit_lvl SELECT g.key_bytes, g.hash, NULL::jsonb FROM pgit_grp g;
    depth := depth + 1;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION pgit.changed_keys(target regclass) RETURNS text[]
LANGUAGE plpgsql STABLE AS $$
DECLARE
  res text[];
BEGIN
  EXECUTE format(
    'SELECT array_agg(DISTINCT encode(convert_to(%s, ''UTF8''), ''hex''))
     FROM (SELECT COALESCE(c.after, c.before) AS img FROM pgit.changes c
           WHERE c.tbl = %L AND c.commit_sha IS NULL) s,
          LATERAL jsonb_populate_record(NULL::%s, s.img) t',
    pgit.pk_canon_expr(target), target::text, target::text)
  INTO res;

  RETURN COALESCE(res, '{}'::text[]);
END $$;

CREATE OR REPLACE FUNCTION pgit.write_tree_incremental(target regclass, prev_root bytea)
RETURNS bytea
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  changed text[] := pgit.changed_keys(target);
  region  record;
  hi_key  text;
BEGIN
  IF prev_root IS NULL OR COALESCE(pgit.node_level(prev_root), -1) < 1
     OR array_length(changed, 1) IS NULL
     OR array_length(changed, 1) > 10000 THEN
    RETURN pgit.write_tree(target);
  END IF;

  PERFORM pgit.ensure_scratch();

  TRUNCATE pgit_l1;
  INSERT INTO pgit_l1
    SELECT l.k, l.h,
           lead(l.k) OVER (ORDER BY l.k),
           row_number() OVER (ORDER BY l.k)
    FROM pgit.nodes_at_level(prev_root, 1) l;

  TRUNCATE pgit_l1hit;
  INSERT INTO pgit_l1hit
    SELECT DISTINCT o.rn FROM pgit_l1 o
    WHERE EXISTS (SELECT 1 FROM unnest(changed) c
                  WHERE c >= o.k AND (o.nk IS NULL OR c < o.nk));

  IF NOT EXISTS (SELECT 1 FROM pgit_l1hit) THEN
    INSERT INTO pgit_l1hit VALUES (1);
  END IF;

  INSERT INTO pgit_l1hit
  SELECT DISTINCT h.rn + d FROM pgit_l1hit h, (VALUES (-1), (1)) AS s(d)
  WHERE h.rn + d BETWEEN 1 AND (SELECT max(rn) FROM pgit_l1)
    AND h.rn + d NOT IN (SELECT rn FROM pgit_l1hit);

  TRUNCATE pgit_old;
  INSERT INTO pgit_old
    SELECT i.k, i.ch,
           lead(i.k) OVER (ORDER BY i.k),
           row_number() OVER (ORDER BY i.k)
    FROM pgit_l1 p
    JOIN pgit_l1hit hit ON hit.rn = p.rn
    CROSS JOIN LATERAL pgit.node_items(decode(p.h, 'hex')) i;

  TRUNCATE pgit_hit;
  INSERT INTO pgit_hit
    SELECT DISTINCT o.rn FROM pgit_old o
    WHERE EXISTS (SELECT 1 FROM unnest(changed) c
                  WHERE c >= o.k AND (o.nk IS NULL OR c < o.nk));

  IF NOT EXISTS (SELECT 1 FROM pgit_hit) THEN
    INSERT INTO pgit_hit VALUES (1);
  END IF;

  INSERT INTO pgit_hit
  SELECT DISTINCT h.rn + d FROM pgit_hit h, (VALUES (-1), (1)) AS s(d)
  WHERE h.rn + d BETWEEN 1 AND (SELECT max(rn) FROM pgit_old)
    AND h.rn + d NOT IN (SELECT rn FROM pgit_hit);

  TRUNCATE pgit_new;

  FOR region IN
    WITH h AS (SELECT DISTINCT rn FROM pgit_hit),
    grp AS (SELECT rn, rn - row_number() OVER (ORDER BY rn) AS g FROM h)
    SELECT min(rn) AS lo_rn, max(rn) AS hi_rn FROM grp GROUP BY g ORDER BY 1
  LOOP
    SELECT o.nk INTO hi_key FROM pgit_old o WHERE o.rn = region.hi_rn;

    TRUNCATE pgit_lvl;
    INSERT INTO pgit_lvl
      SELECT * FROM pgit.row_hashes_range(
        target,
        (SELECT decode(o.k, 'hex') FROM pgit_old o WHERE o.rn = region.lo_rn),
        CASE WHEN hi_key IS NULL THEN NULL ELSE decode(hi_key, 'hex') END);

    TRUNCATE pgit_grp;
    INSERT INTO pgit_grp
      WITH marked AS (
        SELECT key_bytes, hash, image,
               COALESCE(
                 SUM(CASE WHEN pgit.is_boundary(key_bytes) THEN 1 ELSE 0 END)
                   OVER (ORDER BY key_bytes ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS chunk
        FROM pgit_lvl
      )
      SELECT min(key_bytes),
             pgit.hash(string_agg(hash, ''::bytea ORDER BY key_bytes)),
             jsonb_agg(jsonb_build_object('k', encode(key_bytes, 'hex'),
                                          'h', encode(hash, 'hex'),
                                          'v', image) ORDER BY key_bytes)
      FROM marked GROUP BY chunk;

    INSERT INTO pgit.nodes (hash, level, entries)
    SELECT g.hash, 0, g.entries FROM pgit_grp g
    ON CONFLICT (hash) DO NOTHING;

    INSERT INTO pgit_new SELECT g.key_bytes, g.hash FROM pgit_grp g;
  END LOOP;

  TRUNCATE pgit_lvl;
  INSERT INTO pgit_lvl
    SELECT decode(o.k, 'hex'), decode(o.h, 'hex'), NULL::jsonb
    FROM pgit_old o WHERE o.rn NOT IN (SELECT rn FROM pgit_hit)
    UNION ALL
    SELECT key_bytes, hash, NULL::jsonb FROM pgit_new;

  PERFORM pgit.build_one_level(1);

  TRUNCATE pgit_lvl;
  INSERT INTO pgit_lvl
    SELECT decode(p.k, 'hex'), decode(p.h, 'hex'), NULL::jsonb
    FROM pgit_l1 p WHERE p.rn NOT IN (SELECT rn FROM pgit_l1hit)
    UNION ALL
    SELECT key_bytes, hash, NULL::jsonb FROM pgit_built;

  RETURN pgit.build_up(2);
END $$;

DROP FUNCTION IF EXISTS pgit.build_one_level(int);

CREATE OR REPLACE FUNCTION pgit.build_one_level(depth int, with_images boolean DEFAULT false)
RETURNS void
LANGUAGE plpgsql SET client_min_messages = warning AS $$
BEGIN
  PERFORM pgit.ensure_scratch();

  TRUNCATE pgit_grp;
  INSERT INTO pgit_grp
    WITH marked AS (
      SELECT key_bytes, hash, image,
             COALESCE(
               SUM(CASE WHEN pgit.is_boundary(key_bytes) THEN 1 ELSE 0 END)
                 OVER (ORDER BY key_bytes ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS chunk
      FROM pgit_lvl
    )
    SELECT min(key_bytes),
           pgit.hash(string_agg(hash, ''::bytea ORDER BY key_bytes)),
           jsonb_agg(
             CASE WHEN with_images
               THEN jsonb_build_object('k', encode(key_bytes, 'hex'), 'h', encode(hash, 'hex'), 'v', image)
               ELSE jsonb_build_object('k', encode(key_bytes, 'hex'), 'h', encode(hash, 'hex'))
             END ORDER BY key_bytes)
    FROM marked GROUP BY chunk;

  INSERT INTO pgit.nodes (hash, level, entries)
  SELECT g.hash, depth, g.entries FROM pgit_grp g
  ON CONFLICT (hash) DO NOTHING;

  TRUNCATE pgit_built;
  INSERT INTO pgit_built SELECT g.key_bytes, g.hash FROM pgit_grp g;
END $$;

DROP FUNCTION IF EXISTS pgit.snapshot_trees(bytea);

CREATE OR REPLACE FUNCTION pgit.snapshot_trees(parent bytea) RETURNS jsonb
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  r        record;
  root_val bytea;
  prev     bytea;
  roots    jsonb := '{}'::jsonb;
BEGIN
  FOR r IN SELECT t.tbl FROM pgit.tracked t ORDER BY t.tbl::text LOOP
    SELECT x.root_hash INTO prev FROM pgit.trees x
    WHERE x.commit_sha = parent AND x.tbl = r.tbl::text;

    root_val := pgit.write_tree_incremental(r.tbl, prev);
    roots := roots || jsonb_build_object(r.tbl::text, encode(root_val, 'hex'));
  END LOOP;

  RETURN roots;
END $$;

CREATE OR REPLACE FUNCTION pgit.roots_summary(roots jsonb) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(string_agg(e.key || ':' || e.value, E'\n' ORDER BY e.key), '')
  FROM jsonb_each_text(roots) e
$$;

CREATE OR REPLACE FUNCTION pgit.nodes_at_level(root bytea, want int)
RETURNS TABLE (k text, h text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  lvl int := pgit.node_level(root);
  e   jsonb;
BEGIN
  IF lvl IS NULL OR lvl < want THEN RETURN; END IF;

  IF lvl = want THEN
    RETURN QUERY
      SELECT (SELECT min(x ->> 'k') FROM pgit.nodes n, jsonb_array_elements(pgit.entries_of(n.hash)) x
              WHERE n.hash = root),
             encode(root, 'hex');
    RETURN;
  END IF;

  IF lvl = want + 1 THEN
    RETURN QUERY SELECT i.k, i.ch FROM pgit.node_items(root) i ORDER BY i.k;
    RETURN;
  END IF;

  FOR e IN SELECT x FROM pgit.nodes n, jsonb_array_elements(pgit.entries_of(n.hash)) x
           WHERE n.hash = root ORDER BY x ->> 'k' LOOP
    RETURN QUERY SELECT * FROM pgit.nodes_at_level(decode(e ->> 'h', 'hex'), want);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION pgit.journal_stmt() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  cols text[];
  pred text;
BEGIN
  SELECT pk_cols INTO cols FROM pgit.tracked WHERE tbl = TG_RELID::regclass;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO pgit.changes (txid, tbl, pk, op, before, after, actor, source)
    SELECT txid_current(), TG_TABLE_NAME, pgit.pk_of(to_jsonb(n), cols),
           'INSERT', NULL, to_jsonb(n), pgit.actor(), pgit.source()
    FROM newrows n;
    RETURN NULL;
  END IF;

  IF TG_OP = 'DELETE' THEN
    INSERT INTO pgit.changes (txid, tbl, pk, op, before, after, actor, source)
    SELECT txid_current(), TG_TABLE_NAME, pgit.pk_of(to_jsonb(o), cols),
           'DELETE', to_jsonb(o), NULL, pgit.actor(), pgit.source()
    FROM oldrows o;
    RETURN NULL;
  END IF;

  SELECT string_agg(format('o.%I = n.%I', c, c), ' AND ') INTO pred FROM unnest(cols) c;

  EXECUTE format(
    'INSERT INTO pgit.changes (txid, tbl, pk, op, before, after, actor, source)
     SELECT txid_current(), %L,
            pgit.pk_of(COALESCE(to_jsonb(n), to_jsonb(o)), %L::text[]),
            CASE WHEN o IS NULL THEN ''INSERT''
                 WHEN n IS NULL THEN ''DELETE''
                 ELSE ''UPDATE'' END,
            to_jsonb(o), to_jsonb(n), pgit.actor(), pgit.source()
     FROM oldrows o FULL OUTER JOIN newrows n ON %s',
    TG_TABLE_NAME, cols, pred);

  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION pgit.assert_live_schema(target_sha bytea) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
  bad record;
BEGIN
  SELECT s.tbl AS name, s.columns AS recorded,
         pgit.schema_columns(to_regclass(s.tbl)) AS live
  INTO bad
  FROM pgit.schemas s
  WHERE s.commit_sha = target_sha
    AND to_regclass(s.tbl) IS NOT NULL
    AND s.fingerprint <> pgit.schema_fingerprint(to_regclass(s.tbl))
  LIMIT 1;

  IF bad.name IS NOT NULL THEN
    RAISE EXCEPTION
      'pgit: % has a different shape now than in that commit, and checkout restores data but not shape. Now %, then %',
      bad.name, bad.live::text, bad.recorded::text;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgit.repack(max_depth int DEFAULT 1) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  grp          record;
  g            record;
  prev_hash    bytea;
  prev_entries jsonb;
  d            int;
  packed       int := 0;
  cand         jsonb;
BEGIN
  FOR grp IN
    SELECT n.level AS lv, n.entries -> 0 ->> 'k' AS fk
    FROM pgit.nodes n
    WHERE n.entries IS NOT NULL
    GROUP BY 1, 2
    HAVING count(*) > 1
  LOOP
    prev_hash := NULL; prev_entries := NULL; d := 0;

    FOR g IN
      SELECT n.hash, n.entries FROM pgit.nodes n
      WHERE n.level = grp.lv AND n.entries -> 0 ->> 'k' = grp.fk AND n.entries IS NOT NULL
      ORDER BY n.seq DESC
    LOOP
      IF prev_hash IS NULL OR d >= max_depth THEN
        prev_hash := g.hash; prev_entries := g.entries; d := 0;
        CONTINUE;
      END IF;

      cand := pgit.make_delta(prev_entries, g.entries);

      IF pg_column_size(cand) < pg_column_size(g.entries) THEN
        UPDATE pgit.nodes
        SET delta = cand, base_hash = prev_hash, entries = NULL
        WHERE hash = g.hash;
        packed := packed + 1;
        d := d + 1;
      ELSE
        d := 0;
      END IF;

      prev_hash := g.hash; prev_entries := g.entries;
    END LOOP;
  END LOOP;

  RETURN packed;
END $$;

CREATE OR REPLACE FUNCTION pgit.unpack() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  WITH resolved AS (
    SELECT x.hash, pgit.entries_of(x.hash) AS e FROM pgit.nodes x WHERE x.entries IS NULL
  )
  UPDATE pgit.nodes t
  SET entries = r.e, base_hash = NULL, delta = NULL
  FROM resolved r WHERE t.hash = r.hash;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
