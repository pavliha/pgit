\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS fuzz_log (n int, op text, detail text);
TRUNCATE fuzz_log;

SET fuzz.ops  = :ops;
SET fuzz.seed = :seed;

DO $fuzz$
DECLARE
  ops     int := current_setting('fuzz.ops')::int;
  seedv   float8 := current_setting('fuzz.seed')::float8;
  tbls    text[] := ARRAY['fz_a', 'fz_b'];
  hostile text[] := ARRAY['t','s','n','o','v','k','e','cols','pgit_t','img','hash','keys'];
  types   text[] := ARRAY['int','text','numeric(10,2)','timestamptz','boolean','jsonb','bytea','varchar(40)','int[]'];
  i       int;
  pick    int;
  tb      text;
  col     text;
  ty      text;
  br      text;
  cnt     int;
  bad     int;
  extra   int := 0;
  branches text[] := ARRAY['main'];
BEGIN
  PERFORM setseed(seedv);

  FOREACH tb IN ARRAY tbls LOOP
    pick := 1 + floor(random() * array_length(hostile,1))::int;
    EXECUTE format('CREATE TABLE %I (id int PRIMARY KEY, %I text, %I int)',
                   tb, hostile[pick],
                   hostile[1 + (pick + floor(random() * (array_length(hostile,1) - 1))::int)
                               % array_length(hostile,1)]);
    EXECUTE format('INSERT INTO %I SELECT g, ''v'' || g, g FROM generate_series(1, 40) g', tb);
    PERFORM pgit.track(tb::regclass);
  END LOOP;
  PERFORM pgit.commit('fuzz base', 'main');

  FOR i IN 1..ops LOOP
    tb   := tbls[1 + floor(random() * array_length(tbls,1))::int];
    pick := 1 + floor(random() * 10)::int;

    BEGIN
      IF pick <= 3 THEN
        EXECUTE format('INSERT INTO %I (id) SELECT g FROM generate_series(%s, %s) g
                        ON CONFLICT (id) DO NOTHING',
                       tb, 1000 + i * 10, 1000 + i * 10 + 1 + floor(random()*6)::int);
        INSERT INTO fuzz_log VALUES (i, 'insert', tb);

      ELSIF pick <= 5 THEN
        EXECUTE format('UPDATE %I SET id = id WHERE id %% %s = 0', tb, 2 + floor(random()*7)::int);
        INSERT INTO fuzz_log VALUES (i, 'update', tb);

      ELSIF pick = 6 THEN
        EXECUTE format('DELETE FROM %I WHERE id %% %s = 0', tb, 5 + floor(random()*20)::int);
        INSERT INTO fuzz_log VALUES (i, 'delete', tb);

      ELSIF pick = 7 THEN
        extra := extra + 1;
        col := 'c' || extra;
        ty  := types[1 + floor(random() * array_length(types,1))::int];
        EXECUTE format('ALTER TABLE %I ADD COLUMN %I %s', tb, col, ty);
        INSERT INTO fuzz_log VALUES (i, 'add column', tb || '.' || col || ' ' || ty);

      ELSIF pick = 8 THEN
        SELECT a.attname INTO col FROM pg_attribute a
        WHERE a.attrelid = tb::regclass AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname <> 'id'
        ORDER BY random() LIMIT 1;
        IF col IS NOT NULL THEN
          EXECUTE format('ALTER TABLE %I DROP COLUMN %I', tb, col);
          INSERT INTO fuzz_log VALUES (i, 'drop column', tb || '.' || col);
        END IF;

      ELSIF pick = 9 THEN
        br := 'b' || i;
        PERFORM pgit.branch(br, pgit.resolve(pgit.head()));
        branches := branches || br;
        PERFORM pgit.checkout(br);
        INSERT INTO fuzz_log VALUES (i, 'branch+checkout', br);

      ELSE
        IF array_length(branches,1) > 1 AND random() < 0.5 THEN
          br := branches[1 + floor(random() * array_length(branches,1))::int];
          PERFORM pgit.checkout(br);
          INSERT INTO fuzz_log VALUES (i, 'checkout', br);
        ELSE
          PERFORM pgit.repack();
          INSERT INTO fuzz_log VALUES (i, 'repack', '');
        END IF;
      END IF;
    EXCEPTION WHEN others THEN
      INSERT INTO fuzz_log VALUES (i, 'refused', SQLERRM);
      CONTINUE;
    END;

    PERFORM pgit.commit('fuzz ' || i, pgit.head());

    SELECT count(*) INTO bad
    FROM pgit.trees t
    WHERE t.commit_sha = pgit.resolve(pgit.head())
      AND pgit.write_tree(t.tbl::regclass) IS DISTINCT FROM t.root_hash;

    IF bad > 0 THEN
      RAISE EXCEPTION 'fuzz: op % left % tree(s) disagreeing with a rebuild', i, bad;
    END IF;

    SELECT count(*) INTO cnt FROM pgit.fsck();
    IF cnt > 0 THEN
      RAISE EXCEPTION 'fuzz: op % left % fsck problem(s)', i, cnt;
    END IF;
  END LOOP;

  RAISE NOTICE 'fuzz: % operations, every tree matched a rebuild and fsck stayed clean', ops;
END $fuzz$;
