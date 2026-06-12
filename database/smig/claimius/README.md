# Claimius

A distributed claim based access control system for PostgreSQL.

Claimius is a Postgres schema (`claimius`) that manages user access to objects in your application via named permission templates called **claims**. Claims are bound to users (`user_claim`) and to objects (`claim_object`), with cascading inheritance through three orthogonal hierarchies: organization ownership, physical location, and per object self referencing parent chains.

The terminology of **prophet** and **disciple** describes the deployment shape. A prophet is the source of truth for an app's access state; disciples are read only mirrors that receive state via a sync stream and serve reads identically. The same schema runs on both. The role is enforced by Postgres role grants and the set of apps registered in `samna_app`.

## Why Claimius

Most access control libraries either live in app code (you have to remember to filter every query) or are limited to flat role based models. Claimius pushes access calculation into the database as triggers. Reads become O(1) lookups against a denormalized reverse index (`user_object`) regardless of how complex the underlying access graph is.

Once your app tables register with Claimius, every read can ask one question: "what can this user see?" and get an answer in a single index scan.

## Core concepts

**Claim**: a permission template with a numeric `sa_access_level` (lower = stronger; 0 system, 8 guest), an `is_deny` flag, and an `inherits` flag for cascading.

**user_claim**: a grant of a claim to a user, optionally time bounded.

**claim_object**: a binding of a claim to a target row in any registered table. Polymorphic via `(object_type, object_id)`.

**Three hierarchies**:

- **Ownership**: organizations form trees via `sa_owner_id`. Every registered row points into an organization via its own `sa_owner_id`. Claims with `inherits = true` cascade down ownership trees.
- **Location**: locations form trees via `sa_parent_id`, owned by an organization. Registered rows can pin into a location via `sa_location_id`. Claims cascade through location trees.
- **Parenthood**: any registered table can declare its own self referencing tree by including `sa_parent_id` and `sa_root_id`. Claims cascade through that tree too.

**Roots**: a row is a tree root when `sa_owner_id == sa_root_id == id` (organization), or `sa_parent_id == sa_root_id == id` (location, parenthood). Root rows always self reference. There are no nullable parent columns.

**Auto root trigger**: a `BEFORE INSERT` trigger (`tg_self_root`) handles two cases automatically:
- **Root row** (parent column NULL or set to `NEW.id`): self references both columns to `NEW.id`.
- **Child row** (parent column set, `sa_root_id` NULL): copies parent's `sa_root_id`.

Implementers don't need to know about `sa_root_id`. Just set the parent (`sa_owner_id` for orgs, `sa_parent_id` for locations and parenthood tables) or leave both NULL for a root, and the trigger fills in the rest. Attached to `claimius.organization` and `claimius.location` by claimius itself, and attached to implementer parenthood tables when registered via `init_claimius_tables`.

**Composite ids**: identifiers that span polymorphic tables use the format `<object_type>:<object_id>` where `object_type` is the schema qualified table name (`public.device`, `claimius.organization`).

**Trees**: `inheritance_info` is a closure table: one row per ancestor-descendant edge across the three tree types (ownership, location, parenthood). Self-edges at depth 0 are included so a node is its own ancestor. Calc functions maintain edges incrementally on writes; full rebuilds happen via `build_ownership_tree`, `build_location_tree`, `build_parenthood_tree`. Reads use indexed JOINs against the closure or the `get_subtree` / `get_*_ancestors` helpers.

**user_object**: the materialized reverse access index. One row per `(app, user, object)` with access. Carries the contributing grants array, denormalized rendering fields, and a tsvector for search. This is the table consumers read from indirectly through `get_*` functions.

**sync_event**: append only stream of changes to materialized state tables. Prophets write; disciples consume.

**Owner claim rule**: every resource that participates in the access model must carry at least one direct `claim_object` binding to a claim. The "owner claim" is the claim used to create the resource, captured from the actor's `user_claim_id` at write time, or specified explicitly when the writer wants a different binding. The direct binding exists so access is never reliant solely on cascade: even if the cascade machinery is bypassed, disabled per binding, or interrupted by an `inherits = FALSE` flag somewhere up the chain, the resource still has at least one user who can see and modify it. Two exceptions: `samna_user` rows (handled by `user_users` denormalization and `ensure_app_user`), and the claim itself (a claim does not bind itself via `claim_object`; that would be circular). Implementer write paths that insert organizations, locations, apps, or registered application table rows must follow up with an `assign_claim_object` (or direct `claim_object` insert during bootstrap) so the owner claim binding exists before any read tries to find the row.

**Inheritance**: cascades fire only when BOTH `claim.inherits` and the specific `claim_object.inherits` are TRUE. The claim's flag is the master switch for the whole claim; the per-binding flag narrows that to specific bindings. Either FALSE blocks cascade for that binding. A claim with `inherits = FALSE` means none of its bindings cascade regardless of their per-row flag.

## Roles

Four Postgres roles enforce the access boundary:

- **claimius_admin**: schema owner. Used during migrations.
- **claimius_writer**: prophet runtime. Can EXECUTE write functions.
- **claimius_reader**: app code runtime. Can EXECUTE only `get_*` functions.
- **claimius_disciple_client**: disciple sync layer. Can upsert into materialized state tables; cannot execute write functions.

App connections never own the schema. They inherit the appropriate role.

## Deployment shapes

**Prophet only**: production single instance. Full read and write. Calc triggers fire on every change, materialize state, emit `sync_event` rows.

**Disciple only**: read replica. Empty database; sync layer applies events from prophet under `replay_mode = true` so calc triggers stay quiet. Reads serve identical results to the prophet.

**Hybrid**: both. Useful for regional gateways: receives state from a central prophet, also acts as prophet for downstream disciples.

The role is determined at init time by which init function is called: `init_prophet`, `init_disciple`, or `init_hybrid`. There is no separate config table for role. The set of `samna_app` rows that exist plus the role grants tell you which mode you are in.

## Migration layout

Migrations are flyway compatible. Run them in order:

```
V0.0__roles.sql              Defines claimius_admin, _writer, _reader, _disciple_client
V1.0__baseline.sql           All tables, indexes, comments, enums
V2.1__functions_base.sql     Utilities: composite_id, decompose_id, tree primitives
V2.2__functions_internal.sql Tree builders, calc helpers, recompute_user_object
V2.3__functions_access.sql   Trigger functions: calc_object_access, calc_hierarchical_access,
                             calc_claim_access, emit_sync_event, audit_trigger
V2.4__functions_external.sql Public surface: get_*, search_objects, claim management,
                             merge_user, init_*, ensure_app_user
V3.0__triggers.sql           Attaches trigger functions to internal tables
VX.0__init.sql               Calls init_claimius_internal()
```

After Claimius migrations finish, the implementing app runs:

```sql
-- For a fresh prophet instance.
-- private_key, private_seed are generated externally in Go and passed in
-- (Claimius does not generate keys). app_secret is intentionally NOT a
-- bootstrap input: it is the API key disciples authenticate with against
-- this prophet's sync endpoints, and it's filled in by the implementing
-- service on demand via samna_app.app_secret. See "App secret" below.
-- Returns a JSONB object keyed by table name, with the full row each table
-- received. Capture it if you need ids for follow on inserts.
SELECT claimius.init_prophet(
           p_system_app_slug          => 'my_app',
           p_system_app_name          => 'My Application',
           p_system_app_private_key   => '<rsa private key from Go>',
           p_system_app_private_seed  => '<32 random bytes hex from Go>',
           p_system_app_redirect_uri  => 'https://my.app/oauth/callback',
           p_system_app_sync_uri      => 'https://my.app/claimius/sync',
           p_default_claim            => jsonb_build_object(
               'name',            'Guest',
               'description',     'Default claim granted to every regular user on first login. Marks account existence; grants no resource access.',
               'sa_access_level', 8
                                         )
       );
-- Result shape (JSONB), seven keys:
--   {
--     "samna_app":     { full samna_app row, app_secret is NULL until set by implementer },
--     "samna_user":    { full samna_user row, the system user },
--     "organization":  { full organization row, the system org },
--     "claim":         { full claim row, the system administrator claim },
--     "default_claim": { full claim row, the implementer defined default claim },
--     "claim_object":  { full claim_object row, system claim bound to system org },
--     "user_claim":    { full user_claim row, system user granted system claim }
--   }
-- prophet_state and inheritance_info are internal bookkeeping, not returned.

-- Or a disciple. State arrives from upstream prophet via the sync layer.
-- p_disciple_app_slug identifies which prophet app this disciple mirrors;
-- typically read from an env var like CLAIMIUS_DISCIPLE_APP_SLUG so the
-- same migration artefact deploys against any prophet. Returns empty
-- jsonb {}.
SELECT claimius.init_disciple(
           p_disciple_app_slug => 'mainapp'
       );

-- Or a hybrid. Calls both init_prophet (creates this hybrid's own system
-- app) AND init_disciple (records the upstream prophet app slug). Returns
-- the same jsonb shape as init_prophet.
SELECT claimius.init_hybrid(
           p_system_app_slug          => 'my_app',
           p_system_app_name          => 'My Application',
           p_system_app_private_key   => '<rsa private key from Go>',
           p_system_app_private_seed  => '<32 random bytes hex from Go>',
           p_disciple_app_slug        => 'upstream_prophet_slug',
           p_default_claim            => jsonb_build_object(
               'name',            'Guest',
               'description',     'Default claim for new users.',
               'sa_access_level', 8
                                         )
       );

-- Then register app tables:
SELECT claimius.init_claimius_tables(
           'public.device',
           'public.sensor',
           'public.recipe'
       );
```

## Bootstrap and creation order on a prophet

A fresh prophet has nothing in the database. Bringing it up requires a precise order because tables reference each other circularly (app references org, org has app_id, claims reference org, user_claim references claim, etc). `init_prophet` already encapsulates this for the system app and system org. When you create additional apps, organizations, and resources later, you follow the same pattern.

**Order for a fresh prophet (executed automatically by `init_prophet`):**

1. **System app** is inserted first, with a placeholder `sa_owner_id` referencing a UUID that will become the system org. `sa_created_by` is the system user's `user_id` (bootstrap exception, since no `user_claim` exists yet).
2. **System samna_user** is inserted, scoped to the system app.
3. **System organization** is inserted with `sa_owner_id = sa_root_id = id` (self rooted), and `app_id` points at the system app.
4. **App's `sa_owner_id`** is reconciled with an UPDATE to point at the real system org.
5. **`inheritance_info` self-edge** for the system org is inserted (`ownership` tree, depth 0), bootstrapping the closure for that root.
6. **System claim** ('System Administrator', level 0) is created, owned by the system org. This claim is sidelined: granted only to the system user, never via `ensure_app_user`.
   6b. **Default claim** is created from `p_default_claim` (name, description, level supplied by the implementer). Type is `'user'`, `inherits = false`, no `claim_object` binding. Holding this claim alone grants no resource access; it is a "you have an account" marker.
7. **App's `claim_id`** is updated to point at the **default claim** (NOT the system claim). This is the claim every regular user receives via `ensure_app_user`.
8. **claim_object binding** binds the system claim to the system org with `inherits = TRUE` (cascades to everything in the system org tree).
9. **user_claim** grants the system claim to the system user.
10. **prophet_state row** is inserted for the system app, with `last_applied_seq = 0`.
11. **Role grants** are applied so `claimius_writer` can do its job.

After this, the system user has full access to everything in the system org tree. Regular users created via `ensure_app_user` automatically receive the default claim, which by itself gives them no resource access. The implementing app grants additional claims as users earn permissions through normal flow.

**Order for a new (non system) app on an existing prophet:**

1. **Owning organization must exist first**. Either pick an existing org (typically the system org, or a tenant org) or create a fresh root org for the new app.
2. **INSERT INTO `claimius.samna_app`** with all the per app fields. `sa_owner_id` points at the chosen owning org. `sa_created_by` is the user_claim of the actor creating the app.
3. **INSERT INTO `claimius.prophet_state`** with the new `app_id` and `last_applied_seq = 0`.
4. **Optionally create a default claim** for this app and set `samna_app.claim_id` to it. This is the claim newly logged in users get.
5. **Register external app tables** if any: `SELECT claimius.init_claimius_tables(...)` with the table list.

**Order for adding resources to an existing app (the common case):**

1. **Organization** (if needed): direct INSERT with `sa_owner_id` pointing at parent org, or self referential for a new root.
2. **Location** (if needed): direct INSERT with `sa_owner_id` pointing at owning org and `sa_parent_id` pointing at parent location, or self referential for a root.
3. **Application table rows** (devices, recipes, etc): direct INSERT with all required `sa_*` columns.
4. **Grant access**: `create_claim` (if needed) → `assign_claim_object` (bind the claim to the resource) → `assign_claim_user` (grant to a user). See "Granting a user access to something" in the "Creating things" section.

Calc triggers handle tree maintenance and `user_object` updates automatically at every step. You do not need to call any "rebuild" or "refresh" functions in the normal flow.

## App secret

`samna_app.app_secret` is the API key disciples (or any other consumer) authenticate with against this prophet's sync endpoints. It is intentionally not a Claimius bootstrap input. The implementing service generates it (typically as `sha256(seed || raw_secret)` with the raw returned to the caller exactly once) and writes the hash to `samna_app.app_secret` on demand. `secret_version` increments on each rotation. Set both fields directly via UPDATE; there is no Claimius helper for this since the secret format and validation are the implementer's concern.

For the system app on a fresh prophet, `app_secret` is NULL after `init_prophet` runs. The implementer fills it in if and when the system app needs to be authenticated against externally. For non system apps the implementer creates, the same applies: generate a secret, write it to `samna_app.app_secret`, return the raw to the caller once.

## Self identity

A disciple consumes from exactly one upstream prophet app. A prophet has exactly one system app. Both deployments need to answer "which app am I, structurally" without leaking the slug into application code. Two row returning functions cover this:

```sql
-- On prophet or hybrid: returns the system app row.
-- Raises on a pure disciple.
SELECT * FROM claimius.get_prophet_app();

-- On disciple or hybrid: returns the upstream prophet app row.
-- Raises on a pure prophet.
SELECT * FROM claimius.get_disciple_app();
```

Both return `SETOF claimius.samna_app` so they compose with `WHERE`/`JOIN` naturally. They are read-only, fast (single indexed lookup), and granted to every role.

Three scalar variants exist for places that reject subqueries (column `DEFAULT` expressions, generated columns, check constraints):

```sql
claimius.get_prophet_app_id()  -- UUID, system app id; raises on pure disciple
claimius.get_disciple_app_id() -- UUID, upstream app id; raises on pure prophet
claimius.get_app_id()          -- UUID, deployment own app id (resolution below)
```

`get_app_id()` resolves to the prophet/system app on prophet and hybrid deployments, and to the disciple app on a pure disciple. On a hybrid the prophet side wins; callers that specifically want the disciple side on a hybrid must use `get_disciple_app_id()`.

Use these in column defaults instead of inlining a subquery:

```sql
-- Wrong: Postgres rejects subqueries in DEFAULT expressions
CREATE TABLE public.thing (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    app_id UUID NOT NULL DEFAULT (SELECT id FROM claimius.get_disciple_app())
);

-- Right: function call in DEFAULT works
CREATE TABLE public.thing (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    app_id UUID NOT NULL DEFAULT claimius.get_disciple_app_id()
);
```

The slugs are stored at init:

- `init_prophet(p_system_app_slug => 'mainapp', ...)` writes `'mainapp'` to `claimius.prophet_state.system_app_slug` on the system app's row. A partial unique index (`WHERE system_app_slug IS NOT NULL`) enforces "at most one system row."
- `init_disciple(p_disciple_app_slug => 'mainapp')` writes `'mainapp'` to `claimius.disciple_state.disciple_app_slug` (singleton, NOT NULL).

Implementer middleware should call `claimius.get_disciple_app()` (or `get_disciple_app_id()` for a bare UUID) instead of maintaining a parallel `app_id()` helper. On a disciple `claimius.samna_app` only ever contains rows that arrive via sync; the slug-keyed lookup gives you the canonical row even before any migration runs against it.

## Reading and writing

Every read goes through a `get_*` function. The functions self heal (drain `reconcile_queue`), check user status (cascade soft delete if applicable), filter by temporal validity, and return.

```sql
-- Can this user see this object at admin level (3) or stronger?
SELECT * FROM claimius.get_access(
    p_user_id     => :user_id,
    p_app_id      => :app_id,
    p_object_id   => :object_id,
    p_object_type => 'public.device',
    p_min_level   => 3
);

-- All objects of this type the user can see:
SELECT * FROM claimius.get_objects(
    p_user_id     => :user_id,
    p_app_id      => :app_id,
    p_object_type => 'public.device'
);

-- Full text search across accessible objects:
SELECT * FROM claimius.search(
    p_user_id => :user_id,
    p_app_id  => :app_id,
    p_query   => 'thermostat kitchen'
);
```

### `user_claim_id` and the actor token contract

`get_access`, `get_objects`, and `search` return a `user_claim_id` column alongside the access information. This is the **actor token** the caller uses as `sa_created_by` on follow on writes.

The contract: when `claim_id` is non null on the returned row, `user_claim_id` is also populated. `get_access` only returns rows when at least one surviving claim grants access, so a row from `get_access` always carries a usable `user_claim_id`. When the user has no surviving claim grant on the object (a possibility during seeding or in deployments that haven't yet bound every resource), call `get_direct_access` instead. It walks the object's owner, location, and parenthood ancestor chains and returns the closest, highest-privilege user_claim the user holds anywhere on those chains, in the same row shape as `get_access`. If even that returns no rows, the user has no path to act on the object.

```sql
-- Read access AND grab the actor token for a follow on write.
SELECT user_claim_id INTO :acting_user_claim
FROM claimius.get_access(
    p_user_id     => :user_id,
    p_app_id      => :app_id,
    p_object_id   => :recipe_id,
    p_object_type => 'public.recipe',
    p_min_level   => 4
);

-- Now use it as the actor for the write.
UPDATE public.recipe SET name = :new_name, sa_created_by = :acting_user_claim
WHERE id = :recipe_id;
```

The list and graph functions (`get_organizations`, `get_locations`, `get_users`, `get_claims`, `get_audit`, `get_secrets`, `get_owner_graph`, `get_claim_graph`) do NOT include `user_claim_id`. If you need it after listing, call `get_access` for the specific object you're about to act on.

Writes go through functions when one exists for the operation (`create_claim`, `assign_claim_user`, `assign_claim_object`, `merge_user`, etc). For tables without dedicated functions, direct INSERT/UPDATE on the prophet is fine; the prophet runtime role (`claimius_writer`) has the necessary grants. The triggers attached to each table fire either way.

Write functions return a single jsonb object keyed by the affected table name(s). The caller can pull values out with the `->` and `->>` jsonb operators, or pipe the whole object back to a service in Go/Python without further translation.

```sql
-- Create a claim
SELECT claimius.create_claim(
    p_app_id          => :app_id,
    p_name            => 'Device Operator',
    p_description     => 'Read and operate devices',
    p_sa_access_level => 5,
    p_sa_owner_id     => :org_id,
    p_sa_root_id      => :root_org_id,
    p_sa_created_by   => :acting_user_claim
);

-- Grant a claim to a user
SELECT claimius.assign_claim_user(
    p_app_id        => :app_id,
    p_claim_id      => :claim_id,
    p_user_id       => :user_id,
    p_sa_owner_id   => :org_id,
    p_sa_created_by => :acting_user_claim
);

-- Bind a claim to an object
SELECT claimius.assign_claim_object(
    p_app_id        => :app_id,
    p_claim_id      => :claim_id,
    p_object_id     => :device_id,
    p_object_type   => 'public.device',
    p_sa_owner_id   => :org_id,
    p_sa_root_id    => :root_org_id,
    p_sa_created_by => :acting_user_claim
);
```

To use the result inside a DO block for further work, capture and unpack with the jsonb operators:

```sql
DO $$
DECLARE
    v_init     JSONB;
    v_app_id   UUID;
    v_org_id   UUID;
    v_claim_id UUID;
BEGIN
    v_init := claimius.init_prophet(
        p_system_app_slug          => 'my_app',
        p_system_app_name          => 'My App',
        p_system_app_private_key   => :'private_key',
        p_system_app_private_seed  => :'private_seed',
        p_default_claim            => jsonb_build_object(
            'name',            'Guest',
            'description',     'Default claim for new users.',
            'sa_access_level', 8
        )
    );

    v_app_id   := (v_init -> 'samna_app'    ->> 'id')::UUID;
    v_org_id   := (v_init -> 'organization' ->> 'id')::UUID;
    v_claim_id := (v_init -> 'claim'        ->> 'id')::UUID;

    -- now use them in subsequent inserts
    INSERT INTO claimius.organization (
        app_id, name, type, sa_owner_id, sa_root_id, sa_level, sa_created_by
    ) VALUES (
        v_app_id, 'Acme NYC', 'office',
        v_org_id, v_org_id, 1,
        (v_init -> 'user_claim' ->> 'id')::UUID
    );
END $$;
```

## Required columns on registered tables

Every external table registered through `init_claimius_tables` must include:

- `id UUID PRIMARY KEY`
- `sa_owner_id UUID NOT NULL` (organization)
- `sa_created_by UUID NOT NULL` (user_claim id)
- `sa_created_at TIMESTAMPTZ`
- `sa_updated_at TIMESTAMPTZ`
- `sa_deleted_at TIMESTAMPTZ`

Optional:

- `app_id UUID NOT NULL` (when omitted, the deployment's own app id is inferred via `claimius.get_app_id()` at trigger time. Required on prophets that host more than one app, since inference would be ambiguous; rejected at registration in that case.)
- `sa_location_id UUID` (location the row is pinned to)
- `sa_parent_id UUID NOT NULL` and `sa_root_id UUID NOT NULL` (must come together; declares this table is self referencing)
- `name TEXT` and `description TEXT` (denormalized into `user_object` for search and rendering)

`init_claimius_tables` validates these and raises if any required column is missing or if the multi app guard fails on `app_id`.

## Creating things

For every create, `sa_created_by` must be a `user_claim.id` belonging to the actor in this app. Calc triggers handle tree maintenance and `user_object` updates automatically; the notes below say what you should do afterward.

**Function vs direct INSERT.** Some entities have dedicated write functions (`create_claim`, `assign_claim_user`, `assign_claim_object`, `merge_user`, `ensure_app_user`). Use the function when it exists. For everything else, direct INSERT/UPDATE is allowed on the prophet side; the prophet runtime's role (`claimius_writer`) has the necessary grants. The triggers attached to each table fire either way, so the tree maintenance and access calculations are identical.

### A new app

Apps carry per app cryptographic material. `private_key` and `private_seed` (RSA keypair plus seed) are required at insert time and generated externally in your Go service. `app_secret` is the consumer-facing API key for sync; it is generated and written separately, often after the app is created. Claimius does not generate any of these.

```sql
INSERT INTO claimius.samna_app (
    slug, name, description, contact_email, app_image,
    redirect_uri, sync_uri, provider_ids,
    private_key, private_seed,
    style, claim_id, sa_owner_id, sa_created_by, status
) VALUES (
    :slug, :name, :description, :contact_email, :app_image,
    :redirect_uri, :sync_uri, :provider_ids,
    :private_key, :private_seed,
    :style, :default_claim_id, :owning_org_id, :acting_user_claim, 'active'
);
```

After: typically `INSERT INTO claimius.prophet_state (app_id, last_applied_seq) VALUES (:new_app_id, 0)` so the new app has a sync cursor. When the implementing service is ready to issue an API key for this app (typically returned to the caller of the create-app endpoint), generate it externally and `UPDATE claimius.samna_app SET app_secret = :hash, secret_version = secret_version + 1 WHERE id = :new_app_id`.

For the system app (the very first app on a fresh prophet), use `claimius.init_prophet` instead. It handles the system-app/system-org chicken-and-egg ordering and leaves `app_secret` NULL for the implementer to fill on demand.

### A new organization (root)

Use `create_root_organization`. The function handles the self reference on `sa_owner_id` and `sa_root_id` internally and is idempotent on `(app_id, name)`.

```sql
SELECT claimius.create_root_organization(
    p_app_id              => :app_id,
    p_name                => 'Acme Inc',
    p_actor_user_claim_id => :acting_user_claim,
    p_description         => NULL,
    p_type                => 'company'
);
```

Returns `{"organization": {...}}`. After: calc trigger inserts the org's edges into the `inheritance_info` ownership closure (self-edge plus one edge per ancestor in the existing chain). Nobody has access to the new org yet. To give someone access, follow with the create-claim + assign pattern below.

### A new organization (child of an existing org)

```sql
INSERT INTO claimius.organization (
    app_id, name, type,
    sa_owner_id, sa_root_id, sa_level, sa_created_by
) VALUES (
    :app_id, 'Acme NYC', 'office',
    :parent_org_id,
    :parent_org_root_id,    -- same as the parent's sa_root_id
    :parent_level + 1,
    :acting_user_claim
);
```

After: calc trigger splices the new org into the existing ownership tree. Anyone with an inheriting claim on an ancestor automatically gets access (recomputed in `user_object`).

### A new location

A location requires an owning organization. The BEFORE INSERT trigger handles the self references for roots and copies parent's `sa_root_id` for children, so the caller only needs to set the parent (or leave it NULL for a root).

```sql
-- Root location: parent and root left out, trigger self references both
INSERT INTO claimius.location (
    app_id, sa_owner_id, name, type,
    sa_level, sa_created_by
) VALUES (
    :app_id, :org_id, 'Headquarters', 'building',
    0, :acting_user_claim
);

-- Child location: only sa_parent_id needs to be set, trigger copies sa_root_id
INSERT INTO claimius.location (
    app_id, sa_owner_id, name, type,
    sa_parent_id, sa_level, sa_created_by
) VALUES (
    :app_id, :org_id, 'Conference Room A', 'room',
    :parent_loc_id, :parent_level + 1, :acting_user_claim
);
```

After: calc trigger updates the location tree and (if applicable) splices the location into the owning org's ownership tree.

### A row in your own registered table

Just a normal INSERT with the required `sa_*` columns. The calc trigger attached at registration time handles everything else.

```sql
INSERT INTO public.device (
    id, app_id, name, sa_owner_id, sa_created_by
) VALUES (
    gen_random_uuid(), :app_id, 'Thermostat 1', :org_id, :acting_user_claim
);
```

If your table has `sa_location_id`, set it to a valid location id and the row will also appear in that location's tree. If your table has `sa_parent_id`/`sa_root_id`, set both, and either point at a parent (child case) or point at self (root case).

After: nothing. The calc trigger updated `inheritance_info` and recomputed `user_object` for everyone with reach.

### Granting a user access to something (3 steps)

This is the standard pattern whenever you create a new "thing" and want someone to access it. Steps 1 and 2 are skipped if you're reusing an existing claim. Each function returns a single key jsonb (`{"claim": {...}}`, `{"claim_object": {...}}`, `{"user_claim": {...}}`).

```sql
-- 1. Create the claim
SELECT claimius.create_claim(
    p_app_id          => :app_id,
    p_name            => 'Admin: Acme NYC',
    p_description     => 'Full access to Acme NYC and descendants',
    p_sa_access_level => 1,
    p_sa_owner_id     => :org_id,
    p_sa_root_id      => :root_org_id,
    p_sa_created_by   => :acting_user_claim
);

-- 2. Bind it to the object
SELECT claimius.assign_claim_object(
    p_app_id        => :app_id,
    p_claim_id      => :claim_id,
    p_object_id     => :org_id,
    p_object_type   => 'claimius.organization',
    p_sa_owner_id   => :org_id,
    p_sa_root_id    => :root_org_id,
    p_sa_created_by => :acting_user_claim,
    p_inherits      => TRUE
);

-- 3. Grant the claim to the user
SELECT claimius.assign_claim_user(
    p_app_id        => :app_id,
    p_claim_id      => :claim_id,
    p_user_id       => :user_id,
    p_sa_owner_id   => :org_id,
    p_sa_created_by => :acting_user_claim
);
```

After each step, calc triggers fan out and recompute `user_object` for affected users. By the end of step 3, the user can immediately read through `get_*` functions.

### A user logs in to an app for the first time

```sql
SELECT claimius.ensure_app_user(
    p_user_id    => :user_id,
    p_app_id     => :app_id,
    p_first_name => :first,
    p_last_name  => :last,
    p_user_name  => :user_name,
    p_user_image => :user_image,
    p_email      => :email
);
```

Idempotent. Inserts the `samna_user` row if missing. If the app has `samna_app.claim_id` set (the default claim, configured during `init_prophet` via `p_default_claim`), also grants that claim to the user as a `user_claim` row. Returns:

```json
{
  "samna_user": { ... },
  "user_claim": { ... }   // only present when the app has a default claim
}
```

After: nothing else from the Claimius side. The user now has the default claim granted. The implementing app grants additional claims later as the user earns permissions (joining an org, being assigned a role, etc).

## Deny claims

Setting `is_deny = true` on a claim flips it to deny semantics. A deny claim with `sa_access_level = N` erases grants at level `<= N` on the same path. Path is identified by `(tree_type, cascaded_from)` in the grants jsonb.

A deny on the bound object itself (non cascading) blocks all paths.

A deny at level 0 erases direct (creator) grants too.

Denies are computed inside calc functions; the resulting `user_object` row reflects only surviving grants.

## Sync model

Prophet:
1. Writes happen via functions, which run normal SQL.
2. Triggers (calc, audit, emit_sync_event) fire and produce a row in `sync_event` for every change to materialized state tables.
3. Sync middleware (outside Claimius) reads `sync_event` by `seq`, ships events to disciples, and updates `prophet_state.last_applied_seq`.

Disciple:
1. Sync middleware connects to the prophet's sync feed.
2. Receives events, applies them with `claimius.replay_mode = true`. This suppresses calc triggers and event emission so applying replicated state does not generate new events.
3. Updates `disciple_state.last_applied_seq` to the highest seq applied.
4. Failures are queued in `reconcile_queue`, drained inline at the top of `get_*` functions.

The same composite ids on prophet and disciple guarantee idempotent upserts. Apply an event twice, get the same row.

## Graphs

Two functions return flat node lists suitable for visualizing the deployment's access topology. Both return rows of shape `(object_id UUID, object_type TEXT, label TEXT, parent_id UUID, data JSONB)` so the frontend can pipe them straight into a graph layout (dagre, d3-force, whatever). Both go through `reconcile_if_pending` and `check_user_active` first.

Every row's `data` jsonb contains at minimum two keys:
- `access_level` (INTEGER or NULL): the user's effective access level for this object, from `user_object.sa_access_level`. NULL for nodes that aren't accessible objects in the standard model (the requesting user themselves, user_claim connectors, claim_object connectors).
- `level` (INTEGER or NULL): the tree depth of the row in its native hierarchy (orgs and locations have it; other types are NULL).

Additional keys vary by node kind. All field names in `data` use plain naming without `sa_` prefixes (so `owner_id` not `sa_owner_id`, `location_id` not `sa_location_id`, `description` not `sa_description`, etc.).

### `get_owner_graph(p_user_id, p_app_id, p_start_id, p_depth, p_min_level)`

Returns the ownership graph: organizations, locations, and every registered application table that has `sa_owner_id` and/or `sa_location_id`. Rows are scoped to what the calling user has access to via `get_objects`.

Arguments:
- `p_start_id UUID DEFAULT NULL`: organization id to start from. NULL walks every accessible root org. If the start id is not an accessible org, the function returns empty silently.
- `p_depth INTEGER DEFAULT 0`: how many levels of descent below the start. 0 means unlimited. The start org is depth 0; its direct children are depth 1; and so on.
- `p_min_level INTEGER DEFAULT 30`: access level filter passed through to `get_objects`.

Per-row `data` shape:
- Organizations (`object_type = 'claimius.organization'`): `{ access_level, level, description, type, owner_id }`.
- Locations (`object_type = 'claimius.location'`): `{ access_level, level, description, type, owner_id, longitude, latitude }`.
- Other registered tables: `{ access_level, level (NULL), description, owner_id, location_id }`.

`label` comes from the row's `name` column when available (via `user_object.sa_name`), otherwise the id as fallback.

`parent_id` is the canonical ancestor in priority order: `sa_parent_id`, then `sa_location_id`, then `sa_owner_id`. NULL for tree roots.

### `get_claim_graph(p_user_id, p_app_id, p_start_id, p_depth, p_min_level)`

Returns the access graph: the requesting user, every other user this user can see (via `user_users`), every claim the user holds, the user_claim grants, claim_object connector nodes, and the actual objects reachable through those bindings.

Arguments:
- `p_start_id UUID DEFAULT NULL`: claim id. NULL includes every claim the user holds. If the start id is not a claim the user holds, the function returns empty silently.
- `p_depth INTEGER DEFAULT 0`: 0 includes cascaded objects; >= 1 includes only directly-bound objects (no cascade descendants).
- `p_min_level INTEGER DEFAULT 30`.

Topology:
```
user (parent_id = NULL)
  '- user_claim    (parent_id = user.id)
  '- other users   (parent_id = user.id, via user_users)
claim (parent_id = NULL)
  '- claim_object  (parent_id = claim.id)
        '- object  (parent_id = claim_object.id)
```

Per-row `data` shape:
- The requesting user (`object_type = 'claimius.samna_user'`, parent_id NULL): `{ access_level (NULL), level (NULL), user_id, email, status }`.
- Other users (`object_type = 'claimius.samna_user'`, parent_id = requesting user id): `{ access_level, level (NULL), user_id, email, status }`.
- user_claim (`object_type = 'claimius.user_claim'`): `{ access_level (NULL), level (NULL), claim_id, starts_at, ends_at, reason }`.
- Claim (`object_type = 'claimius.claim'`): `{ access_level (the claim's own level), level (NULL), description, is_deny, inherits, type }`.
- claim_object connector (`object_type = 'claimius.claim_object'`): `{ access_level (NULL), level (NULL), target_object_id, target_object_type, inherits }`.
- Reachable object (`object_type = the object's schema-qualified type`): `{ access_level, level (NULL), description, owner_id, location_id, tree_type }`. `tree_type` is `'direct'` for directly-bound objects or `'ownership'`/`'location'`/`'parenthood'` for cascaded ones.

### Extending the graphs

The graph functions surface what claimius knows: the structural ownership chain and the access topology, with object data limited to the columns claimius materializes (`sa_name`, `sa_description`, `sa_access_level`, `sa_owner_id`, `sa_location_id`). If you need richer per-table fields (a bookable's `type_id`, an asset's specifics, etc.) write a wrapper in your own schema that UNIONs claimius's output with rows from your own tables, scoped through `get_objects`:

```sql
CREATE OR REPLACE FUNCTION public.get_owner_graph(p_user_id UUID, p_start_id UUID DEFAULT NULL, p_depth INTEGER DEFAULT 0, p_min_level INTEGER DEFAULT 30)
   RETURNS TABLE(object_id UUID, object_type TEXT, label TEXT, parent_id UUID, data JSONB) AS $$
DECLARE
   v_app_id UUID := claimius.get_app_id();
BEGIN
   RETURN QUERY SELECT * FROM claimius.get_owner_graph(p_user_id, v_app_id, p_start_id, p_depth, p_min_level);
   -- Add your own enrichment, override per-row data jsonb where you want
   -- richer fields, etc. claimius's rows will still be there with the
   -- canonical schema-qualified types.
END;
$$ LANGUAGE plpgsql;
```