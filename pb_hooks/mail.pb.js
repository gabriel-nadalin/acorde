/// Outbound mail: the deployment's configuration, and the two messages the app
/// sends on its own.
///
/// # Why everything here is defined inside its handler
///
/// PocketBase's JSVM does not run these files as one module. Each registered
/// handler is re-evaluated later in a synthetic `pb.js` scope, so a `function`
/// declared at file level is NOT in scope when the handler runs — it fails with
/// `ReferenceError: <name> is not defined`, and for `onBootstrap` that failure
/// repeats on every boot until the server stops answering. The helpers are
/// therefore declared inside the handlers, which is also what every other hook in
/// this directory does.
///
/// # Configuration
///
/// `PB_APP_URL`, `PB_SMTP_*` — see `.env.example`. Everything is optional, and an
/// unset variable is a no-op, so the PocketBase dashboard remains a perfectly good
/// way to configure any of it by hand.
onBootstrap((e) => {
  e.next();

  // The public URL of the APP, which is not the backend's. PocketBase builds
  // password-reset links from it, and its default (http://localhost:8090) points
  // at the API port, which serves no app and which a recipient's browser cannot
  // reach — a link that fails only in their mail client, where nothing here can
  // see it.
  //
  // A migration cannot do this: it runs once, and the app URL is exactly the
  // setting that changes when a deployment moves.
  const configuredAppUrl = String($os.getenv("PB_APP_URL") || "").trim();
  try {
    if (configuredAppUrl !== "") {
      const settings = $app.settings();
      const current = String(settings.meta.appURL || "").trim();
      // Trailing slashes would produce `https://host//#/reset-password`;
      // PocketBase does not normalise them for us.
      const wanted = configuredAppUrl.replace(/\/+$/, "");
      if (current.replace(/\/+$/, "") !== wanted) {
        settings.meta.appURL = wanted;
        $app.save(settings);
        console.log("mail: appURL set to " + wanted + " (was " + current + ")");
      }
    }
  } catch (error) {
    // A wrong URL in one email must not stop the server from starting.
    console.log("mail: could not apply PB_APP_URL: " + error);
  }

  // The mail account, from the environment rather than the dashboard: credentials
  // belong beside the other credentials (PB_ADMIN_EMAIL/PB_ADMIN_PASSWORD) and out
  // of the data directory.
  //
  // A partial configuration is refused rather than half-applied. A host with no
  // password cannot send anything, and writing it would turn "no mail configured"
  // into "mail configured and failing" — which the client's mail-status probe
  // would then report as working.
  const smtpHost = String($os.getenv("PB_SMTP_HOST") || "").trim();
  try {
    if (smtpHost !== "") {
      const smtpPassword = String($os.getenv("PB_SMTP_PASSWORD") || "");
      if (smtpPassword === "") {
        console.log(
          "mail: PB_SMTP_HOST is set but PB_SMTP_PASSWORD is not; ignored"
        );
      } else {
        const settings = $app.settings();
        const port = parseInt(String($os.getenv("PB_SMTP_PORT") || "587"), 10);
        const username = String($os.getenv("PB_SMTP_USERNAME") || "").trim();
        // Defaults to the username, because that is what nearly every relay wants
        // and a second variable for the common case is one more thing to get wrong.
        const from =
          String($os.getenv("PB_SMTP_FROM") || "").trim() || username;

        settings.smtp.enabled = true;
        settings.smtp.host = smtpHost;
        settings.smtp.port = port > 0 ? port : 587;
        settings.smtp.username = username;
        settings.smtp.password = smtpPassword;
        // `tls: true` is IMPLICIT TLS (SMTPS — connect encrypted, usually port
        // 465), while `false` sends STARTTLS and lets the server upgrade (the
        // standard submission setup on port 587). PocketBase's own field
        // documents this as "when set to false StartTLS command is send".
        //
        // Defaulting to STARTTLS because that is the common configuration, and
        // because guessing the other way fails in a confusing manner: Go reports
        // "first record does not look like a TLS handshake" — which reads like a
        // broken server rather than a wrong flag. Set PB_SMTP_TLS=1 for 465.
        settings.smtp.tls = String($os.getenv("PB_SMTP_TLS") || "0") === "1";
        if (from !== "") {
          settings.meta.senderAddress = from;
          settings.meta.senderName =
            String($os.getenv("PB_SMTP_SENDER_NAME") || "").trim() ||
            String(settings.meta.appName || "Acorde");
        }
        $app.save(settings);
        console.log("mail: smtp enabled via " + smtpHost + ":" + settings.smtp.port);
      }
    }
  } catch (error) {
    console.log("mail: could not apply the SMTP configuration: " + error);
  }
});

/// The two messages the app sends by itself, for the one mechanism it exists for.
///
/// # Why this is a single handler with two branches
///
/// Both fire on the same event — a `memberships` row being created — and both need
/// the same helpers. Two handlers would duplicate all of them, and (see the note
/// at the top of this file) they cannot be shared from file scope, so the split
/// would buy nothing but a second copy.
///
/// # Why it exists at all
///
/// Membership is the app's central mechanism and it had no way to reach anybody: an
/// invite was a row on somebody's dashboard, and an invitation to a person who
/// never opens the app is an invitation that never happened. Likewise a request to
/// join was visible only to a manager who happened to look. So:
///
///   * `initiatedBy = "invite"`   → the invited ADDRESS is told.
///   * `initiatedBy = "request"`  → every active MANAGER of the target is told.
///
/// Only PENDING rows are announced. An active row is a fact about an account that
/// already agreed, and mailing about it would be noise.
///
/// # Why a failure cannot propagate
///
/// The row is already written. Throwing would fail a membership creation over a
/// mail server and leave the manager retrying a row that exists — so every failure
/// is logged and swallowed, exactly as `invites.pb.js` treats its own claim.
///
/// Sending is synchronous inside the request, so a relay that hangs delays the
/// response until PocketBase's own mailer timeout. That is the honest tradeoff:
/// the alternative is losing the message with no record of it.
onRecordAfterCreateSuccess((e) => {
  const record = e.record;
  if (!record) return;

  /// An empty host is not a mailer whatever `enabled` says — the same reading the
  /// client's `GET /api/agenda/mail-status` does, so the two cannot disagree.
  function mailReady() {
    try {
      const smtp = $app.settings().smtp;
      return !!smtp.enabled && String(smtp.host || "") !== "";
    } catch (_) {
      return false;
    }
  }

  /// The app's own address, for links inside a message. Trailing slash trimmed so
  /// `${appUrl}/#/` never becomes `//#/`.
  function appUrl() {
    try {
      return String($app.settings().meta.appURL || "").replace(/\/+$/, "");
    } catch (_) {
      return "";
    }
  }

  function escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function send(to, subject, html) {
    if (!mailReady() || to === "") return;
    try {
      const settings = $app.settings();
      const message = new MailerMessage({
        from: {
          address: String(settings.meta.senderAddress || ""),
          name: String(settings.meta.senderName || ""),
        },
        to: [{ address: to }],
        subject: subject,
        html: html,
      });
      $app.newMailClient().send(message);
      console.log('mail: sent "' + subject + '" to ' + to);
    } catch (error) {
      // See above: the write already landed, and a mail problem is not the
      // caller's problem.
      console.log('mail: could not send "' + subject + '" to ' + to + ": " + error);
    }
  }

  /// The display name of a `(targetType, targetId)` pair, or "" when it is gone.
  function targetName(targetType, targetId) {
    try {
      const collection = targetType === "performer" ? "performers" : "venues";
      return String($app.findRecordById(collection, targetId).get("name") || "");
    } catch (_) {
      return "";
    }
  }

  /// An account's display name, or "". The lookup can miss — accounts live in
  /// another collection and deleting one cascades nothing.
  function userName(userId) {
    try {
      return String($app.findRecordById("users", userId).get("name") || "");
    } catch (_) {
      return "";
    }
  }

  /// The link that goes at the bottom of both messages. The root, because the
  /// router sends a signed-out visitor to sign-in and a signed-in one to the
  /// dashboard — which is where both an invite and a request are answered.
  function appLink() {
    const url = appUrl();
    return url !== "" ? '<p><a href="' + url + '">Abrir o Acorde</a></p>' : "";
  }

  try {
    const status = String(record.get("status") || "");
    const initiatedBy = String(record.get("initiatedBy") || "");
    if (status !== "pending") return;

    const targetType = String(record.get("targetType") || "");
    const targetId = String(record.get("targetId") || "");
    const name = targetName(targetType, targetId);
    // Falls back to the kind rather than to nothing: "a venue" is worth saying,
    // and an empty name would read as a broken message.
    const label = name !== "" ? name : targetType;

    if (initiatedBy === "invite") {
      const pendingEmail = String(record.get("pendingEmail") || "");
      if (pendingEmail === "") return;
      const role = String(record.get("role") || "member");
      // `invitedBy` is written by entities.guard.pb.js from the authenticated
      // caller (see 1790300100). Read from the ROW rather than from the request:
      // this handler runs after the row is committed, where `e.auth` is gone, and
      // the stored value is the one the guard already validated. Empty for a
      // superuser- or script-created invite, which is why the message has a form
      // that names nobody.
      const inviter = userName(String(record.get("invitedBy") || ""));

      send(
        pendingEmail,
        "Convite para " + label + " — Acorde",
        "<p>" +
          (inviter !== ""
            ? escapeHtml(inviter) + " convidou você"
            : "Você foi convidado(a)") +
          " para participar de <strong>" +
          escapeHtml(label) +
          "</strong> como " +
          escapeHtml(role === "manager" ? "administrador(a)" : "membro") +
          ".</p>" +
          "<p>Crie uma conta ou entre com este endereço de e-mail e o convite " +
          "aparecerá no seu painel, onde você pode aceitá-lo ou recusá-lo.</p>" +
          appLink()
      );
      return;
    }

    if (initiatedBy === "request") {
      const requesterId = String(record.get("userId") || "");
      const requester =
        userName(requesterId) || String(record.get("pendingEmail") || "") || "Alguém";

      const filter =
        'targetType = "' +
        targetType.replace(/["\\]/g, "") +
        '" && targetId = "' +
        targetId.replace(/["\\]/g, "") +
        '" && status = "active" && role = "manager"';
      const rows = $app.findRecordsByFilter("memberships", filter, "", 200, 0);

      // De-duplicated by id, minus the requester: a manager asking to join their
      // own entity is refused elsewhere, so this is only a guard against mailing
      // somebody about their own action.
      const seen = {};
      for (const row of rows) {
        const managerId = String(row.get("userId") || "");
        if (managerId === "" || managerId === requesterId || seen[managerId]) {
          continue;
        }
        seen[managerId] = true;

        let email = "";
        try {
          email = String($app.findRecordById("users", managerId).email() || "");
        } catch (_) {
          // A manager whose account vanished has no address to write to.
        }
        if (email === "") continue;

        send(
          email,
          "Pedido de acesso a " + label + " — Acorde",
          "<p><strong>" +
            escapeHtml(requester) +
            "</strong> pediu para participar de <strong>" +
            escapeHtml(label) +
            "</strong>.</p>" +
            "<p>Você pode aprovar ou recusar este pedido no seu painel.</p>" +
            appLink()
        );
      }
    }
  } catch (error) {
    // See `send`: never let this fail the write that triggered it.
    console.log("mail: membership notification failed: " + error);
  }
}, "memberships");
