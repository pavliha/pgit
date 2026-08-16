BEGIN;
SELECT plan(4);

CREATE TABLE n_null (id int PRIMARY KEY, v text);
CREATE TABLE n_empty (id int PRIMARY KEY, v text);
CREATE TABLE n_tilde (id int PRIMARY KEY, v text);
CREATE TABLE n_absent (id int PRIMARY KEY);

INSERT INTO n_null  VALUES (1, NULL);
INSERT INTO n_empty VALUES (1, '');
INSERT INTO n_tilde VALUES (1, '~');
INSERT INTO n_absent VALUES (1);

SELECT isnt(
  grove.tree_root('n_null'), grove.tree_root('n_empty'),
  'AC-CANON-03: NULL and empty string are distinct'
);

SELECT isnt(
  grove.tree_root('n_null'), grove.tree_root('n_absent'),
  'AC-CANON-03: NULL and an absent column are distinct'
);

SELECT isnt(
  grove.tree_root('n_empty'), grove.tree_root('n_absent'),
  'AC-CANON-03: empty string and an absent column are distinct'
);

SELECT isnt(
  grove.tree_root('n_null'), grove.tree_root('n_tilde'),
  'AC-CANON-03: the NULL marker cannot be forged by a literal value'
);

SELECT * FROM finish();
ROLLBACK;
