/// Makes the venue and performer lists readable without a session.
///
/// # Why
///
/// The app documents these two lists as public — `README.md` ("Sem conta dá
/// para abrir as listas de locais e de artistas. Elas são públicas") and the
/// sign-in page, which offers a button to each. Neither worked: the collections
/// carried `listRule: '@request.auth.id != ""'`, so an anonymous visitor's
/// request answered 401, and the router bounced them off the route before the
/// request was even made. Both halves are fixed; this file is the server half.
///
/// # Read-only
///
/// Only `listRule` and `viewRule` change. Creating, updating and deleting stay
/// authenticated — and stay narrowed further by `entities.guard.pb.js`, which
/// enforces ownership on top of the rule. Publishing a list is not publishing
/// the ability to edit it.
///
/// # What this exposes
///
/// Every field of both records, to anyone who asks: not only a venue's name and
/// address but its `contact`, and a performer's `contact` too. PocketBase rules
/// are per-record, not per-field, so making the list public makes the whole row
/// public — there is no expression that hides one column. That is a deliberate
/// trade for a directory whose point is to be found by people who do not have
/// an account yet, and the seeded data is fictitious. A deployment with real
/// contact addresses should either move them to a collection with its own rules
/// or drop them from the public projection.
///
/// Idempotent, and written as its own migration rather than an edit to
/// `1789450062_collections_snapshot.js`: PocketBase records an applied migration
/// by filename and never re-runs it, so editing the snapshot would fix fresh
/// databases only and leave every existing one — including the one the
/// screenshots were taken from — still refusing anonymous reads.
migrate((app) => {
  for (const name of ["venues", "performers"]) {
    const collection = app.findCollectionByNameOrId(name);
    unmarshal(
      {
        // Empty string, not null: in PocketBase a rule of `""` means "everyone,
        // signed in or not", while `null` means "superusers only" — which is
        // what a missing rule would silently give us.
        "listRule": "",
        "viewRule": "",
      },
      collection
    );
    app.save(collection);
  }
}, (app) => {
  for (const name of ["venues", "performers"]) {
    const collection = app.findCollectionByNameOrId(name);
    unmarshal(
      {
        "listRule": '@request.auth.id != ""',
        "viewRule": '@request.auth.id != ""',
      },
      collection
    );
    app.save(collection);
  }
});
