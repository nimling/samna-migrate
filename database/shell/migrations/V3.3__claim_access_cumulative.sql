UPDATE claimius.claim
   SET sa_access = sa_access | 14
 WHERE (sa_access & 1) = 1
   AND sa_deleted_at IS NULL;

UPDATE claimius.claim
   SET sa_access = sa_access | 12
 WHERE (sa_access & 2) = 2
   AND sa_deleted_at IS NULL;

UPDATE claimius.claim
   SET sa_access = sa_access | 4
 WHERE (sa_access & 8) = 8
   AND sa_deleted_at IS NULL;
