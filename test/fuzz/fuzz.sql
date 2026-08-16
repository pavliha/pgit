\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS fuzz_log (n int, op text, detail text);
TRUNCATE fuzz_log;

SET fuzz.ops  = :ops;
SET fuzz.seed = :seed;
SET fuzz.rows = :rows;
UPDATE grove.meta SET value = :'chunk' WHERE key = 'chunk_target';

DO $fuzz$
DECLARE
  ops     int := current_setting('fuzz.ops')::int;
  seedv   float8 := current_setting('fuzz.seed')::float8;
  tbls    text[] := ARRAY['fz_a', 'fz_b'];
  hostile text[] := ARRAY['t','s','n','o','v','k','e','cols','grove_t','img','hash','keys'];
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
    PERFORM grove.track(tb::regclass);
  END LOOP;
  PERFORM grove.commit('fuzz base', 'main');

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
        PERFORM grove.branch(br, grove.resolve(grove.head()));
        branches := branches || br;
        PERFORM grove.checkout(br);
        INSERT INTO fuzz_log VALUES (i, 'branch+checkout', br);

      ELSIF pick = 10 AND i > 3 THEN
        SELECT a.attname INTO col FROM pg_attribute a
        WHERE a.attrelid = tb::regclass AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname <> 'id' AND a.atttypid = 'text'::regtype
        ORDER BY a.attnum LIMIT 1;
        IF col IS NOT NULL THEN
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 13 = 0', tb, col, 'pruned-' || i);
          PERFORM grove.prune((SELECT c.at FROM grove.commits c ORDER BY c.at DESC OFFSET 1 LIMIT 1));
          INSERT INTO fuzz_log VALUES (i, 'change then prune', tb || '.' || col);
        END IF;

      ELSIF pick = 12 THEN
        SELECT a.attname INTO col FROM pg_attribute a
        WHERE a.attrelid = tb::regclass AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname <> 'id' AND a.atttypid = 'text'::regtype
        ORDER BY a.attnum LIMIT 1;

        IF col IS NOT NULL THEN
          home := grove.head();
          br   := 'm' || i;
          PERFORM grove.branch(br);
          PERFORM grove.checkout(br);
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 11 = 0', tb, col, 'theirs-' || i);
          PERFORM grove.commit('theirs ' || i, grove.head(), now(), true);
          PERFORM grove.checkout(home);
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 11 = 0', tb, col, 'ours-' || i);
          PERFORM grove.commit('ours ' || i, grove.head(), now(), true);
          branches := branches || br;

          cnt := grove.merge(br, 'fuzz merge ' || i);
          IF cnt > 0 THEN
            SELECT max(m.id) INTO mid FROM grove.merges m;
            IF random() < 0.5 THEN
              PERFORM grove.resolve_all(mid, CASE WHEN random() < 0.5 THEN 'ours' ELSE 'theirs' END);
              PERFORM grove.merge_finish(mid);
              INSERT INTO fuzz_log VALUES (i, 'merge resolved', br || ' (' || cnt || ' conflicts)');
            ELSE
              PERFORM grove.merge_abort(mid);
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
          home := grove.head();
          br   := 'oa' || i;
          br2  := 'ob' || i;

          PERFORM grove.branch(br);
          PERFORM grove.checkout(br);
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 17 = 0 AND id %% 2 = 0', tb, col, 'oct-a-' || i);
          PERFORM grove.commit('octopus a ' || i, grove.head(), now(), true);
          PERFORM grove.checkout(home);

          PERFORM grove.branch(br2);
          PERFORM grove.checkout(br2);
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 19 = 0 AND id %% 2 = 1', tb, col, 'oct-b-' || i);
          PERFORM grove.commit('octopus b ' || i, grove.head(), now(), true);
          PERFORM grove.checkout(home);

          branches := branches || br || br2;
          BEGIN
            cnt := grove.merge_octopus(ARRAY[br, br2], 'fuzz octopus ' || i);
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
          PERFORM grove.commit('to revert ' || i, grove.head(), now(), true);
          BEGIN
            PERFORM grove.revert(grove.resolve(grove.head()));
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
          home := grove.head();
          br   := 'cp' || i;
          PERFORM grove.branch(br);
          PERFORM grove.checkout(br);
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 29 = 0', tb, col, 'picked-' || i);
          PERFORM grove.commit('pick source ' || i, grove.head(), now(), true);
          PERFORM grove.checkout(home);
          branches := branches || br;
          BEGIN
            cnt := grove.cherry_pick(grove.resolve(br), 'fuzz pick ' || i);
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
          home := grove.head();
          br   := 'rb' || i;
          PERFORM grove.branch(br);
          PERFORM grove.checkout(br);
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 31 = 0', tb, col, 'rebase-side-' || i);
          PERFORM grove.commit('rebase side ' || i, grove.head(), now(), true);
          PERFORM grove.checkout(home);
          EXECUTE format('UPDATE %I SET %I = %L WHERE id %% 37 = 0', tb, col, 'rebase-home-' || i);
          PERFORM grove.commit('rebase home ' || i, grove.head(), now(), true);
          PERFORM grove.checkout(br);
          branches := branches || br;
          BEGIN
            cnt := grove.rebase(home);
            IF cnt > 0 THEN
              PERFORM grove.rebase_abort();
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
          PERFORM grove.checkout(br);
          INSERT INTO fuzz_log VALUES (i, 'checkout', br);
        ELSE
          PERFORM grove.repack();
          INSERT INTO fuzz_log VALUES (i, 'repack', '');
        END IF;
      END IF;
    EXCEPTION WHEN others THEN
      INSERT INTO fuzz_log VALUES (i, 'refused', SQLERRM);
      CONTINUE;
    END;

    PERFORM grove.commit('fuzz ' || i, grove.head(), now(), true);

    SELECT count(*) INTO bad
    FROM grove.trees t
    WHERE t.commit_sha = grove.resolve(grove.head())
      AND grove.write_tree(t.tbl::regclass) IS DISTINCT FROM t.root_hash;

    IF bad > 0 THEN
      RAISE EXCEPTION 'fuzz: op % left % tree(s) disagreeing with a rebuild', i, bad;
    END IF;

    SELECT count(*) INTO cnt FROM grove.fsck();
    IF cnt > 0 THEN
      RAISE EXCEPTION 'fuzz: op % left % fsck problem(s)', i, cnt;
    END IF;
  END LOOP;

  RAISE NOTICE 'fuzz: % operations, every tree matched a rebuild and fsck stayed clean', ops;
END $fuzz$;
