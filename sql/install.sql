CREATE SCHEMA IF NOT EXISTS grove;

CREATE TABLE IF NOT EXISTS grove.meta (
  key   text PRIMARY KEY,
  value text NOT NULL
);

INSERT INTO grove.meta (key, value) VALUES
  ('canon_version', '1'),
  ('hash_algo', 'sha256'),
  ('chunk_target', '64'),
  ('max_tree_depth', '40'),
  ('max_incremental_keys', '10000'),
  ('rebuild_when_hit_fraction', '0.75'),
  ('splice_max_changes_per_chunk', '8'),
  ('log_events', 'on'),
  ('log_server', 'off'),
  ('log_retain_days', '30')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION grove.setting(k text) RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT value FROM grove.meta WHERE key = k
$$;

CREATE OR REPLACE FUNCTION grove.hash_len() RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT 32 $$;

CREATE OR REPLACE FUNCTION grove.hash(v bytea) RETURNS bytea
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT sha256(v)
$$;

CREATE OR REPLACE FUNCTION grove.hash(v text) RETURNS bytea
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT sha256(convert_to(v, 'UTF8'))
$$;

CREATE OR REPLACE FUNCTION grove.base_type(t oid) RETURNS oid
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

CREATE OR REPLACE FUNCTION grove.canon_numeric(v numeric) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN v IS NULL      THEN NULL
    WHEN v::text = 'NaN' THEN 'NaN'
    ELSE trim_scale(v)::text
  END
$$;

CREATE OR REPLACE FUNCTION grove.canon_float(v float8) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN v IS NULL                  THEN NULL
    WHEN v::text = 'NaN'            THEN 'NaN'
    WHEN v::text = 'Infinity'       THEN 'Infinity'
    WHEN v::text = '-Infinity'      THEN '-Infinity'
    WHEN v = 0::float8              THEN '0'
    ELSE v::text
  END
$$;

CREATE OR REPLACE FUNCTION grove.canon_ts(v timestamptz) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN v IS NULL                       THEN NULL
    WHEN v = 'infinity'::timestamptz     THEN 'infinity'
    WHEN v = '-infinity'::timestamptz    THEN '-infinity'
    ELSE to_char(v AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
  END
$$;

CREATE OR REPLACE FUNCTION grove.canon_tsn(v timestamp) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN v IS NULL                    THEN NULL
    WHEN v = 'infinity'::timestamp    THEN 'infinity'
    WHEN v = '-infinity'::timestamp   THEN '-infinity'
    ELSE to_char(v, 'YYYY-MM-DD"T"HH24:MI:SS.US')
  END
$$;

CREATE OR REPLACE FUNCTION grove.canon_date(v date) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN v IS NULL                 THEN NULL
    WHEN v = 'infinity'::date      THEN 'infinity'
    WHEN v = '-infinity'::date     THEN '-infinity'
    ELSE to_char(v, 'YYYY-MM-DD')
  END
$$;

CREATE OR REPLACE FUNCTION grove.canon_text(x text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN octet_length(x) = length(x) THEN x ELSE normalize(x, NFC) END
$$;

CREATE OR REPLACE FUNCTION grove.canon_expr(col text, typid oid) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  b oid  := grove.base_type(typid);
  k char;
BEGIN
  SELECT typtype INTO k FROM pg_type WHERE oid = b;

  IF k = 'e' THEN
    RETURN format('%I::text', col);
  END IF;

  RETURN CASE b
    WHEN 'numeric'::regtype::oid     THEN format('grove.canon_numeric(%I)', col)
    WHEN 'float4'::regtype::oid      THEN format('grove.canon_float(%I::float8)', col)
    WHEN 'float8'::regtype::oid      THEN format('grove.canon_float(%I)', col)
    WHEN 'timestamptz'::regtype::oid THEN format('grove.canon_ts(%I)', col)
    WHEN 'timestamp'::regtype::oid   THEN format('grove.canon_tsn(%I)', col)
    WHEN 'date'::regtype::oid        THEN format('grove.canon_date(%I)', col)
    WHEN 'bool'::regtype::oid        THEN format('CASE WHEN %I THEN ''t'' ELSE ''f'' END', col)
    WHEN 'bytea'::regtype::oid       THEN format('encode(%I, ''hex'')', col)
    WHEN 'text'::regtype::oid        THEN format('grove.canon_text(%I)', col)
    WHEN 'varchar'::regtype::oid     THEN format('grove.canon_text(%I::text)', col)
    WHEN 'bpchar'::regtype::oid      THEN format('grove.canon_text(%I::text)', col)
    ELSE format('%I::text', col)
  END;
END $$;

CREATE OR REPLACE FUNCTION grove.canon_field_expr(col text, typid oid) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT format(
    '%L || ''='' || CASE WHEN (%s) IS NULL THEN ''~'' ELSE ''#'' || length(%s)::text || '':'' || (%s) END || ''|''',
    col, e.expr, e.expr, e.expr
  )
  FROM (SELECT grove.canon_expr(col, typid) AS expr) e
$$;

CREATE OR REPLACE FUNCTION grove.row_canon_expr(tbl regclass) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT string_agg(grove.canon_field_expr(a.attname, a.atttypid), ' || ' ORDER BY a.attname)
  FROM pg_attribute a
  WHERE a.attrelid = tbl AND a.attnum > 0 AND NOT a.attisdropped
$$;

CREATE OR REPLACE FUNCTION grove.pk_canon_expr(tbl regclass) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  e text;
BEGIN
  SELECT string_agg(grove.canon_field_expr(a.attname, a.atttypid), ' || ' ORDER BY a.attname)
  INTO e
  FROM pg_index i
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
  WHERE i.indrelid = tbl AND i.indisprimary AND NOT a.attisdropped;

  IF e IS NULL THEN
    RAISE EXCEPTION 'grove: table % has no primary key', tbl::text;
  END IF;

  RETURN e;
END $$;
DROP FUNCTION IF EXISTS grove.row_hashes(regclass);
DROP FUNCTION IF EXISTS grove.write_tree(regclass);
DROP FUNCTION IF EXISTS grove.tree_root(regclass);

CREATE OR REPLACE FUNCTION grove.row_hashes_sql(tbl regclass) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT format(
    'SELECT convert_to(%s, ''UTF8'') AS key_bytes, grove.hash(%s) AS hash,'
    ' to_jsonb("grove row") AS image FROM %s "grove row"',
    grove.pk_canon_expr(tbl), grove.row_canon_expr(tbl), tbl::text
  )
$$;

CREATE OR REPLACE FUNCTION grove.row_hashes(tbl regclass)
RETURNS TABLE (key_bytes bytea, hash bytea, image jsonb)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN QUERY EXECUTE grove.row_hashes_sql(tbl);
END $$;

CREATE OR REPLACE FUNCTION grove.is_boundary(key_bytes bytea, target int DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT ('x' || encode(substring(grove.hash(key_bytes) FROM 1 FOR 3), 'hex'))::bit(24)::int
         % COALESCE(target, grove.setting('chunk_target')::int) = 0
$$;

CREATE OR REPLACE FUNCTION grove.chunk_stats(tbl regclass)
RETURNS TABLE (rows bigint, chunks bigint)
LANGUAGE sql STABLE AS $$
  WITH lvl AS (SELECT key_bytes FROM grove.row_hashes(tbl)),
  marked AS (
    SELECT COALESCE(
      SUM(CASE WHEN grove.is_boundary(key_bytes) THEN 1 ELSE 0 END)
        OVER (ORDER BY key_bytes ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS chunk
    FROM lvl
  )
  SELECT count(*)::bigint, count(DISTINCT chunk)::bigint FROM marked
$$;

CREATE TABLE IF NOT EXISTS grove.nodes (
  hash    bytea PRIMARY KEY,
  level   int   NOT NULL,
  entries jsonb NOT NULL
);

CREATE TABLE IF NOT EXISTS grove.trees (
  commit_sha bytea NOT NULL,
  tbl        text  NOT NULL,
  root_hash  bytea NOT NULL,
  PRIMARY KEY (commit_sha, tbl)
);

ALTER TABLE grove.nodes ADD COLUMN IF NOT EXISTS base_hash bytea;
ALTER TABLE grove.nodes ADD COLUMN IF NOT EXISTS delta jsonb;
ALTER TABLE grove.nodes ADD COLUMN IF NOT EXISTS seq bigserial;
ALTER TABLE grove.nodes ALTER COLUMN entries DROP NOT NULL;

ALTER TABLE grove.nodes ADD COLUMN IF NOT EXISTS hashes bytea;
ALTER TABLE grove.nodes ADD COLUMN IF NOT EXISTS keys   text[];

CREATE INDEX IF NOT EXISTS nodes_base_idx ON grove.nodes (base_hash);

CREATE INDEX IF NOT EXISTS nodes_group_idx ON grove.nodes (level, (keys[1]), seq DESC)
  WHERE entries IS NOT NULL;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM grove.nodes WHERE delta IS NOT NULL LIMIT 1)
     AND COALESCE((SELECT value FROM grove.meta WHERE key = 'delta_format'), '1') <> '2' THEN
    RAISE EXCEPTION 'grove: this database holds deltas with character offsets, and this '
      'version reads byte offsets. They would resolve to corrupt nodes rather than '
      'failing. Run SELECT grove.unpack(); on the current version first, then install '
      'this one and SELECT grove.repack();';
  END IF;
END $$;

DO $$
DECLARE
  ours   int := 4;
  theirs int := COALESCE((SELECT value FROM grove.meta WHERE key = 'format_version')::int, 0);
  has_data boolean := EXISTS (SELECT 1 FROM grove.nodes LIMIT 1);
BEGIN
  IF theirs > ours THEN
    RAISE EXCEPTION 'grove: this database was written by a newer grove (on-disk format %, this one '
      'reads %). Installing over it would corrupt it. Use the newer grove, or rebuild: your tables '
      'are the source of truth.', theirs, ours;
  END IF;

  IF theirs > 0 AND theirs < ours AND has_data THEN
    RAISE EXCEPTION 'grove: this database is on on-disk format % and this grove writes %. There is no '
      'in-place migration. Either stay on the older grove, or drop the history and rebuild it - '
      'TRUNCATE grove.nodes, grove.trees, grove.commits, grove.commit_parent, grove.changes CASCADE; '
      'then commit again.', theirs, ours;
  END IF;

  INSERT INTO grove.meta (key, value) VALUES ('format_version', ours::text)
    ON CONFLICT (key) DO UPDATE SET value = ours::text;
END $$;

INSERT INTO grove.meta (key, value) VALUES ('delta_format', '2')
  ON CONFLICT (key) DO UPDATE SET value = '2';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM grove.nodes WHERE keys IS NULL AND entries IS NOT NULL LIMIT 1) THEN
    RAISE EXCEPTION 'grove: this database holds nodes from the pre-packed format. '
      'Rebuild them before upgrading: your tables are the source of truth, so '
      'SELECT grove.write_tree(tbl) FROM grove.tracked reproduces every tree.';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'nodes_stored_or_delta') THEN
    ALTER TABLE grove.nodes ADD CONSTRAINT nodes_stored_or_delta
      CHECK (entries IS NOT NULL OR (base_hash IS NOT NULL AND delta IS NOT NULL));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION grove.common_prefix(a text, b text) RETURNS int
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
  ab  bytea := convert_to(a, 'UTF8');
  bb  bytea := convert_to(b, 'UTF8');
  lo  int := 0;
  hi  int := least(octet_length(ab), octet_length(bb));
  mid int;
BEGIN
  WHILE lo < hi LOOP
    mid := (lo + hi + 1) / 2;
    IF substring(ab FROM 1 FOR mid) = substring(bb FROM 1 FOR mid)
      THEN lo := mid; ELSE hi := mid - 1; END IF;
  END LOOP;

  WHILE lo > 0 AND lo < octet_length(ab) AND (get_byte(ab, lo) & 192) = 128 LOOP
    lo := lo - 1;
  END LOOP;

  RETURN length(convert_from(substring(ab FROM 1 FOR lo), 'UTF8'));
END $$;

CREATE OR REPLACE FUNCTION grove.common_suffix(a text, b text, cap int) RETURNS int
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
  ab  bytea := convert_to(a, 'UTF8');
  bb  bytea := convert_to(b, 'UTF8');
  la  int := octet_length(ab);
  lb  int := octet_length(bb);
  lo  int := 0;
  hi  int := least(la, lb);
  mid int;
  n   int;
BEGIN
  IF cap <= 0 THEN RETURN 0; END IF;

  WHILE lo < hi LOOP
    mid := (lo + hi + 1) / 2;
    IF substring(ab FROM la - mid + 1 FOR mid) = substring(bb FROM lb - mid + 1 FOR mid)
      THEN lo := mid; ELSE hi := mid - 1; END IF;
  END LOOP;

  WHILE lo > 0 AND lo < la AND (get_byte(ab, la - lo) & 192) = 128 LOOP
    lo := lo - 1;
  END LOOP;

  n := length(convert_from(substring(ab FROM la - lo + 1 FOR lo), 'UTF8'));
  RETURN least(n, cap);
END $$;

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT n.hash, n.delta, n.base_hash FROM grove.nodes n
           WHERE n.entries IS NULL AND n.delta ? 'p' LOOP
    UPDATE grove.nodes t
    SET entries = (substr(b.txt, 1, (r.delta ->> 'p')::int) || (r.delta ->> 'm')
                   || right(b.txt, (r.delta ->> 's')::int))::jsonb,
        delta = NULL, base_hash = NULL
    FROM (SELECT x.entries::text AS txt FROM grove.nodes x WHERE x.hash = r.base_hash) b
    WHERE t.hash = r.hash;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION grove.coalesce_ops(ops jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  out_ops jsonb := '[]'::jsonb;
  last_op jsonb;
  e       jsonb;
BEGIN
  FOR e IN SELECT jsonb_array_elements(ops) LOOP
    IF last_op IS NULL THEN
      last_op := e;
    ELSIF last_op ? 'i' AND e ? 'i' THEN
      last_op := jsonb_build_object('i', (last_op ->> 'i') || (e ->> 'i'));
    ELSIF last_op ? 'c' AND e ? 'c'
      AND (last_op -> 'c' ->> 0)::int + (last_op -> 'c' ->> 1)::int = (e -> 'c' ->> 0)::int THEN
      last_op := jsonb_build_object('c', jsonb_build_array(
        (last_op -> 'c' ->> 0)::int,
        (last_op -> 'c' ->> 1)::int + (e -> 'c' ->> 1)::int));
    ELSE
      out_ops := out_ops || last_op;
      last_op := e;
    END IF;
  END LOOP;

  IF last_op IS NOT NULL THEN out_ops := out_ops || last_op; END IF;
  RETURN out_ops;
END $$;

DROP FUNCTION IF EXISTS grove.apply_delta_txt(text, jsonb);
CREATE OR REPLACE FUNCTION grove.apply_delta_bin(base bytea, d jsonb) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(string_agg(
           CASE WHEN t.e ? 'c'
             THEN substring(base FROM (t.e -> 'c' ->> 0)::int FOR (t.e -> 'c' ->> 1)::int)
             ELSE convert_to(t.e ->> 'i', 'UTF8') END,
           ''::bytea ORDER BY t.ord), ''::bytea)
  FROM jsonb_array_elements(d) WITH ORDINALITY t(e, ord)
$$;

CREATE OR REPLACE FUNCTION grove.make_delta(base jsonb, target jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  bb      bytea := convert_to(base::text, 'UTF8');
  tb      bytea := convert_to(target::text, 'UTF8');
  tt      text  := target::text;
  ops     jsonb := '[]'::jsonb;
  r       record;
  p       int;
  s       int;
  n       int;
  pb      int;
  sb      int;
  hb      int;
  sep_pos int;
  first   boolean := true;
BEGIN
  IF base IS NULL OR target IS NULL OR jsonb_array_length(base) = 0 THEN
    RETURN jsonb_build_array(jsonb_build_object('i', tt));
  END IF;

  ops := ops || jsonb_build_object('c', jsonb_build_array(1, 1));

  FOR r IN
    WITH b AS (
      SELECT x.ord, x.e::text AS t
      FROM jsonb_array_elements(base) WITH ORDINALITY x(e, ord)
    ),
    bo AS (
      SELECT b.ord, b.t,
             (2 + COALESCE(sum(octet_length(convert_to(b.t, 'UTF8')) + 2) OVER (
                   ORDER BY b.ord ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                   EXCLUDE CURRENT ROW), 0))::int AS pos,
             (b.ord = count(*) OVER ()) AS is_last
      FROM b
    ),
    tg AS (
      SELECT y.ord, y.e::text AS t
      FROM jsonb_array_elements(target) WITH ORDINALITY y(e, ord)
    )
    SELECT tg.ord, tg.t AS want, bo.pos, bo.t AS have, bo.is_last
    FROM tg LEFT JOIN bo ON bo.ord = tg.ord
    ORDER BY tg.ord
  LOOP
    IF NOT first THEN
      ops := ops || CASE WHEN sep_pos IS NOT NULL
        THEN jsonb_build_object('c', jsonb_build_array(sep_pos, 2))
        ELSE jsonb_build_object('i', ', ') END;
    END IF;
    first := false;

    sep_pos := CASE WHEN r.have IS NOT NULL AND NOT r.is_last
                    THEN r.pos + octet_length(convert_to(r.have, 'UTF8')) END;

    IF r.have IS NULL THEN
      ops := ops || jsonb_build_object('i', r.want);
    ELSIF r.have = r.want THEN
      ops := ops || jsonb_build_object('c',
        jsonb_build_array(r.pos, octet_length(convert_to(r.have, 'UTF8'))));
    ELSE
      p  := grove.common_prefix(r.have, r.want);
      s  := grove.common_suffix(r.have, r.want, least(length(r.have), length(r.want)) - p);
      n  := length(r.want) - p - s;
      pb := octet_length(convert_to(substr(r.have, 1, p), 'UTF8'));
      sb := octet_length(convert_to(right(r.have, s), 'UTF8'));
      hb := octet_length(convert_to(r.have, 'UTF8'));

      IF p > 0 THEN ops := ops || jsonb_build_object('c', jsonb_build_array(r.pos, pb)); END IF;
      IF n > 0 THEN ops := ops || jsonb_build_object('i', substr(r.want, p + 1, n)); END IF;
      IF s > 0 THEN
        ops := ops || jsonb_build_object('c', jsonb_build_array(r.pos + hb - sb, sb));
      END IF;
    END IF;
  END LOOP;

  ops := grove.coalesce_ops(ops || jsonb_build_object('c', jsonb_build_array(octet_length(bb), 1)));

  IF grove.apply_delta_bin(bb, ops) <> tb THEN
    RETURN jsonb_build_array(jsonb_build_object('i', tt));
  END IF;

  RETURN ops;
END $$;

CREATE OR REPLACE FUNCTION grove.apply_delta(base jsonb, d jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT convert_from(grove.apply_delta_bin(convert_to(base::text, 'UTF8'), d), 'UTF8')::jsonb
$$;

CREATE OR REPLACE FUNCTION grove.node_parts(hs bytea, ks text[], es jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_array(encode(hs, 'hex'), array_to_string(ks, E'\n'), es)
$$;

CREATE OR REPLACE FUNCTION grove.node_cols(h bytea)
RETURNS TABLE (hashes bytea, keys text[], entries jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  chain jsonb[] := '{}';
  cur   bytea   := h;
  rec   record;
  parts jsonb;
  bin   bytea;
  i     int;
BEGIN
  LOOP
    SELECT n.hashes AS hs, n.keys AS ks, n.entries AS es, n.base_hash AS bh, n.delta AS dl
    INTO rec FROM grove.nodes n WHERE n.hash = cur;
    IF NOT FOUND THEN RETURN; END IF;
    EXIT WHEN rec.es IS NOT NULL;
    chain := chain || rec.dl;
    cur := rec.bh;
  END LOOP;

  IF array_length(chain, 1) IS NULL THEN
    RETURN QUERY SELECT rec.hs, rec.ks, rec.es;
    RETURN;
  END IF;

  bin := convert_to(grove.node_parts(rec.hs, rec.ks, rec.es)::text, 'UTF8');
  FOR i IN REVERSE array_length(chain, 1)..1 LOOP
    bin := grove.apply_delta_bin(bin, chain[i]);
  END LOOP;
  parts := convert_from(bin, 'UTF8')::jsonb;

  RETURN QUERY SELECT decode(parts ->> 0, 'hex'),
                      CASE WHEN parts ->> 1 = '' THEN '{}'::text[]
                           ELSE string_to_array(parts ->> 1, E'\n') END,
                      parts -> 2;
END $$;

CREATE OR REPLACE FUNCTION grove.entries_of(h bytea) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT c.entries FROM grove.node_cols(h) c
$$;

CREATE TABLE IF NOT EXISTS grove.tracked (
  tbl     regclass PRIMARY KEY,
  pk_cols text[]   NOT NULL
);

ALTER TABLE grove.tracked ADD COLUMN IF NOT EXISTS name_at_track text NOT NULL DEFAULT '';

CREATE TABLE IF NOT EXISTS grove.changes (
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

CREATE INDEX IF NOT EXISTS changes_txid_idx ON grove.changes (txid);
CREATE INDEX IF NOT EXISTS changes_tbl_pk_idx ON grove.changes (tbl, (pk::text));

CREATE OR REPLACE FUNCTION grove.actor() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(current_setting('grove.actor', true), ''), current_user)
$$;

CREATE OR REPLACE FUNCTION grove.source() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(current_setting('grove.source', true), ''), 'raw-sql')
$$;

CREATE OR REPLACE FUNCTION grove.pk_of(rec jsonb, cols text[]) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_object_agg(k, rec -> k) FROM unnest(cols) k
$$;

CREATE OR REPLACE FUNCTION grove.journal_truncate() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  cols text[];
BEGIN
  SELECT pk_cols INTO cols FROM grove.tracked WHERE tbl = TG_RELID::regclass;

  EXECUTE format(
    'INSERT INTO grove.changes (txid, tbl, pk, op, before, after, actor, source)
     SELECT txid_current(), %L, grove.pk_of(to_jsonb("grove row"), %L::text[]), ''DELETE'',
            to_jsonb("grove row"), NULL, grove.actor(), grove.source()
     FROM %s "grove row"',
    TG_TABLE_NAME, cols, TG_RELID::regclass::text
  );

  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION grove.pk_columns(tbl regclass) RETURNS text[]
LANGUAGE sql STABLE AS $$
  SELECT array_agg(a.attname ORDER BY a.attname)
  FROM pg_index i
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
  WHERE i.indrelid = tbl AND i.indisprimary AND NOT a.attisdropped
$$;

DROP FUNCTION IF EXISTS grove.track(regclass);
DROP FUNCTION IF EXISTS grove.untrack(regclass);

CREATE OR REPLACE FUNCTION grove.track(target regclass) RETURNS void
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  cols text[] := grove.pk_columns(target);
  started timestamptz := clock_timestamp();
BEGIN
  IF cols IS NULL THEN
    RAISE EXCEPTION 'grove: table % has no primary key', target::text;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_attribute a
    WHERE a.attrelid = target AND a.attnum > 0 AND NOT a.attisdropped
      AND a.attname IN ('grove row', 'grove img')
  ) THEN
    RAISE EXCEPTION 'grove: table % has a column named "grove row" or "grove img", '
      'which collide with the aliases grove generates. Rename it before tracking.',
      target::text;
  END IF;

  INSERT INTO grove.tracked (tbl, pk_cols, name_at_track) VALUES (target, cols, target::text)
  ON CONFLICT (tbl) DO UPDATE SET pk_cols = EXCLUDED.pk_cols, name_at_track = EXCLUDED.name_at_track;

  EXECUTE format('DROP TRIGGER IF EXISTS grove_journal_ins ON %s', target::text);
  EXECUTE format('DROP TRIGGER IF EXISTS grove_journal_upd ON %s', target::text);
  EXECUTE format('DROP TRIGGER IF EXISTS grove_journal_del ON %s', target::text);

  EXECUTE format(
    'CREATE TRIGGER grove_journal_ins AFTER INSERT ON %s
     REFERENCING NEW TABLE AS newrows
     FOR EACH STATEMENT EXECUTE FUNCTION grove.journal_stmt()', target::text);
  EXECUTE format(
    'CREATE TRIGGER grove_journal_upd AFTER UPDATE ON %s
     REFERENCING OLD TABLE AS oldrows NEW TABLE AS newrows
     FOR EACH STATEMENT EXECUTE FUNCTION grove.journal_stmt()', target::text);
  EXECUTE format(
    'CREATE TRIGGER grove_journal_del AFTER DELETE ON %s
     REFERENCING OLD TABLE AS oldrows
     FOR EACH STATEMENT EXECUTE FUNCTION grove.journal_stmt()', target::text);

  EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER grove_journal_ins', target::text);
  EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER grove_journal_upd', target::text);
  EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER grove_journal_del', target::text);

  EXECUTE format('DROP TRIGGER IF EXISTS grove_journal_truncate ON %s', target::text);
  EXECUTE format(
    'CREATE TRIGGER grove_journal_truncate BEFORE TRUNCATE ON %s
     FOR EACH STATEMENT EXECUTE FUNCTION grove.journal_truncate()', target::text);

  PERFORM grove.emit('track', started, jsonb_build_object('table', target::text));

  PERFORM grove.ensure_key_index(target);
END $$;

CREATE OR REPLACE FUNCTION grove.untrack(target regclass) RETURNS void
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  started timestamptz := clock_timestamp();
BEGIN
  EXECUTE format('DROP TRIGGER IF EXISTS grove_journal_ins ON %s', target::text);
  EXECUTE format('DROP TRIGGER IF EXISTS grove_journal_upd ON %s', target::text);
  EXECUTE format('DROP TRIGGER IF EXISTS grove_journal_del ON %s', target::text);
  EXECUTE format('DROP TRIGGER IF EXISTS grove_journal_truncate ON %s', target::text);
  PERFORM grove.emit('untrack', started, jsonb_build_object('table', target::text));

  DELETE FROM grove.tracked WHERE tbl = target;
END $$;

INSERT INTO grove.meta (key, value) VALUES ('head', 'main')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS grove.commits (
  sha        bytea PRIMARY KEY,
  parent_sha bytea REFERENCES grove.commits(sha),
  author     text,
  message    text        NOT NULL,
  at         timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS grove.refs (
  name text  PRIMARY KEY,
  sha  bytea NOT NULL REFERENCES grove.commits(sha)
);

CREATE OR REPLACE FUNCTION grove.head() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(grove.setting('head'), 'main')
$$;

CREATE OR REPLACE FUNCTION grove.resolve(ref_name text) RETURNS bytea
LANGUAGE sql STABLE AS $$
  SELECT sha FROM grove.refs WHERE name = ref_name
$$;

CREATE TABLE IF NOT EXISTS grove.events (
  id          bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  verb        text        NOT NULL,
  ok          boolean     NOT NULL,
  actor       text        NOT NULL,
  branch      text,
  duration_ms numeric     NOT NULL,
  txid        bigint      NOT NULL DEFAULT txid_current(),
  detail      jsonb       NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS events_at_idx ON grove.events (at DESC);
CREATE INDEX IF NOT EXISTS events_verb_idx ON grove.events (verb, at DESC);

CREATE OR REPLACE FUNCTION grove.emit(verb text, started timestamptz, detail jsonb DEFAULT '{}'::jsonb,
                                     ok boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  ms   numeric := round(extract(epoch FROM clock_timestamp() - started) * 1000, 3);
  who  text    := grove.actor();
  br   text    := grove.head();
  wide jsonb;
BEGIN
  IF grove.setting('log_server') = 'on' THEN
    wide := jsonb_build_object('verb', verb, 'ok', ok, 'actor', who, 'branch', br,
                               'duration_ms', ms, 'txid', txid_current()) || detail;
    RAISE LOG 'grove %', wide::text;
  END IF;

  IF grove.setting('log_events') = 'on' THEN
    INSERT INTO grove.events (verb, ok, actor, branch, duration_ms, detail)
    VALUES (verb, ok, who, br, ms, detail);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION grove.commit_sha(
  parent bytea, who text, msg text, ts timestamptz, trees text
) RETURNS bytea
LANGUAGE sql STABLE AS $$
  SELECT grove.hash(
    COALESCE(encode(parent, 'hex'), '') || E'\n' ||
    COALESCE(who, '') || E'\n' ||
    msg || E'\n' ||
    to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || E'\n' ||
    trees
  )
$$;

CREATE OR REPLACE FUNCTION grove.advance_ref(ref_name text, expected bytea, next_sha bytea)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  IF expected IS NULL THEN
    INSERT INTO grove.refs (name, sha) VALUES (ref_name, next_sha)
    ON CONFLICT (name) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n = 0 THEN
      RAISE EXCEPTION 'grove: ref % already exists, refusing to create it', ref_name;
    END IF;
  ELSE
    UPDATE grove.refs SET sha = next_sha WHERE name = ref_name AND sha = expected;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n = 0 THEN
      RAISE EXCEPTION 'grove: ref % moved under us', ref_name;
    END IF;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION grove.record_trees(sha bytea, roots jsonb) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO grove.trees (commit_sha, tbl, root_hash)
  SELECT sha, e.key, decode(e.value, 'hex') FROM jsonb_each_text(roots) e
  ON CONFLICT DO NOTHING
$$;

DROP FUNCTION IF EXISTS grove.commit(text, text, timestamptz);
CREATE OR REPLACE FUNCTION grove.commit(msg text, who text DEFAULT NULL, ts timestamptz DEFAULT now(),
                                       allow_empty boolean DEFAULT false)
RETURNS bytea LANGUAGE plpgsql AS $$
DECLARE
  branch  text  := grove.head();
  parent  bytea := grove.resolve(grove.head());
  summary text;
  roots   jsonb;
  author  text  := COALESCE(who, grove.actor());
  new_sha bytea;
  started timestamptz := clock_timestamp();
  rows_in int;
BEGIN
  roots   := grove.snapshot_trees(parent);
  summary := grove.roots_summary(roots);

  IF NOT allow_empty AND parent IS NOT NULL AND roots =
     (SELECT COALESCE(jsonb_object_agg(t.tbl, encode(t.root_hash, 'hex')), '{}'::jsonb)
      FROM grove.trees t WHERE t.commit_sha = parent)
     AND NOT EXISTS (
       SELECT 1 FROM grove.tracked tr
       WHERE grove.schema_fingerprint(tr.tbl) IS DISTINCT FROM
             (SELECT sc.fingerprint FROM grove.schemas sc
              WHERE sc.commit_sha = parent AND sc.tbl = tr.tbl::text))
  THEN
    RAISE EXCEPTION 'grove: nothing to commit, every tracked table already matches %',
      grove.short_sha(parent)
      USING HINT = 'pass allow_empty := true to record a commit anyway';
  END IF;

  new_sha := grove.commit_sha(parent, author, msg, ts, summary);

  INSERT INTO grove.commits (sha, parent_sha, author, message, at)
  VALUES (new_sha, parent, author, msg, ts)
  ON CONFLICT (sha) DO NOTHING;

  PERFORM grove.record_trees(new_sha, roots);

  PERFORM grove.record_schemas(new_sha);

  UPDATE grove.changes SET commit_sha = new_sha WHERE commit_sha IS NULL;
  GET DIAGNOSTICS rows_in = ROW_COUNT;

  PERFORM grove.advance_ref(branch, parent, new_sha);

  PERFORM grove.emit('commit', started, jsonb_build_object(
    'sha', grove.short_sha(new_sha), 'parent', grove.short_sha(parent),
    'journal_rows', rows_in,
    'tables', (SELECT count(*) FROM jsonb_object_keys(roots))));

  RETURN new_sha;
END $$;

CREATE OR REPLACE FUNCTION grove.ensure_scratch() RETURNS void
LANGUAGE plpgsql SET client_min_messages = warning AS $$
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS grove_lvl   (key_bytes bytea, hash bytea, image jsonb);
  CREATE TEMP TABLE IF NOT EXISTS grove_nxt   (key_bytes bytea, hash bytea, image jsonb);
  CREATE TEMP TABLE IF NOT EXISTS grove_grp   (key_bytes bytea, hash bytea, entries jsonb, hashes bytea, keys text[]);
  CREATE TEMP TABLE IF NOT EXISTS grove_built (key_bytes bytea, hash bytea);
  CREATE TEMP TABLE IF NOT EXISTS grove_new   (key_bytes bytea, hash bytea);
  CREATE TEMP TABLE IF NOT EXISTS grove_l1    (k text COLLATE "C", h text, nk text COLLATE "C", rn bigint);
  CREATE TEMP TABLE IF NOT EXISTS grove_l1hit (rn bigint);
  CREATE TEMP TABLE IF NOT EXISTS grove_old   (k text COLLATE "C", h text, nk text COLLATE "C", rn bigint);
  CREATE TEMP TABLE IF NOT EXISTS grove_hit   (rn bigint);

  CREATE TEMP TABLE IF NOT EXISTS grove_chg   (k text COLLATE "C" PRIMARY KEY, h bytea, v jsonb, rn bigint);
  CREATE TEMP TABLE IF NOT EXISTS grove_plan  (tbl text, k text, action text, merged jsonb, conflict_col text);

  CREATE INDEX IF NOT EXISTS grove_l1_k_idx  ON grove_l1 (k);
  CREATE INDEX IF NOT EXISTS grove_old_k_idx ON grove_old (k);
END $$;

CREATE OR REPLACE FUNCTION grove.write_tree(target regclass) RETURNS bytea
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  n bigint;
BEGIN
  PERFORM grove.ensure_scratch();
  TRUNCATE grove_lvl;
  INSERT INTO grove_lvl SELECT * FROM grove.row_hashes(target);

  SELECT count(*) INTO n FROM grove_lvl;
  IF n = 0 THEN RETURN grove.hash(''::bytea); END IF;

  PERFORM grove.build_one_level(0, true);

  TRUNCATE grove_lvl;
  INSERT INTO grove_lvl SELECT b.key_bytes, b.hash, NULL::jsonb FROM grove_built b;

  RETURN grove.build_up(1);
END $$;

CREATE OR REPLACE FUNCTION grove.tree_root(target regclass) RETURNS bytea
LANGUAGE sql AS $$
  SELECT grove.write_tree(target)
$$;

CREATE OR REPLACE FUNCTION grove.leaves(h bytea)
RETURNS TABLE (k text, rh text, v jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  lvl int := grove.node_level(h);
  e   jsonb;
BEGIN
  IF lvl IS NULL THEN RETURN; END IF;

  IF lvl = 0 THEN
    RETURN QUERY SELECT i.k, i.ch, i.v FROM grove.node_items(h) i;
    RETURN;
  END IF;

  FOR e IN SELECT to_jsonb(i) FROM grove.node_entries(h) i LOOP
    RETURN QUERY SELECT * FROM grove.leaves(decode(e ->> 'ch', 'hex'));
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION grove.diff_pairs(a bytea, b bytea)
RETURNS TABLE (ach bytea, bch bytea)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  lvl int;
  r   record;
BEGIN
  IF a IS NOT DISTINCT FROM b THEN RETURN; END IF;

  IF a IS NULL THEN RETURN QUERY SELECT NULL::bytea, b; RETURN; END IF;
  IF b IS NULL THEN RETURN QUERY SELECT a, NULL::bytea; RETURN; END IF;

  IF grove.node_level(a) IS DISTINCT FROM grove.node_level(b) THEN
    RETURN QUERY SELECT a, NULL::bytea;
    RETURN QUERY SELECT NULL::bytea, b;
    RETURN;
  END IF;

  lvl := COALESCE(grove.node_level(a), grove.node_level(b));
  IF lvl IS NULL THEN RETURN; END IF;

  IF lvl = 0 THEN RETURN QUERY SELECT a, b; RETURN; END IF;

  FOR r IN
    WITH ae AS (
      SELECT e.k, e.ch, lead(e.k) OVER (ORDER BY e.k) AS nk FROM grove.node_entries(a) e
    ),
    be AS (
      SELECT e.k, e.ch, lead(e.k) OVER (ORDER BY e.k) AS nk FROM grove.node_entries(b) e
    ),
    exact AS (
      SELECT ae.k, ae.ch AS ach, be.ch AS bch FROM ae JOIN be ON be.k = ae.k
    ),
    a_rest AS (SELECT ae.* FROM ae WHERE NOT EXISTS (SELECT 1 FROM exact e WHERE e.k = ae.k)),
    b_rest AS (SELECT be.* FROM be WHERE NOT EXISTS (SELECT 1 FROM exact e WHERE e.k = be.k)),
    paired AS (
      SELECT exact.ach, exact.bch FROM exact
      UNION
      SELECT a_rest.ch AS ach, be.ch AS bch
      FROM a_rest LEFT JOIN be
        ON a_rest.k < COALESCE(be.nk, 'g') AND be.k < COALESCE(a_rest.nk, 'g')
      UNION
      SELECT ae.ch AS ach, b_rest.ch AS bch
      FROM b_rest LEFT JOIN ae
        ON ae.k < COALESCE(b_rest.nk, 'g') AND b_rest.k < COALESCE(ae.nk, 'g')
    )
    SELECT DISTINCT paired.ach, paired.bch FROM paired
    WHERE paired.ach IS DISTINCT FROM paired.bch
  LOOP
    RETURN QUERY SELECT * FROM grove.diff_pairs(decode(r.ach, 'hex'), decode(r.bch, 'hex'));
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION grove.node_items(h bytea)
RETURNS TABLE (k text, ch text, v jsonb)
LANGUAGE sql STABLE AS $$
  WITH node AS MATERIALIZED (
    SELECT CASE WHEN n.entries IS NOT NULL THEN n.keys
                ELSE (SELECT c.keys FROM grove.node_cols(n.hash) c) END AS keys,
           CASE WHEN n.entries IS NOT NULL THEN n.hashes
                ELSE (SELECT c.hashes FROM grove.node_cols(n.hash) c) END AS hashes,
           CASE WHEN n.entries IS NOT NULL THEN n.entries
                ELSE (SELECT c.entries FROM grove.node_cols(n.hash) c) END AS arr
    FROM grove.nodes n WHERE n.hash = h
  ),
  ks AS (SELECT t.key, t.ord FROM node, unnest(node.keys) WITH ORDINALITY t(key, ord)),
  vs AS (SELECT t.el, t.ord FROM node, jsonb_array_elements(node.arr) WITH ORDINALITY t(el, ord))
  SELECT ks.key,
         encode(substring(node.hashes FROM (ks.ord - 1)::int * grove.hash_len() + 1 FOR grove.hash_len()), 'hex'),
         vs.el
  FROM node, ks LEFT JOIN vs ON vs.ord = ks.ord
$$;

CREATE OR REPLACE FUNCTION grove.node_raw(h bytea)
RETURNS TABLE (keys text[], hashes bytea, entries jsonb)
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN n.entries IS NOT NULL THEN n.keys
              ELSE (SELECT c.keys FROM grove.node_cols(n.hash) c) END,
         CASE WHEN n.entries IS NOT NULL THEN n.hashes
              ELSE (SELECT c.hashes FROM grove.node_cols(n.hash) c) END,
         CASE WHEN n.entries IS NOT NULL THEN n.entries
              ELSE (SELECT c.entries FROM grove.node_cols(n.hash) c) END
  FROM grove.nodes n WHERE n.hash = h
$$;

CREATE OR REPLACE FUNCTION grove.leaf_diff(a bytea, b bytea)
RETURNS TABLE (side text, k text, rh text, v jsonb)
LANGUAGE sql STABLE AS $$
  WITH an AS MATERIALIZED (SELECT * FROM grove.node_raw(a)),
       bn AS MATERIALIZED (SELECT * FROM grove.node_raw(b)),
       ae AS MATERIALIZED (
         SELECT t.key, t.ord, substring(an.hashes FROM (t.ord - 1)::int * grove.hash_len() + 1 FOR grove.hash_len()) AS h
         FROM an, unnest(an.keys) WITH ORDINALITY t(key, ord)
       ),
       be AS MATERIALIZED (
         SELECT t.key, t.ord, substring(bn.hashes FROM (t.ord - 1)::int * grove.hash_len() + 1 FOR grove.hash_len()) AS h
         FROM bn, unnest(bn.keys) WITH ORDINALITY t(key, ord)
       ),
       dd AS (
         SELECT 'a'::text AS s, ae.key, ae.h, ae.ord FROM ae LEFT JOIN be ON be.key = ae.key
           WHERE be.key IS NULL OR be.h IS DISTINCT FROM ae.h
         UNION ALL
         SELECT 'b'::text, be.key, be.h, be.ord FROM be LEFT JOIN ae ON ae.key = be.key
           WHERE ae.key IS NULL OR ae.h IS DISTINCT FROM be.h
       )
  SELECT dd.s, dd.key, encode(dd.h, 'hex'),
         CASE WHEN dd.s = 'a' THEN (SELECT an.entries -> (dd.ord - 1)::int FROM an)
              ELSE (SELECT bn.entries -> (dd.ord - 1)::int FROM bn) END
  FROM dd
  WHERE a IS NOT NULL AND b IS NOT NULL
  UNION ALL
  SELECT 'b'::text, l.k, l.rh, l.v FROM grove.leaves(b) l WHERE a IS NULL
  UNION ALL
  SELECT 'a'::text, l.k, l.rh, l.v FROM grove.leaves(a) l WHERE b IS NULL
$$;

CREATE OR REPLACE FUNCTION grove.diff_leaves(a bytea, b bytea)
RETURNS TABLE (side text, k text, rh text, v jsonb)
LANGUAGE sql STABLE AS $$
  SELECT x.side, x.k, x.rh, x.v
  FROM grove.diff_pairs(a, b) p
  CROSS JOIN LATERAL grove.leaf_diff(p.ach, p.bch) x
$$;

CREATE OR REPLACE FUNCTION grove.lookup(root bytea, key_hex text)
RETURNS TABLE (rh text, v jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  cur bytea := root;
  lvl int;
BEGIN
  LOOP
    lvl := grove.node_level(cur);
    IF lvl IS NULL THEN RETURN; END IF;

    IF lvl = 0 THEN
      RETURN QUERY SELECT i.ch, i.v FROM grove.node_items(cur) i WHERE i.k = key_hex;
      RETURN;
    END IF;

    SELECT decode(i.ch, 'hex') INTO cur
    FROM grove.node_entries(cur) i
    WHERE i.k <= key_hex
    ORDER BY i.k DESC
    LIMIT 1;

    IF cur IS NULL THEN RETURN; END IF;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION grove.diff_tree(a bytea, b bytea)
RETURNS TABLE (k text, op text, before jsonb, after jsonb)
LANGUAGE sql STABLE AS $$
  WITH d AS MATERIALIZED (
    SELECT x.side, x.k, x.rh, x.v FROM grove.diff_leaves(a, b) x
  ),
  pivoted AS (
    SELECT d.k,
           max(d.rh) FILTER (WHERE d.side = 'a') AS arh,
           max(d.rh) FILTER (WHERE d.side = 'b') AS brh,
           (array_agg(d.v) FILTER (WHERE d.side = 'a'))[1] AS av,
           (array_agg(d.v) FILTER (WHERE d.side = 'b'))[1] AS bv
    FROM d GROUP BY d.k
  ),
  resolved AS (
    SELECT p.k, p.av, p.bv, p.arh AS seen_a, p.brh AS seen_b,
           CASE WHEN p.arh IS NOT NULL THEN p.arh
                ELSE (SELECT l.rh FROM grove.lookup(a, p.k) l) END AS arh,
           CASE WHEN p.brh IS NOT NULL THEN p.brh
                ELSE (SELECT l.rh FROM grove.lookup(b, p.k) l) END AS brh
    FROM pivoted p
  )
  SELECT r.k,
         CASE WHEN r.arh IS NULL THEN 'INSERT'
              WHEN r.brh IS NULL THEN 'DELETE'
              ELSE 'UPDATE' END,
         CASE WHEN r.arh IS NULL THEN NULL
              WHEN r.seen_a IS NOT NULL THEN r.av
              ELSE (SELECT l.v FROM grove.lookup(a, r.k) l) END,
         CASE WHEN r.brh IS NULL THEN NULL
              WHEN r.seen_b IS NOT NULL THEN r.bv
              ELSE (SELECT l.v FROM grove.lookup(b, r.k) l) END
  FROM resolved r
  WHERE r.arh IS DISTINCT FROM r.brh
$$;

CREATE OR REPLACE FUNCTION grove.row_matches(tbl_name text, image jsonb, want text)
RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE
  cols text[];
BEGIN
  IF want IS NULL THEN RETURN true; END IF;

  SELECT pk_cols INTO cols FROM grove.tracked WHERE tbl::text = tbl_name;
  IF cols IS NULL THEN RETURN false; END IF;

  IF array_length(cols, 1) <> 1 THEN
    RAISE EXCEPTION 'grove: a row pathspec needs a single column primary key, but % has %',
      tbl_name, array_to_string(cols, ',');
  END IF;

  RETURN image ->> cols[1] = want;
END $$;

DROP FUNCTION IF EXISTS grove.diff(bytea, bytea);

CREATE OR REPLACE FUNCTION grove.diff(a_sha bytea, b_sha bytea, pathspec text DEFAULT NULL)
RETURNS TABLE (tbl text, k text, op text, before jsonb, after jsonb)
LANGUAGE sql STABLE AS $$
  WITH spec AS (
    SELECT NULLIF(split_part(split_part(pathspec, ':', 1), '.', 1), '') AS want_tbl,
           NULLIF(split_part(split_part(pathspec, ':', 1), '.', 2), '') AS want_col,
           NULLIF(split_part(pathspec, ':', 2), '')                     AS want_row
  ),
  tables AS (
    SELECT t.tbl FROM grove.trees t WHERE t.commit_sha = a_sha
    UNION
    SELECT t.tbl FROM grove.trees t WHERE t.commit_sha = b_sha
  ),
  wanted AS (
    SELECT tables.tbl FROM tables, spec
    WHERE spec.want_tbl IS NULL OR tables.tbl = spec.want_tbl
  ),
  raw AS (
    SELECT w.tbl, d.k, d.op, d.before, d.after
    FROM wanted w
    CROSS JOIN LATERAL grove.diff_tree(
      (SELECT root_hash FROM grove.trees WHERE commit_sha = a_sha AND grove.trees.tbl = w.tbl),
      (SELECT root_hash FROM grove.trees WHERE commit_sha = b_sha AND grove.trees.tbl = w.tbl)
    ) d
  )
  SELECT raw.tbl, raw.k, raw.op,
         CASE WHEN spec.want_col IS NULL OR raw.before IS NULL THEN raw.before
              ELSE jsonb_build_object(spec.want_col, raw.before -> spec.want_col) END,
         CASE WHEN spec.want_col IS NULL OR raw.after IS NULL THEN raw.after
              ELSE jsonb_build_object(spec.want_col, raw.after -> spec.want_col) END
  FROM raw, spec
  WHERE grove.row_matches(raw.tbl, COALESCE(raw.before, raw.after), spec.want_row)
    AND (spec.want_col IS NULL
         OR COALESCE(raw.before -> spec.want_col, 'null'::jsonb)
            IS DISTINCT FROM COALESCE(raw.after -> spec.want_col, 'null'::jsonb))
$$;

CREATE OR REPLACE FUNCTION grove.diff_stat(a_sha bytea, b_sha bytea, pathspec text DEFAULT NULL)
RETURNS TABLE (tbl text, inserted bigint, updated bigint, deleted bigint)
LANGUAGE sql STABLE AS $$
  SELECT d.tbl,
         count(*) FILTER (WHERE d.op = 'INSERT'),
         count(*) FILTER (WHERE d.op = 'UPDATE'),
         count(*) FILTER (WHERE d.op = 'DELETE')
  FROM grove.diff(a_sha, b_sha, pathspec) d
  GROUP BY d.tbl
  ORDER BY d.tbl
$$;

CREATE OR REPLACE FUNCTION grove.diff_numstat(a_sha bytea, b_sha bytea, pathspec text DEFAULT NULL)
RETURNS TABLE (added bigint, removed bigint, tbl text)
LANGUAGE sql STABLE AS $$
  SELECT count(*) FILTER (WHERE d.op IN ('INSERT', 'UPDATE')),
         count(*) FILTER (WHERE d.op IN ('DELETE', 'UPDATE')),
         d.tbl
  FROM grove.diff(a_sha, b_sha, pathspec) d
  GROUP BY d.tbl
  ORDER BY d.tbl
$$;

CREATE OR REPLACE FUNCTION grove.diff_shortstat(a_sha bytea, b_sha bytea, pathspec text DEFAULT NULL)
RETURNS TABLE (tables bigint, insertions bigint, deletions bigint)
LANGUAGE sql STABLE AS $$
  SELECT count(DISTINCT d.tbl),
         count(*) FILTER (WHERE d.op IN ('INSERT', 'UPDATE')),
         count(*) FILTER (WHERE d.op IN ('DELETE', 'UPDATE'))
  FROM grove.diff(a_sha, b_sha, pathspec) d
$$;

CREATE OR REPLACE FUNCTION grove.diff_name_only(a_sha bytea, b_sha bytea, pathspec text DEFAULT NULL)
RETURNS TABLE (tbl text)
LANGUAGE sql STABLE AS $$
  SELECT DISTINCT d.tbl FROM grove.diff(a_sha, b_sha, pathspec) d ORDER BY 1
$$;

CREATE OR REPLACE FUNCTION grove.diff_name_status(a_sha bytea, b_sha bytea, pathspec text DEFAULT NULL)
RETURNS TABLE (status text, tbl text)
LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN NOT EXISTS (SELECT 1 FROM grove.trees t
                            WHERE t.commit_sha = a_sha AND t.tbl = c.tbl) THEN 'A'
           WHEN NOT EXISTS (SELECT 1 FROM grove.trees t
                            WHERE t.commit_sha = b_sha AND t.tbl = c.tbl) THEN 'D'
           ELSE 'M'
         END,
         c.tbl
  FROM (SELECT DISTINCT d.tbl FROM grove.diff(a_sha, b_sha, pathspec) d) c
  ORDER BY c.tbl
$$;

CREATE OR REPLACE FUNCTION grove.node_level(h bytea) RETURNS int
LANGUAGE sql STABLE AS $$
  SELECT level FROM grove.nodes WHERE hash = h
$$;

CREATE OR REPLACE FUNCTION grove.node_entries(h bytea)
RETURNS TABLE (k text, ch text)
LANGUAGE sql STABLE AS $$
  WITH node AS MATERIALIZED (
    SELECT CASE WHEN n.entries IS NOT NULL THEN n.keys
                ELSE (SELECT c.keys FROM grove.node_cols(n.hash) c) END AS keys,
           CASE WHEN n.entries IS NOT NULL THEN n.hashes
                ELSE (SELECT c.hashes FROM grove.node_cols(n.hash) c) END AS hashes
    FROM grove.nodes n WHERE n.hash = h
  )
  SELECT t.key, encode(substring(node.hashes FROM (t.ord - 1)::int * grove.hash_len() + 1 FOR grove.hash_len()), 'hex')
  FROM node, unnest(node.keys) WITH ORDINALITY t(key, ord)
$$;

DROP FUNCTION IF EXISTS grove.all_columns(regclass);

CREATE OR REPLACE FUNCTION grove.writable_columns(tbl regclass) RETURNS text[]
LANGUAGE sql STABLE AS $$
  SELECT array_agg(a.attname ORDER BY a.attnum)
  FROM pg_attribute a
  WHERE a.attrelid = tbl AND a.attnum > 0 AND NOT a.attisdropped
    AND a.attgenerated = ''
$$;

CREATE OR REPLACE FUNCTION grove.has_identity(tbl regclass) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM pg_attribute a
    WHERE a.attrelid = tbl AND a.attnum > 0 AND NOT a.attisdropped
      AND a.attidentity = 'a')
$$;

DROP FUNCTION IF EXISTS grove.apply_diff(regclass, bytea, bytea);

CREATE OR REPLACE FUNCTION grove.apply_tree_diff(target regclass, a bytea, b bytea) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r       record;
  applied int := 0;
BEGIN
  FOR r IN SELECT * FROM grove.diff_tree(a, b) LOOP
    IF r.op = 'INSERT' THEN
      PERFORM grove.apply_row(target, 'upsert', r.after);
    ELSIF r.op = 'DELETE' THEN
      PERFORM grove.apply_row(target, 'delete', r.before);
    ELSE
      PERFORM grove.apply_row(target, 'upsert', r.after);
    END IF;
    applied := applied + 1;
  END LOOP;

  RETURN applied;
END $$;

CREATE OR REPLACE FUNCTION grove.apply_diff(
  target regclass, a_sha bytea, b_sha bytea, source text DEFAULT NULL
) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  src text  := COALESCE(source, target::text);
  a   bytea;
  b   bytea;
BEGIN
  SELECT root_hash INTO a FROM grove.trees WHERE commit_sha = a_sha AND tbl = src;
  SELECT root_hash INTO b FROM grove.trees WHERE commit_sha = b_sha AND tbl = src;
  RETURN grove.apply_tree_diff(target, a, b);
END $$;

ALTER TABLE grove.changes ADD COLUMN IF NOT EXISTS commit_sha bytea;
CREATE INDEX IF NOT EXISTS changes_commit_idx ON grove.changes (commit_sha);

CREATE OR REPLACE FUNCTION grove.ancestry(from_sha bytea, to_sha bytea) RETURNS bytea[]
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE w AS (
    SELECT c.sha, c.parent_sha FROM grove.commits c WHERE c.sha = to_sha
    UNION ALL
    SELECT c.sha, c.parent_sha
    FROM w JOIN grove.commits c ON c.sha = w.parent_sha
    WHERE w.sha IS DISTINCT FROM from_sha
  )
  SELECT array_agg(sha) FROM w WHERE sha IS DISTINCT FROM from_sha
$$;

CREATE OR REPLACE FUNCTION grove.diff_journal(a_sha bytea, b_sha bytea)
RETURNS TABLE (tbl text, k text, op text, before jsonb, after jsonb)
LANGUAGE sql STABLE AS $$
  WITH path AS (SELECT unnest(grove.ancestry(a_sha, b_sha)) AS sha),
  touched AS (
    SELECT c.tbl, c.pk::text AS k, c.before, c.after, c.id
    FROM grove.changes c JOIN path p ON p.sha = c.commit_sha
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

DROP FUNCTION IF EXISTS grove.revert(bytea);
CREATE OR REPLACE FUNCTION grove.revert(target_sha bytea, msg text DEFAULT NULL) RETURNS bytea
LANGUAGE plpgsql AS $$
DECLARE
  parent    bytea;
  r         record;
  applied   int := 0;
  conflicts bigint;
  found_it  boolean;
  guard     jsonb;
  orig_msg  text;
  new_sha   bytea;
  started   timestamptz := clock_timestamp();
BEGIN
  SELECT true, c.parent_sha, c.message INTO found_it, parent, orig_msg
  FROM grove.commits c WHERE c.sha = target_sha;

  IF NOT COALESCE(found_it, false) THEN
    RAISE EXCEPTION 'grove: unknown commit %', encode(target_sha, 'hex');
  END IF;

  FOR r IN SELECT DISTINCT t.tbl FROM grove.trees t WHERE t.commit_sha = target_sha LOOP
    SELECT count(*) INTO conflicts
    FROM grove.diff(parent, target_sha, r.tbl) d
    WHERE grove.live_hash(r.tbl::regclass, d.k) IS DISTINCT FROM
          (SELECT lo.rh FROM grove.lookup(
             (SELECT t2.root_hash FROM grove.trees t2
              WHERE t2.commit_sha = target_sha AND t2.tbl = r.tbl), d.k) lo);

    IF conflicts > 0 THEN
      RAISE EXCEPTION 'grove: % row(s) in % changed since commit %, refusing to revert',
        conflicts, r.tbl, encode(target_sha, 'hex');
    END IF;
  END LOOP;

  guard := grove.replay_begin();
  SET CONSTRAINTS ALL DEFERRED;

  FOR r IN SELECT DISTINCT t.tbl FROM grove.trees t WHERE t.commit_sha = target_sha LOOP
    applied := applied + grove.apply_diff(r.tbl::regclass, target_sha, parent, r.tbl);
  END LOOP;

  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM grove.replay_end(guard);

  new_sha := grove.commit(
    COALESCE(msg, 'Revert "' || COALESCE(orig_msg, grove.short_sha(target_sha)) || '"'),
    NULL, now(), false);

  PERFORM grove.emit('revert', started, jsonb_build_object(
    'reverted', grove.short_sha(target_sha), 'sha', grove.short_sha(new_sha), 'rows', applied));

  RETURN new_sha;
END $$;

CREATE OR REPLACE FUNCTION grove.short_sha(v bytea) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT substring(encode(v, 'hex') FROM 1 FOR 7)
$$;

CREATE OR REPLACE FUNCTION grove.log(start_sha bytea DEFAULT NULL, pathspec text DEFAULT NULL)
RETURNS TABLE (depth int, sha bytea, parent_sha bytea, author text, message text, at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE walk AS (
    SELECT 0 AS depth, c.sha, c.parent_sha, c.author, c.message, c.at
    FROM grove.commits c
    WHERE c.sha = COALESCE(start_sha, grove.resolve(grove.head()))
    UNION ALL
    SELECT w.depth + 1, c.sha, c.parent_sha, c.author, c.message, c.at
    FROM walk w
    JOIN grove.commits c ON c.sha = w.parent_sha
  )
  SELECT w.depth, w.sha, w.parent_sha, w.author, w.message, w.at
  FROM walk w
  WHERE pathspec IS NULL
     OR EXISTS (SELECT 1 FROM grove.diff(w.parent_sha, w.sha, pathspec))
  ORDER BY w.depth
$$;

CREATE OR REPLACE FUNCTION grove.show(target_sha bytea, pathspec text DEFAULT NULL)
RETURNS TABLE (tbl text, k text, op text, before jsonb, after jsonb)
LANGUAGE sql STABLE AS $$
  SELECT d.tbl, d.k, d.op, d.before, d.after
  FROM grove.diff(
    (SELECT c.parent_sha FROM grove.commits c WHERE c.sha = target_sha),
    target_sha,
    pathspec
  ) d
$$;

CREATE OR REPLACE FUNCTION grove.is_dirty() RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
  h bytea := grove.resolve(grove.head());
  r record;
BEGIN
  IF h IS NULL THEN
    RETURN EXISTS (SELECT 1 FROM grove.changes);
  END IF;

  FOR r IN SELECT t.tbl FROM grove.tracked t LOOP
    IF grove.write_tree(r.tbl) IS DISTINCT FROM
       (SELECT t2.root_hash FROM grove.trees t2
        WHERE t2.commit_sha = h AND t2.tbl = r.tbl::text) THEN
      RETURN true;
    END IF;
  END LOOP;

  RETURN false;
END $$;

CREATE OR REPLACE FUNCTION grove.branch(branch_name text, at_sha bytea DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  target bytea := COALESCE(at_sha, grove.resolve(grove.head()));
  started timestamptz := clock_timestamp();
BEGIN
  IF target IS NULL THEN
    RAISE EXCEPTION 'grove: nothing committed yet, cannot branch';
  END IF;

  IF EXISTS (SELECT 1 FROM grove.refs r WHERE r.name = branch_name) THEN
    RAISE EXCEPTION 'grove: branch % already exists', branch_name;
  END IF;

  PERFORM grove.emit('branch', started, jsonb_build_object(
    'name', branch_name, 'at', grove.short_sha(target)));

  INSERT INTO grove.refs (name, sha) VALUES (branch_name, target);
END $$;

CREATE OR REPLACE FUNCTION grove.branches()
RETURNS TABLE (name text, sha bytea, is_head boolean)
LANGUAGE sql STABLE AS $$
  SELECT r.name, r.sha, r.name = grove.head() FROM grove.refs r ORDER BY r.name
$$;

CREATE OR REPLACE FUNCTION grove.checkout(branch_name text, force boolean DEFAULT false) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  cur     bytea := grove.resolve(grove.head());
  tgt     bytea := grove.resolve(branch_name);
  r       record;
  applied int := 0;
  guard   jsonb;
  started timestamptz := clock_timestamp();
BEGIN
  IF tgt IS NULL THEN
    RAISE EXCEPTION 'grove: unknown branch %', branch_name;
  END IF;

  PERFORM grove.assert_live_schema(tgt);

  IF NOT force AND grove.is_dirty() THEN
    RAISE EXCEPTION 'grove: uncommitted changes present, refusing to checkout %', branch_name;
  END IF;

  guard := grove.replay_begin();
  SET CONSTRAINTS ALL DEFERRED;

  FOR r IN SELECT DISTINCT t.tbl FROM grove.trees t WHERE t.commit_sha IN (cur, tgt) LOOP
    applied := applied + grove.apply_diff(r.tbl::regclass, cur, tgt, r.tbl);
  END LOOP;

  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM grove.replay_end(guard);

  DELETE FROM grove.changes WHERE commit_sha IS NULL;
  UPDATE grove.meta SET value = branch_name WHERE key = 'head';

  PERFORM grove.emit('checkout', started, jsonb_build_object(
    'to', branch_name, 'from', grove.short_sha(cur), 'rows', applied, 'forced', force));

  RETURN applied;
END $$;

CREATE OR REPLACE FUNCTION grove.delete_branch(branch_name text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  started timestamptz := clock_timestamp();
BEGIN
  IF branch_name = grove.head() THEN
    RAISE EXCEPTION 'grove: cannot delete %, it is the checked out branch', branch_name;
  END IF;

  PERFORM grove.emit('delete_branch', started, jsonb_build_object(
    'name', branch_name, 'was', grove.short_sha(grove.resolve(branch_name))));

  DELETE FROM grove.refs r WHERE r.name = branch_name;
END $$;

CREATE TABLE IF NOT EXISTS grove.commit_parent (
  commit_sha bytea NOT NULL REFERENCES grove.commits(sha) ON DELETE CASCADE,
  ord        int   NOT NULL CHECK (ord >= 2),
  parent_sha bytea NOT NULL REFERENCES grove.commits(sha) ON DELETE CASCADE,
  PRIMARY KEY (commit_sha, ord)
);

CREATE INDEX IF NOT EXISTS grove_commit_parent_parent_idx ON grove.commit_parent (parent_sha);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'grove' AND table_name = 'commits'
               AND column_name = 'parent2_sha') THEN
    EXECUTE $q$ INSERT INTO grove.commit_parent (commit_sha, ord, parent_sha)
                SELECT sha, 2, parent2_sha FROM grove.commits WHERE parent2_sha IS NOT NULL
                ON CONFLICT DO NOTHING $q$;
    EXECUTE 'ALTER TABLE grove.commits DROP COLUMN parent2_sha';
  END IF;
END $$;

CREATE OR REPLACE VIEW grove.parent_edge AS
  SELECT c.sha AS child, c.parent_sha AS parent, 1 AS ord
  FROM grove.commits c WHERE c.parent_sha IS NOT NULL
  UNION ALL
  SELECT p.commit_sha, p.parent_sha, p.ord FROM grove.commit_parent p;

CREATE OR REPLACE FUNCTION grove.parents_of(c_sha bytea)
RETURNS TABLE (ord int, parent bytea)
LANGUAGE sql STABLE AS $$
  SELECT e.ord, e.parent FROM grove.parent_edge e WHERE e.child = c_sha ORDER BY e.ord
$$;

CREATE SEQUENCE IF NOT EXISTS grove.merge_seq;

CREATE TABLE IF NOT EXISTS grove.conflicts (
  id       bigserial PRIMARY KEY,
  merge_id bigint NOT NULL,
  tbl      text   NOT NULL,
  k        text   NOT NULL,
  col      text,
  base     jsonb,
  ours     jsonb,
  theirs   jsonb
);

CREATE OR REPLACE FUNCTION grove.ancestors(from_sha bytea)
RETURNS TABLE (a bytea)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE w AS (
    SELECT c.sha FROM grove.commits c WHERE c.sha = from_sha
    UNION
    SELECT e.parent FROM w JOIN grove.parent_edge e ON e.child = w.sha
  )
  SELECT w.sha FROM w
$$;

DROP FUNCTION IF EXISTS grove.blame(text, text);
CREATE OR REPLACE FUNCTION grove.blame(tbl_name text, key_value text)
RETURNS TABLE (col text, commit_sha bytea, actor text, at timestamptz, value jsonb, exact boolean)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  acc     jsonb := '{}'::jsonb;
  pkcol   text;
  key_hex text;
  img     jsonb;
  c       record;
  k       text;
BEGIN
  SELECT jsonb_object_agg(x.col, jsonb_build_array(encode(x.commit_sha, 'hex'), x.actor,
                                                   to_jsonb(x.at), x.value, to_jsonb(true)))
  INTO acc
  FROM (
    WITH reachable AS (
      SELECT a.a FROM grove.ancestors(grove.resolve(grove.head())) a
    ),
    touching AS (
      SELECT ch.id, ch.op, ch.before, ch.after, ch.commit_sha, ch.actor, ch.at
      FROM grove.changes ch
      WHERE ch.tbl = tbl_name
        AND (ch.commit_sha IS NULL OR ch.commit_sha IN (SELECT r.a FROM reachable r))
        AND grove.row_matches(tbl_name, COALESCE(ch.after, ch.before), key_value)
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
  ) x;

  acc := COALESCE(acc, '{}'::jsonb);

  SELECT (grove.pk_columns(tbl_name::regclass))[1] INTO pkcol;

  EXECUTE format('SELECT encode(convert_to(%s, %L), %L) FROM %s WHERE %I::text = %L LIMIT 1',
                 grove.pk_canon_expr(tbl_name::regclass), 'utf8', 'hex',
                 tbl_name::regclass::text, pkcol, key_value)
  INTO key_hex;

  IF key_hex IS NOT NULL THEN
    FOR c IN SELECT l.sha, l.at, l.author FROM grove.log() l ORDER BY l.depth DESC LOOP
      SELECT lo.v INTO img
      FROM grove.lookup((SELECT t.root_hash FROM grove.trees t
                        WHERE t.commit_sha = c.sha AND t.tbl = tbl_name), key_hex) lo;

      IF img IS NOT NULL THEN
        FOR k IN SELECT jsonb_object_keys(img) LOOP
          IF NOT acc ? k THEN
            acc := acc || jsonb_build_object(k, jsonb_build_array(encode(c.sha, 'hex'), c.author,
                                                                  to_jsonb(c.at), img -> k,
                                                                  to_jsonb(false)));
          END IF;
        END LOOP;
        EXIT;
      END IF;
    END LOOP;
  END IF;

  RETURN QUERY
  SELECT e.key,
         decode(e.value ->> 0, 'hex'),
         e.value ->> 1,
         (e.value ->> 2)::timestamptz,
         e.value -> 3,
         (e.value ->> 4)::boolean
  FROM jsonb_each(acc) e
  ORDER BY e.key;
END $$;

CREATE OR REPLACE FUNCTION grove.merge_base(a_sha bytea, b_sha bytea) RETURNS bytea
LANGUAGE plpgsql AS $$
DECLARE
  arr bytea[];
BEGIN
  WITH common AS (
    SELECT x.a AS s FROM grove.ancestors(a_sha) x
    INTERSECT
    SELECT y.a FROM grove.ancestors(b_sha) y
  ),
  best AS (
    SELECT c.s FROM common c
    WHERE NOT EXISTS (
      SELECT 1 FROM common c2
      WHERE c2.s <> c.s AND c.s IN (SELECT z.a FROM grove.ancestors(c2.s) z)
    )
  )
  SELECT array_agg(b.s ORDER BY b.s) INTO arr FROM best b;

  IF arr IS NULL OR cardinality(arr) = 0 THEN
    RAISE EXCEPTION 'grove: the two commits share no history';
  END IF;

  IF cardinality(arr) = 1 THEN
    RETURN arr[1];
  END IF;

  IF cardinality(arr) > 2 THEN
    RAISE EXCEPTION 'grove: % merge bases; only a criss-cross of two is resolved automatically',
      cardinality(arr);
  END IF;

  RETURN grove.virtual_merge(arr[1], arr[2]);
END $$;

CREATE OR REPLACE FUNCTION grove.merge_plan_raw(base_sha bytea, our_sha bytea, their_sha bytea)
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
    SELECT DISTINCT x.tbl AS name FROM grove.trees x
    WHERE x.commit_sha IN (base_sha, our_sha, their_sha)
  LOOP
    SELECT x.root_hash INTO broot FROM grove.trees x WHERE x.commit_sha = base_sha  AND x.tbl = t.name;
    SELECT x.root_hash INTO oroot FROM grove.trees x WHERE x.commit_sha = our_sha   AND x.tbl = t.name;
    SELECT x.root_hash INTO troot FROM grove.trees x WHERE x.commit_sha = their_sha AND x.tbl = t.name;

    FOR key IN
      SELECT COALESCE(dobj.k, dthr.k) AS kk,
             COALESCE(dobj.b, dthr.b) AS bimg,
             CASE WHEN dobj.k IS NULL THEN dthr.b ELSE dobj.o END AS oimg,
             CASE WHEN dthr.k IS NULL THEN dobj.b ELSE dthr.t END AS timg
      FROM (SELECT d.k, d.before AS b, d.after AS o FROM grove.diff_tree(broot, oroot) d) dobj
      FULL OUTER JOIN
           (SELECT d.k, d.before AS b, d.after AS t FROM grove.diff_tree(broot, troot) d) dthr
        ON dthr.k = dobj.k
    LOOP
      bimg := key.bimg;
      oimg := key.oimg;
      timg := key.timg;

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

CREATE OR REPLACE FUNCTION grove.apply_row(target regclass, action text, img jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  pk       text[] := grove.pk_columns(target);
  cols     text[] := grove.writable_columns(target);
  pk_pred  text; set_cols text; set_vals text;
  override text := CASE WHEN grove.has_identity(target) THEN ' OVERRIDING SYSTEM VALUE' ELSE '' END;
  upd_assign text;
  touched  int;
BEGIN
  SELECT string_agg(format('"grove row".%I = "grove img".%I', c, c), ' AND ') INTO pk_pred FROM unnest(pk) c;
  SELECT string_agg(format('%I', c), ', ')  INTO set_cols FROM unnest(cols) c;
  SELECT string_agg(format('"grove img".%I', c), ', ') INTO set_vals FROM unnest(cols) c;

  IF action = 'delete' THEN
    EXECUTE format('DELETE FROM %s "grove row" USING jsonb_populate_record(NULL::%s, $1) "grove img" WHERE %s',
                   target::text, target::text, pk_pred) USING img;
    RETURN;
  END IF;

  SELECT string_agg(format('%I = "grove img".%I', c, c), ', ') INTO upd_assign
  FROM unnest(cols) c WHERE NOT (c = ANY (pk));

  IF upd_assign IS NULL THEN
    EXECUTE format('SELECT 1 FROM %s "grove row", jsonb_populate_record(NULL::%s, $1) "grove img" WHERE %s',
                   target::text, target::text, pk_pred) USING img;
  ELSE
    EXECUTE format('UPDATE %s "grove row" SET %s FROM jsonb_populate_record(NULL::%s, $1) "grove img" WHERE %s',
                   target::text, upd_assign, target::text, pk_pred) USING img;
  END IF;
  GET DIAGNOSTICS touched = ROW_COUNT;

  IF touched = 0 THEN
    EXECUTE format('INSERT INTO %s (%s)%s SELECT %s FROM jsonb_populate_record(NULL::%s, $1) "grove img"',
                   target::text, set_cols, override, set_vals, target::text) USING img;
  END IF;
END $$;

DROP FUNCTION IF EXISTS grove.merge(text, text);

CREATE OR REPLACE FUNCTION grove.merge(branch_name text, msg text DEFAULT NULL, opt text DEFAULT NULL)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  ours    bytea := grove.resolve(grove.head());
  theirs  bytea := grove.resolve(branch_name);
  base    bytea;
  r       record;
  n       int := 0;
  mid     bigint;
  started timestamptz := clock_timestamp();
BEGIN
  IF theirs IS NULL THEN
    RAISE EXCEPTION 'grove: unknown branch %', branch_name;
  END IF;

  IF opt IS NOT NULL AND opt NOT IN ('ours', 'theirs', 'ours-tree') THEN
    RAISE EXCEPTION 'grove: unknown strategy option %, expected ours, theirs or ours-tree', opt;
  END IF;

  PERFORM grove.assert_same_schema(ours, theirs);
  base := grove.merge_base(ours, theirs);

  IF base = theirs THEN
    RETURN 0;
  END IF;

  IF opt = 'ours-tree' THEN
    mid := nextval('grove.merge_seq');
    INSERT INTO grove.merges (id, branch, ours_sha, theirs_sha, base_sha, msg)
    VALUES (mid, grove.head(), ours, theirs, ours, COALESCE(msg, 'merge ' || branch_name || ' (ours tree)'));
    RETURN grove.merge_finish(mid);
  END IF;

  IF base = ours THEN
    SET CONSTRAINTS ALL DEFERRED;
    FOR r IN SELECT DISTINCT x.tbl FROM grove.trees x WHERE x.commit_sha IN (ours, theirs) LOOP
      PERFORM grove.apply_diff(r.tbl::regclass, ours, theirs, r.tbl);
    END LOOP;
    SET CONSTRAINTS ALL IMMEDIATE;
    PERFORM grove.advance_ref(grove.head(), ours, theirs);
    DELETE FROM grove.changes WHERE commit_sha IS NULL;
    RETURN 0;
  END IF;

  mid := nextval('grove.merge_seq');
  INSERT INTO grove.merges (id, branch, ours_sha, theirs_sha, base_sha, msg)
  VALUES (mid, grove.head(), ours, theirs, base, COALESCE(msg, 'merge ' || branch_name));

  n := grove.record_conflicts(mid, base, ours, theirs);

  IF n > 0 THEN
    PERFORM grove.rerere_apply(mid);
    SELECT count(*) INTO n FROM grove.conflicts WHERE merge_id = mid AND NOT resolved;
  END IF;

  IF n > 0 AND opt IN ('ours', 'theirs') THEN
    PERFORM grove.resolve_all(mid, opt);
    n := 0;
  END IF;

  IF n > 0 THEN
    PERFORM grove.emit('merge', started, jsonb_build_object(
      'branch', branch_name, 'merge_id', mid, 'conflicts', n, 'finished', false), false);
    RETURN n;
  END IF;

  PERFORM grove.emit('merge', started, jsonb_build_object(
    'branch', branch_name, 'merge_id', mid, 'conflicts', 0, 'finished', true));

  RETURN grove.merge_finish(mid);
END $$;

CREATE TABLE IF NOT EXISTS grove.rebase_state (
  branch       text  PRIMARY KEY,
  original_sha bytea NOT NULL,
  onto_sha     bytea NOT NULL
);

DROP FUNCTION IF EXISTS grove.record_conflicts(bytea, bytea, bytea);

CREATE OR REPLACE FUNCTION grove.record_conflicts(mid bigint, base_sha bytea, our_sha bytea, their_sha bytea)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  INSERT INTO grove.conflicts (merge_id, tbl, k, col, base, ours, theirs)
  SELECT mid, mp.tbl, mp.k, mp.conflict_col,
    (SELECT l.v FROM grove.lookup((SELECT x.root_hash FROM grove.trees x
                                  WHERE x.commit_sha = base_sha AND x.tbl = mp.tbl), mp.k) l),
    (SELECT l.v FROM grove.lookup((SELECT x.root_hash FROM grove.trees x
                                  WHERE x.commit_sha = our_sha AND x.tbl = mp.tbl), mp.k) l),
    (SELECT l.v FROM grove.lookup((SELECT x.root_hash FROM grove.trees x
                                  WHERE x.commit_sha = their_sha AND x.tbl = mp.tbl), mp.k) l)
  FROM grove.merge_plan(base_sha, our_sha, their_sha) mp
  WHERE mp.action = 'conflict';

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION grove.cherry_pick(target_sha bytea, msg text DEFAULT NULL) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  ours    bytea := grove.resolve(grove.head());
  base    bytea;
  who     text;
  m       text;
  p       record;
  n       int;
  summary text;
  roots   jsonb;
  new_sha bytea;
  ts      timestamptz := clock_timestamp();
  started timestamptz := clock_timestamp();
BEGIN
  SELECT c.parent_sha, c.author, c.message INTO base, who, m
  FROM grove.commits c WHERE c.sha = target_sha;

  IF who IS NULL AND m IS NULL THEN
    RAISE EXCEPTION 'grove: unknown commit %', encode(target_sha, 'hex');
  END IF;

  PERFORM grove.assert_same_schema(target_sha, ours);

  PERFORM grove.ensure_scratch();
  TRUNCATE grove_plan;
  INSERT INTO grove_plan SELECT * FROM grove.merge_plan(base, ours, target_sha);

  SELECT count(*) INTO n FROM grove_plan mp WHERE mp.action = 'conflict';

  IF n > 0 THEN
    PERFORM grove.record_conflicts(nextval('grove.merge_seq'), base, ours, target_sha);
    RETURN n;
  END IF;

  SET CONSTRAINTS ALL DEFERRED;
  FOR p IN SELECT * FROM grove_plan LOOP
    PERFORM grove.apply_row(p.tbl::regclass, p.action, p.merged);
  END LOOP;
  SET CONSTRAINTS ALL IMMEDIATE;

  roots   := grove.snapshot_trees(ours);
  summary := grove.roots_summary(roots);
  new_sha := grove.commit_sha(ours, who, COALESCE(msg, m), ts, summary);

  INSERT INTO grove.commits (sha, parent_sha, author, message, at)
  VALUES (new_sha, ours, who, COALESCE(msg, m), ts)
  ON CONFLICT (sha) DO NOTHING;

  PERFORM grove.record_trees(new_sha, roots);

  PERFORM grove.record_schemas(new_sha);

  UPDATE grove.changes SET commit_sha = new_sha WHERE commit_sha IS NULL;
  PERFORM grove.advance_ref(grove.head(), ours, new_sha);

  PERFORM grove.emit('cherry_pick', started, jsonb_build_object(
    'from', grove.short_sha(target_sha), 'sha', grove.short_sha(new_sha),
    'onto', grove.short_sha(ours)));

  RETURN 0;
END $$;

CREATE OR REPLACE FUNCTION grove.materialise(from_sha bytea, to_sha bytea) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r       record;
  applied int := 0;
BEGIN
  SET CONSTRAINTS ALL DEFERRED;
  FOR r IN SELECT DISTINCT x.tbl FROM grove.trees x WHERE x.commit_sha IN (from_sha, to_sha) LOOP
    applied := applied + grove.apply_diff(r.tbl::regclass, from_sha, to_sha, r.tbl);
  END LOOP;
  SET CONSTRAINTS ALL IMMEDIATE;
  DELETE FROM grove.changes WHERE commit_sha IS NULL;
  RETURN applied;
END $$;

CREATE OR REPLACE FUNCTION grove.rebase(onto_branch text) RETURNS int
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  cur_branch text := grove.head();
  ours   bytea := grove.resolve(cur_branch);
  onto   bytea := grove.resolve(onto_branch);
  base   bytea;
  r      record;
  n      int;
  started timestamptz := clock_timestamp();
BEGIN
  IF onto IS NULL THEN
    RAISE EXCEPTION 'grove: unknown branch %', onto_branch;
  END IF;

  base := grove.merge_base(ours, onto);

  IF base = onto THEN
    PERFORM grove.emit('rebase', started, jsonb_build_object(
      'onto', onto_branch, 'branch', cur_branch, 'was', grove.short_sha(ours),
      'now', grove.short_sha(ours), 'rewritten', false, 'noop', true));
    RETURN 0;
  END IF;

  DROP TABLE IF EXISTS grove_replay;
  CREATE TEMP TABLE grove_replay ON COMMIT DROP AS
    SELECT l.depth, l.sha FROM grove.log(ours) l
    WHERE l.sha NOT IN (SELECT a.a FROM grove.ancestors(base) a);

  INSERT INTO grove.rebase_state (branch, original_sha, onto_sha)
  VALUES (cur_branch, ours, onto)
  ON CONFLICT (branch) DO UPDATE SET original_sha = EXCLUDED.original_sha, onto_sha = EXCLUDED.onto_sha;

  PERFORM grove.materialise(ours, onto);
  PERFORM grove.advance_ref(cur_branch, ours, onto);

  FOR r IN SELECT sha FROM grove_replay ORDER BY depth DESC LOOP
    n := grove.cherry_pick(r.sha);
    IF n > 0 THEN
      PERFORM grove.emit('rebase', started, jsonb_build_object(
        'onto', onto_branch, 'branch', cur_branch, 'was', grove.short_sha(ours),
        'stopped_at', grove.short_sha(r.sha), 'conflicts', n, 'finished', false), false);
      RETURN n;
    END IF;
  END LOOP;

  PERFORM grove.emit('rebase', started, jsonb_build_object(
    'onto', onto_branch, 'branch', cur_branch, 'was', grove.short_sha(ours),
    'now', grove.short_sha(grove.resolve(cur_branch)),
    'rewritten', NOT EXISTS (SELECT 1 FROM grove.ancestors(grove.resolve(cur_branch)) a
                             WHERE a.a = ours)));

  DELETE FROM grove.rebase_state s WHERE s.branch = cur_branch;
  RETURN 0;
END $$;

CREATE OR REPLACE FUNCTION grove.rebase_abort() RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  st record;
  started timestamptz := clock_timestamp();
BEGIN
  SELECT * INTO st FROM grove.rebase_state s WHERE s.branch = grove.head();

  IF st IS NULL THEN
    RAISE EXCEPTION 'grove: no rebase in progress on %', grove.head();
  END IF;

  PERFORM grove.materialise(grove.resolve(grove.head()), st.original_sha);
  UPDATE grove.refs SET sha = st.original_sha WHERE name = st.branch;
  PERFORM grove.emit('rebase_abort', started, jsonb_build_object(
    'branch', st.branch, 'back_to', grove.short_sha(st.original_sha)), false);

  DELETE FROM grove.conflicts;
  DELETE FROM grove.rebase_state s WHERE s.branch = st.branch;
END $$;

CREATE TABLE IF NOT EXISTS grove.schemas (
  commit_sha  bytea NOT NULL,
  tbl         text  NOT NULL,
  fingerprint bytea NOT NULL,
  columns     jsonb NOT NULL,
  PRIMARY KEY (commit_sha, tbl)
);

CREATE OR REPLACE FUNCTION grove.schema_columns(target regclass) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_agg(jsonb_build_object('name', a.attname,
                                      'type', format_type(a.atttypid, a.atttypmod))
                   ORDER BY a.attnum)
  FROM pg_attribute a
  WHERE a.attrelid = target AND a.attnum > 0 AND NOT a.attisdropped
$$;

CREATE OR REPLACE FUNCTION grove.schema_fingerprint(target regclass) RETURNS bytea
LANGUAGE sql STABLE AS $$
  SELECT grove.hash(grove.schema_columns(target)::text)
$$;

ALTER TABLE grove.schemas ADD COLUMN IF NOT EXISTS pk_cols text[];

CREATE OR REPLACE FUNCTION grove.record_schemas(new_sha bytea) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO grove.schemas (commit_sha, tbl, fingerprint, columns, pk_cols)
  SELECT new_sha, x.tbl::text, grove.schema_fingerprint(x.tbl), grove.schema_columns(x.tbl), x.pk_cols
  FROM grove.tracked x
  ON CONFLICT DO NOTHING
$$;

CREATE OR REPLACE FUNCTION grove.assert_same_schema(a_sha bytea, b_sha bytea) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
  bad record;
  ren record;
BEGIN
  SELECT sa.tbl, sa.columns AS acols, sb.columns AS bcols
  INTO bad
  FROM grove.schemas sa
  JOIN grove.schemas sb ON sb.tbl = sa.tbl AND sb.commit_sha = b_sha
  WHERE sa.commit_sha = a_sha AND sa.fingerprint <> sb.fingerprint
  LIMIT 1;

  IF bad.tbl IS NOT NULL THEN
    RAISE EXCEPTION 'grove: table % has a different shape in the two commits, refusing to replay across a schema change (% versus %)',
      bad.tbl, bad.acols::text, bad.bcols::text;
  END IF;

  SELECT * INTO ren FROM grove.table_renames(a_sha, b_sha) r
  ORDER BY r.similarity DESC, r.old_tbl LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'grove: % looks renamed to % between these commits (% match, % of rows in common); following a table rename through a replay is not supported, rename it back or replay table by table',
      ren.old_tbl, ren.new_tbl, ren.kind, round(ren.similarity * 100) || '%';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION grove.key_index_name(target regclass) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT 'grove_key_' || target::oid::text
$$;

CREATE OR REPLACE FUNCTION grove.ensure_key_index(target regclass) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %s (((%s) COLLATE "C"))',
                 grove.key_index_name(target), target::text, grove.pk_canon_expr(target));
EXCEPTION WHEN others THEN
  RAISE WARNING 'grove: no key index on % (%), range reads will scan every row', target::text, SQLERRM;
END $$;

CREATE OR REPLACE FUNCTION grove.row_hashes_keys(target regclass, keys text[])
RETURNS TABLE (key_bytes bytea, hash bytea, image jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE pk text := grove.pk_canon_expr(target);
BEGIN
  RETURN QUERY EXECUTE format(
    'SELECT convert_to(%s, ''UTF8''), grove.hash(%s), to_jsonb("grove row")
     FROM unnest($1) AS grove_kk(grove_key)
     JOIN %s "grove row" ON (%s) COLLATE "C" = grove_kk.grove_key',
    pk, grove.row_canon_expr(target), target::text, pk)
  USING (SELECT array_agg(convert_from(decode(k, 'hex'), 'UTF8')) FROM unnest(keys) k);
END $$;

CREATE OR REPLACE FUNCTION grove.live_hash(target regclass, key_hex text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT encode(r.hash, 'hex')
  FROM grove.row_hashes_keys(target, ARRAY[key_hex]) r
$$;

CREATE OR REPLACE FUNCTION grove.row_hashes_range(target regclass, lo bytea, hi bytea)
RETURNS TABLE (key_bytes bytea, hash bytea, image jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  pk text := grove.pk_canon_expr(target);
BEGIN
  RETURN QUERY EXECUTE format(
    'SELECT convert_to(%s, ''UTF8''), grove.hash(%s), to_jsonb("grove row")
     FROM %s "grove row"
     WHERE (%s) COLLATE "C" >= $1
       AND ($2 IS NULL OR (%s) COLLATE "C" < $2)',
    pk, grove.row_canon_expr(target), target::text, pk, pk)
  USING convert_from(lo, 'UTF8'),
        CASE WHEN hi IS NULL THEN NULL ELSE convert_from(hi, 'UTF8') END;
END $$;

CREATE OR REPLACE FUNCTION grove.build_up(lvl int) RETURNS bytea
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  ct int := grove.setting('chunk_target')::int;
  n     bigint;
  depth int := lvl;
BEGIN
  PERFORM grove.ensure_scratch();

  LOOP
    SELECT count(*) INTO n FROM grove_lvl;
    IF n = 0 THEN RETURN grove.hash(''::bytea); END IF;
    IF n = 1 THEN RETURN (SELECT hash FROM grove_lvl); END IF;
    IF depth > grove.setting('max_tree_depth')::int THEN
      RAISE EXCEPTION 'grove: tree depth exceeded at level %, max_tree_depth is %',
        depth, grove.setting('max_tree_depth');
    END IF;

    TRUNCATE grove_grp;
    INSERT INTO grove_grp (key_bytes, hash, hashes, keys, entries)
      WITH marked AS (
        SELECT key_bytes, hash, image,
               COALESCE(
                 SUM(CASE WHEN grove.is_boundary(key_bytes, ct) THEN 1 ELSE 0 END)
                   OVER (ORDER BY key_bytes ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS chunk
        FROM grove_lvl
      )
      SELECT (array_agg(key_bytes ORDER BY key_bytes))[1],
             grove.hash(string_agg(hash, ''::bytea ORDER BY key_bytes)),
             string_agg(hash, ''::bytea ORDER BY key_bytes),
             array_agg(encode(key_bytes, 'hex') ORDER BY key_bytes),
             CASE WHEN depth = 0
               THEN jsonb_agg(image ORDER BY key_bytes)
               ELSE '[]'::jsonb END
      FROM marked GROUP BY chunk;

    IF (SELECT count(*) FROM grove_grp) = n THEN
      TRUNCATE grove_grp;
      INSERT INTO grove_grp (key_bytes, hash, hashes, keys, entries)
      SELECT (array_agg(key_bytes ORDER BY key_bytes))[1],
             grove.hash(string_agg(hash, ''::bytea ORDER BY key_bytes)),
             string_agg(hash, ''::bytea ORDER BY key_bytes),
             array_agg(encode(key_bytes, 'hex') ORDER BY key_bytes),
             CASE WHEN depth = 0
               THEN jsonb_agg(image ORDER BY key_bytes)
               ELSE '[]'::jsonb END
      FROM grove_lvl;
    END IF;

    INSERT INTO grove.nodes (hash, level, entries, hashes, keys)
    SELECT g.hash, depth, g.entries, g.hashes, g.keys FROM grove_grp g
    ON CONFLICT (hash) DO NOTHING;

    TRUNCATE grove_lvl;
    INSERT INTO grove_lvl SELECT g.key_bytes, g.hash, NULL::jsonb FROM grove_grp g;
    depth := depth + 1;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION grove.changed_keys(target regclass) RETURNS text[]
LANGUAGE plpgsql STABLE AS $$
DECLARE
  res text[];
BEGIN
  EXECUTE format(
    'SELECT array_agg(DISTINCT encode(convert_to(%s, ''UTF8''), ''hex''))
     FROM (SELECT COALESCE(c.after, c.before) AS img FROM grove.changes c
           WHERE c.tbl = %L AND c.commit_sha IS NULL) s,
          LATERAL jsonb_populate_record(NULL::%s, s.img) "grove row"',
    grove.pk_canon_expr(target), target::text, target::text)
  INTO res;

  RETURN COALESCE(res, '{}'::text[]);
END $$;

CREATE OR REPLACE FUNCTION grove.locate_touched_chunks(
  prev_root bytea, changed text[], pure_updates boolean) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  TRUNCATE grove_l1;
  INSERT INTO grove_l1
    SELECT l.k, l.h,
           lead(l.k) OVER (ORDER BY l.k),
           row_number() OVER (ORDER BY l.k)
    FROM grove.nodes_at_level(prev_root, 1) l;

  TRUNCATE grove_l1hit;
  INSERT INTO grove_l1hit
    SELECT DISTINCT o.rn
    FROM unnest(changed) c
    CROSS JOIN LATERAL (
      SELECT x.rn FROM grove_l1 x WHERE x.k <= c ORDER BY x.k DESC LIMIT 1
    ) o;

  IF NOT EXISTS (SELECT 1 FROM grove_l1hit) THEN
    INSERT INTO grove_l1hit VALUES (1);
  END IF;

  IF NOT pure_updates THEN
    INSERT INTO grove_l1hit
    SELECT DISTINCT h.rn + d FROM grove_l1hit h, (VALUES (-1), (1)) AS s(d)
    WHERE h.rn + d BETWEEN 1 AND (SELECT max(rn) FROM grove_l1)
      AND h.rn + d NOT IN (SELECT rn FROM grove_l1hit);
  END IF;

  TRUNCATE grove_old;
  INSERT INTO grove_old
    SELECT i.k, i.ch,
           COALESCE(lead(i.k) OVER (PARTITION BY p.rn ORDER BY i.k), p.nk),
           row_number() OVER (ORDER BY i.k)
    FROM grove_l1 p
    JOIN grove_l1hit hit ON hit.rn = p.rn
    CROSS JOIN LATERAL grove.node_items(decode(p.h, 'hex')) i;

  TRUNCATE grove_hit;
  INSERT INTO grove_hit
    SELECT DISTINCT o.rn
    FROM unnest(changed) c
    CROSS JOIN LATERAL (
      SELECT x.rn FROM grove_old x WHERE x.k <= c ORDER BY x.k DESC LIMIT 1
    ) o;

  IF NOT EXISTS (SELECT 1 FROM grove_hit) THEN
    INSERT INTO grove_hit VALUES (1);
  END IF;

  IF NOT pure_updates THEN
    INSERT INTO grove_hit
    SELECT DISTINCT h.rn + d FROM grove_hit h, (VALUES (-1), (1)) AS s(d)
    WHERE h.rn + d BETWEEN 1 AND (SELECT max(rn) FROM grove_old)
      AND h.rn + d NOT IN (SELECT rn FROM grove_hit);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION grove.rebuild_beats_splice() RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
  ok boolean;
BEGIN
  SELECT (SELECT count(*) FROM grove_hit) >
         ((SELECT count(*) FROM grove_old) * (SELECT count(*) FROM grove_l1)
           / GREATEST((SELECT count(*) FROM grove_l1hit), 1))
         * grove.setting('rebuild_when_hit_fraction')::numeric
  INTO ok;
  RETURN ok;
END $$;

CREATE OR REPLACE FUNCTION grove.changes_are_sparse_in_their_chunks(changed text[])
RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
  ok boolean;
BEGIN
  SELECT (SELECT count(*) FROM grove_hit)
           * grove.setting('splice_max_changes_per_chunk')::int
         > COALESCE(array_length(changed, 1), 0)
  INTO ok;
  RETURN ok;
END $$;

CREATE OR REPLACE FUNCTION grove.splice_touched_chunks(target regclass, changed text[])
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  chunk_rec record;
  chg_rec   record;
  node_e    jsonb;
  node_h    bytea;
  node_k    text[];
  idx       int;
  new_node  bytea;
BEGIN
  TRUNCATE grove_chg;
  INSERT INTO grove_chg (k, h, v, rn)
    SELECT encode(r.key_bytes, 'hex'), r.hash, r.image, o.rn
    FROM grove.row_hashes_keys(target, changed) r
    CROSS JOIN LATERAL (
      SELECT x.rn FROM grove_old x
      WHERE x.k <= encode(r.key_bytes, 'hex') ORDER BY x.k DESC LIMIT 1
    ) o
    ON CONFLICT (k) DO NOTHING;

  FOR chunk_rec IN SELECT o.rn, o.k, o.h FROM grove_old o JOIN grove_hit x ON x.rn = o.rn LOOP
    SELECT r.entries, r.hashes, r.keys
    INTO node_e, node_h, node_k
    FROM grove.node_raw(decode(chunk_rec.h, 'hex')) r;

    FOR chg_rec IN SELECT c.k, c.h, c.v FROM grove_chg c WHERE c.rn = chunk_rec.rn LOOP
      idx := array_position(node_k, chg_rec.k);
      CONTINUE WHEN idx IS NULL;
      node_h := overlay(node_h placing chg_rec.h from (idx - 1) * grove.hash_len() + 1 for grove.hash_len());
      node_e := jsonb_set(node_e, ARRAY[(idx - 1)::text], chg_rec.v);
    END LOOP;

    new_node := grove.hash(node_h);
    INSERT INTO grove.nodes (hash, level, entries, hashes, keys)
    VALUES (new_node, 0, node_e, node_h, node_k)
    ON CONFLICT (hash) DO NOTHING;

    INSERT INTO grove_new VALUES (decode(chunk_rec.k, 'hex'), new_node);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION grove.rebuild_touched_ranges(target regclass) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  ct     int := grove.setting('chunk_target')::int;
  region record;
  hi_key text;
BEGIN
  FOR region IN
    WITH h AS (SELECT DISTINCT rn FROM grove_hit),
    j AS (SELECT h.rn, o.k, o.nk FROM h JOIN grove_old o ON o.rn = h.rn),
    w AS (
      SELECT rn,
             CASE WHEN lag(rn) OVER (ORDER BY rn) = rn - 1
                   AND lag(nk) OVER (ORDER BY rn) = k
                  THEN 0 ELSE 1 END AS brk
      FROM j
    ),
    grp AS (SELECT rn, sum(brk) OVER (ORDER BY rn ROWS UNBOUNDED PRECEDING) AS g FROM w)
    SELECT min(rn) AS lo_rn, max(rn) AS hi_rn FROM grp GROUP BY g ORDER BY 1
  LOOP
    SELECT o.nk INTO hi_key FROM grove_old o WHERE o.rn = region.hi_rn;

    TRUNCATE grove_lvl;
    INSERT INTO grove_lvl
      SELECT * FROM grove.row_hashes_range(
        target,
        (SELECT decode(o.k, 'hex') FROM grove_old o WHERE o.rn = region.lo_rn),
        CASE WHEN hi_key IS NULL THEN NULL ELSE decode(hi_key, 'hex') END);

    TRUNCATE grove_grp;
    INSERT INTO grove_grp (key_bytes, hash, hashes, keys, entries)
      WITH marked AS (
        SELECT key_bytes, hash, image,
               COALESCE(
                 SUM(CASE WHEN grove.is_boundary(key_bytes, ct) THEN 1 ELSE 0 END)
                   OVER (ORDER BY key_bytes ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS chunk
        FROM grove_lvl
      )
      SELECT (array_agg(key_bytes ORDER BY key_bytes))[1],
             grove.hash(string_agg(hash, ''::bytea ORDER BY key_bytes)),
             string_agg(hash, ''::bytea ORDER BY key_bytes),
             array_agg(encode(key_bytes, 'hex') ORDER BY key_bytes),
             jsonb_agg(image ORDER BY key_bytes)
      FROM marked GROUP BY chunk;

    INSERT INTO grove.nodes (hash, level, entries, hashes, keys)
    SELECT g.hash, 0, g.entries, g.hashes, g.keys FROM grove_grp g
    ON CONFLICT (hash) DO NOTHING;

    INSERT INTO grove_new SELECT g.key_bytes, g.hash FROM grove_grp g;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION grove.assemble_above_leaves() RETURNS bytea
LANGUAGE plpgsql AS $$
BEGIN
  TRUNCATE grove_lvl;
  INSERT INTO grove_lvl
    SELECT decode(o.k, 'hex'), decode(o.h, 'hex'), NULL::jsonb
    FROM grove_old o WHERE o.rn NOT IN (SELECT rn FROM grove_hit)
    UNION ALL
    SELECT key_bytes, hash, NULL::jsonb FROM grove_new;

  IF (SELECT count(*) FROM grove_lvl) = 1
     AND NOT EXISTS (SELECT 1 FROM grove_l1 p WHERE p.rn NOT IN (SELECT rn FROM grove_l1hit)) THEN
    RETURN (SELECT hash FROM grove_lvl);
  END IF;

  PERFORM grove.build_one_level(1);

  TRUNCATE grove_lvl;
  INSERT INTO grove_lvl
    SELECT decode(p.k, 'hex'), decode(p.h, 'hex'), NULL::jsonb
    FROM grove_l1 p WHERE p.rn NOT IN (SELECT rn FROM grove_l1hit)
    UNION ALL
    SELECT key_bytes, hash, NULL::jsonb FROM grove_built;

  RETURN grove.build_up(2);
END $$;

CREATE OR REPLACE FUNCTION grove.write_tree_incremental(target regclass, prev_root bytea)
RETURNS bytea
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  changed      text[] := grove.changed_keys(target);
  pure_updates boolean;
BEGIN
  IF prev_root IS NOT NULL AND COALESCE(grove.node_level(prev_root), 0) <= 1 THEN
    RETURN grove.write_tree(target);
  END IF;

  IF array_length(changed, 1) IS NULL AND prev_root IS NOT NULL THEN
    RETURN prev_root;
  END IF;

  IF prev_root IS NULL OR COALESCE(grove.node_level(prev_root), -1) < 1
     OR array_length(changed, 1) IS NULL
     OR array_length(changed, 1) > grove.setting('max_incremental_keys')::int THEN
    RETURN grove.write_tree(target);
  END IF;

  PERFORM grove.ensure_scratch();

  SELECT NOT EXISTS (
    SELECT 1 FROM grove.changes c
    WHERE c.tbl = target::text AND c.commit_sha IS NULL AND c.op <> 'UPDATE'
  ) INTO pure_updates;

  PERFORM grove.locate_touched_chunks(prev_root, changed, pure_updates);

  IF grove.rebuild_beats_splice() THEN
    RETURN grove.write_tree(target);
  END IF;

  TRUNCATE grove_new;

  IF pure_updates AND grove.changes_are_sparse_in_their_chunks(changed) THEN
    PERFORM grove.splice_touched_chunks(target, changed);
  ELSE
    PERFORM grove.rebuild_touched_ranges(target);
  END IF;

  RETURN grove.assemble_above_leaves();
END $$;

DROP FUNCTION IF EXISTS grove.build_one_level(int);

CREATE OR REPLACE FUNCTION grove.build_one_level(depth int, with_images boolean DEFAULT false)
RETURNS void
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  ct int := grove.setting('chunk_target')::int;
BEGIN
  PERFORM grove.ensure_scratch();

  TRUNCATE grove_grp;
  INSERT INTO grove_grp (key_bytes, hash, hashes, keys, entries)
    WITH marked AS (
      SELECT key_bytes, hash, image,
             COALESCE(
               SUM(CASE WHEN grove.is_boundary(key_bytes, ct) THEN 1 ELSE 0 END)
                 OVER (ORDER BY key_bytes ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS chunk
      FROM grove_lvl
    )
    SELECT (array_agg(key_bytes ORDER BY key_bytes))[1],
           grove.hash(string_agg(hash, ''::bytea ORDER BY key_bytes)),
           string_agg(hash, ''::bytea ORDER BY key_bytes),
           array_agg(encode(key_bytes, 'hex') ORDER BY key_bytes),
           CASE WHEN with_images
             THEN jsonb_agg(image ORDER BY key_bytes)
             ELSE '[]'::jsonb END
    FROM marked GROUP BY chunk;

  INSERT INTO grove.nodes (hash, level, entries, hashes, keys)
  SELECT g.hash, depth, g.entries, g.hashes, g.keys FROM grove_grp g
  ON CONFLICT (hash) DO NOTHING;

  TRUNCATE grove_built;
  INSERT INTO grove_built SELECT g.key_bytes, g.hash FROM grove_grp g;
END $$;

DROP FUNCTION IF EXISTS grove.snapshot_trees(bytea);

CREATE OR REPLACE FUNCTION grove.missing_tracked() RETURNS TABLE (gone_table text, gone_oid text)
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(t.name_at_track, ''), t.tbl::text), t.tbl::text
  FROM grove.tracked t
  WHERE NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = t.tbl)
$$;

CREATE OR REPLACE FUNCTION grove.untrack_missing() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  started timestamptz := clock_timestamp();
  gone    text[];
  n       int;
BEGIN
  SELECT array_agg(m.gone_table) INTO gone FROM grove.missing_tracked() m;

  DELETE FROM grove.tracked t
  WHERE NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = t.tbl);
  GET DIAGNOSTICS n = ROW_COUNT;

  IF n > 0 THEN
    PERFORM grove.emit('untrack_missing', started,
      jsonb_build_object('tables', to_jsonb(gone), 'count', n));
  END IF;

  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION grove.snapshot_trees(parent bytea) RETURNS jsonb
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  r        record;
  root_val bytea;
  prev     bytea;
  prev_fp  bytea;
  roots    jsonb := '{}'::jsonb;
BEGIN
  IF EXISTS (SELECT 1 FROM grove.missing_tracked()) THEN
    RAISE EXCEPTION 'grove: tracked table(s) no longer exist: %',
      (SELECT string_agg(m.gone_table, ', ') FROM grove.missing_tracked() m)
      USING HINT = 'they were dropped while tracked; run SELECT grove.untrack_missing() '
                   'to stop tracking them, then commit again';
  END IF;

  FOR r IN SELECT t.tbl FROM grove.tracked t ORDER BY t.tbl::text LOOP
    SELECT x.root_hash INTO prev FROM grove.trees x
    WHERE x.commit_sha = parent AND x.tbl = r.tbl::text;

    SELECT sc.fingerprint INTO prev_fp FROM grove.schemas sc
    WHERE sc.commit_sha = parent AND sc.tbl = r.tbl::text;

    IF prev IS NOT NULL AND prev_fp IS DISTINCT FROM grove.schema_fingerprint(r.tbl) THEN
      root_val := grove.write_tree(r.tbl);
    ELSE
      root_val := grove.write_tree_incremental(r.tbl, prev);
    END IF;

    roots := roots || jsonb_build_object(r.tbl::text, encode(root_val, 'hex'));
  END LOOP;

  RETURN roots;
END $$;

CREATE OR REPLACE FUNCTION grove.roots_summary(roots jsonb) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(string_agg(e.key || ':' || e.value, E'\n' ORDER BY e.key), '')
  FROM jsonb_each_text(roots) e
$$;

CREATE OR REPLACE FUNCTION grove.nodes_at_level(root bytea, want int)
RETURNS TABLE (k text, h text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  lvl int := grove.node_level(root);
  e   jsonb;
BEGIN
  IF lvl IS NULL OR lvl < want THEN RETURN; END IF;

  IF lvl = want THEN
    RETURN QUERY
      SELECT (SELECT r.keys[1] FROM grove.node_raw(root) r),
             encode(root, 'hex');
    RETURN;
  END IF;

  IF lvl = want + 1 THEN
    RETURN QUERY SELECT i.k, i.ch FROM grove.node_entries(root) i ORDER BY i.k;
    RETURN;
  END IF;

  FOR e IN SELECT to_jsonb(i) FROM grove.node_entries(root) i ORDER BY i.k COLLATE "C" LOOP
    RETURN QUERY SELECT * FROM grove.nodes_at_level(decode(e ->> 'ch', 'hex'), want);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION grove.journal_stmt() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  j_cols text[];
  j_pred text;
BEGIN
  SELECT pk_cols INTO j_cols FROM grove.tracked WHERE tbl = TG_RELID::regclass;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO grove.changes (txid, tbl, pk, op, before, after, actor, source)
    SELECT txid_current(), TG_TABLE_NAME, grove.pk_of(to_jsonb(grove_nr), j_cols),
           'INSERT', NULL, to_jsonb(grove_nr), grove.actor(), grove.source()
    FROM newrows grove_nr;
    RETURN NULL;
  END IF;

  IF TG_OP = 'DELETE' THEN
    INSERT INTO grove.changes (txid, tbl, pk, op, before, after, actor, source)
    SELECT txid_current(), TG_TABLE_NAME, grove.pk_of(to_jsonb(grove_or), j_cols),
           'DELETE', to_jsonb(grove_or), NULL, grove.actor(), grove.source()
    FROM oldrows grove_or;
    RETURN NULL;
  END IF;

  SELECT string_agg(format('grove_or.%I = grove_nr.%I', c, c), ' AND ') INTO j_pred FROM unnest(j_cols) c;

  EXECUTE format(
    'INSERT INTO grove.changes (txid, tbl, pk, op, before, after, actor, source)
     SELECT txid_current(), %L,
            grove.pk_of(COALESCE(to_jsonb(grove_nr), to_jsonb(grove_or)), %L::text[]),
            CASE WHEN grove_or IS NULL THEN ''INSERT''
                 WHEN grove_nr IS NULL THEN ''DELETE''
                 ELSE ''UPDATE'' END,
            to_jsonb(grove_or), to_jsonb(grove_nr), grove.actor(), grove.source()
     FROM oldrows grove_or FULL OUTER JOIN newrows grove_nr ON %s',
    TG_TABLE_NAME, j_cols, j_pred);

  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION grove.assert_live_schema(target_sha bytea) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
  bad record;
BEGIN
  SELECT s.tbl AS name, s.columns AS recorded,
         grove.schema_columns(to_regclass(s.tbl)) AS live
  INTO bad
  FROM grove.schemas s
  WHERE s.commit_sha = target_sha
    AND to_regclass(s.tbl) IS NOT NULL
    AND s.fingerprint <> grove.schema_fingerprint(to_regclass(s.tbl))
  LIMIT 1;

  IF bad.name IS NOT NULL THEN
    RAISE EXCEPTION
      'grove: % has a different shape now than in that commit, and checkout restores data but not shape. Now %, then %',
      bad.name, bad.live::text, bad.recorded::text;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION grove.repack(max_depth int DEFAULT 4) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  grp          record;
  g            record;
  prev_hash    bytea;
  prev_entries jsonb;
  d            int;
  packed       int := 0;
  cand         jsonb;
  parts        jsonb;
  started      timestamptz := clock_timestamp();
  bytes_before bigint := pg_total_relation_size('grove.nodes');
BEGIN
  FOR grp IN
    SELECT n.level AS lv, n.keys[1] AS fk
    FROM grove.nodes n
    WHERE n.entries IS NOT NULL
    GROUP BY 1, 2
    HAVING count(*) > 1
  LOOP
    prev_hash := NULL; prev_entries := NULL; d := 0;

    FOR g IN
      SELECT n.hash, n.entries, n.hashes, n.keys FROM grove.nodes n
      WHERE n.level = grp.lv AND n.keys[1] = grp.fk AND n.entries IS NOT NULL
      ORDER BY n.seq DESC
    LOOP
      parts := grove.node_parts(g.hashes, g.keys, g.entries);

      IF prev_hash IS NULL OR d >= max_depth THEN
        prev_hash := g.hash;
        prev_entries := parts;
        d := 0;
        CONTINUE;
      END IF;

      cand := grove.make_delta(prev_entries, parts);

      IF pg_column_size(cand)
         < pg_column_size(g.entries) + pg_column_size(g.hashes) + pg_column_size(g.keys) THEN
        UPDATE grove.nodes
        SET delta = cand, base_hash = prev_hash, entries = NULL, hashes = NULL, keys = NULL
        WHERE hash = g.hash;
        packed := packed + 1;
        d := d + 1;
      ELSE
        d := 0;
      END IF;

      prev_hash := g.hash;
      prev_entries := parts;
    END LOOP;
  END LOOP;

  PERFORM grove.log_rotate();

  PERFORM grove.emit('repack', started, jsonb_build_object(
    'packed', packed, 'max_depth', max_depth,
    'nodes', (SELECT count(*) FROM grove.nodes),
    'bytes_before', bytes_before,
    'bytes_after', pg_total_relation_size('grove.nodes')));

  RETURN packed;
END $$;

CREATE OR REPLACE FUNCTION grove.unpack() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  WITH resolved AS (
    SELECT x.hash, c.hashes, c.keys, c.entries
    FROM grove.nodes x CROSS JOIN LATERAL grove.node_cols(x.hash) c
    WHERE x.entries IS NULL
  )
  UPDATE grove.nodes t
  SET entries = r.entries, hashes = r.hashes, keys = r.keys, base_hash = NULL, delta = NULL
  FROM resolved r WHERE t.hash = r.hash;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION grove.replay_begin() RETURNS jsonb
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
    FROM grove.tracked t
    JOIN pg_trigger tg ON tg.tgrelid = t.tbl AND NOT tg.tgisinternal
    WHERE tg.tgname NOT LIKE 'grove_journal%'
  LOOP
    saved := saved || jsonb_build_object('tbl', r.tbl, 'tg', r.tgname, 'en', r.tgenabled);
    EXECUTE format('ALTER TABLE %s DISABLE TRIGGER %I', r.tbl, r.tgname);
  END LOOP;

  RETURN jsonb_build_object('mode', 'triggers', 'saved', saved);
END $$;

CREATE OR REPLACE FUNCTION grove.replay_end(st jsonb) RETURNS void
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

CREATE TABLE IF NOT EXISTS grove.merges (
  id         bigint PRIMARY KEY,
  branch     text        NOT NULL,
  ours_sha   bytea       NOT NULL,
  theirs_sha bytea       NOT NULL,
  base_sha   bytea       NOT NULL,
  msg        text,
  started_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE grove.conflicts ADD COLUMN IF NOT EXISTS resolution_kind text;
ALTER TABLE grove.conflicts ADD COLUMN IF NOT EXISTS resolution jsonb;
ALTER TABLE grove.conflicts ADD COLUMN IF NOT EXISTS resolved boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION grove.resolve_conflict(
  mid bigint, target_tbl text, key_hex text, kind text, value jsonb DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  c record;
  img jsonb;
  started timestamptz := clock_timestamp();
BEGIN
  SELECT * INTO c FROM grove.conflicts x
  WHERE x.merge_id = mid AND x.tbl = target_tbl AND x.k = key_hex;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'grove: no conflict on %.% in merge %', target_tbl, key_hex, mid;
  END IF;

  img := CASE kind
           WHEN 'ours'   THEN c.ours
           WHEN 'theirs' THEN c.theirs
           WHEN 'base'   THEN c.base
           WHEN 'delete' THEN NULL
           WHEN 'custom' THEN value
         END;

  IF kind NOT IN ('ours', 'theirs', 'base', 'delete', 'custom') THEN
    RAISE EXCEPTION 'grove: unknown resolution %, expected ours, theirs, base, delete or custom', kind;
  END IF;

  IF kind = 'custom' AND value IS NULL THEN
    RAISE EXCEPTION 'grove: a custom resolution needs a row image';
  END IF;

  PERFORM grove.emit('resolve_conflict', started, jsonb_build_object(
    'merge_id', mid, 'table', target_tbl, 'key', key_hex, 'kind', kind));

  UPDATE grove.conflicts
  SET resolution_kind = kind, resolution = img, resolved = true
  WHERE merge_id = mid AND tbl = target_tbl AND k = key_hex;
END $$;

CREATE OR REPLACE FUNCTION grove.resolve_all(mid bigint, kind text) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  IF kind NOT IN ('ours', 'theirs', 'base') THEN
    RAISE EXCEPTION 'grove: resolve_all takes ours, theirs or base, not %', kind;
  END IF;

  UPDATE grove.conflicts
  SET resolution_kind = kind,
      resolution = CASE kind WHEN 'ours' THEN ours WHEN 'theirs' THEN theirs ELSE base END,
      resolved = true
  WHERE merge_id = mid AND NOT resolved;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION grove.merge_abort(mid bigint) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  started timestamptz := clock_timestamp();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM grove.merges WHERE id = mid) THEN
    RAISE EXCEPTION 'grove: no merge % in progress', mid;
  END IF;

  PERFORM grove.emit('merge_abort', started, jsonb_build_object(
    'merge_id', mid,
    'discarded_conflicts', (SELECT count(*) FROM grove.conflicts WHERE merge_id = mid)), false);

  DELETE FROM grove.conflicts WHERE merge_id = mid;
  DELETE FROM grove.merges WHERE id = mid;
END $$;

CREATE OR REPLACE FUNCTION grove.merge_finish(mid bigint) RETURNS int
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
  who     text := COALESCE(grove.actor(), 'merge');
  started timestamptz := clock_timestamp();
BEGIN
  SELECT * INTO m FROM grove.merges WHERE id = mid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'grove: no merge % in progress', mid;
  END IF;

  SELECT count(*) INTO n FROM grove.conflicts WHERE merge_id = mid AND NOT resolved;
  IF n > 0 THEN
    RAISE EXCEPTION 'grove: % conflict(s) still unresolved in merge %', n, mid;
  END IF;

  IF grove.resolve(m.branch) IS DISTINCT FROM m.ours_sha THEN
    RAISE EXCEPTION 'grove: % moved since the merge started, abort and retry', m.branch;
  END IF;

  SET CONSTRAINTS ALL DEFERRED;

  FOR p IN SELECT * FROM grove.merge_plan(m.base_sha, m.ours_sha, m.theirs_sha) LOOP
    IF p.action = 'conflict' THEN
      SELECT c.resolution INTO r FROM grove.conflicts c
      WHERE c.merge_id = mid AND c.tbl = p.tbl AND c.k = p.k;

      IF r IS NULL THEN
        PERFORM grove.apply_row(p.tbl::regclass, 'delete',
          (SELECT c.ours FROM grove.conflicts c
           WHERE c.merge_id = mid AND c.tbl = p.tbl AND c.k = p.k));
      ELSE
        PERFORM grove.apply_row(p.tbl::regclass, 'upsert', r);
      END IF;
    ELSE
      PERFORM grove.apply_row(p.tbl::regclass, p.action, p.merged);
    END IF;
  END LOOP;

  SET CONSTRAINTS ALL IMMEDIATE;

  roots   := grove.snapshot_trees(m.ours_sha);
  summary := grove.roots_summary(roots);
  new_sha := grove.hash(encode(m.ours_sha, 'hex') || E'\n' || encode(m.theirs_sha, 'hex') || E'\n' ||
                       COALESCE(m.msg, 'merge') || E'\n' ||
                       to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || E'\n' || summary);

  INSERT INTO grove.commits (sha, parent_sha, author, message, at)
  VALUES (new_sha, m.ours_sha, who, COALESCE(m.msg, 'merge'), ts)
  ON CONFLICT (sha) DO NOTHING;

  INSERT INTO grove.commit_parent (commit_sha, ord, parent_sha)
  VALUES (new_sha, 2, m.theirs_sha)
  ON CONFLICT DO NOTHING;

  PERFORM grove.record_trees(new_sha, roots);

  PERFORM grove.record_schemas(new_sha);
  UPDATE grove.changes SET commit_sha = new_sha WHERE commit_sha IS NULL;
  PERFORM grove.advance_ref(m.branch, m.ours_sha, new_sha);

  PERFORM grove.rerere_learn(mid);

  DELETE FROM grove.conflicts WHERE merge_id = mid;
  DELETE FROM grove.merges WHERE id = mid;

  PERFORM grove.emit('merge_finish', started, jsonb_build_object(
    'merge_id', mid, 'sha', grove.short_sha(new_sha)));

  RETURN 0;
END $$;

CREATE OR REPLACE FUNCTION grove.virtual_merge(x bytea, y bytea) RETURNS bytea
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  vb     bytea := grove.hash('virtual' || encode(x, 'hex') || encode(y, 'hex'));
  xb     bytea;
  t      record;
  p      record;
  root_x bytea;
  root   bytea;
  roots  jsonb := '{}'::jsonb;
BEGIN
  IF EXISTS (SELECT 1 FROM grove.trees WHERE commit_sha = vb) THEN
    RETURN vb;
  END IF;

  xb := grove.merge_base(x, y);

  FOR t IN SELECT DISTINCT tr.tbl FROM grove.trees tr WHERE tr.commit_sha IN (x, y) LOOP
    SELECT tr.root_hash INTO root_x FROM grove.trees tr
    WHERE tr.commit_sha = x AND tr.tbl = t.tbl;

    EXECUTE 'DROP TABLE IF EXISTS grove_vb';
    EXECUTE format('CREATE TEMP TABLE grove_vb (LIKE %s INCLUDING ALL)', t.tbl);
    EXECUTE format(
      'INSERT INTO grove_vb SELECT (jsonb_populate_record(NULL::%s, l.v)).* FROM grove.leaves($1) l',
      t.tbl) USING root_x;

    FOR p IN SELECT * FROM grove.merge_plan(xb, x, y) mp WHERE mp.tbl = t.tbl LOOP
      IF p.action <> 'conflict' THEN
        PERFORM grove.apply_row('grove_vb'::regclass, p.action, p.merged);
      END IF;
    END LOOP;

    root  := grove.write_tree('grove_vb'::regclass);
    roots := roots || jsonb_build_object(t.tbl, encode(root, 'hex'));
  END LOOP;

  EXECUTE 'DROP TABLE IF EXISTS grove_vb';

  PERFORM grove.record_trees(vb, roots);

  RETURN vb;
END $$;

CREATE OR REPLACE FUNCTION grove.row_similarity(a jsonb, b jsonb, pk text[]) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN count(*) = 0 THEN 0
              ELSE count(*) FILTER (WHERE a -> k IS NOT DISTINCT FROM b -> k)::numeric / count(*) END
  FROM jsonb_object_keys(COALESCE(a, '{}'::jsonb)) k
  WHERE NOT (k = ANY (pk))
$$;

CREATE OR REPLACE FUNCTION grove.rename_pairs(
  base_root bytea, side_root bytea, pk text[], threshold numeric DEFAULT 0.5
) RETURNS TABLE (old_k text, new_k text, sim numeric)
LANGUAGE sql STABLE AS $$
  WITH d AS (SELECT * FROM grove.diff_tree(base_root, side_root)),
  del AS (SELECT x.k, x.before AS img FROM d x WHERE x.op = 'DELETE'),
  ins AS (SELECT x.k, x.after  AS img FROM d x WHERE x.op = 'INSERT'),
  cand AS (
    SELECT del.k AS ok, ins.k AS nk, grove.row_similarity(del.img, ins.img, pk) AS s
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

CREATE OR REPLACE FUNCTION grove.three_way_row(bimg jsonb, oimg jsonb, timg jsonb, pk text[])
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

CREATE OR REPLACE FUNCTION grove.merge_plan(base_sha bytea, our_sha bytea, their_sha bytea)
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
  FOR r IN SELECT * FROM grove.merge_plan_raw(base_sha, our_sha, their_sha) LOOP
    IF r.action <> 'conflict' OR r.conflict_col IS NOT NULL THEN
      tbl := r.tbl; k := r.k; action := r.action; merged := r.merged; conflict_col := r.conflict_col;
      RETURN NEXT; CONTINUE;
    END IF;

    IF cur IS DISTINCT FROM r.tbl THEN
      cur := r.tbl;
      SELECT x.root_hash INTO broot FROM grove.trees x WHERE x.commit_sha = base_sha  AND x.tbl = cur;
      SELECT x.root_hash INTO oroot FROM grove.trees x WHERE x.commit_sha = our_sha   AND x.tbl = cur;
      SELECT x.root_hash INTO troot FROM grove.trees x WHERE x.commit_sha = their_sha AND x.tbl = cur;
      pk := grove.pk_columns(cur::regclass);
    END IF;

    SELECT l.v INTO bimg FROM grove.lookup(broot, r.k) l;
    SELECT l.v INTO oimg FROM grove.lookup(oroot, r.k) l;
    SELECT l.v INTO timg FROM grove.lookup(troot, r.k) l;

    nk := NULL;
    IF oimg IS NULL AND timg IS NOT NULL THEN
      SELECT p.new_k INTO nk FROM grove.rename_pairs(broot, oroot, pk) p WHERE p.old_k = r.k;
      IF nk IS NOT NULL THEN SELECT l.v INTO other FROM grove.lookup(oroot, nk) l; END IF;
    ELSIF timg IS NULL AND oimg IS NOT NULL THEN
      SELECT p.new_k INTO nk FROM grove.rename_pairs(broot, troot, pk) p WHERE p.old_k = r.k;
      IF nk IS NOT NULL THEN
        SELECT l.v INTO other FROM grove.lookup(troot, nk) l;
        timg := oimg; oimg := other; other := timg;
      END IF;
    END IF;

    IF nk IS NULL THEN
      tbl := r.tbl; k := r.k; action := r.action; merged := r.merged; conflict_col := r.conflict_col;
      RETURN NEXT; CONTINUE;
    END IF;

    fixed := grove.three_way_row(bimg, other, CASE WHEN oimg IS NULL THEN timg ELSE oimg END, pk);

    tbl := r.tbl; k := nk;
    IF fixed IS NULL THEN
      action := 'conflict'; merged := NULL; conflict_col := NULL;
    ELSE
      action := 'upsert'; merged := fixed; conflict_col := NULL;
    END IF;
    RETURN NEXT;
  END LOOP;
END $$;

CREATE TABLE IF NOT EXISTS grove.reflog (
  id      bigserial PRIMARY KEY,
  ref     text        NOT NULL,
  old_sha bytea,
  new_sha bytea       NOT NULL,
  action  text        NOT NULL,
  actor   text,
  at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS reflog_ref_idx ON grove.reflog (ref, id DESC);

DROP FUNCTION IF EXISTS grove.advance_ref(text, bytea, bytea);

CREATE OR REPLACE FUNCTION grove.advance_ref(
  ref_name text, expected bytea, next_sha bytea, act text DEFAULT 'update'
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  IF expected IS NULL THEN
    INSERT INTO grove.refs (name, sha) VALUES (ref_name, next_sha)
    ON CONFLICT (name) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n = 0 THEN
      RAISE EXCEPTION 'grove: ref % already exists, refusing to create it', ref_name;
    END IF;
  ELSE
    UPDATE grove.refs SET sha = next_sha WHERE name = ref_name AND sha = expected;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n = 0 THEN
      RAISE EXCEPTION 'grove: ref % moved under us', ref_name;
    END IF;
  END IF;

  INSERT INTO grove.reflog (ref, old_sha, new_sha, action, actor)
  VALUES (ref_name, expected, next_sha, act, grove.actor());
END $$;

CREATE OR REPLACE FUNCTION grove.rev(spec text) RETURNS bytea
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
    cur := grove.resolve(grove.head());
  ELSIF EXISTS (SELECT 1 FROM grove.refs r WHERE r.name = base) THEN
    cur := grove.resolve(base);
  ELSIF EXISTS (SELECT 1 FROM grove.tags t WHERE t.name = base) THEN
    SELECT t.sha INTO cur FROM grove.tags t WHERE t.name = base;
  ELSIF base ~ '^[0-9a-fA-F]{4,64}$' THEN
    SELECT c.sha INTO cur FROM grove.commits c
    WHERE encode(c.sha, 'hex') LIKE lower(base) || '%';
    IF cur IS NULL THEN
      RAISE EXCEPTION 'grove: no commit matching %', base;
    END IF;
  ELSE
    RAISE EXCEPTION 'grove: cannot resolve %', spec;
  END IF;

  FOREACH m IN ARRAY ops LOOP
    n := COALESCE(NULLIF(substring(m FROM '[0-9]+'), '')::int, 1);
    IF left(m, 1) = '~' THEN
      FOR i IN 1..n LOOP
        SELECT c.parent_sha INTO cur FROM grove.commits c WHERE c.sha = cur;
        IF cur IS NULL THEN RAISE EXCEPTION 'grove: % goes past the root commit', spec; END IF;
      END LOOP;
    ELSE
      SELECT p.parent INTO cur FROM grove.parents_of(cur) p WHERE p.ord = n;
      IF cur IS NULL THEN RAISE EXCEPTION 'grove: % has no such parent', spec; END IF;
    END IF;
  END LOOP;

  RETURN cur;
END $$;

DROP FUNCTION IF EXISTS grove.log(bytea, text);

CREATE OR REPLACE FUNCTION grove.log(
  start_sha bytea DEFAULT NULL, pathspec text DEFAULT NULL,
  max_count int DEFAULT NULL, since timestamptz DEFAULT NULL, who text DEFAULT NULL
) RETURNS TABLE (depth int, sha bytea, parent_sha bytea, author text, message text, at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE walk AS (
    SELECT 0 AS depth, c.sha, c.parent_sha, c.author, c.message, c.at
    FROM grove.commits c
    WHERE c.sha = COALESCE(start_sha, grove.resolve(grove.head()))
    UNION ALL
    SELECT w.depth + 1, c.sha, c.parent_sha, c.author, c.message, c.at
    FROM walk w JOIN grove.commits c ON c.sha = w.parent_sha
  )
  SELECT w.depth, w.sha, w.parent_sha, w.author, w.message, w.at
  FROM walk w
  WHERE (pathspec IS NULL OR EXISTS (SELECT 1 FROM grove.diff(w.parent_sha, w.sha, pathspec)))
    AND (since IS NULL OR w.at >= since)
    AND (who IS NULL OR w.author = who)
  ORDER BY w.depth
  LIMIT max_count
$$;

CREATE OR REPLACE FUNCTION grove.reset(spec text, mode text DEFAULT 'hard') RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  branch  text  := grove.head();
  cur     bytea := grove.resolve(branch);
  tgt     bytea := grove.rev(spec);
  applied int   := 0;
  r       record;
  troot   bytea;
  guard   jsonb;
  started timestamptz := clock_timestamp();
BEGIN
  IF mode NOT IN ('soft', 'hard') THEN
    RAISE EXCEPTION 'grove: reset takes soft or hard, not % (there is no index to reset)', mode;
  END IF;

  IF tgt IS NULL THEN
    RAISE EXCEPTION 'grove: cannot resolve %', spec;
  END IF;

  IF mode = 'hard' THEN
    guard := grove.replay_begin();
    SET CONSTRAINTS ALL DEFERRED;

    FOR r IN SELECT x.tbl FROM grove.tracked x LOOP
      SELECT y.root_hash INTO troot FROM grove.trees y
      WHERE y.commit_sha = tgt AND y.tbl = r.tbl::text;
      applied := applied + grove.apply_tree_diff(r.tbl, grove.write_tree(r.tbl), troot);
    END LOOP;

    SET CONSTRAINTS ALL IMMEDIATE;
    PERFORM grove.replay_end(guard);
    DELETE FROM grove.changes WHERE commit_sha IS NULL;
  END IF;

  UPDATE grove.refs SET sha = tgt WHERE name = branch;
  INSERT INTO grove.reflog (ref, old_sha, new_sha, action, actor)
  VALUES (branch, cur, tgt, 'reset --' || mode, grove.actor());

  PERFORM grove.emit('reset', started, jsonb_build_object(
    'spec', spec, 'mode', mode, 'from', grove.short_sha(cur), 'to', grove.short_sha(tgt),
    'rows', applied));

  RETURN applied;
END $$;

CREATE OR REPLACE FUNCTION grove.diff_working(pathspec text DEFAULT NULL)
RETURNS TABLE (tbl text, k text, op text, before jsonb, after jsonb)
LANGUAGE plpgsql AS $$
DECLARE
  h     bytea := grove.resolve(grove.head());
  t     record;
  hroot bytea;
  lroot bytea;
BEGIN
  FOR t IN SELECT x.tbl FROM grove.tracked x ORDER BY x.tbl::text LOOP
    CONTINUE WHEN pathspec IS NOT NULL
              AND split_part(split_part(pathspec, ':', 1), '.', 1) <> t.tbl::text;

    SELECT x.root_hash INTO hroot FROM grove.trees x
    WHERE x.commit_sha = h AND x.tbl = t.tbl::text;

    lroot := grove.write_tree(t.tbl);

    RETURN QUERY
      SELECT t.tbl::text, d.k, d.op, d.before, d.after
      FROM grove.diff_tree(hroot, lroot) d;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION grove.fsck()
RETURNS TABLE (problem text, detail text)
LANGUAGE sql STABLE AS $$
  SELECT 'node hash mismatch', encode(n.hash, 'hex')
  FROM grove.nodes n
  WHERE n.hash <> grove.hash(COALESCE((SELECT c.hashes FROM grove.node_cols(n.hash) c), ''::bytea))

  UNION ALL
  SELECT 'node vectors disagree', encode(n.hash, 'hex')
  FROM grove.nodes n
  WHERE n.entries IS NOT NULL
    AND COALESCE(array_length(n.keys, 1), 0) * grove.hash_len() <> COALESCE(octet_length(n.hashes), 0)

  UNION ALL
  SELECT 'node has no key vector', encode(n.hash, 'hex')
  FROM grove.nodes n WHERE n.entries IS NOT NULL AND n.keys IS NULL

  UNION ALL
  SELECT 'tracked table no longer exists', m.gone_table
  FROM grove.missing_tracked() m

  UNION ALL
  SELECT 'delta base missing', encode(n.hash, 'hex')
  FROM grove.nodes n
  WHERE n.base_hash IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM grove.nodes b WHERE b.hash = n.base_hash)

  UNION ALL
  SELECT 'node unresolvable', encode(n.hash, 'hex')
  FROM grove.nodes n WHERE grove.entries_of(n.hash) IS NULL

  UNION ALL
  SELECT 'ref points at a missing commit', r.name
  FROM grove.refs r
  WHERE NOT EXISTS (SELECT 1 FROM grove.commits c WHERE c.sha = r.sha)

  UNION ALL
  SELECT 'commit parent missing', encode(e.child, 'hex') || ' ^' || e.ord
  FROM grove.parent_edge e
  WHERE NOT EXISTS (SELECT 1 FROM grove.commits p WHERE p.sha = e.parent)

  UNION ALL
  SELECT 'merge commit has a gap in its parents', encode(p.commit_sha, 'hex')
  FROM grove.commit_parent p
  WHERE NOT EXISTS (SELECT 1 FROM grove.commit_parent q
                    WHERE q.commit_sha = p.commit_sha AND q.ord = p.ord - 1)
    AND p.ord > 2

  UNION ALL
  SELECT 'tree root missing from the node store', t.commit_sha::text || ' ' || t.tbl
  FROM grove.trees t
  WHERE t.root_hash <> grove.hash(''::bytea)
    AND NOT EXISTS (SELECT 1 FROM grove.nodes n WHERE n.hash = t.root_hash)

  UNION ALL
  SELECT 'child node missing', encode(n.hash, 'hex') || ' -> ' || i.ch
  FROM grove.nodes n CROSS JOIN LATERAL grove.node_items(n.hash) i
  WHERE n.level > 0
    AND NOT EXISTS (SELECT 1 FROM grove.nodes c WHERE c.hash = decode(i.ch, 'hex'))
$$;

CREATE TABLE IF NOT EXISTS grove.remotes (
  name text PRIMARY KEY,
  url  text NOT NULL
);

CREATE OR REPLACE FUNCTION grove.remote_add(remote_name text, remote_url text) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO grove.remotes (name, url) VALUES (remote_name, remote_url)
  ON CONFLICT (name) DO UPDATE SET url = EXCLUDED.url
$$;

CREATE OR REPLACE FUNCTION grove.reachable_nodes(roots bytea[]) RETURNS TABLE (h bytea)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE w AS (
    SELECT r AS h FROM unnest(roots) r WHERE r IS NOT NULL
    UNION
    SELECT decode(x.ch, 'hex')
    FROM w
    JOIN grove.nodes n ON n.hash = w.h
    CROSS JOIN LATERAL grove.node_items(n.hash) x
    WHERE n.level > 0
  )
  SELECT w.h FROM w WHERE EXISTS (SELECT 1 FROM grove.nodes n WHERE n.hash = w.h)
$$;

CREATE OR REPLACE FUNCTION grove.commits_to_send(ref_names text[], have bytea[])
RETURNS TABLE (sha bytea)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE tips AS (
    SELECT r.sha FROM grove.refs r WHERE r.name = ANY (ref_names)
  ),
  w AS (
    SELECT t.sha FROM tips t WHERE NOT (t.sha = ANY (have))
    UNION
    SELECT e.parent FROM w JOIN grove.parent_edge e ON e.child = w.sha
    WHERE NOT (e.parent = ANY (have))
  )
  SELECT DISTINCT w.sha FROM w
$$;

CREATE OR REPLACE FUNCTION grove.have() RETURNS bytea[]
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(array_agg(c.sha), '{}'::bytea[]) FROM grove.commits c
$$;

CREATE OR REPLACE FUNCTION grove.canon_settings() RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_object_agg(m.key, m.value)
  FROM grove.meta m
  WHERE m.key IN ('canon_version', 'hash_algo', 'chunk_target', 'format_version')
$$;

CREATE OR REPLACE FUNCTION grove.bundle(ref_names text[], have bytea[] DEFAULT '{}'::bytea[])
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  send    bytea[];
  keep    bytea[];
  skip    bytea[];
  result  jsonb;
BEGIN
  SELECT COALESCE(array_agg(x.sha), '{}'::bytea[]) INTO send
  FROM grove.commits_to_send(ref_names, have) x;

  IF array_length(send, 1) IS NULL THEN
    RETURN jsonb_build_object('refs', (
      SELECT COALESCE(jsonb_object_agg(r.name, encode(r.sha, 'hex')), '{}'::jsonb)
      FROM grove.refs r WHERE r.name = ANY (ref_names)),
      'commits', '[]'::jsonb, 'trees', '[]'::jsonb,
      'schemas', '[]'::jsonb, 'nodes', '[]'::jsonb,
      'settings', grove.canon_settings());
  END IF;

  SELECT COALESCE(array_agg(DISTINCT t.root_hash), '{}'::bytea[]) INTO keep
  FROM grove.trees t WHERE t.commit_sha = ANY (send);

  SELECT COALESCE(array_agg(DISTINCT t.root_hash), '{}'::bytea[]) INTO skip
  FROM grove.trees t WHERE t.commit_sha = ANY (have);

  SELECT jsonb_build_object(
    'settings', grove.canon_settings(),
    'refs', (SELECT COALESCE(jsonb_object_agg(r.name, encode(r.sha, 'hex')), '{}'::jsonb)
             FROM grove.refs r WHERE r.name = ANY (ref_names)),
    'commits', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                  'sha', encode(c.sha, 'hex'),
                  'parent', encode(c.parent_sha, 'hex'),
                  'parents', (SELECT COALESCE(jsonb_agg(encode(p.parent_sha, 'hex') ORDER BY p.ord), '[]'::jsonb)
                              FROM grove.commit_parent p WHERE p.commit_sha = c.sha),
                  'author', c.author, 'message', c.message, 'at', c.at)), '[]'::jsonb)
                FROM grove.commits c WHERE c.sha = ANY (send)),
    'trees', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'commit', encode(t.commit_sha, 'hex'), 'tbl', t.tbl,
                'root', encode(t.root_hash, 'hex'))), '[]'::jsonb)
              FROM grove.trees t WHERE t.commit_sha = ANY (send)),
    'schemas', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                  'commit', encode(x.commit_sha, 'hex'), 'tbl', x.tbl,
                  'fp', encode(x.fingerprint, 'hex'), 'cols', x.columns,
                  'pk', x.pk_cols)), '[]'::jsonb)
                FROM grove.schemas x WHERE x.commit_sha = ANY (send)),
    'nodes', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'hash', encode(n.hash, 'hex'), 'level', n.level,
                'entries', (SELECT COALESCE(jsonb_agg(jsonb_build_object('k', i.k, 'h', i.ch, 'v', i.v)
                                                      ORDER BY i.k COLLATE "C"), '[]'::jsonb)
                            FROM grove.node_items(n.hash) i))), '[]'::jsonb)
              FROM grove.nodes n
              WHERE n.hash IN (SELECT r.h FROM grove.reachable_nodes(keep) r)
                AND n.hash NOT IN (SELECT r.h FROM grove.reachable_nodes(skip) r))
  ) INTO result;

  RETURN result;
END $$;

DROP FUNCTION IF EXISTS grove.verify_images(bytea, jsonb);

CREATE OR REPLACE FUNCTION grove.verify_images(root bytea, cols jsonb) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  expr    text;
  defs    text;
  unknown text;
  bad     int;
  payload jsonb;
BEGIN
  SELECT string_agg(c ->> 'type', ', ') INTO unknown
  FROM jsonb_array_elements(cols) c WHERE to_regtype(c ->> 'type') IS NULL;

  IF unknown IS NOT NULL THEN
    RAISE EXCEPTION 'grove: this bundle describes column type(s) this database does not have (%)', unknown
      USING HINT = 'install the type first, or clone into a database that has it';
  END IF;

  SELECT string_agg(grove.canon_field_expr(c ->> 'name', to_regtype(c ->> 'type')::oid), ' || '
                    ORDER BY (c ->> 'name') COLLATE "C"),
         string_agg(format('%I %s', c ->> 'name', c ->> 'type'), ', '
                    ORDER BY (c ->> 'name') COLLATE "C")
  INTO expr, defs
  FROM jsonb_array_elements(cols) c;

  IF expr IS NULL THEN RETURN 0; END IF;

  SELECT jsonb_agg(jsonb_build_object('h', l.rh, 'v', l.v)) INTO payload FROM grove.leaves(root) l;
  IF payload IS NULL THEN RETURN 0; END IF;

  EXECUTE format(
    'SELECT count(*) FROM jsonb_array_elements($1) e,'
    ' LATERAL jsonb_to_record(e.value -> ''v'') AS "grove row"(%s)'
    ' WHERE grove.hash(%s) IS DISTINCT FROM decode(e.value ->> ''h'', ''hex'')', defs, expr)
  INTO bad USING payload;

  RETURN bad;
END $$;

CREATE OR REPLACE FUNCTION grove.unbundle(b jsonb) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  e      jsonb;
  n      int := 0;
  h      bytea;
  calc   bytea;
  theirs jsonb := b -> 'settings';
  mine   jsonb := grove.canon_settings();
  missing int;
  summary text;
  extra   bytea[];
  k      text;
  tv     record;
  bad    int;
  shapes text;
  fresh  boolean := NOT EXISTS (SELECT 1 FROM grove.nodes);
BEGIN
  IF theirs IS NULL THEN
    RAISE EXCEPTION 'grove: this bundle carries no settings block, so its canonical form cannot be checked'
      USING HINT = 'it was written by an incompatible grove or altered in transit; ask for it again';
  END IF;

  IF theirs IS NOT NULL THEN
    FOR k IN SELECT jsonb_object_keys(theirs) LOOP
      IF theirs ->> k IS DISTINCT FROM mine ->> k THEN
        IF fresh AND k = 'chunk_target' THEN
          UPDATE grove.meta SET value = theirs ->> k WHERE key = k;
        ELSE
          RAISE EXCEPTION 'grove: this bundle was written with % = %, this database uses %',
            k, theirs ->> k, mine ->> k
            USING HINT = 'trees built under different canonical settings cannot be mixed; '
                         'clone into an empty database instead of receiving into this one';
        END IF;
      END IF;
    END LOOP;
  END IF;

  FOR e IN SELECT jsonb_array_elements(b -> 'nodes') LOOP
    h := decode(e ->> 'hash', 'hex');

    SELECT grove.hash((
      SELECT COALESCE(string_agg(decode(x ->> 'h', 'hex'), ''::bytea ORDER BY x ->> 'k'), ''::bytea)
      FROM jsonb_array_elements(e -> 'entries') x)) INTO calc;

    IF calc <> h THEN
      RAISE EXCEPTION 'grove: bundle node % does not hash to its content, refusing', e ->> 'hash';
    END IF;

    INSERT INTO grove.nodes (hash, level, entries, hashes, keys)
    VALUES (h, (e ->> 'level')::int,
            CASE WHEN (e ->> 'level')::int = 0
              THEN (SELECT COALESCE(jsonb_agg(x -> 'v' ORDER BY (x ->> 'k') COLLATE "C"), '[]'::jsonb)
                    FROM jsonb_array_elements(e -> 'entries') x)
              ELSE '[]'::jsonb END,
            (SELECT string_agg(decode(x ->> 'h', 'hex'), ''::bytea ORDER BY (x ->> 'k') COLLATE "C")
             FROM jsonb_array_elements(e -> 'entries') x),
            (SELECT array_agg((x ->> 'k') ORDER BY (x ->> 'k') COLLATE "C")
             FROM jsonb_array_elements(e -> 'entries') x))
    ON CONFLICT (hash) DO NOTHING;
    n := n + 1;
  END LOOP;

  INSERT INTO grove.commits (sha, parent_sha, author, message, at)
  SELECT decode(x ->> 'sha', 'hex'), decode(x ->> 'parent', 'hex'),
         x ->> 'author', x ->> 'message', (x ->> 'at')::timestamptz
  FROM jsonb_array_elements(b -> 'commits') x
  ORDER BY (x ->> 'at')::timestamptz
  ON CONFLICT (sha) DO NOTHING;

  INSERT INTO grove.commit_parent (commit_sha, ord, parent_sha)
  SELECT decode(x ->> 'sha', 'hex'), (p.ord + 1)::int, decode(p.val, 'hex')
  FROM jsonb_array_elements(b -> 'commits') x
  CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(x -> 'parents', '[]'::jsonb))
       WITH ORDINALITY p(val, ord)
  ON CONFLICT DO NOTHING;

  INSERT INTO grove.trees (commit_sha, tbl, root_hash)
  SELECT decode(x ->> 'commit', 'hex'), x ->> 'tbl', decode(x ->> 'root', 'hex')
  FROM jsonb_array_elements(b -> 'trees') x
  ON CONFLICT DO NOTHING;

  INSERT INTO grove.schemas (commit_sha, tbl, fingerprint, columns, pk_cols)
  SELECT decode(x ->> 'commit', 'hex'), x ->> 'tbl', decode(x ->> 'fp', 'hex'), x -> 'cols',
         CASE WHEN x -> 'pk' IS NULL OR x -> 'pk' = 'null'::jsonb THEN NULL
              ELSE ARRAY(SELECT jsonb_array_elements_text(x -> 'pk')) END
  FROM jsonb_array_elements(b -> 'schemas') x
  ON CONFLICT DO NOTHING;

  SELECT count(*) INTO missing
  FROM jsonb_array_elements(b -> 'nodes') bn
  JOIN grove.nodes nd ON nd.hash = decode(bn ->> 'hash', 'hex')
  CROSS JOIN LATERAL grove.node_items(nd.hash) i
  WHERE nd.level > 0
    AND NOT EXISTS (SELECT 1 FROM grove.nodes c WHERE c.hash = decode(i.ch, 'hex'));

  IF missing > 0 THEN
    RAISE EXCEPTION 'grove: this bundle is incomplete, % node reference(s) point at nodes it does not carry',
      missing
      USING HINT = 'it was truncated or altered in transit; ask for it again rather than storing it';
  END IF;

  SELECT count(*) INTO missing
  FROM jsonb_array_elements(b -> 'trees') x
  WHERE NOT EXISTS (SELECT 1 FROM grove.nodes c WHERE c.hash = decode(x ->> 'root', 'hex'));

  IF missing > 0 THEN
    RAISE EXCEPTION 'grove: this bundle is incomplete, % recorded tree(s) have no root node in it',
      missing
      USING HINT = 'it was truncated or altered in transit; ask for it again rather than storing it';
  END IF;

  SELECT count(*) INTO missing
  FROM (
    (SELECT x ->> 'commit' AS c, x ->> 'tbl' AS t FROM jsonb_array_elements(b -> 'trees') x
     EXCEPT
     SELECT y ->> 'commit', y ->> 'tbl' FROM jsonb_array_elements(b -> 'schemas') y)
    UNION ALL
    (SELECT y ->> 'commit', y ->> 'tbl' FROM jsonb_array_elements(b -> 'schemas') y
     EXCEPT
     SELECT x ->> 'commit', x ->> 'tbl' FROM jsonb_array_elements(b -> 'trees') x)
  ) z;

  IF missing > 0 THEN
    RAISE EXCEPTION 'grove: this bundle is inconsistent, % table(s) have a tree without a shape or a shape without a tree',
      missing
      USING HINT = 'a table needs both to be restorable; the bundle was altered in transit';
  END IF;

  SELECT string_agg(x ->> 'tbl', ', ') INTO shapes
  FROM jsonb_array_elements(b -> 'schemas') x
  WHERE decode(x ->> 'fp', 'hex') IS DISTINCT FROM grove.hash((x -> 'cols')::text);

  IF shapes IS NOT NULL THEN
    RAISE EXCEPTION 'grove: the recorded shape of % does not match its own fingerprint', shapes
      USING HINT = 'the fingerprint is what checkout compares the live table against, so a forged one '
                   'would let rows be restored into a table of the wrong shape';
  END IF;

  FOR tv IN
    SELECT DISTINCT ON (t ->> 'tbl', t ->> 'root')
           t ->> 'tbl' AS tbl, decode(t ->> 'root', 'hex') AS root, s -> 'cols' AS cols
    FROM jsonb_array_elements(b -> 'trees') t
    JOIN jsonb_array_elements(b -> 'schemas') s
      ON s ->> 'commit' = t ->> 'commit' AND s ->> 'tbl' = t ->> 'tbl'
  LOOP
    bad := grove.verify_images(tv.root, tv.cols);

    IF bad > 0 THEN
      RAISE EXCEPTION 'grove: % row image(s) of % do not hash to the values recorded beside them', bad, tv.tbl
        USING HINT = 'the data was altered in transit; the tree records what each row should be '
                     'and the rows it carries do not match it, so nothing here is trustworthy';
    END IF;
  END LOOP;

  FOR e IN SELECT * FROM jsonb_array_elements(b -> 'commits') LOOP
    h := decode(e ->> 'sha', 'hex');

    SELECT COALESCE(string_agg(t.tbl || ':' || encode(t.root_hash, 'hex'), E'\n' ORDER BY t.tbl), '')
    INTO summary FROM grove.trees t WHERE t.commit_sha = h;

    SELECT array_agg(p.parent_sha ORDER BY p.ord) INTO extra
    FROM grove.commit_parent p WHERE p.commit_sha = h;

    IF extra IS NULL THEN
      calc := grove.commit_sha(decode(e ->> 'parent', 'hex'), e ->> 'author',
                               e ->> 'message', (e ->> 'at')::timestamptz, summary);
    ELSE
      calc := grove.octopus_commit_sha(
                ARRAY[decode(e ->> 'parent', 'hex')] || extra,
                e ->> 'message', (e ->> 'at')::timestamptz, summary);
    END IF;

    IF calc <> h THEN
      RAISE EXCEPTION 'grove: commit % does not hash to its own author, message, time and trees',
        left(e ->> 'sha', 12)
        USING HINT = 'the history in this bundle was rewritten in transit; refusing all of it';
    END IF;
  END LOOP;

  SELECT count(*) INTO missing
  FROM jsonb_each_text(COALESCE(b -> 'refs', '{}'::jsonb)) r
  WHERE NOT EXISTS (SELECT 1 FROM grove.commits c WHERE c.sha = decode(r.value, 'hex'));

  IF missing > 0 THEN
    RAISE EXCEPTION 'grove: this bundle has % ref(s) pointing at commits it does not carry', missing
      USING HINT = 'it was truncated or altered in transit; ask for it again rather than storing it';
  END IF;

  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION grove.fetch(remote_name text, b jsonb) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  e jsonb;
  k text;
  n int;
  started timestamptz := clock_timestamp();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM grove.remotes r WHERE r.name = remote_name) THEN
    RAISE EXCEPTION 'grove: no remote named %', remote_name
      USING HINT = 'add it first: SELECT grove.remote_add(' || quote_literal(remote_name)
                   || ', ''where the bundle came from'')';
  END IF;

  n := grove.unbundle(b);

  FOR k IN SELECT jsonb_object_keys(b -> 'refs') LOOP
    INSERT INTO grove.refs (name, sha)
    VALUES ('remotes/' || remote_name || '/' || k, decode(b -> 'refs' ->> k, 'hex'))
    ON CONFLICT (name) DO UPDATE SET sha = EXCLUDED.sha;
  END LOOP;

  PERFORM grove.emit('fetch', started, jsonb_build_object('remote', remote_name, 'commits', n));

  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION grove.receive(b jsonb, force boolean DEFAULT false) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  k       text;
  incoming bytea;
  cur      bytea;
  n        int;
  started timestamptz := clock_timestamp();
BEGIN
  n := grove.unbundle(b);

  FOR k IN SELECT jsonb_object_keys(b -> 'refs') LOOP
    incoming := decode(b -> 'refs' ->> k, 'hex');
    cur := grove.resolve(k);

    IF cur IS NOT NULL AND NOT force
       AND NOT EXISTS (SELECT 1 FROM grove.ancestors(incoming) a WHERE a.a = cur) THEN
      RAISE EXCEPTION 'grove: push to % is not a fast forward, it would drop commits', k;
    END IF;

    IF cur IS NULL THEN
      INSERT INTO grove.refs (name, sha) VALUES (k, incoming);
      INSERT INTO grove.reflog (ref, old_sha, new_sha, action, actor)
      VALUES (k, NULL, incoming, 'receive', grove.actor());
    ELSE
      UPDATE grove.refs SET sha = incoming WHERE name = k;
      INSERT INTO grove.reflog (ref, old_sha, new_sha, action, actor)
      VALUES (k, cur, incoming, 'receive', grove.actor());
    END IF;
  END LOOP;

  PERFORM grove.emit('receive', started, jsonb_build_object('commits', n, 'forced', force));

  RETURN n;
END $$;

CREATE TABLE IF NOT EXISTS grove.tags (
  name    text PRIMARY KEY,
  sha     bytea       NOT NULL,
  tagger  text,
  message text,
  at      timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION grove.tag(tag_name text, spec text DEFAULT 'HEAD',
                                    msg text DEFAULT NULL, force boolean DEFAULT false)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  target bytea := grove.rev(spec);
  started timestamptz := clock_timestamp();
BEGIN
  IF target IS NULL THEN RAISE EXCEPTION 'grove: cannot resolve %', spec; END IF;

  IF EXISTS (SELECT 1 FROM grove.tags t WHERE t.name = tag_name) AND NOT force THEN
    RAISE EXCEPTION 'grove: tag % already exists', tag_name;
  END IF;

  PERFORM grove.emit('tag', started, jsonb_build_object(
    'name', tag_name, 'at', grove.short_sha(target), 'forced', force));

  INSERT INTO grove.tags (name, sha, tagger, message)
  VALUES (tag_name, target, grove.actor(), msg)
  ON CONFLICT (name) DO UPDATE SET sha = EXCLUDED.sha, message = EXCLUDED.message;
END $$;

CREATE OR REPLACE FUNCTION grove.tag_delete(tag_name text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  started timestamptz := clock_timestamp();
  was     bytea       := (SELECT t.sha FROM grove.tags t WHERE t.name = tag_name);
BEGIN
  DELETE FROM grove.tags WHERE name = tag_name;
  PERFORM grove.emit('tag_delete', started, jsonb_build_object(
    'name', tag_name, 'was', grove.short_sha(was)));
END $$;

CREATE OR REPLACE FUNCTION grove.restore(spec text, pathspec text) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  target bytea := grove.rev(spec);
  want   text  := NULLIF(split_part(split_part(pathspec, ':', 1), '.', 1), '');
  row_k  text  := NULLIF(split_part(pathspec, ':', 2), '');
  r      record;
  d      record;
  troot  bytea;
  guard  jsonb;
  n      int := 0;
  started timestamptz := clock_timestamp();
BEGIN
  IF want IS NULL THEN RAISE EXCEPTION 'grove: restore needs a pathspec naming a table'; END IF;

  guard := grove.replay_begin();
  SET CONSTRAINTS ALL DEFERRED;

  FOR r IN SELECT x.tbl FROM grove.tracked x WHERE x.tbl::text = want LOOP
    SELECT y.root_hash INTO troot FROM grove.trees y
    WHERE y.commit_sha = target AND y.tbl = r.tbl::text;

    FOR d IN SELECT * FROM grove.diff_tree(grove.write_tree(r.tbl), troot) LOOP
      CONTINUE WHEN row_k IS NOT NULL
                AND NOT grove.row_matches(r.tbl::text, COALESCE(d.after, d.before), row_k);
      IF d.op = 'DELETE' THEN
        PERFORM grove.apply_row(r.tbl, 'delete', d.before);
      ELSE
        PERFORM grove.apply_row(r.tbl, 'upsert', d.after);
      END IF;
      n := n + 1;
    END LOOP;
  END LOOP;

  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM grove.replay_end(guard);
  PERFORM grove.emit('restore', started, jsonb_build_object(
    'spec', spec, 'pathspec', pathspec, 'rows', n));

  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION grove.stash_push(msg text DEFAULT 'stash') RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  branch text  := grove.head();
  parent bytea := grove.resolve(branch);
  snap   bytea;
  slot   text;
  started timestamptz := clock_timestamp();
BEGIN
  IF NOT grove.is_dirty() THEN
    RAISE EXCEPTION 'grove: nothing to stash, the working tree is clean';
  END IF;

  snap := grove.commit(msg, grove.actor());
  slot := 'stash/' || nextval('grove.merge_seq');

  INSERT INTO grove.refs (name, sha) VALUES (slot, snap);
  UPDATE grove.refs SET sha = parent WHERE name = branch;
  INSERT INTO grove.reflog (ref, old_sha, new_sha, action, actor)
  VALUES (branch, snap, parent, 'stash', grove.actor());

  PERFORM grove.reset(encode(parent, 'hex'), 'hard');
  PERFORM grove.emit('stash_push', started, jsonb_build_object('slot', slot, 'msg', msg));

  RETURN slot;
END $$;

CREATE OR REPLACE FUNCTION grove.stash_list() RETURNS TABLE (slot text, sha bytea, message text)
LANGUAGE sql STABLE AS $$
  SELECT r.name, r.sha, c.message
  FROM grove.refs r JOIN grove.commits c ON c.sha = r.sha
  WHERE r.name LIKE 'stash/%' ORDER BY r.name
$$;

DROP FUNCTION IF EXISTS grove.stash_pop(text);

CREATE OR REPLACE FUNCTION grove.stash_pop(want_slot text DEFAULT NULL) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  pick   text;
  snap   bytea;
  parent bytea;
  r      record;
  guard  jsonb;
  n      int := 0;
  aroot  bytea; broot bytea;
  started timestamptz := clock_timestamp();
BEGIN
  SELECT s.slot INTO pick FROM grove.stash_list() s
  WHERE want_slot IS NULL OR s.slot = want_slot
  ORDER BY s.slot DESC LIMIT 1;

  IF pick IS NULL THEN RAISE EXCEPTION 'grove: no stash to pop'; END IF;

  snap := grove.resolve(pick);
  SELECT c.parent_sha INTO parent FROM grove.commits c WHERE c.sha = snap;

  guard := grove.replay_begin();
  SET CONSTRAINTS ALL DEFERRED;

  FOR r IN SELECT x.tbl FROM grove.tracked x LOOP
    SELECT y.root_hash INTO aroot FROM grove.trees y WHERE y.commit_sha = parent AND y.tbl = r.tbl::text;
    SELECT y.root_hash INTO broot FROM grove.trees y WHERE y.commit_sha = snap   AND y.tbl = r.tbl::text;
    n := n + grove.apply_tree_diff(r.tbl, aroot, broot);
  END LOOP;

  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM grove.replay_end(guard);

  PERFORM grove.emit('stash_pop', started, jsonb_build_object('slot', pick, 'rows', n));

  DELETE FROM grove.refs WHERE name = pick;
  RETURN n;
END $$;

CREATE TABLE IF NOT EXISTS grove.bisect (
  id      int PRIMARY KEY DEFAULT 1,
  good    bytea NOT NULL,
  bad     bytea NOT NULL,
  CONSTRAINT bisect_single CHECK (id = 1)
);

ALTER TABLE grove.bisect ADD COLUMN IF NOT EXISTS orig_ref text;
ALTER TABLE grove.bisect ADD COLUMN IF NOT EXISTS orig_sha bytea;

CREATE OR REPLACE FUNCTION grove.bisect_start(good_spec text, bad_spec text) RETURNS bytea
LANGUAGE plpgsql AS $$
DECLARE
  ref text := grove.head();
  started timestamptz := clock_timestamp();
BEGIN
  DELETE FROM grove.bisect;
  INSERT INTO grove.bisect (id, good, bad, orig_ref, orig_sha)
  VALUES (1, grove.rev(good_spec), grove.rev(bad_spec), ref, grove.resolve(ref));
  PERFORM grove.emit('bisect_start', started, jsonb_build_object(
    'good', good_spec, 'bad', bad_spec, 'ref', ref));

  RETURN grove.bisect_next();
END $$;

CREATE OR REPLACE FUNCTION grove.bisect_range() RETURNS TABLE (sha bytea, ord int)
LANGUAGE sql STABLE AS $$
  WITH b AS (SELECT * FROM grove.bisect),
  span AS (
    SELECT l.sha, l.depth FROM b, grove.log((SELECT bad FROM b)) l
    WHERE l.sha <> (SELECT good FROM b)
      AND NOT EXISTS (SELECT 1 FROM grove.ancestors((SELECT good FROM b)) a WHERE a.a = l.sha)
  )
  SELECT span.sha, row_number() OVER (ORDER BY span.depth DESC)::int FROM span
$$;

CREATE OR REPLACE FUNCTION grove.bisect_next() RETURNS bytea
LANGUAGE plpgsql AS $$
DECLARE
  n   int;
  pick bytea;
BEGIN
  SELECT count(*) INTO n FROM grove.bisect_range();
  IF n = 0 THEN RETURN NULL; END IF;

  SELECT r.sha INTO pick FROM grove.bisect_range() r WHERE r.ord = greatest(1, (n + 1) / 2);
  PERFORM grove.reset(encode(pick, 'hex'), 'hard');
  RETURN pick;
END $$;

CREATE OR REPLACE FUNCTION grove.bisect_good(spec text DEFAULT 'HEAD') RETURNS bytea
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE grove.bisect SET good = grove.rev(spec);
  RETURN grove.bisect_next();
END $$;

CREATE OR REPLACE FUNCTION grove.bisect_bad(spec text DEFAULT 'HEAD') RETURNS bytea
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE grove.bisect SET bad = grove.rev(spec);
  RETURN grove.bisect_next();
END $$;

CREATE OR REPLACE FUNCTION grove.bisect_reset() RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  b record;
BEGIN
  SELECT * INTO b FROM grove.bisect WHERE id = 1;

  IF FOUND AND b.orig_sha IS NOT NULL AND grove.resolve(b.orig_ref) IS DISTINCT FROM b.orig_sha THEN
    PERFORM grove.reset(encode(b.orig_sha, 'hex'), 'hard');
  END IF;

  DELETE FROM grove.bisect;
END $$;

CREATE OR REPLACE FUNCTION grove.gc_nodes() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS grove_keep (h bytea PRIMARY KEY) ON COMMIT DROP;
  TRUNCATE grove_keep;

  INSERT INTO grove_keep
  SELECT DISTINCT r.h FROM grove.reachable_nodes(
    (SELECT COALESCE(array_agg(DISTINCT t.root_hash), '{}'::bytea[]) FROM grove.trees t)) r
  ON CONFLICT DO NOTHING;

  LOOP
    INSERT INTO grove_keep
    SELECT DISTINCT n2.base_hash FROM grove.nodes n2
    JOIN grove_keep k ON k.h = n2.hash
    WHERE n2.base_hash IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM grove_keep k2 WHERE k2.h = n2.base_hash)
    ON CONFLICT DO NOTHING;
    EXIT WHEN NOT FOUND;
  END LOOP;

  DELETE FROM grove.nodes WHERE hash NOT IN (SELECT h FROM grove_keep);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION grove.prune(before_at timestamptz) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r       record;
  cutoff  bytea;
  n       int := 0;
  started timestamptz := clock_timestamp();
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS grove_alive (sha bytea PRIMARY KEY) ON COMMIT DROP;
  TRUNCATE grove_alive;

  FOR r IN SELECT name, sha FROM grove.refs UNION SELECT name, sha FROM grove.tags LOOP
    INSERT INTO grove_alive
    SELECT l.sha FROM grove.log(r.sha) l WHERE l.at >= before_at
    ON CONFLICT DO NOTHING;

    SELECT l.sha INTO cutoff FROM grove.log(r.sha) l
    WHERE l.at >= before_at ORDER BY l.depth DESC LIMIT 1;

    IF cutoff IS NOT NULL THEN
      UPDATE grove.commits SET parent_sha = NULL WHERE sha = cutoff;
      DELETE FROM grove.commit_parent WHERE commit_sha = cutoff;
    ELSE
      INSERT INTO grove_alive VALUES (r.sha) ON CONFLICT DO NOTHING;
      UPDATE grove.commits SET parent_sha = NULL WHERE sha = r.sha;
      DELETE FROM grove.commit_parent WHERE commit_sha = r.sha;
    END IF;
  END LOOP;

  DELETE FROM grove.reflog   WHERE new_sha NOT IN (SELECT sha FROM grove_alive);
  DELETE FROM grove.trees    WHERE commit_sha NOT IN (SELECT sha FROM grove_alive);
  DELETE FROM grove.schemas  WHERE commit_sha NOT IN (SELECT sha FROM grove_alive);
  DELETE FROM grove.changes
   WHERE commit_sha IS NOT NULL AND commit_sha NOT IN (SELECT sha FROM grove_alive);
  DELETE FROM grove.commits  WHERE sha NOT IN (SELECT sha FROM grove_alive);
  GET DIAGNOSTICS n = ROW_COUNT;

  PERFORM grove.gc_nodes();

  PERFORM grove.emit('prune', started, jsonb_build_object(
    'commits_removed', n, 'before', before_at,
    'commits_left', (SELECT count(*) FROM grove.commits),
    'nodes_left', (SELECT count(*) FROM grove.nodes)));

  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION grove.checked_type(spec text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  known regtype;
BEGIN
  BEGIN
    known := to_regtype(spec);
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'grove: refusing a shape whose column type does not parse as a type: %', spec;
  END;

  IF known IS NULL THEN
    RAISE EXCEPTION 'grove: refusing a shape whose column type is not a known type: %', spec;
  END IF;

  RETURN spec;
END $$;

CREATE OR REPLACE FUNCTION grove.create_from_schema(sha bytea, target_tbl text) RETURNS void
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  sc   record;
  cols text;
BEGIN
  SELECT * INTO sc FROM grove.schemas x WHERE x.commit_sha = sha AND x.tbl = target_tbl;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'grove: commit % records no shape for %', encode(sha, 'hex'), target_tbl;
  END IF;

  IF sc.pk_cols IS NULL THEN
    RAISE EXCEPTION 'grove: the recorded shape for % has no primary key, cannot create it', target_tbl;
  END IF;

  SELECT string_agg(format('%I %s', e.value ->> 'name', grove.checked_type(e.value ->> 'type')), ', '
                    ORDER BY e.ordinality)
  INTO cols FROM jsonb_array_elements(sc.columns) WITH ORDINALITY e;

  EXECUTE format('CREATE TABLE %I (%s, PRIMARY KEY (%s))',
                 target_tbl, cols,
                 (SELECT string_agg(quote_ident(c), ', ') FROM unnest(sc.pk_cols) c));
END $$;

CREATE OR REPLACE FUNCTION grove.clone_from(b jsonb, branch text DEFAULT 'main') RETURNS int
LANGUAGE plpgsql SET client_min_messages = warning AS $$
DECLARE
  tip    bytea;
  t      record;
  made   int := 0;
  forged text;
  started timestamptz := clock_timestamp();
BEGIN
  IF EXISTS (SELECT 1 FROM grove.commits) THEN
    RAISE EXCEPTION 'grove: clone needs an empty history, use fetch or receive instead';
  END IF;

  PERFORM grove.unbundle(b);

  tip := decode(b -> 'refs' ->> branch, 'hex');
  IF tip IS NULL THEN
    RAISE EXCEPTION 'grove: the bundle carries no branch called %', branch;
  END IF;

  FOR t IN SELECT x.tbl FROM grove.schemas x WHERE x.commit_sha = tip LOOP
    IF to_regclass(t.tbl) IS NULL THEN
      PERFORM grove.create_from_schema(tip, t.tbl);
      made := made + 1;
    END IF;
    PERFORM grove.track(t.tbl::regclass);
  END LOOP;

  INSERT INTO grove.refs (name, sha) VALUES (branch, tip)
  ON CONFLICT (name) DO UPDATE SET sha = EXCLUDED.sha;
  UPDATE grove.meta SET value = branch WHERE key = 'head';

  INSERT INTO grove.reflog (ref, old_sha, new_sha, action, actor)
  VALUES (branch, NULL, tip, 'clone', grove.actor());

  PERFORM grove.reset(encode(tip, 'hex'), 'hard');

  SELECT string_agg(x.tbl, ', ') INTO forged
  FROM grove.trees x
  WHERE x.commit_sha = tip
    AND grove.write_tree(x.tbl::regclass) IS DISTINCT FROM x.root_hash;

  IF forged IS NOT NULL THEN
    RAISE EXCEPTION 'grove: the rows in this bundle do not hash to the tree it carries (%)', forged
      USING HINT = 'the restored table does not reproduce the root the bundle claims, so either the '
                   'shape it described is wrong or materialising it went wrong';
  END IF;

  PERFORM grove.emit('clone_from', started, jsonb_build_object(
    'branch', branch, 'tables', made, 'tip', grove.short_sha(tip)));

  RETURN made;
END $$;

CREATE TABLE IF NOT EXISTS grove.notes (
  commit_sha bytea PRIMARY KEY,
  note       text        NOT NULL,
  author     text,
  at         timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION grove.note_add(spec text, body text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  target bytea := grove.rev(spec);
  started timestamptz := clock_timestamp();
BEGIN
  IF target IS NULL THEN RAISE EXCEPTION 'grove: cannot resolve %', spec; END IF;
  PERFORM grove.emit('note_add', started, jsonb_build_object(
    'spec', spec, 'sha', grove.short_sha(target)));

  INSERT INTO grove.notes (commit_sha, note, author) VALUES (target, body, grove.actor())
  ON CONFLICT (commit_sha) DO UPDATE SET note = EXCLUDED.note, at = now();
END $$;

CREATE OR REPLACE FUNCTION grove.note_show(spec text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT n.note FROM grove.notes n WHERE n.commit_sha = grove.rev(spec)
$$;

CREATE OR REPLACE FUNCTION grove.note_delete(spec text) RETURNS void
LANGUAGE sql AS $$ DELETE FROM grove.notes WHERE commit_sha = grove.rev(spec) $$;

CREATE TABLE IF NOT EXISTS grove.rerere (
  signature       bytea PRIMARY KEY,
  tbl             text  NOT NULL,
  resolution_kind text  NOT NULL,
  resolution      jsonb,
  used            int   NOT NULL DEFAULT 0,
  at              timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION grove.rerere_signature(t text, b jsonb, o jsonb, th jsonb) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$
  SELECT grove.hash(t || '|' || COALESCE(b::text,'~') || '|' ||
                   COALESCE(o::text,'~') || '|' || COALESCE(th::text,'~'))
$$;

CREATE OR REPLACE FUNCTION grove.rerere_learn(mid bigint) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n int := 0;
  c record;
BEGIN
  FOR c IN SELECT * FROM grove.conflicts x WHERE x.merge_id = mid AND x.resolved LOOP
    INSERT INTO grove.rerere (signature, tbl, resolution_kind, resolution)
    VALUES (grove.rerere_signature(c.tbl, c.base, c.ours, c.theirs),
            c.tbl, c.resolution_kind, c.resolution)
    ON CONFLICT (signature) DO UPDATE
      SET resolution_kind = EXCLUDED.resolution_kind, resolution = EXCLUDED.resolution;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION grove.rerere_apply(mid bigint) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n int := 0;
  c record;
  r record;
BEGIN
  FOR c IN SELECT * FROM grove.conflicts x WHERE x.merge_id = mid AND NOT x.resolved LOOP
    SELECT * INTO r FROM grove.rerere y
    WHERE y.signature = grove.rerere_signature(c.tbl, c.base, c.ours, c.theirs);

    IF FOUND THEN
      UPDATE grove.conflicts
      SET resolution_kind = r.resolution_kind, resolution = r.resolution, resolved = true
      WHERE id = c.id;
      UPDATE grove.rerere SET used = used + 1 WHERE signature = r.signature;
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION grove.tree_similarity(a bytea, b bytea) RETURNS numeric
LANGUAGE sql STABLE AS $$
  WITH la AS (SELECT k, rh FROM grove.leaves(a)),
       lb AS (SELECT k, rh FROM grove.leaves(b)),
       shared AS (SELECT count(*) AS c FROM la JOIN lb USING (k, rh)),
       total  AS (SELECT (SELECT count(*) FROM la) + (SELECT count(*) FROM lb) AS c)
  SELECT CASE WHEN total.c = 0 THEN 0
              ELSE round((2.0 * shared.c) / total.c, 4) END
  FROM shared, total
$$;

DROP FUNCTION IF EXISTS grove.table_renames(bytea, bytea);
CREATE OR REPLACE FUNCTION grove.table_renames(a_sha bytea, b_sha bytea, threshold numeric DEFAULT 0.5)
RETURNS TABLE (old_tbl text, new_tbl text, kind text, similarity numeric)
LANGUAGE sql STABLE AS $$
  WITH gone AS (
    SELECT x.tbl, x.root_hash FROM grove.trees x WHERE x.commit_sha = a_sha
      AND x.tbl NOT IN (SELECT y.tbl FROM grove.trees y WHERE y.commit_sha = b_sha)
  ),
  fresh AS (
    SELECT x.tbl, x.root_hash FROM grove.trees x WHERE x.commit_sha = b_sha
      AND x.tbl NOT IN (SELECT y.tbl FROM grove.trees y WHERE y.commit_sha = a_sha)
  ),
  scored AS (
    SELECT g.tbl AS old_tbl, f.tbl AS new_tbl,
           CASE WHEN g.root_hash = f.root_hash THEN 1.0
                ELSE grove.tree_similarity(g.root_hash, f.root_hash) END AS sim
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

CREATE OR REPLACE FUNCTION grove.octopus_plan(base_sha bytea, heads bytea[])
RETURNS TABLE (tbl text, k text, op text, before jsonb, after jsonb, sides int, conflicted boolean)
LANGUAGE sql STABLE AS $$
  WITH d AS (
    SELECT h.ord, x.tbl, x.k, x.op, x.before, x.after
    FROM unnest(heads) WITH ORDINALITY h(sha, ord)
    CROSS JOIN LATERAL grove.diff(base_sha, h.sha) x
  )
  SELECT d.tbl, d.k,
         (array_agg(d.op     ORDER BY d.ord))[1],
         (array_agg(d.before ORDER BY d.ord))[1],
         (array_agg(d.after  ORDER BY d.ord))[1],
         count(DISTINCT d.ord)::int,
         count(DISTINCT d.op || '|' || COALESCE(d.after::text, '~')) > 1
  FROM d GROUP BY d.tbl, d.k
$$;

CREATE OR REPLACE FUNCTION grove.octopus_head_names(ours bytea, branch_names text[])
RETURNS text[]
LANGUAGE plpgsql STABLE AS $$
DECLARE
  names text[]   := '{}';
  heads bytea[]  := '{}';
  b     text;
  h     bytea;
BEGIN
  FOREACH b IN ARRAY branch_names LOOP
    h := grove.resolve(b);
    IF h IS NULL THEN RAISE EXCEPTION 'grove: unknown branch %', b; END IF;
    PERFORM grove.assert_same_schema(ours, h);

    IF h <> ours AND NOT (h = ANY (heads)) AND grove.merge_base(ours, h) <> h THEN
      heads := heads || h;
      names := names || b;
    END IF;
  END LOOP;

  RETURN names;
END $$;

CREATE OR REPLACE FUNCTION grove.octopus_refuse_if_conflicted(base bytea, all_heads bytea[])
RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
  bad record;
  key text;
BEGIN
  SELECT * INTO bad FROM grove.octopus_plan(base, all_heads) p
  WHERE p.conflicted ORDER BY p.tbl, p.k LIMIT 1;

  IF NOT FOUND THEN RETURN; END IF;

  SELECT string_agg(c || '=' || COALESCE(COALESCE(bad.after, bad.before) ->> c, 'null'), ',' ORDER BY c)
  INTO key FROM unnest(grove.pk_columns(bad.tbl::regclass)) c;

  RAISE EXCEPTION 'grove: octopus refuses this merge, % of the % heads changed %(%) differently; merge them one at a time',
    bad.sides, array_length(all_heads, 1), bad.tbl, key;
END $$;

CREATE OR REPLACE FUNCTION grove.octopus_commit_sha(
  all_heads bytea[], msg text, ts timestamptz, summary text) RETURNS bytea
LANGUAGE sql STABLE AS $$
  SELECT grove.hash(
    (SELECT string_agg(encode(x.sha, 'hex'), E'\n' ORDER BY x.ord)
     FROM unnest(all_heads) WITH ORDINALITY x(sha, ord)) || E'\n' ||
    msg || E'\n' ||
    to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || E'\n' || summary)
$$;

CREATE OR REPLACE FUNCTION grove.merge_octopus(branch_names text[], msg text DEFAULT NULL)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  ours    bytea   := grove.resolve(grove.head());
  names   text[]  := grove.octopus_head_names(grove.resolve(grove.head()), branch_names);
  heads   bytea[];
  all_h   bytea[];
  base    bytea;
  h       bytea;
  full_msg text;
  plan_row record;
  roots   jsonb;
  new_sha bytea;
  ts      timestamptz := clock_timestamp();
  started timestamptz := clock_timestamp();
BEGIN
  IF COALESCE(array_length(branch_names, 1), 0) < 2 THEN
    RAISE EXCEPTION 'grove: an octopus merge needs at least two branches, use merge for one';
  END IF;

  IF COALESCE(array_length(names, 1), 0) = 0 THEN
    RETURN 0;
  END IF;

  IF array_length(names, 1) = 1 THEN
    RETURN grove.merge(names[1], msg);
  END IF;

  SELECT array_agg(grove.resolve(n) ORDER BY o) INTO heads
  FROM unnest(names) WITH ORDINALITY x(n, o);

  full_msg := COALESCE(msg, 'merge ' || array_to_string(names, ' '));
  all_h    := ARRAY[ours] || heads;
  base     := ours;

  FOREACH h IN ARRAY heads LOOP
    base := grove.merge_base(base, h);
  END LOOP;

  PERFORM grove.octopus_refuse_if_conflicted(base, all_h);

  SET CONSTRAINTS ALL DEFERRED;

  FOR plan_row IN SELECT * FROM grove.octopus_plan(base, all_h) LOOP
    IF plan_row.op = 'DELETE' THEN
      PERFORM grove.apply_row(plan_row.tbl::regclass, 'delete', plan_row.before);
    ELSE
      PERFORM grove.apply_row(plan_row.tbl::regclass, 'upsert', plan_row.after);
    END IF;
  END LOOP;

  SET CONSTRAINTS ALL IMMEDIATE;

  roots   := grove.snapshot_trees(ours);
  new_sha := grove.octopus_commit_sha(all_h, full_msg, ts, grove.roots_summary(roots));

  INSERT INTO grove.commits (sha, parent_sha, author, message, at)
  VALUES (new_sha, ours, grove.actor(), full_msg, ts)
  ON CONFLICT (sha) DO NOTHING;

  INSERT INTO grove.commit_parent (commit_sha, ord, parent_sha)
  SELECT new_sha, (x.ord + 1)::int, x.sha
  FROM unnest(heads) WITH ORDINALITY x(sha, ord)
  ON CONFLICT DO NOTHING;

  PERFORM grove.record_trees(new_sha, roots);

  PERFORM grove.record_schemas(new_sha);
  UPDATE grove.changes SET commit_sha = new_sha WHERE commit_sha IS NULL;
  PERFORM grove.advance_ref(grove.head(), ours, new_sha);

  PERFORM grove.emit('merge_octopus', started, jsonb_build_object(
    'branches', to_jsonb(branch_names), 'sha', grove.short_sha(new_sha),
    'parents', array_length(all_h, 1), 'onto', grove.short_sha(ours)));

  RETURN 0;
END $$;

REVOKE ALL ON SCHEMA grove FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA grove FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA grove FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA grove FROM PUBLIC;

CREATE OR REPLACE FUNCTION grove.admin_only_verbs() RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['track','untrack','prune','gc_nodes','repack','unpack','reset',
               'delete_branch','unbundle','clone_from','receive','create_from_schema',
               'remote_add','grant_read','grant_write','grant_admin','log_rotate','untrack_missing']
$$;

CREATE OR REPLACE FUNCTION grove.write_verbs() RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['commit','branch','checkout','merge','merge_octopus','merge_finish',
               'merge_abort','merge_continue','cherry_pick','revert','rebase','rebase_abort',
               'tag','tag_delete','note_add','note_delete','stash_push','stash_pop',
               'bisect_start','bisect_good','bisect_bad','bisect_next','bisect_reset',
               'advance_ref','apply_row','apply_diff','materialise','replay_begin',
               'replay_end','record_conflicts','record_schemas','record_trees','resolve_all',
               'rerere_learn','rerere_apply','rerere_forget','write_tree',
               'write_tree_incremental','snapshot_trees','ensure_scratch','ensure_key_index',
               'build_up','build_one_level','locate_touched_chunks','splice_touched_chunks','emit',
               'rebuild_touched_ranges','assemble_above_leaves','journal_stmt','journal_truncate']
$$;

CREATE OR REPLACE FUNCTION grove.grant_level(role_name text, level text) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  fn    record;
  n     int := 0;
  admin text[] := grove.admin_only_verbs();
  wr    text[] := grove.write_verbs();
BEGIN
  IF level NOT IN ('read', 'write', 'admin') THEN
    RAISE EXCEPTION 'grove: level must be read, write or admin, not %', level;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
    RAISE EXCEPTION 'grove: role % does not exist; create it first', role_name;
  END IF;

  EXECUTE format('GRANT USAGE ON SCHEMA grove TO %I', role_name);
  EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA grove TO %I', role_name);

  IF level <> 'read' THEN
    EXECUTE format('GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA grove TO %I', role_name);
    EXECUTE format('GRANT USAGE ON ALL SEQUENCES IN SCHEMA grove TO %I', role_name);
  END IF;

  FOR fn IN
    SELECT p.oid, p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'grove'
  LOOP
    CONTINUE WHEN level = 'read'  AND (fn.proname = ANY (admin) OR fn.proname = ANY (wr));
    CONTINUE WHEN level = 'write' AND fn.proname = ANY (admin);
    EXECUTE format('GRANT EXECUTE ON FUNCTION grove.%I(%s) TO %I', fn.proname, fn.args, role_name);
    n := n + 1;
  END LOOP;

  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION grove.grant_read(role_name text) RETURNS int
LANGUAGE sql AS $$ SELECT grove.grant_level(role_name, 'read') $$;

CREATE OR REPLACE FUNCTION grove.grant_write(role_name text) RETURNS int
LANGUAGE sql AS $$ SELECT grove.grant_level(role_name, 'write') $$;

CREATE OR REPLACE FUNCTION grove.grant_admin(role_name text) RETURNS int
LANGUAGE sql AS $$ SELECT grove.grant_level(role_name, 'admin') $$;

CREATE OR REPLACE FUNCTION grove.health()
RETURNS TABLE (metric text, value text, attention boolean)
LANGUAGE sql STABLE AS $$
  WITH n AS (
    SELECT count(*) AS total,
           count(*) FILTER (WHERE entries IS NULL) AS packed,
           pg_total_relation_size('grove.nodes') AS bytes
    FROM grove.nodes
  ),
  j AS (
    SELECT count(*) FILTER (WHERE commit_sha IS NULL) AS pending,
           count(*) AS total,
           pg_total_relation_size('grove.changes') AS bytes
    FROM grove.changes
  ),
  c AS (SELECT count(*) AS commits, max(at) AS newest FROM grove.commits),
  t AS (SELECT count(*) AS tracked FROM grove.tracked),
  f AS (SELECT count(*) AS problems FROM grove.fsck())
  SELECT 'tracked tables', t.tracked::text, t.tracked = 0 FROM t
  UNION ALL SELECT 'commits', c.commits::text, false FROM c
  UNION ALL SELECT 'newest commit', COALESCE(c.newest::text, 'none'), false FROM c
  UNION ALL SELECT 'nodes', n.total::text, false FROM n
  UNION ALL SELECT 'node store', pg_size_pretty(n.bytes), false FROM n
  UNION ALL SELECT 'nodes packed by gc',
                   CASE WHEN n.total = 0 THEN '0%'
                        ELSE round(n.packed * 100.0 / n.total)::text || '%' END,
                   n.total > 5000 AND n.packed * 4 < n.total
            FROM n
  UNION ALL SELECT 'journal rows', j.total::text, false FROM j
  UNION ALL SELECT 'journal awaiting commit', j.pending::text, j.pending > 100000 FROM j
  UNION ALL SELECT 'journal size', pg_size_pretty(j.bytes), false FROM j
  UNION ALL SELECT 'fsck problems', f.problems::text, f.problems > 0 FROM f
  UNION ALL SELECT 'head', COALESCE(grove.head(), 'none'), false
  UNION ALL SELECT 'merge in progress',
                   COALESCE((SELECT string_agg(m.branch || ' <- ' || grove.short_sha(m.theirs_sha), ', ')
                             FROM grove.merges m), 'no'),
                   EXISTS (SELECT 1 FROM grove.merges)
  UNION ALL SELECT 'conflicts awaiting resolution',
                   (SELECT count(*)::text FROM grove.conflicts WHERE NOT resolved),
                   EXISTS (SELECT 1 FROM grove.conflicts WHERE NOT resolved)
  UNION ALL SELECT 'bisect in progress',
                   COALESCE((SELECT b.orig_ref FROM grove.bisect b LIMIT 1), 'no'),
                   EXISTS (SELECT 1 FROM grove.bisect)
  UNION ALL SELECT 'tracked tables missing',
                   COALESCE((SELECT string_agg(m.gone_table, ', ') FROM grove.missing_tracked() m), 'none'),
                   EXISTS (SELECT 1 FROM grove.missing_tracked())
  UNION ALL SELECT 'rebase in progress',
                   COALESCE((SELECT r.branch FROM grove.rebase_state r LIMIT 1), 'no'),
                   EXISTS (SELECT 1 FROM grove.rebase_state)
$$;

CREATE OR REPLACE FUNCTION grove.needs_attention() RETURNS TABLE (metric text, value text)
LANGUAGE sql STABLE AS $$
  SELECT h.metric, h.value FROM grove.health() h WHERE h.attention
$$;

CREATE OR REPLACE FUNCTION grove.metrics() RETURNS TABLE (metric text, value numeric)
LANGUAGE sql STABLE AS $$
  WITH n AS (
    SELECT count(*) AS total, count(*) FILTER (WHERE entries IS NULL) AS packed,
           pg_total_relation_size('grove.nodes') AS bytes
    FROM grove.nodes
  ),
  j AS (
    SELECT count(*) AS total, count(*) FILTER (WHERE commit_sha IS NULL) AS pending,
           pg_total_relation_size('grove.changes') AS bytes
    FROM grove.changes
  ),
  e AS (
    SELECT count(*) AS total,
           count(*) FILTER (WHERE NOT ok) AS failed,
           percentile_disc(0.5) WITHIN GROUP (ORDER BY duration_ms)
             FILTER (WHERE verb = 'commit') AS commit_p50,
           percentile_disc(0.95) WITHIN GROUP (ORDER BY duration_ms)
             FILTER (WHERE verb = 'commit') AS commit_p95,
           max(duration_ms) FILTER (WHERE verb = 'commit') AS commit_max
    FROM grove.events
  )
  SELECT 'grove_commits_total', count(*)::numeric FROM grove.commits
  UNION ALL SELECT 'grove_branches', count(*)::numeric FROM grove.refs
  UNION ALL SELECT 'grove_tracked_tables', count(*)::numeric FROM grove.tracked
  UNION ALL SELECT 'grove_nodes_total', n.total::numeric FROM n
  UNION ALL SELECT 'grove_nodes_packed', n.packed::numeric FROM n
  UNION ALL SELECT 'grove_node_bytes', n.bytes::numeric FROM n
  UNION ALL SELECT 'grove_journal_rows', j.total::numeric FROM j
  UNION ALL SELECT 'grove_journal_pending', j.pending::numeric FROM j
  UNION ALL SELECT 'grove_journal_bytes', j.bytes::numeric FROM j
  UNION ALL SELECT 'grove_merges_open', count(*)::numeric FROM grove.merges
  UNION ALL SELECT 'grove_conflicts_unresolved', count(*)::numeric FROM grove.conflicts WHERE NOT resolved
  UNION ALL SELECT 'grove_events_total', e.total::numeric FROM e
  UNION ALL SELECT 'grove_events_failed', e.failed::numeric FROM e
  UNION ALL SELECT 'grove_commit_ms_p50', COALESCE(e.commit_p50, 0) FROM e
  UNION ALL SELECT 'grove_commit_ms_p95', COALESCE(e.commit_p95, 0) FROM e
  UNION ALL SELECT 'grove_commit_ms_max', COALESCE(e.commit_max, 0) FROM e
  UNION ALL SELECT 'grove_seconds_since_last_commit',
                   COALESCE(round(extract(epoch FROM now() - max(at))), -1) FROM grove.commits
$$;

CREATE OR REPLACE FUNCTION grove.log_rotate() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  DELETE FROM grove.events
  WHERE at < now() - (grove.setting('log_retain_days') || ' days')::interval;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
