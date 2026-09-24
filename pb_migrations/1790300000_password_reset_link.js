/// <reference path="../pb_data/types.d.ts" />
///
/// Points the password-reset email at this app instead of the PocketBase dashboard.
///
/// # What was wrong
///
/// PocketBase's built-in `resetPasswordTemplate` links to
/// `{APP_URL}/_/#/auth/confirm-password-reset/{TOKEN}` — the **admin dashboard's**
/// own reset page. That is the right link for an app whose users are
/// administrators, and the wrong one for this one: the deployment serves the
/// Flutter bundle from `/` and proxies only `/api/` to PocketBase (see
/// docker/nginx.conf), so `/_/` falls through to the SPA catch-all and renders the
/// app at a path it has no route for. The reset link opened a blank screen, and
/// the password could never be changed.
///
/// The failure is silent in the worst way: `request-password-reset` answers 204
/// and the email is genuinely sent, so everything looks like it worked right up
/// until the user clicks the link.
///
/// # Why it rewrites the link rather than the whole body
///
/// The default body is otherwise fine, and an operator may legitimately have
/// reworded it. Replacing only the URL leaves their wording intact and is
/// idempotent: a template that already points at the app is already correct, and
/// one that has been customised *and* left pointing at the dashboard still gets
/// fixed. Rewriting the body wholesale would silently discard their edit.
///
/// The subject is left alone — it says "Reset your {APP_NAME} password", which is
/// accurate whatever the link is.
///
/// # The one thing this cannot do
///
/// The link is absolute, so it is only as correct as `{APP_URL}`. That is a
/// deployment setting, not a schema one, and `pb_hooks/mail.pb.js` applies it from
/// the environment on boot; see the deployment section of DEVELOPMENT.md.
migrate(
  (app) => {
    /// The dashboard path, exactly as PocketBase ships it.
    const dashboardPath = "/_/#/auth/confirm-password-reset/{TOKEN}";
    /// This app's route. `token` is a query parameter because the link arrives
    /// from outside the app — a mail client, a pasted URL — where there is no
    /// navigation stack or `extra` to carry it.
    const appPath = "/#/reset-password?token={TOKEN}";

    let collection = null;
    try {
      // By name, matching how the hooks resolve it (`findAuthRecordByEmail("users", …)`).
      collection = app.findCollectionByNameOrId("users");
    } catch (_) {
      // No auth collection means nothing to point at an app.
      return;
    }

    const template = collection.resetPasswordTemplate;
    if (!template || typeof template.body !== "string") return;
    if (template.body.indexOf(dashboardPath) === -1) return;

    template.body = template.body.split(dashboardPath).join(appPath);
    app.save(collection);
  },
  // Down restores PocketBase's own default, so a rollback leaves the schema exactly
  // as a fresh install of this version would have it.
  (app) => {
    let collection = null;
    try {
      collection = app.findCollectionByNameOrId("users");
    } catch (_) {
      return;
    }
    const template = collection.resetPasswordTemplate;
    if (!template || typeof template.body !== "string") return;
    if (template.body.indexOf("/#/reset-password?token={TOKEN}") === -1) return;

    template.body = template.body
      .split("/#/reset-password?token={TOKEN}")
      .join("/_/#/auth/confirm-password-reset/{TOKEN}");
    app.save(collection);
  }
);
