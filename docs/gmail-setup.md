# Optional Google mail and calendar connections

Google setup is optional. Puddle’s conversation, memory, and local reminders
need only the Splash model connection.

The app owner provides one Google OAuth **Desktop app** client. Users click
**Connect Google**, select their account, and approve Gmail and Calendar access
in their browser. Tokens use macOS Keychain. Initial service access is read only;
users can separately grant reviewed sends, organization and calendar writes.

## Create the client

1. Create or select a project in [Google Cloud Console](https://console.cloud.google.com/).
2. Enable [Gmail API](https://console.cloud.google.com/apis/library/gmail.googleapis.com)
   for email, and [Google Calendar API](https://console.cloud.google.com/apis/library/calendar-json.googleapis.com)
   for calendar.
3. Configure Google Auth Platform branding with Puddle as the app name.
4. For personal Gmail, use External audience, Testing status, and add your
   address under Audience → Test users. Workspace organizations can use an
   internal app subject to administrator policy.
5. Declare `openid`, `https://www.googleapis.com/auth/userinfo.email`,
   `https://www.googleapis.com/auth/userinfo.profile`,
   `https://www.googleapis.com/auth/gmail.readonly`, and
   `https://www.googleapis.com/auth/calendar.events.readonly`.
   For optional Actions also declare `https://www.googleapis.com/auth/gmail.send`,
   `https://www.googleapis.com/auth/gmail.modify`,
   `https://www.googleapis.com/auth/calendar.events`, and
   `https://www.googleapis.com/auth/calendar.calendarlist.readonly` for selection
   of secondary calendars. Google verification/admin policy may apply.
6. Under Clients, create a **Desktop app** client and download its JSON. Keep the
   file private. Downloaded `client_secret*.json` files are gitignored.

## Provision the app once

Place the downloaded `client_secret*.json` in the project root and run
`make build`. The build includes that client in the local app, which imports
it into Keychain on first launch. Alternatively, keep the file elsewhere:

    PUDDLE_GOOGLE_CLIENT_FILE=/absolute/path/to/client.json make build

Only Desktop client configuration is included in the app. User account tokens
are never bundled. A later build preserves an already configured client and
connection. If multiple client files exist, select one with the environment
variable above. For an unconfigured build, **Connect Google → App owner setup**
also provides a one-time import.

See Google’s [Desktop OAuth documentation](https://developers.google.com/identity/protocols/oauth2/native-app),
[Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes), and
[Calendar scopes](https://developers.google.com/workspace/calendar/api/auth).

## Connect from Puddle

1. Open **Connections → Connect Google**.
2. Google opens directly in Safari. Choose your Google account. You can switch
   to your system’s default browser under **Settings → Connections → Sign-in browser**.
3. Approve read access for Gmail, Calendar, or both. Puddle connects the services
   you approve and confirms your Google email address, including Calendar-only accounts.
4. A test app can show a Google
   verification warning; check that it belongs to your own Cloud project.
5. Return to Puddle. Ask “What’s on my calendar?” or “Check my unread mail.”

The short-lived callback binds only to 127.0.0.1 at a random port. PKCE and
random state verify sign-in. Offline access allows refresh while the app runs.
Testing-mode tokens can expire after seven days; reconnect if asked.
[Token expiration guidance](https://developers.google.com/identity/protocols/oauth2#expiration).

To change services later, use **Manage Google Permissions**, select the desired
services, and sign in again. Disconnect Google before replacing the client JSON
under **Manage Google Permissions → App owner settings**.

## Troubleshooting

| Problem | Check |
| --- | --- |
| Account denied | Add it to Test users and check Workspace policies |
| Redirect mismatch | Use a Desktop app client, not Web or iOS |
| API disabled / HTTP 403 | Enable the relevant API in the client’s project |
| Read access not granted | Retry with the intended connections selected |
| Expired session | Reconnect; test tokens can expire or be revoked |
| Keychain error | Unlock the login keychain and allow the local build access |
| Callback timeout | Retry and check local loopback firewall rules |

Disconnecting clears local Google tokens and cached mail/calendar data.
Conversation, saved memory, and tasks remain. Revoke the grant itself through
[Google Account connections](https://myaccount.google.com/connections) if desired.
Public distribution requires the appropriate Google verification.

