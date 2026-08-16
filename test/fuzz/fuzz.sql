\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS fuzz_log (n int, op text, detail text);
TRUNCATE fuzz_log;

SET fuzz.ops  = :ops;
SET fuzz.seed = :seed;
SET fuzz.rows = :rows;
UPDATE pgit.meta SET value = :'chunk' WHERE key = 'chunk_target';

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
  mid     bigint;
  home    text;
  br2     text;
  branches text[] := ARRAY['main'];
BEGIN
  PERFORM setseed(seedv);

  FOREACH tb IN ARRAY tbls LOOP
    pick := 1 + floor(random() * array_length(hostile,1))::int;
    EXECUTE format('CREATE TABLE %I (id int PRIMARY KEY, %I text, %I int)',
                   tb, hostile[pick],
                   hostile[1 + (pick + floor(random() * (array_length(hostile,1) - 1))::int)
                               % array_length(hostile,1)]);
    EXECUTE format('INSERT INTO %I SELECT g, ''v'' || g, g FROM generate_series(1, %s) g',
                   tb, current_setting('fuzz.rows')::int);
    PERFORM pgit.track(tb::regclass);
  END LOOP;
  PERFORM pgit.commit('fuzz base', 'main');

  FOR i IN 1..ops LOOP
    tb   := tbls[1 + floor(random() * array_length(tbls,1))::int];
    pick := 1 + floor(random() * 16)::int;

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

      ELSIF pick = 10 AND i > 3 THEN
        SELECT a.attname INTO col FROM pg_attribute a
        WHERE a.attrelid = tb::regclass AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname <> 'id' AND a.atttypid = 'text'::regtype
        ORDER BY a.attnum LIMIT 1;
        IF col IS NOT NULL THEN
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 13 = 0', tb, col, 'pruned-' || i);
          PERFORM pgit.prune((SELECT c.at FROM pgit.commits c ORDER BY c.at DESC OFFSET 1 LIMIT 1));
          INSERT INTO fuzz_log VALUES (i, 'change then prune', tb || '.' || col);
        END IF;

      ELSIF pick = 12 THEN
        SELECT a.attname INTO col FROM pg_attribute a
        WHERE a.attrelid = tb::regclass AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname <> 'id' AND a.atttypid = 'text'::regtype
        ORDER BY a.attnum LIMIT 1;

        IF col IS NOT NULL THEN
          home := pgit.head();
          br   := 'm' || i;
          PERFORM pgit.branch(br);
          PERFORM pgit.checkout(br);
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 11 = 0', tb, col, 'theirs-' || i);
          PERFORM pgit.commit('theirs ' || i, pgit.head(), now(), true);
          PERFORM pgit.checkout(home);
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 11 = 0', tb, col, 'ours-' || i);
          PERFORM pgit.commit('ours ' || i, pgit.head(), now(), true);
          branches := branches || br;

          cnt := pgit.merge(br, 'fuzz merge ' || i);
          IF cnt > 0 THEN
            SELECT max(m.id) INTO mid FROM pgit.merges m;
            IF random() < 0.5 THEN
              PERFORM pgit.resolve_all(mid, CASE WHEN random() < 0.5 THEN 'ours' ELSE 'theirs' END);
              PERFORM pgit.merge_finish(mid);
              INSERT INTO fuzz_log VALUES (i, 'merge resolved', br || ' (' || cnt || ' conflicts)');
            ELSE
              PERFORM pgit.merge_abort(mid);
              INSERT INTO fuzz_log VALUES (i, 'merge aborted', br || ' (' || cnt || ' conflicts)');
            END IF;
          ELSE
            INSERT INTO fuzz_log VALUES (i, 'merge clean', br);
          END IF;
        END IF;

      ELSIF pick = 13 THEN
        SELECT a.attname INTO col FROM pg_attribute a
        WHERE a.attrelid = tb::regclass AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname <> 'id' AND a.atttypid = 'text'::regtype
        ORDER BY a.attnum LIMIT 1;

        IF col IS NOT NULL THEN
          home := pgit.head();
          br   := 'oa' || i;
          br2  := 'ob' || i;

          PERFORM pgit.branch(br);
          PERFORM pgit.checkout(br);
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 17 = 0 AND id %% 2 = 0', tb, col, 'oct-a-' || i);
          PERFORM pgit.commit('octopus a ' || i, pgit.head(), now(), true);
          PERFORM pgit.checkout(home);

          PERFORM pgit.branch(br2);
          PERFORM pgit.checkout(br2);
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 19 = 0 AND id %% 2 = 1', tb, col, 'oct-b-' || i);
          PERFORM pgit.commit('octopus b ' || i, pgit.head(), now(), true);
          PERFORM pgit.checkout(home);

          branches := branches || br || br2;
          BEGIN
            cnt := pgit.merge_octopus(ARRAY[br, br2], 'fuzz octopus ' || i);
            INSERT INTO fuzz_log VALUES (i, 'octopus merged', br || ',' || br2);
          EXCEPTION WHEN others THEN
            INSERT INTO fuzz_log VALUES (i, 'octopus refused', SQLERRM);
          END;
        END IF;

      ELSIF pick = 14 THEN
        SELECT a.attname INTO col FROM pg_attribute a
        WHERE a.attrelid = tb::regclass AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname <> 'id' AND a.atttypid = 'text'::regtype
        ORDER BY a.attnum LIMIT 1;
        IF col IS NOT NULL THEN
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 23 = 0', tb, col, 'to-revert-' || i);
          PERFORM pgit.commit('to revert ' || i, pgit.head(), now(), true);
          BEGIN
            PERFORM pgit.revert(pgit.resolve(pgit.head()));
            INSERT INTO fuzz_log VALUES (i, 'revert', tb);
          EXCEPTION WHEN others THEN
            INSERT INTO fuzz_log VALUES (i, 'revert refused', SQLERRM);
          END;
        END IF;

      ELSIF pick = 15 THEN
        SELECT a.attname INTO col FROM pg_attribute a
        WHERE a.attrelid = tb::regclass AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname <> 'id' AND a.atttypid = 'text'::regtype
        ORDER BY a.attnum LIMIT 1;
        IF col IS NOT NULL THEN
          home := pgit.head();
          br   := 'cp' || i;
          PERFORM pgit.branch(br);
          PERFORM pgit.checkout(br);
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 29 = 0', tb, col, 'picked-' || i);
          PERFORM pgit.commit('pick source ' || i, pgit.head(), now(), true);
          PERFORM pgit.checkout(home);
          branches := branches || br;
          BEGIN
            cnt := pgit.cherry_pick(pgit.resolve(br), 'fuzz pick ' || i);
            INSERT INTO fuzz_log VALUES (i, 'cherry_pick', br || ' -> ' || cnt);
          EXCEPTION WHEN others THEN
            INSERT INTO fuzz_log VALUES (i, 'cherry_pick refused', SQLERRM);
          END;
        END IF;

      ELSIF pick = 16 THEN
        SELECT a.attname INTO col FROM pg_attribute a
        WHERE a.attrelid = tb::regclass AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname <> 'id' AND a.atttypid = 'text'::regtype
        ORDER BY a.attnum LIMIT 1;
        IF col IS NOT NULL THEN
          home := pgit.head();
          br   := 'rb' || i;
          PERFORM pgit.branch(br);
          PERFORM pgit.checkout(br);
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 31 = 0', tb, col, 'rebase-side-' || i);
          PERFORM pgit.commit('rebase side ' || i, pgit.head(), now(), true);
          PERFORM pgit.checkout(home);
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 37 = 0', tb, col, 'rebase-home-' || i);
          PERFORM pgit.commit('rebase home ' || i, pgit.head(), now(), true);
          PERFORM pgit.checkout(br);
          branches := branches || br;
          BEGIN
            cnt := pgit.rebase(home);
            IF cnt > 0 THEN
              PERFORM pgit.rebase_abort();
              INSERT INTO fuzz_log VALUES (i, 'rebase aborted', home || ' (' || cnt || ' conflicts)');
            ELSE
              INSERT INTO fuzz_log VALUES (i, 'rebase', home);
            END IF;
          EXCEPTION WHEN others THEN
            INSERT INTO fuzz_log VALUES (i, 'rebase refused', SQLERRM);
          END;
        END IF;

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

    PERFORM pgit.commit('fuzz ' || i, pgit.head(), now(), true);

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
