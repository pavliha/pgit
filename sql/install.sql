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

CREATE OR REPLACE FUNCTION pgit.common_prefix(a text, b text) RETURNS int
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  lo int := 0;
  hi int := least(length(a), length(b));
  mid int;
BEGIN
  WHILE lo < hi LOOP
    mid := (lo + hi + 1) / 2;
    IF substr(a, 1, mid) = substr(b, 1, mid) THEN lo := mid; ELSE hi := mid - 1; END IF;
  END LOOP;
  RETURN lo;
END $$;

CREATE OR REPLACE FUNCTION pgit.common_suffix(a text, b text, cap int) RETURNS int
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  lo int := 0;
  hi int := greatest(cap, 0);
  mid int;
BEGIN
  WHILE lo < hi LOOP
    mid := (lo + hi + 1) / 2;
    IF right(a, mid) = right(b, mid) THEN lo := mid; ELSE hi := mid - 1; END IF;
  END LOOP;
  RETURN lo;
END $$;

CREATE OR REPLACE FUNCTION pgit.make_delta(base jsonb, target jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  a text := base::text;
  b text := target::text;
  p int;
  sfx int;
BEGIN
  p := pgit.common_prefix(a, b);
  sfx := pgit.common_suffix(a, b, least(length(a), length(b)) - p);

  RETURN jsonb_build_object(
    'p', p,
    's', sfx,
    'm', substr(b, p + 1, length(b) - p - sfx));
END $$;

CREATE OR REPLACE FUNCTION pgit.apply_delta_txt(base text, d jsonb) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT substr(base, 1, (d ->> 'p')::int)
      || (d ->> 'm')
      || right(base, (d ->> 's')::int)
$$;

CREATE OR REPLACE FUNCTION pgit.apply_delta(base jsonb, d jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT pgit.apply_delta_txt(base::text, d)::jsonb
$$;

CREATE OR REPLACE FUNCTION pgit.entries_of(h bytea) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  chain bytea[] := '{}';
  cur   bytea   := h;
  acc   jsonb;
  txt   text;
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

  txt := acc::text;

  FOR i IN REVERSE array_length(chain, 1)..1 LOOP
    SELECT n.delta INTO dl FROM pgit.nodes n WHERE n.hash = chain[i];
    txt := pgit.apply_delta_txt(txt, dl);
  END LOOP;

  RETURN txt::jsonb;
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
LANGUAGE plpgsql SET client_min_messages = warning AS $$
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
LANGUAGE plpgsql SET client_min_messages = warning AS $$
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

CREATE OR REPLACE FUNCTION pgit.apply_tree_diff(target regclass, a bytea, b bytea) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r       record;
  applied int := 0;
BEGIN
  FOR r IN SELECT * FROM pgit.diff_tree(a, b) LOOP
    IF r.op = 'INSERT' THEN
      PERFORM pgit.apply_row(target, 'upsert', r.after);
    ELSIF r.op = 'DELETE' THEN
      PERFORM pgit.apply_row(target, 'delete', r.before);
    ELSE
      PERFORM pgit.apply_row(target, 'upsert', r.after);
    END IF;
    applied := applied + 1;
  END LOOP;

  RETURN applied;
END $$;

CREATE OR REPLACE FUNCTION pgit.apply_diff(
  target regclass, a_sha bytea, b_sha bytea, source text DEFAULT NULL
) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  src text  := COALESCE(source, target::text);
  a   bytea;
  b   bytea;
BEGIN
  SELECT root_hash INTO a FROM pgit.trees WHERE commit_sha = a_sha AND tbl = src;
  SELECT root_hash INTO b FROM pgit.trees WHERE commit_sha = b_sha AND tbl = src;
  RETURN pgit.apply_tree_diff(target, a, b);
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
  guard     jsonb;
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

  guard := pgit.replay_begin();
  SET CONSTRAINTS ALL DEFERRED;

  FOR r IN SELECT DISTINCT t.tbl FROM pgit.trees t WHERE t.commit_sha = target_sha LOOP
    applied := applied + pgit.apply_diff(r.tbl::regclass, target_sha, parent, r.tbl);
  END LOOP;

  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM pgit.replay_end(guard);

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
  guard   jsonb;
BEGIN
  IF tgt IS NULL THEN
    RAISE EXCEPTION 'pgit: unknown branch %', branch_name;
  END IF;

  PERFORM pgit.assert_live_schema(tgt);

  IF NOT force AND pgit.is_dirty() THEN
    RAISE EXCEPTION 'pgit: uncommitted changes present, refusing to checkout %', branch_name;
  END IF;

  guard := pgit.replay_begin();
  SET CONSTRAINTS ALL DEFERRED;

  FOR r IN SELECT DISTINCT t.tbl FROM pgit.trees t WHERE t.commit_sha IN (cur, tgt) LOOP
    applied := applied + pgit.apply_diff(r.tbl::regclass, cur, tgt, r.tbl);
  END LOOP;

  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM pgit.replay_end(guard);

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

CREATE TABLE IF NOT EXISTS pgit.commit_parent (
  commit_sha bytea NOT NULL REFERENCES pgit.commits(sha) ON DELETE CASCADE,
  ord        int   NOT NULL CHECK (ord >= 2),
  parent_sha bytea NOT NULL REFERENCES pgit.commits(sha) ON DELETE CASCADE,
  PRIMARY KEY (commit_sha, ord)
);

CREATE INDEX IF NOT EXISTS pgit_commit_parent_parent_idx ON pgit.commit_parent (parent_sha);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'pgit' AND table_name = 'commits'
               AND column_name = 'parent2_sha') THEN
    EXECUTE $q$ INSERT INTO pgit.commit_parent (commit_sha, ord, parent_sha)
                SELECT sha, 2, parent2_sha FROM pgit.commits WHERE parent2_sha IS NOT NULL
                ON CONFLICT DO NOTHING $q$;
    EXECUTE 'ALTER TABLE pgit.commits DROP COLUMN parent2_sha';
  END IF;
END $$;

CREATE OR REPLACE VIEW pgit.parent_edge AS
  SELECT c.sha AS child, c.parent_sha AS parent, 1 AS ord
  FROM pgit.commits c WHERE c.parent_sha IS NOT NULL
  UNION ALL
  SELECT p.commit_sha, p.parent_sha, p.ord FROM pgit.commit_parent p;

CREATE OR REPLACE FUNCTION pgit.parents_of(c_sha bytea)
RETURNS TABLE (ord int, parent bytea)
LANGUAGE sql STABLE AS $$
  SELECT e.ord, e.parent FROM pgit.parent_edge e WHERE e.child = c_sha ORDER BY e.ord
$$;

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
    SELECT c.sha FROM pgit.commits c WHERE c.sha = from_sha
    UNION
    SELECT e.parent FROM w JOIN pgit.parent_edge e ON e.child = w.sha
  )
  SELECT w.sha FROM w
$$;

CREATE OR REPLACE FUNCTION pgit.merge_base(a_sha bytea, b_sha bytea) RETURNS bytea
LANGUAGE plpgsql AS $$
DECLARE
  arr bytea[];
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
  SELECT array_agg(b.s ORDER BY b.s) INTO arr FROM best b;

  IF arr IS NULL OR cardinality(arr) = 0 THEN
    RAISE EXCEPTION 'pgit: the two commits share no history';
  END IF;

  IF cardinality(arr) = 1 THEN
    RETURN arr[1];
  END IF;

  IF cardinality(arr) > 2 THEN
    RAISE EXCEPTION 'pgit: % merge bases; only a criss-cross of two is resolved automatically',
      cardinality(arr);
  END IF;

  RETURN pgit.virtual_merge(arr[1], arr[2]);
END $$;

CREATE OR REPLACE FUNCTION pgit.merge_plan_raw(base_sha bytea, our_sha bytea, their_sha bytea)
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

DROP FUNCTION IF EXISTS pgit.merge(text, text);

CREATE OR REPLACE FUNCTION pgit.merge(branch_name text, msg text DEFAULT NULL, opt text DEFAULT NULL)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  ours   bytea := pgit.resolve(pgit.head());
  theirs bytea := pgit.resolve(branch_name);
  base   bytea;
  r      record;
  n      int := 0;
  mid    bigint;
BEGIN
  IF theirs IS NULL THEN
    RAISE EXCEPTION 'pgit: unknown branch %', branch_name;
  END IF;

  IF opt IS NOT NULL AND opt NOT IN ('ours', 'theirs', 'ours-tree') THEN
    RAISE EXCEPTION 'pgit: unknown strategy option %, expected ours, theirs or ours-tree', opt;
  END IF;

  PERFORM pgit.assert_same_schema(ours, theirs);
  base := pgit.merge_base(ours, theirs);

  IF base = theirs THEN
    RETURN 0;
  END IF;

  IF opt = 'ours-tree' THEN
    mid := nextval('pgit.merge_seq');
    INSERT INTO pgit.merges (id, branch, ours_sha, theirs_sha, base_sha, msg)
    VALUES (mid, pgit.head(), ours, theirs, ours, COALESCE(msg, 'merge ' || branch_name || ' (ours tree)'));
    RETURN pgit.merge_finish(mid);
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

  mid := nextval('pgit.merge_seq');
  INSERT INTO pgit.merges (id, branch, ours_sha, theirs_sha, base_sha, msg)
  VALUES (mid, pgit.head(), ours, theirs, base, COALESCE(msg, 'merge ' || branch_name));

  n := pgit.record_conflicts(mid, base, ours, theirs);

  IF n > 0 THEN
    PERFORM pgit.rerere_apply(mid);
    SELECT count(*) INTO n FROM pgit.conflicts WHERE merge_id = mid AND NOT resolved;
  END IF;

  IF n > 0 AND opt IN ('ours', 'theirs') THEN
    PERFORM pgit.resolve_all(mid, opt);
    n := 0;
  END IF;

  IF n > 0 THEN
    RETURN n;
  END IF;

  RETURN pgit.merge_finish(mid);
END $$;

CREATE TABLE IF NOT EXISTS pgit.rebase_state (
  branch       text  PRIMARY KEY,
  original_sha bytea NOT NULL,
  onto_sha     bytea NOT NULL
);

DROP FUNCTION IF EXISTS pgit.record_conflicts(bytea, bytea, bytea);

CREATE OR REPLACE FUNCTION pgit.record_conflicts(mid bigint, base_sha bytea, our_sha bytea, their_sha bytea)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n int;
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
    PERFORM pgit.record_conflicts(nextval('pgit.merge_seq'), base, ours, target_sha);
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

ALTER TABLE pgit.schemas ADD COLUMN IF NOT EXISTS pk_cols text[];

CREATE OR REPLACE FUNCTION pgit.record_schemas(new_sha bytea) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO pgit.schemas (commit_sha, tbl, fingerprint, columns, pk_cols)
  SELECT new_sha, x.tbl::text, pgit.schema_fingerprint(x.tbl), pgit.schema_columns(x.tbl), x.pk_cols
  FROM pgit.tracked x
  ON CONFLICT DO NOTHING
$$;

CREATE OR REPLACE FUNCTION pgit.assert_same_schema(a_sha bytea, b_sha bytea) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
  bad record;
  ren record;
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

  SELECT * INTO ren FROM pgit.table_renames(a_sha, b_sha) r
  ORDER BY r.similarity DESC, r.old_tbl LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'pgit: % looks renamed to % between these commits (% match, % of rows in common); following a table rename through a replay is not supported, rename it back or replay table by table',
      ren.old_tbl, ren.new_tbl, ren.kind, round(ren.similarity * 100) || '%';
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

CREATE OR REPLACE FUNCTION pgit.repack(max_depth int DEFAULT 4) RETURNS int
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

CREATE OR REPLACE FUNCTION pgit.replay_begin() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  saved jsonb := '[]'::jsonb;
  r     record;
BEGIN
  BEGIN
    PERFORM set_config('session_replication_role', 'replica', true);
    RETURN jsonb_build_object('mode', 'session');
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  FOR r IN
    SELECT t.tbl::text AS tbl, tg.tgname, tg.tgenabled
    FROM pgit.tracked t
    JOIN pg_trigger tg ON tg.tgrelid = t.tbl AND NOT tg.tgisinternal
    WHERE tg.tgname NOT LIKE 'pgit_journal%'
  LOOP
    saved := saved || jsonb_build_object('tbl', r.tbl, 'tg', r.tgname, 'en', r.tgenabled);
    EXECUTE format('ALTER TABLE %s DISABLE TRIGGER %I', r.tbl, r.tgname);
  END LOOP;

  RETURN jsonb_build_object('mode', 'triggers', 'saved', saved);
END $$;

CREATE OR REPLACE FUNCTION pgit.replay_end(st jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  e jsonb;
BEGIN
  IF st ->> 'mode' = 'session' THEN
    PERFORM set_config('session_replication_role', 'origin', true);
    RETURN;
  END IF;

  FOR e IN SELECT jsonb_array_elements(st -> 'saved') LOOP
    EXECUTE format('ALTER TABLE %s %s TRIGGER %I',
      e ->> 'tbl',
      CASE e ->> 'en'
        WHEN 'D' THEN 'DISABLE'
        WHEN 'A' THEN 'ENABLE ALWAYS'
        WHEN 'R' THEN 'ENABLE REPLICA'
        ELSE 'ENABLE' END,
      e ->> 'tg');
  END LOOP;
END $$;

CREATE TABLE IF NOT EXISTS pgit.merges (
  id         bigint PRIMARY KEY,
  branch     text        NOT NULL,
  ours_sha   bytea       NOT NULL,
  theirs_sha bytea       NOT NULL,
  base_sha   bytea       NOT NULL,
  msg        text,
  started_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE pgit.conflicts ADD COLUMN IF NOT EXISTS resolution_kind text;
ALTER TABLE pgit.conflicts ADD COLUMN IF NOT EXISTS resolution jsonb;
ALTER TABLE pgit.conflicts ADD COLUMN IF NOT EXISTS resolved boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION pgit.resolve_conflict(
  mid bigint, target_tbl text, key_hex text, kind text, value jsonb DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  c record;
  img jsonb;
BEGIN
  SELECT * INTO c FROM pgit.conflicts x
  WHERE x.merge_id = mid AND x.tbl = target_tbl AND x.k = key_hex;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pgit: no conflict on %.% in merge %', target_tbl, key_hex, mid;
  END IF;

  img := CASE kind
           WHEN 'ours'   THEN c.ours
           WHEN 'theirs' THEN c.theirs
           WHEN 'base'   THEN c.base
           WHEN 'delete' THEN NULL
           WHEN 'custom' THEN value
         END;

  IF kind NOT IN ('ours', 'theirs', 'base', 'delete', 'custom') THEN
    RAISE EXCEPTION 'pgit: unknown resolution %, expected ours, theirs, base, delete or custom', kind;
  END IF;

  IF kind = 'custom' AND value IS NULL THEN
    RAISE EXCEPTION 'pgit: a custom resolution needs a row image';
  END IF;

  UPDATE pgit.conflicts
  SET resolution_kind = kind, resolution = img, resolved = true
  WHERE merge_id = mid AND tbl = target_tbl AND k = key_hex;
END $$;

CREATE OR REPLACE FUNCTION pgit.resolve_all(mid bigint, kind text) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  IF kind NOT IN ('ours', 'theirs', 'base') THEN
    RAISE EXCEPTION 'pgit: resolve_all takes ours, theirs or base, not %', kind;
  END IF;

  UPDATE pgit.conflicts
  SET resolution_kind = kind,
      resolution = CASE kind WHEN 'ours' THEN ours WHEN 'theirs' THEN theirs ELSE base END,
      resolved = true
  WHERE merge_id = mid AND NOT resolved;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION pgit.merge_abort(mid bigint) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pgit.merges WHERE id = mid) THEN
    RAISE EXCEPTION 'pgit: no merge % in progress', mid;
  END IF;

  DELETE FROM pgit.conflicts WHERE merge_id = mid;
  DELETE FROM pgit.merges WHERE id = mid;
END $$;

CREATE OR REPLACE FUNCTION pgit.merge_finish(mid bigint) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  m       record;
  p       record;
  r       jsonb;
  n       int;
  summary text;
  roots   jsonb;
  new_sha bytea;
  ts      timestamptz := now();
  who     text := COALESCE(pgit.actor(), 'merge');
BEGIN
  SELECT * INTO m FROM pgit.merges WHERE id = mid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pgit: no merge % in progress', mid;
  END IF;

  SELECT count(*) INTO n FROM pgit.conflicts WHERE merge_id = mid AND NOT resolved;
  IF n > 0 THEN
    RAISE EXCEPTION 'pgit: % conflict(s) still unresolved in merge %', n, mid;
  END IF;

  IF pgit.resolve(m.branch) IS DISTINCT FROM m.ours_sha THEN
    RAISE EXCEPTION 'pgit: % moved since the merge started, abort and retry', m.branch;
  END IF;

  SET CONSTRAINTS ALL DEFERRED;

  FOR p IN SELECT * FROM pgit.merge_plan(m.base_sha, m.ours_sha, m.theirs_sha) LOOP
    IF p.action = 'conflict' THEN
      SELECT c.resolution INTO r FROM pgit.conflicts c
      WHERE c.merge_id = mid AND c.tbl = p.tbl AND c.k = p.k;

      IF r IS NULL THEN
        PERFORM pgit.apply_row(p.tbl::regclass, 'delete',
          (SELECT c.ours FROM pgit.conflicts c
           WHERE c.merge_id = mid AND c.tbl = p.tbl AND c.k = p.k));
      ELSE
        PERFORM pgit.apply_row(p.tbl::regclass, 'upsert', r);
      END IF;
    ELSE
      PERFORM pgit.apply_row(p.tbl::regclass, p.action, p.merged);
    END IF;
  END LOOP;

  SET CONSTRAINTS ALL IMMEDIATE;

  roots   := pgit.snapshot_trees(m.ours_sha);
  summary := pgit.roots_summary(roots);
  new_sha := pgit.hash(encode(m.ours_sha, 'hex') || E'\n' || encode(m.theirs_sha, 'hex') || E'\n' ||
                       COALESCE(m.msg, 'merge') || E'\n' ||
                       to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || E'\n' || summary);

  INSERT INTO pgit.commits (sha, parent_sha, author, message, at)
  VALUES (new_sha, m.ours_sha, who, COALESCE(m.msg, 'merge'), ts)
  ON CONFLICT (sha) DO NOTHING;

  INSERT INTO pgit.commit_parent (commit_sha, ord, parent_sha)
  VALUES (new_sha, 2, m.theirs_sha)
  ON CONFLICT DO NOTHING;

  INSERT INTO pgit.trees (commit_sha, tbl, root_hash)
  SELECT new_sha, e.key, decode(e.value, 'hex') FROM jsonb_each_text(roots) e
  ON CONFLICT DO NOTHING;

  PERFORM pgit.record_schemas(new_sha);
  UPDATE pgit.changes SET commit_sha = new_sha WHERE commit_sha IS NULL;
  PERFORM pgit.advance_ref(m.branch, m.ours_sha, new_sha);

  PERFORM pgit.rerere_learn(mid);

  DELETE FROM pgit.conflicts WHERE merge_id = mid;
  DELETE FROM pgit.merges WHERE id = mid;

  RETURN 0;
END $$;

CREATE OR REPLACE FUNCTION pgit.virtual_merge(x bytea, y bytea) RETURNS bytea
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  vb     bytea := pgit.hash('virtual' || encode(x, 'hex') || encode(y, 'hex'));
  xb     bytea;
  t      record;
  p      record;
  root_x bytea;
  root   bytea;
  roots  jsonb := '{}'::jsonb;
BEGIN
  IF EXISTS (SELECT 1 FROM pgit.trees WHERE commit_sha = vb) THEN
    RETURN vb;
  END IF;

  xb := pgit.merge_base(x, y);

  FOR t IN SELECT DISTINCT tr.tbl FROM pgit.trees tr WHERE tr.commit_sha IN (x, y) LOOP
    SELECT tr.root_hash INTO root_x FROM pgit.trees tr
    WHERE tr.commit_sha = x AND tr.tbl = t.tbl;

    EXECUTE 'DROP TABLE IF EXISTS pgit_vb';
    EXECUTE format('CREATE TEMP TABLE pgit_vb (LIKE %s INCLUDING ALL)', t.tbl);
    EXECUTE format(
      'INSERT INTO pgit_vb SELECT (jsonb_populate_record(NULL::%s, l.v)).* FROM pgit.leaves($1) l',
      t.tbl) USING root_x;

    FOR p IN SELECT * FROM pgit.merge_plan(xb, x, y) mp WHERE mp.tbl = t.tbl LOOP
      IF p.action <> 'conflict' THEN
        PERFORM pgit.apply_row('pgit_vb'::regclass, p.action, p.merged);
      END IF;
    END LOOP;

    root  := pgit.write_tree('pgit_vb'::regclass);
    roots := roots || jsonb_build_object(t.tbl, encode(root, 'hex'));
  END LOOP;

  EXECUTE 'DROP TABLE IF EXISTS pgit_vb';

  INSERT INTO pgit.trees (commit_sha, tbl, root_hash)
  SELECT vb, e.key, decode(e.value, 'hex') FROM jsonb_each_text(roots) e
  ON CONFLICT DO NOTHING;

  RETURN vb;
END $$;

CREATE OR REPLACE FUNCTION pgit.row_similarity(a jsonb, b jsonb, pk text[]) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN count(*) = 0 THEN 0
              ELSE count(*) FILTER (WHERE a -> k IS NOT DISTINCT FROM b -> k)::numeric / count(*) END
  FROM jsonb_object_keys(COALESCE(a, '{}'::jsonb)) k
  WHERE NOT (k = ANY (pk))
$$;

CREATE OR REPLACE FUNCTION pgit.rename_pairs(
  base_root bytea, side_root bytea, pk text[], threshold numeric DEFAULT 0.5
) RETURNS TABLE (old_k text, new_k text, sim numeric)
LANGUAGE sql STABLE AS $$
  WITH d AS (SELECT * FROM pgit.diff_tree(base_root, side_root)),
  del AS (SELECT x.k, x.before AS img FROM d x WHERE x.op = 'DELETE'),
  ins AS (SELECT x.k, x.after  AS img FROM d x WHERE x.op = 'INSERT'),
  cand AS (
    SELECT del.k AS ok, ins.k AS nk, pgit.row_similarity(del.img, ins.img, pk) AS s
    FROM del CROSS JOIN ins
  ),
  ranked AS (
    SELECT c.*,
           row_number() OVER (PARTITION BY c.ok ORDER BY c.s DESC, c.nk) AS r1,
           row_number() OVER (PARTITION BY c.nk ORDER BY c.s DESC, c.ok) AS r2
    FROM cand c WHERE c.s >= threshold
  )
  SELECT r.ok, r.nk, r.s FROM ranked r WHERE r.r1 = 1 AND r.r2 = 1
$$;

CREATE OR REPLACE FUNCTION pgit.three_way_row(bimg jsonb, oimg jsonb, timg jsonb, pk text[])
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  out_img jsonb := oimg;
  col text;
  bv jsonb; ov jsonb; tv jsonb;
BEGIN
  FOR col IN SELECT jsonb_object_keys(COALESCE(bimg, oimg)) LOOP
    CONTINUE WHEN col = ANY (pk);
    bv := bimg -> col; ov := oimg -> col; tv := timg -> col;
    IF ov IS NOT DISTINCT FROM tv THEN CONTINUE;
    ELSIF ov IS NOT DISTINCT FROM bv THEN
      out_img := jsonb_set(out_img, ARRAY[col], COALESCE(tv, 'null'::jsonb));
    ELSIF tv IS NOT DISTINCT FROM bv THEN CONTINUE;
    ELSE RETURN NULL;
    END IF;
  END LOOP;
  RETURN out_img;
END $$;

CREATE OR REPLACE FUNCTION pgit.merge_plan(base_sha bytea, our_sha bytea, their_sha bytea)
RETURNS TABLE (tbl text, k text, action text, merged jsonb, conflict_col text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  r      record;
  broot  bytea; oroot bytea; troot bytea;
  pk     text[];
  bimg   jsonb; oimg jsonb; timg jsonb; other jsonb;
  nk     text;
  fixed  jsonb;
  cur    text := NULL;
BEGIN
  FOR r IN SELECT * FROM pgit.merge_plan_raw(base_sha, our_sha, their_sha) LOOP
    IF r.action <> 'conflict' OR r.conflict_col IS NOT NULL THEN
      tbl := r.tbl; k := r.k; action := r.action; merged := r.merged; conflict_col := r.conflict_col;
      RETURN NEXT; CONTINUE;
    END IF;

    IF cur IS DISTINCT FROM r.tbl THEN
      cur := r.tbl;
      SELECT x.root_hash INTO broot FROM pgit.trees x WHERE x.commit_sha = base_sha  AND x.tbl = cur;
      SELECT x.root_hash INTO oroot FROM pgit.trees x WHERE x.commit_sha = our_sha   AND x.tbl = cur;
      SELECT x.root_hash INTO troot FROM pgit.trees x WHERE x.commit_sha = their_sha AND x.tbl = cur;
      pk := pgit.pk_columns(cur::regclass);
    END IF;

    SELECT l.v INTO bimg FROM pgit.lookup(broot, r.k) l;
    SELECT l.v INTO oimg FROM pgit.lookup(oroot, r.k) l;
    SELECT l.v INTO timg FROM pgit.lookup(troot, r.k) l;

    nk := NULL;
    IF oimg IS NULL AND timg IS NOT NULL THEN
      SELECT p.new_k INTO nk FROM pgit.rename_pairs(broot, oroot, pk) p WHERE p.old_k = r.k;
      IF nk IS NOT NULL THEN SELECT l.v INTO other FROM pgit.lookup(oroot, nk) l; END IF;
    ELSIF timg IS NULL AND oimg IS NOT NULL THEN
      SELECT p.new_k INTO nk FROM pgit.rename_pairs(broot, troot, pk) p WHERE p.old_k = r.k;
      IF nk IS NOT NULL THEN
        SELECT l.v INTO other FROM pgit.lookup(troot, nk) l;
        timg := oimg; oimg := other; other := timg;
      END IF;
    END IF;

    IF nk IS NULL THEN
      tbl := r.tbl; k := r.k; action := r.action; merged := r.merged; conflict_col := r.conflict_col;
      RETURN NEXT; CONTINUE;
    END IF;

    fixed := pgit.three_way_row(bimg, other, CASE WHEN oimg IS NULL THEN timg ELSE oimg END, pk);

    tbl := r.tbl; k := nk;
    IF fixed IS NULL THEN
      action := 'conflict'; merged := NULL; conflict_col := NULL;
    ELSE
      action := 'upsert'; merged := fixed; conflict_col := NULL;
    END IF;
    RETURN NEXT;
  END LOOP;
END $$;

CREATE TABLE IF NOT EXISTS pgit.reflog (
  id      bigserial PRIMARY KEY,
  ref     text        NOT NULL,
  old_sha bytea,
  new_sha bytea       NOT NULL,
  action  text        NOT NULL,
  actor   text,
  at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS reflog_ref_idx ON pgit.reflog (ref, id DESC);

DROP FUNCTION IF EXISTS pgit.advance_ref(text, bytea, bytea);

CREATE OR REPLACE FUNCTION pgit.advance_ref(
  ref_name text, expected bytea, next_sha bytea, act text DEFAULT 'update'
) RETURNS void
LANGUAGE plpgsql AS $$
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

  INSERT INTO pgit.reflog (ref, old_sha, new_sha, action, actor)
  VALUES (ref_name, expected, next_sha, act, pgit.actor());
END $$;

CREATE OR REPLACE FUNCTION pgit.rev(spec text) RETURNS bytea
LANGUAGE plpgsql STABLE AS $$
DECLARE
  base text := spec;
  ops  text[] := '{}';
  m    text;
  cur  bytea;
  i    int;
  n    int;
BEGIN
  IF spec IS NULL THEN RETURN NULL; END IF;

  LOOP
    m := substring(base FROM '(\^[0-9]*|~[0-9]*)$');
    EXIT WHEN m IS NULL;
    ops := m || ops;
    base := left(base, length(base) - length(m));
  END LOOP;

  IF base = 'HEAD' OR base = '@' THEN
    cur := pgit.resolve(pgit.head());
  ELSIF EXISTS (SELECT 1 FROM pgit.refs r WHERE r.name = base) THEN
    cur := pgit.resolve(base);
  ELSIF EXISTS (SELECT 1 FROM pgit.tags t WHERE t.name = base) THEN
    SELECT t.sha INTO cur FROM pgit.tags t WHERE t.name = base;
  ELSIF base ~ '^[0-9a-fA-F]{4,64}$' THEN
    SELECT c.sha INTO cur FROM pgit.commits c
    WHERE encode(c.sha, 'hex') LIKE lower(base) || '%';
    IF cur IS NULL THEN
      RAISE EXCEPTION 'pgit: no commit matching %', base;
    END IF;
  ELSE
    RAISE EXCEPTION 'pgit: cannot resolve %', spec;
  END IF;

  FOREACH m IN ARRAY ops LOOP
    n := COALESCE(NULLIF(substring(m FROM '[0-9]+'), '')::int, 1);
    IF left(m, 1) = '~' THEN
      FOR i IN 1..n LOOP
        SELECT c.parent_sha INTO cur FROM pgit.commits c WHERE c.sha = cur;
        IF cur IS NULL THEN RAISE EXCEPTION 'pgit: % goes past the root commit', spec; END IF;
      END LOOP;
    ELSE
      SELECT p.parent INTO cur FROM pgit.parents_of(cur) p WHERE p.ord = n;
      IF cur IS NULL THEN RAISE EXCEPTION 'pgit: % has no such parent', spec; END IF;
    END IF;
  END LOOP;

  RETURN cur;
END $$;

DROP FUNCTION IF EXISTS pgit.log(bytea, text);

CREATE OR REPLACE FUNCTION pgit.log(
  start_sha bytea DEFAULT NULL, pathspec text DEFAULT NULL,
  max_count int DEFAULT NULL, since timestamptz DEFAULT NULL, who text DEFAULT NULL
) RETURNS TABLE (depth int, sha bytea, parent_sha bytea, author text, message text, at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE walk AS (
    SELECT 0 AS depth, c.sha, c.parent_sha, c.author, c.message, c.at
    FROM pgit.commits c
    WHERE c.sha = COALESCE(start_sha, pgit.resolve(pgit.head()))
    UNION ALL
    SELECT w.depth + 1, c.sha, c.parent_sha, c.author, c.message, c.at
    FROM walk w JOIN pgit.commits c ON c.sha = w.parent_sha
  )
  SELECT w.depth, w.sha, w.parent_sha, w.author, w.message, w.at
  FROM walk w
  WHERE (pathspec IS NULL OR EXISTS (SELECT 1 FROM pgit.diff(w.parent_sha, w.sha, pathspec)))
    AND (since IS NULL OR w.at >= since)
    AND (who IS NULL OR w.author = who)
  ORDER BY w.depth
  LIMIT max_count
$$;

CREATE OR REPLACE FUNCTION pgit.reset(spec text, mode text DEFAULT 'hard') RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  branch  text  := pgit.head();
  cur     bytea := pgit.resolve(branch);
  tgt     bytea := pgit.rev(spec);
  applied int   := 0;
  r       record;
  troot   bytea;
  guard   jsonb;
BEGIN
  IF mode NOT IN ('soft', 'hard') THEN
    RAISE EXCEPTION 'pgit: reset takes soft or hard, not % (there is no index to reset)', mode;
  END IF;

  IF tgt IS NULL THEN
    RAISE EXCEPTION 'pgit: cannot resolve %', spec;
  END IF;

  IF mode = 'hard' THEN
    guard := pgit.replay_begin();
    SET CONSTRAINTS ALL DEFERRED;

    FOR r IN SELECT x.tbl FROM pgit.tracked x LOOP
      SELECT y.root_hash INTO troot FROM pgit.trees y
      WHERE y.commit_sha = tgt AND y.tbl = r.tbl::text;
      applied := applied + pgit.apply_tree_diff(r.tbl, pgit.write_tree(r.tbl), troot);
    END LOOP;

    SET CONSTRAINTS ALL IMMEDIATE;
    PERFORM pgit.replay_end(guard);
    DELETE FROM pgit.changes WHERE commit_sha IS NULL;
  END IF;

  UPDATE pgit.refs SET sha = tgt WHERE name = branch;
  INSERT INTO pgit.reflog (ref, old_sha, new_sha, action, actor)
  VALUES (branch, cur, tgt, 'reset --' || mode, pgit.actor());

  RETURN applied;
END $$;

CREATE OR REPLACE FUNCTION pgit.diff_working(pathspec text DEFAULT NULL)
RETURNS TABLE (tbl text, k text, op text, before jsonb, after jsonb)
LANGUAGE plpgsql AS $$
DECLARE
  h     bytea := pgit.resolve(pgit.head());
  t     record;
  hroot bytea;
  lroot bytea;
BEGIN
  FOR t IN SELECT x.tbl FROM pgit.tracked x ORDER BY x.tbl::text LOOP
    CONTINUE WHEN pathspec IS NOT NULL
              AND split_part(split_part(pathspec, ':', 1), '.', 1) <> t.tbl::text;

    SELECT x.root_hash INTO hroot FROM pgit.trees x
    WHERE x.commit_sha = h AND x.tbl = t.tbl::text;

    lroot := pgit.write_tree(t.tbl);

    RETURN QUERY
      SELECT t.tbl::text, d.k, d.op, d.before, d.after
      FROM pgit.diff_tree(hroot, lroot) d;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION pgit.fsck()
RETURNS TABLE (problem text, detail text)
LANGUAGE sql STABLE AS $$
  SELECT 'node hash mismatch', encode(n.hash, 'hex')
  FROM pgit.nodes n
  WHERE n.hash <> pgit.hash((
    SELECT COALESCE(string_agg(decode(x ->> 'h', 'hex'), ''::bytea ORDER BY x ->> 'k'), ''::bytea)
    FROM jsonb_array_elements(pgit.entries_of(n.hash)) x))

  UNION ALL
  SELECT 'delta base missing', encode(n.hash, 'hex')
  FROM pgit.nodes n
  WHERE n.base_hash IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM pgit.nodes b WHERE b.hash = n.base_hash)

  UNION ALL
  SELECT 'node unresolvable', encode(n.hash, 'hex')
  FROM pgit.nodes n WHERE pgit.entries_of(n.hash) IS NULL

  UNION ALL
  SELECT 'ref points at a missing commit', r.name
  FROM pgit.refs r
  WHERE NOT EXISTS (SELECT 1 FROM pgit.commits c WHERE c.sha = r.sha)

  UNION ALL
  SELECT 'commit parent missing', encode(e.child, 'hex') || ' ^' || e.ord
  FROM pgit.parent_edge e
  WHERE NOT EXISTS (SELECT 1 FROM pgit.commits p WHERE p.sha = e.parent)

  UNION ALL
  SELECT 'merge commit has a gap in its parents', encode(p.commit_sha, 'hex')
  FROM pgit.commit_parent p
  WHERE NOT EXISTS (SELECT 1 FROM pgit.commit_parent q
                    WHERE q.commit_sha = p.commit_sha AND q.ord = p.ord - 1)
    AND p.ord > 2

  UNION ALL
  SELECT 'tree root missing from the node store', t.commit_sha::text || ' ' || t.tbl
  FROM pgit.trees t
  WHERE t.root_hash <> pgit.hash(''::bytea)
    AND NOT EXISTS (SELECT 1 FROM pgit.nodes n WHERE n.hash = t.root_hash)

  UNION ALL
  SELECT 'child node missing', encode(n.hash, 'hex') || ' -> ' || (x ->> 'h')
  FROM pgit.nodes n, jsonb_array_elements(pgit.entries_of(n.hash)) x
  WHERE n.level > 0
    AND NOT EXISTS (SELECT 1 FROM pgit.nodes c WHERE c.hash = decode(x ->> 'h', 'hex'))
$$;

CREATE TABLE IF NOT EXISTS pgit.remotes (
  name text PRIMARY KEY,
  url  text NOT NULL
);

CREATE OR REPLACE FUNCTION pgit.remote_add(remote_name text, remote_url text) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO pgit.remotes (name, url) VALUES (remote_name, remote_url)
  ON CONFLICT (name) DO UPDATE SET url = EXCLUDED.url
$$;

CREATE OR REPLACE FUNCTION pgit.reachable_nodes(roots bytea[]) RETURNS TABLE (h bytea)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE w AS (
    SELECT r AS h FROM unnest(roots) r WHERE r IS NOT NULL
    UNION
    SELECT decode(x ->> 'h', 'hex')
    FROM w
    JOIN pgit.nodes n ON n.hash = w.h
    CROSS JOIN LATERAL jsonb_array_elements(pgit.entries_of(n.hash)) x
    WHERE n.level > 0
  )
  SELECT w.h FROM w WHERE EXISTS (SELECT 1 FROM pgit.nodes n WHERE n.hash = w.h)
$$;

CREATE OR REPLACE FUNCTION pgit.commits_to_send(ref_names text[], have bytea[])
RETURNS TABLE (sha bytea)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE tips AS (
    SELECT r.sha FROM pgit.refs r WHERE r.name = ANY (ref_names)
  ),
  w AS (
    SELECT t.sha FROM tips t WHERE NOT (t.sha = ANY (have))
    UNION
    SELECT e.parent FROM w JOIN pgit.parent_edge e ON e.child = w.sha
    WHERE NOT (e.parent = ANY (have))
  )
  SELECT DISTINCT w.sha FROM w
$$;

CREATE OR REPLACE FUNCTION pgit.have() RETURNS bytea[]
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(array_agg(c.sha), '{}'::bytea[]) FROM pgit.commits c
$$;

CREATE OR REPLACE FUNCTION pgit.bundle(ref_names text[], have bytea[] DEFAULT '{}'::bytea[])
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  send    bytea[];
  keep    bytea[];
  skip    bytea[];
  result  jsonb;
BEGIN
  SELECT COALESCE(array_agg(x.sha), '{}'::bytea[]) INTO send
  FROM pgit.commits_to_send(ref_names, have) x;

  IF array_length(send, 1) IS NULL THEN
    RETURN jsonb_build_object('refs', (
      SELECT COALESCE(jsonb_object_agg(r.name, encode(r.sha, 'hex')), '{}'::jsonb)
      FROM pgit.refs r WHERE r.name = ANY (ref_names)),
      'commits', '[]'::jsonb, 'trees', '[]'::jsonb,
      'schemas', '[]'::jsonb, 'nodes', '[]'::jsonb);
  END IF;

  SELECT COALESCE(array_agg(DISTINCT t.root_hash), '{}'::bytea[]) INTO keep
  FROM pgit.trees t WHERE t.commit_sha = ANY (send);

  SELECT COALESCE(array_agg(DISTINCT t.root_hash), '{}'::bytea[]) INTO skip
  FROM pgit.trees t WHERE t.commit_sha = ANY (have);

  SELECT jsonb_build_object(
    'refs', (SELECT COALESCE(jsonb_object_agg(r.name, encode(r.sha, 'hex')), '{}'::jsonb)
             FROM pgit.refs r WHERE r.name = ANY (ref_names)),
    'commits', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                  'sha', encode(c.sha, 'hex'),
                  'parent', encode(c.parent_sha, 'hex'),
                  'parents', (SELECT COALESCE(jsonb_agg(encode(p.parent_sha, 'hex') ORDER BY p.ord), '[]'::jsonb)
                              FROM pgit.commit_parent p WHERE p.commit_sha = c.sha),
                  'author', c.author, 'message', c.message, 'at', c.at)), '[]'::jsonb)
                FROM pgit.commits c WHERE c.sha = ANY (send)),
    'trees', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'commit', encode(t.commit_sha, 'hex'), 'tbl', t.tbl,
                'root', encode(t.root_hash, 'hex'))), '[]'::jsonb)
              FROM pgit.trees t WHERE t.commit_sha = ANY (send)),
    'schemas', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                  'commit', encode(x.commit_sha, 'hex'), 'tbl', x.tbl,
                  'fp', encode(x.fingerprint, 'hex'), 'cols', x.columns,
                  'pk', x.pk_cols)), '[]'::jsonb)
                FROM pgit.schemas x WHERE x.commit_sha = ANY (send)),
    'nodes', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'hash', encode(n.hash, 'hex'), 'level', n.level,
                'entries', pgit.entries_of(n.hash))), '[]'::jsonb)
              FROM pgit.nodes n
              WHERE n.hash IN (SELECT r.h FROM pgit.reachable_nodes(keep) r)
                AND n.hash NOT IN (SELECT r.h FROM pgit.reachable_nodes(skip) r))
  ) INTO result;

  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION pgit.unbundle(b jsonb) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  e      jsonb;
  n      int := 0;
  h      bytea;
  calc   bytea;
BEGIN
  FOR e IN SELECT jsonb_array_elements(b -> 'nodes') LOOP
    h := decode(e ->> 'hash', 'hex');

    SELECT pgit.hash((
      SELECT COALESCE(string_agg(decode(x ->> 'h', 'hex'), ''::bytea ORDER BY x ->> 'k'), ''::bytea)
      FROM jsonb_array_elements(e -> 'entries') x)) INTO calc;

    IF calc <> h THEN
      RAISE EXCEPTION 'pgit: bundle node % does not hash to its content, refusing', e ->> 'hash';
    END IF;

    INSERT INTO pgit.nodes (hash, level, entries)
    VALUES (h, (e ->> 'level')::int, e -> 'entries')
    ON CONFLICT (hash) DO NOTHING;
    n := n + 1;
  END LOOP;

  INSERT INTO pgit.commits (sha, parent_sha, author, message, at)
  SELECT decode(x ->> 'sha', 'hex'), decode(x ->> 'parent', 'hex'),
         x ->> 'author', x ->> 'message', (x ->> 'at')::timestamptz
  FROM jsonb_array_elements(b -> 'commits') x
  ORDER BY (x ->> 'at')::timestamptz
  ON CONFLICT (sha) DO NOTHING;

  INSERT INTO pgit.commit_parent (commit_sha, ord, parent_sha)
  SELECT decode(x ->> 'sha', 'hex'), (p.ord + 1)::int, decode(p.val, 'hex')
  FROM jsonb_array_elements(b -> 'commits') x
  CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(x -> 'parents', '[]'::jsonb))
       WITH ORDINALITY p(val, ord)
  ON CONFLICT DO NOTHING;

  INSERT INTO pgit.trees (commit_sha, tbl, root_hash)
  SELECT decode(x ->> 'commit', 'hex'), x ->> 'tbl', decode(x ->> 'root', 'hex')
  FROM jsonb_array_elements(b -> 'trees') x
  ON CONFLICT DO NOTHING;

  INSERT INTO pgit.schemas (commit_sha, tbl, fingerprint, columns, pk_cols)
  SELECT decode(x ->> 'commit', 'hex'), x ->> 'tbl', decode(x ->> 'fp', 'hex'), x -> 'cols',
         CASE WHEN x -> 'pk' IS NULL OR x -> 'pk' = 'null'::jsonb THEN NULL
              ELSE ARRAY(SELECT jsonb_array_elements_text(x -> 'pk')) END
  FROM jsonb_array_elements(b -> 'schemas') x
  ON CONFLICT DO NOTHING;

  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION pgit.fetch(remote_name text, b jsonb) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  e jsonb;
  k text;
  n int;
BEGIN
  n := pgit.unbundle(b);

  FOR k IN SELECT jsonb_object_keys(b -> 'refs') LOOP
    INSERT INTO pgit.refs (name, sha)
    VALUES ('remotes/' || remote_name || '/' || k, decode(b -> 'refs' ->> k, 'hex'))
    ON CONFLICT (name) DO UPDATE SET sha = EXCLUDED.sha;
  END LOOP;

  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION pgit.receive(b jsonb, force boolean DEFAULT false) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  k       text;
  incoming bytea;
  cur      bytea;
  n        int;
BEGIN
  n := pgit.unbundle(b);

  FOR k IN SELECT jsonb_object_keys(b -> 'refs') LOOP
    incoming := decode(b -> 'refs' ->> k, 'hex');
    cur := pgit.resolve(k);

    IF cur IS NOT NULL AND NOT force
       AND NOT EXISTS (SELECT 1 FROM pgit.ancestors(incoming) a WHERE a.a = cur) THEN
      RAISE EXCEPTION 'pgit: push to % is not a fast forward, it would drop commits', k;
    END IF;

    IF cur IS NULL THEN
      INSERT INTO pgit.refs (name, sha) VALUES (k, incoming);
      INSERT INTO pgit.reflog (ref, old_sha, new_sha, action, actor)
      VALUES (k, NULL, incoming, 'receive', pgit.actor());
    ELSE
      UPDATE pgit.refs SET sha = incoming WHERE name = k;
      INSERT INTO pgit.reflog (ref, old_sha, new_sha, action, actor)
      VALUES (k, cur, incoming, 'receive', pgit.actor());
    END IF;
  END LOOP;

  RETURN n;
END $$;

CREATE TABLE IF NOT EXISTS pgit.tags (
  name    text PRIMARY KEY,
  sha     bytea       NOT NULL,
  tagger  text,
  message text,
  at      timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION pgit.tag(tag_name text, spec text DEFAULT 'HEAD',
                                    msg text DEFAULT NULL, force boolean DEFAULT false)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  target bytea := pgit.rev(spec);
BEGIN
  IF target IS NULL THEN RAISE EXCEPTION 'pgit: cannot resolve %', spec; END IF;

  IF EXISTS (SELECT 1 FROM pgit.tags t WHERE t.name = tag_name) AND NOT force THEN
    RAISE EXCEPTION 'pgit: tag % already exists', tag_name;
  END IF;

  INSERT INTO pgit.tags (name, sha, tagger, message)
  VALUES (tag_name, target, pgit.actor(), msg)
  ON CONFLICT (name) DO UPDATE SET sha = EXCLUDED.sha, message = EXCLUDED.message;
END $$;

CREATE OR REPLACE FUNCTION pgit.tag_delete(tag_name text) RETURNS void
LANGUAGE sql AS $$ DELETE FROM pgit.tags WHERE name = tag_name $$;

CREATE OR REPLACE FUNCTION pgit.restore(spec text, pathspec text) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  target bytea := pgit.rev(spec);
  want   text  := NULLIF(split_part(split_part(pathspec, ':', 1), '.', 1), '');
  row_k  text  := NULLIF(split_part(pathspec, ':', 2), '');
  r      record;
  d      record;
  troot  bytea;
  guard  jsonb;
  n      int := 0;
BEGIN
  IF want IS NULL THEN RAISE EXCEPTION 'pgit: restore needs a pathspec naming a table'; END IF;

  guard := pgit.replay_begin();
  SET CONSTRAINTS ALL DEFERRED;

  FOR r IN SELECT x.tbl FROM pgit.tracked x WHERE x.tbl::text = want LOOP
    SELECT y.root_hash INTO troot FROM pgit.trees y
    WHERE y.commit_sha = target AND y.tbl = r.tbl::text;

    FOR d IN SELECT * FROM pgit.diff_tree(pgit.write_tree(r.tbl), troot) LOOP
      CONTINUE WHEN row_k IS NOT NULL
                AND NOT pgit.row_matches(r.tbl::text, COALESCE(d.after, d.before), row_k);
      IF d.op = 'DELETE' THEN
        PERFORM pgit.apply_row(r.tbl, 'delete', d.before);
      ELSE
        PERFORM pgit.apply_row(r.tbl, 'upsert', d.after);
      END IF;
      n := n + 1;
    END LOOP;
  END LOOP;

  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM pgit.replay_end(guard);
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION pgit.stash_push(msg text DEFAULT 'stash') RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  branch text  := pgit.head();
  parent bytea := pgit.resolve(branch);
  snap   bytea;
  slot   text;
BEGIN
  IF NOT pgit.is_dirty() THEN
    RAISE EXCEPTION 'pgit: nothing to stash, the working tree is clean';
  END IF;

  snap := pgit.commit(msg, pgit.actor());
  slot := 'stash/' || nextval('pgit.merge_seq');

  INSERT INTO pgit.refs (name, sha) VALUES (slot, snap);
  UPDATE pgit.refs SET sha = parent WHERE name = branch;
  INSERT INTO pgit.reflog (ref, old_sha, new_sha, action, actor)
  VALUES (branch, snap, parent, 'stash', pgit.actor());

  PERFORM pgit.reset(encode(parent, 'hex'), 'hard');
  RETURN slot;
END $$;

CREATE OR REPLACE FUNCTION pgit.stash_list() RETURNS TABLE (slot text, sha bytea, message text)
LANGUAGE sql STABLE AS $$
  SELECT r.name, r.sha, c.message
  FROM pgit.refs r JOIN pgit.commits c ON c.sha = r.sha
  WHERE r.name LIKE 'stash/%' ORDER BY r.name
$$;

DROP FUNCTION IF EXISTS pgit.stash_pop(text);

CREATE OR REPLACE FUNCTION pgit.stash_pop(want_slot text DEFAULT NULL) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  pick   text;
  snap   bytea;
  parent bytea;
  r      record;
  guard  jsonb;
  n      int := 0;
  aroot  bytea; broot bytea;
BEGIN
  SELECT s.slot INTO pick FROM pgit.stash_list() s
  WHERE want_slot IS NULL OR s.slot = want_slot
  ORDER BY s.slot DESC LIMIT 1;

  IF pick IS NULL THEN RAISE EXCEPTION 'pgit: no stash to pop'; END IF;

  snap := pgit.resolve(pick);
  SELECT c.parent_sha INTO parent FROM pgit.commits c WHERE c.sha = snap;

  guard := pgit.replay_begin();
  SET CONSTRAINTS ALL DEFERRED;

  FOR r IN SELECT x.tbl FROM pgit.tracked x LOOP
    SELECT y.root_hash INTO aroot FROM pgit.trees y WHERE y.commit_sha = parent AND y.tbl = r.tbl::text;
    SELECT y.root_hash INTO broot FROM pgit.trees y WHERE y.commit_sha = snap   AND y.tbl = r.tbl::text;
    n := n + pgit.apply_tree_diff(r.tbl, aroot, broot);
  END LOOP;

  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM pgit.replay_end(guard);

  DELETE FROM pgit.refs WHERE name = pick;
  RETURN n;
END $$;

CREATE TABLE IF NOT EXISTS pgit.bisect (
  id      int PRIMARY KEY DEFAULT 1,
  good    bytea NOT NULL,
  bad     bytea NOT NULL,
  CONSTRAINT bisect_single CHECK (id = 1)
);

CREATE OR REPLACE FUNCTION pgit.bisect_start(good_spec text, bad_spec text) RETURNS bytea
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM pgit.bisect;
  INSERT INTO pgit.bisect (id, good, bad) VALUES (1, pgit.rev(good_spec), pgit.rev(bad_spec));
  RETURN pgit.bisect_next();
END $$;

CREATE OR REPLACE FUNCTION pgit.bisect_range() RETURNS TABLE (sha bytea, ord int)
LANGUAGE sql STABLE AS $$
  WITH b AS (SELECT * FROM pgit.bisect),
  span AS (
    SELECT l.sha, l.depth FROM b, pgit.log((SELECT bad FROM b)) l
    WHERE l.sha <> (SELECT good FROM b)
      AND NOT EXISTS (SELECT 1 FROM pgit.ancestors((SELECT good FROM b)) a WHERE a.a = l.sha)
  )
  SELECT span.sha, row_number() OVER (ORDER BY span.depth DESC)::int FROM span
$$;

CREATE OR REPLACE FUNCTION pgit.bisect_next() RETURNS bytea
LANGUAGE plpgsql AS $$
DECLARE
  n   int;
  pick bytea;
BEGIN
  SELECT count(*) INTO n FROM pgit.bisect_range();
  IF n = 0 THEN RETURN NULL; END IF;

  SELECT r.sha INTO pick FROM pgit.bisect_range() r WHERE r.ord = greatest(1, (n + 1) / 2);
  PERFORM pgit.reset(encode(pick, 'hex'), 'hard');
  RETURN pick;
END $$;

CREATE OR REPLACE FUNCTION pgit.bisect_good(spec text DEFAULT 'HEAD') RETURNS bytea
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE pgit.bisect SET good = pgit.rev(spec);
  RETURN pgit.bisect_next();
END $$;

CREATE OR REPLACE FUNCTION pgit.bisect_bad(spec text DEFAULT 'HEAD') RETURNS bytea
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE pgit.bisect SET bad = pgit.rev(spec);
  RETURN pgit.bisect_next();
END $$;

CREATE OR REPLACE FUNCTION pgit.bisect_reset() RETURNS void
LANGUAGE sql AS $$ DELETE FROM pgit.bisect $$;

CREATE OR REPLACE FUNCTION pgit.gc_nodes() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS pgit_keep (h bytea PRIMARY KEY) ON COMMIT DROP;
  TRUNCATE pgit_keep;

  INSERT INTO pgit_keep
  SELECT DISTINCT r.h FROM pgit.reachable_nodes(
    (SELECT COALESCE(array_agg(DISTINCT t.root_hash), '{}'::bytea[]) FROM pgit.trees t)) r
  ON CONFLICT DO NOTHING;

  LOOP
    INSERT INTO pgit_keep
    SELECT DISTINCT n2.base_hash FROM pgit.nodes n2
    JOIN pgit_keep k ON k.h = n2.hash
    WHERE n2.base_hash IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM pgit_keep k2 WHERE k2.h = n2.base_hash)
    ON CONFLICT DO NOTHING;
    EXIT WHEN NOT FOUND;
  END LOOP;

  DELETE FROM pgit.nodes WHERE hash NOT IN (SELECT h FROM pgit_keep);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION pgit.prune(before_at timestamptz) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r      record;
  cutoff bytea;
  n      int := 0;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS pgit_alive (sha bytea PRIMARY KEY) ON COMMIT DROP;
  TRUNCATE pgit_alive;

  FOR r IN SELECT name, sha FROM pgit.refs UNION SELECT name, sha FROM pgit.tags LOOP
    INSERT INTO pgit_alive
    SELECT l.sha FROM pgit.log(r.sha) l WHERE l.at >= before_at
    ON CONFLICT DO NOTHING;

    SELECT l.sha INTO cutoff FROM pgit.log(r.sha) l
    WHERE l.at >= before_at ORDER BY l.depth DESC LIMIT 1;

    IF cutoff IS NOT NULL THEN
      UPDATE pgit.commits SET parent_sha = NULL WHERE sha = cutoff;
      DELETE FROM pgit.commit_parent WHERE commit_sha = cutoff;
    ELSE
      INSERT INTO pgit_alive VALUES (r.sha) ON CONFLICT DO NOTHING;
      UPDATE pgit.commits SET parent_sha = NULL WHERE sha = r.sha;
      DELETE FROM pgit.commit_parent WHERE commit_sha = r.sha;
    END IF;
  END LOOP;

  DELETE FROM pgit.reflog   WHERE new_sha NOT IN (SELECT sha FROM pgit_alive);
  DELETE FROM pgit.trees    WHERE commit_sha NOT IN (SELECT sha FROM pgit_alive);
  DELETE FROM pgit.schemas  WHERE commit_sha NOT IN (SELECT sha FROM pgit_alive);
  UPDATE pgit.changes SET commit_sha = NULL
   WHERE commit_sha IS NOT NULL AND commit_sha NOT IN (SELECT sha FROM pgit_alive);
  DELETE FROM pgit.changes  WHERE commit_sha IS NULL;
  DELETE FROM pgit.commits  WHERE sha NOT IN (SELECT sha FROM pgit_alive);
  GET DIAGNOSTICS n = ROW_COUNT;

  PERFORM pgit.gc_nodes();
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION pgit.create_from_schema(sha bytea, target_tbl text) RETURNS void
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  sc   record;
  cols text;
BEGIN
  SELECT * INTO sc FROM pgit.schemas x WHERE x.commit_sha = sha AND x.tbl = target_tbl;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pgit: commit % records no shape for %', encode(sha, 'hex'), target_tbl;
  END IF;

  IF sc.pk_cols IS NULL THEN
    RAISE EXCEPTION 'pgit: the recorded shape for % has no primary key, cannot create it', target_tbl;
  END IF;

  SELECT string_agg(format('%I %s', e ->> 'name', e ->> 'type'), ', ' ORDER BY e ->> 'name')
  INTO cols FROM jsonb_array_elements(sc.columns) e;

  EXECUTE format('CREATE TABLE %I (%s, PRIMARY KEY (%s))',
                 target_tbl, cols,
                 (SELECT string_agg(quote_ident(c), ', ') FROM unnest(sc.pk_cols) c));
END $$;

CREATE OR REPLACE FUNCTION pgit.clone_from(b jsonb, branch text DEFAULT 'main') RETURNS int
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  tip  bytea;
  t    record;
  made int := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM pgit.commits) THEN
    RAISE EXCEPTION 'pgit: clone needs an empty history, use fetch or receive instead';
  END IF;

  PERFORM pgit.unbundle(b);

  tip := decode(b -> 'refs' ->> branch, 'hex');
  IF tip IS NULL THEN
    RAISE EXCEPTION 'pgit: the bundle carries no branch called %', branch;
  END IF;

  FOR t IN SELECT x.tbl FROM pgit.schemas x WHERE x.commit_sha = tip LOOP
    IF to_regclass(t.tbl) IS NULL THEN
      PERFORM pgit.create_from_schema(tip, t.tbl);
      made := made + 1;
    END IF;
    PERFORM pgit.track(t.tbl::regclass);
  END LOOP;

  INSERT INTO pgit.refs (name, sha) VALUES (branch, tip)
  ON CONFLICT (name) DO UPDATE SET sha = EXCLUDED.sha;
  UPDATE pgit.meta SET value = branch WHERE key = 'head';

  INSERT INTO pgit.reflog (ref, old_sha, new_sha, action, actor)
  VALUES (branch, NULL, tip, 'clone', pgit.actor());

  PERFORM pgit.reset(encode(tip, 'hex'), 'hard');
  RETURN made;
END $$;

CREATE TABLE IF NOT EXISTS pgit.notes (
  commit_sha bytea PRIMARY KEY,
  note       text        NOT NULL,
  author     text,
  at         timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION pgit.note_add(spec text, body text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  target bytea := pgit.rev(spec);
BEGIN
  IF target IS NULL THEN RAISE EXCEPTION 'pgit: cannot resolve %', spec; END IF;
  INSERT INTO pgit.notes (commit_sha, note, author) VALUES (target, body, pgit.actor())
  ON CONFLICT (commit_sha) DO UPDATE SET note = EXCLUDED.note, at = now();
END $$;

CREATE OR REPLACE FUNCTION pgit.note_show(spec text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT n.note FROM pgit.notes n WHERE n.commit_sha = pgit.rev(spec)
$$;

CREATE OR REPLACE FUNCTION pgit.note_delete(spec text) RETURNS void
LANGUAGE sql AS $$ DELETE FROM pgit.notes WHERE commit_sha = pgit.rev(spec) $$;

CREATE TABLE IF NOT EXISTS pgit.rerere (
  signature       bytea PRIMARY KEY,
  tbl             text  NOT NULL,
  resolution_kind text  NOT NULL,
  resolution      jsonb,
  used            int   NOT NULL DEFAULT 0,
  at              timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION pgit.rerere_signature(t text, b jsonb, o jsonb, th jsonb) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$
  SELECT pgit.hash(t || '|' || COALESCE(b::text,'~') || '|' ||
                   COALESCE(o::text,'~') || '|' || COALESCE(th::text,'~'))
$$;

CREATE OR REPLACE FUNCTION pgit.rerere_learn(mid bigint) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n int := 0;
  c record;
BEGIN
  FOR c IN SELECT * FROM pgit.conflicts x WHERE x.merge_id = mid AND x.resolved LOOP
    INSERT INTO pgit.rerere (signature, tbl, resolution_kind, resolution)
    VALUES (pgit.rerere_signature(c.tbl, c.base, c.ours, c.theirs),
            c.tbl, c.resolution_kind, c.resolution)
    ON CONFLICT (signature) DO UPDATE
      SET resolution_kind = EXCLUDED.resolution_kind, resolution = EXCLUDED.resolution;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION pgit.rerere_apply(mid bigint) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n int := 0;
  c record;
  r record;
BEGIN
  FOR c IN SELECT * FROM pgit.conflicts x WHERE x.merge_id = mid AND NOT x.resolved LOOP
    SELECT * INTO r FROM pgit.rerere y
    WHERE y.signature = pgit.rerere_signature(c.tbl, c.base, c.ours, c.theirs);

    IF FOUND THEN
      UPDATE pgit.conflicts
      SET resolution_kind = r.resolution_kind, resolution = r.resolution, resolved = true
      WHERE id = c.id;
      UPDATE pgit.rerere SET used = used + 1 WHERE signature = r.signature;
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION pgit.tree_similarity(a bytea, b bytea) RETURNS numeric
LANGUAGE sql STABLE AS $$
  WITH la AS (SELECT k, rh FROM pgit.leaves(a)),
       lb AS (SELECT k, rh FROM pgit.leaves(b)),
       shared AS (SELECT count(*) AS c FROM la JOIN lb USING (k, rh)),
       total  AS (SELECT (SELECT count(*) FROM la) + (SELECT count(*) FROM lb) AS c)
  SELECT CASE WHEN total.c = 0 THEN 0
              ELSE round((2.0 * shared.c) / total.c, 4) END
  FROM shared, total
$$;

DROP FUNCTION IF EXISTS pgit.table_renames(bytea, bytea);
CREATE OR REPLACE FUNCTION pgit.table_renames(a_sha bytea, b_sha bytea, threshold numeric DEFAULT 0.5)
RETURNS TABLE (old_tbl text, new_tbl text, kind text, similarity numeric)
LANGUAGE sql STABLE AS $$
  WITH gone AS (
    SELECT x.tbl, x.root_hash FROM pgit.trees x WHERE x.commit_sha = a_sha
      AND x.tbl NOT IN (SELECT y.tbl FROM pgit.trees y WHERE y.commit_sha = b_sha)
  ),
  fresh AS (
    SELECT x.tbl, x.root_hash FROM pgit.trees x WHERE x.commit_sha = b_sha
      AND x.tbl NOT IN (SELECT y.tbl FROM pgit.trees y WHERE y.commit_sha = a_sha)
  ),
  scored AS (
    SELECT g.tbl AS old_tbl, f.tbl AS new_tbl,
           CASE WHEN g.root_hash = f.root_hash THEN 1.0
                ELSE pgit.tree_similarity(g.root_hash, f.root_hash) END AS sim
    FROM gone g CROSS JOIN fresh f
  ),
  best AS (
    SELECT DISTINCT ON (s.old_tbl) s.old_tbl, s.new_tbl, s.sim
    FROM scored s WHERE s.sim >= threshold
    ORDER BY s.old_tbl, s.sim DESC, s.new_tbl
  )
  SELECT b.old_tbl, b.new_tbl,
         CASE WHEN b.sim = 1.0 THEN 'identical' ELSE 'similar' END, b.sim
  FROM best b
$$;

CREATE OR REPLACE FUNCTION pgit.octopus_plan(base_sha bytea, heads bytea[])
RETURNS TABLE (tbl text, k text, op text, before jsonb, after jsonb, sides int, conflicted boolean)
LANGUAGE sql STABLE AS $$
  WITH d AS (
    SELECT h.ord, x.tbl, x.k, x.op, x.before, x.after
    FROM unnest(heads) WITH ORDINALITY h(sha, ord)
    CROSS JOIN LATERAL pgit.diff(base_sha, h.sha) x
  )
  SELECT d.tbl, d.k,
         (array_agg(d.op     ORDER BY d.ord))[1],
         (array_agg(d.before ORDER BY d.ord))[1],
         (array_agg(d.after  ORDER BY d.ord))[1],
         count(DISTINCT d.ord)::int,
         count(DISTINCT d.op || '|' || COALESCE(d.after::text, '~')) > 1
  FROM d GROUP BY d.tbl, d.k
$$;

CREATE OR REPLACE FUNCTION pgit.merge_octopus(branch_names text[], msg text DEFAULT NULL)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  oct_ours    bytea   := pgit.resolve(pgit.head());
  oct_names   text[]  := '{}';
  oct_heads   bytea[] := '{}';
  oct_all     bytea[];
  oct_base    bytea;
  oct_b       text;
  oct_h       bytea;
  oct_msg     text;
  oct_bad     record;
  oct_key     text;
  oct_p       record;
  oct_roots   jsonb;
  oct_summary text;
  oct_new     bytea;
  oct_ts      timestamptz := clock_timestamp();
  oct_who     text := pgit.actor();
BEGIN
  IF COALESCE(array_length(branch_names, 1), 0) < 2 THEN
    RAISE EXCEPTION 'pgit: an octopus merge needs at least two branches, use merge for one';
  END IF;

  FOREACH oct_b IN ARRAY branch_names LOOP
    oct_h := pgit.resolve(oct_b);
    IF oct_h IS NULL THEN RAISE EXCEPTION 'pgit: unknown branch %', oct_b; END IF;
    PERFORM pgit.assert_same_schema(oct_ours, oct_h);

    IF oct_h <> oct_ours AND NOT (oct_h = ANY (oct_heads))
       AND pgit.merge_base(oct_ours, oct_h) <> oct_h THEN
      oct_heads := oct_heads || oct_h;
      oct_names := oct_names || oct_b;
    END IF;
  END LOOP;

  IF COALESCE(array_length(oct_heads, 1), 0) = 0 THEN
    RETURN 0;
  END IF;

  IF array_length(oct_heads, 1) = 1 THEN
    RETURN pgit.merge(oct_names[1], msg);
  END IF;

  oct_msg  := COALESCE(msg, 'merge ' || array_to_string(oct_names, ' '));
  oct_all  := ARRAY[oct_ours] || oct_heads;
  oct_base := oct_ours;

  FOREACH oct_h IN ARRAY oct_heads LOOP
    oct_base := pgit.merge_base(oct_base, oct_h);
  END LOOP;

  SELECT * INTO oct_bad FROM pgit.octopus_plan(oct_base, oct_all) p
  WHERE p.conflicted ORDER BY p.tbl, p.k LIMIT 1;

  IF FOUND THEN
    SELECT string_agg(c || '=' || COALESCE(COALESCE(oct_bad.after, oct_bad.before) ->> c, 'null'), ',' ORDER BY c)
    INTO oct_key FROM unnest(pgit.pk_columns(oct_bad.tbl::regclass)) c;

    RAISE EXCEPTION 'pgit: octopus refuses this merge, % of the % heads changed %(%) differently; merge them one at a time',
      oct_bad.sides, array_length(oct_all, 1), oct_bad.tbl, oct_key;
  END IF;

  SET CONSTRAINTS ALL DEFERRED;

  FOR oct_p IN SELECT * FROM pgit.octopus_plan(oct_base, oct_all) LOOP
    IF oct_p.op = 'DELETE' THEN
      PERFORM pgit.apply_row(oct_p.tbl::regclass, 'delete', oct_p.before);
    ELSE
      PERFORM pgit.apply_row(oct_p.tbl::regclass, 'upsert', oct_p.after);
    END IF;
  END LOOP;

  SET CONSTRAINTS ALL IMMEDIATE;

  oct_roots   := pgit.snapshot_trees(oct_ours);
  oct_summary := pgit.roots_summary(oct_roots);
  oct_new     := pgit.hash(
    (SELECT string_agg(encode(x.sha, 'hex'), E'\n' ORDER BY x.ord)
     FROM unnest(oct_all) WITH ORDINALITY x(sha, ord)) || E'\n' ||
    oct_msg || E'\n' ||
    to_char(oct_ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || E'\n' || oct_summary);

  INSERT INTO pgit.commits (sha, parent_sha, author, message, at)
  VALUES (oct_new, oct_ours, oct_who, oct_msg, oct_ts)
  ON CONFLICT (sha) DO NOTHING;

  INSERT INTO pgit.commit_parent (commit_sha, ord, parent_sha)
  SELECT oct_new, (x.ord + 1)::int, x.sha
  FROM unnest(oct_heads) WITH ORDINALITY x(sha, ord)
  ON CONFLICT DO NOTHING;

  INSERT INTO pgit.trees (commit_sha, tbl, root_hash)
  SELECT oct_new, e.key, decode(e.value, 'hex') FROM jsonb_each_text(oct_roots) e
  ON CONFLICT DO NOTHING;

  PERFORM pgit.record_schemas(oct_new);
  UPDATE pgit.changes SET commit_sha = oct_new WHERE commit_sha IS NULL;
  PERFORM pgit.advance_ref(pgit.head(), oct_ours, oct_new);

  RETURN 0;
END $$;
