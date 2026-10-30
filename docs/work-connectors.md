# GitHub, Jira and Confluence

Puddle can search and read GitHub.com, Jira Cloud and Confluence Cloud from
**Developer** or **Connections**, and use those sources in local conversations.
Connections belong to your shared personal workspace and remain available when
you switch profiles. A local project folder is optional and grants no cloud access.

## Connect GitHub

1. Open **Connections → Connect GitHub**. Follow the link to create a
   **fine-grained personal access token** on GitHub.com.
2. Choose the resource owner and specific repositories. Allow **Issues: Read**
   and **Pull requests: Read**. Add **Checks: Read** if you want reported CI
   check runs. Metadata read access is included by GitHub. Choose an expiration
   appropriate for your account; organization approval may be required.
3. Paste the token into the secure token field, then paste repository URLs such
   as `https://github.com/owner/repository` or enter `owner/repository` names.
   Separate entries with new lines or commas, up to ten different repositories.
   HTTPS `.git` clone URLs and trailing slashes are accepted. The form previews
   the normalized repository names; duplicate entries count once. Choose
   **Save & Test GitHub**.
4. Puddle verifies the account, repository metadata and issue/PR list access
   before saving. CI checks can still fail if the optional Checks permission is
   absent. **Test** rechecks account and repository access; **Manage GitHub** replaces
   the token/repository selection only after successful verification and storage.

Validation messages identify a missing/invalid token, an invalid repository
entry, or more than ten repositories separately. Use repository root URLs;
issue, PR, branch and file URLs are not accepted as repository selections.
URL query parameters and fragments are removed during normalization. The
connector always makes authenticated requests to `api.github.com`, not a
pasted URL. Invalid input is rejected before network access; error text does
not repeat token values or pasted URL contents.

Tokens go in the connection form, never chat. See GitHub's
[token creation guide](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
and [fine-grained permission reference](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens).
The connector pins the supported `2022-11-28` REST contract; GitHub currently
[supports it through March 10, 2028](https://docs.github.com/en/rest/about-the-rest-api/api-versions).

## Connect Jira and Confluence

1. Open **Connections → Connect Jira / Confluence**.
2. Choose Jira, Confluence, or both, then **Sign in with Atlassian**.
3. Complete account/site selection and consent in the browser. Return to
   Puddle while it verifies available sites and the requested read/search tools.
4. If more than one site is available, choose an **Atlassian site** in
   Connections before searching. All Jira/Confluence reads use that site.
5. Use **Manage Atlassian Access** to change the selected products, **Test** to
   verify access again, or **Disconnect Atlassian** to remove both products'
   local credentials.

This uses Atlassian's official Rovo MCP v2 service and its public-client OAuth
flow, with dynamic registration, PKCE, state validation and a temporary
`127.0.0.1` callback. End users do not register a developer app or supply an
Atlassian API token. An organization's administrator may restrict consent or
tool access. The sign-in expires after five minutes and can be cancelled.
See [Atlassian's OAuth setup](https://developer.atlassian.com/cloud/rovo-mcp/guides/configuring-oauth-2-1/)
and [authentication guide](https://developer.atlassian.com/cloud/rovo-mcp/guides/authentication-and-authorization/).

Requested permissions are `read:me`, `offline_access`, and the selected
products' `read:*:agent-interface` / `search:*:agent-interface` scopes. Puddle
does not request write/delete/manage scopes. A fixed read-tool allowlist is
enforced in code, independently of the remote catalog or model output. Unknown
tools and generic write/execute pathways cannot be called.

## Use connected work

- Search a phrase across all ready sources or choose one source. Search works
  without a running model. Results show scope, fetch time, source links and
  incomplete-result indicators; a provider failure leaves other results usable.
- **Open work & recent docs** searches open work in configured GitHub
  repositories, unresolved Jira work assigned to the signed-in user, and recent
  Confluence pages. GitHub results are not necessarily assigned to you.
- Open a result to read details, then choose **Ask Puddle about this** for a
  local conversation. GitHub PRs also offer patch excerpts and reported checks.
- **Ask for my work brief** searches connected sources through the local
  model. Other examples: “Find requirements for retry handling”, “Read DEV-42
  and find relevant documentation”, or “Review the patch for acme/app#7”.
- The assistant exposes two bounded tools: `search_connected_work` and
  `read_connected_work_item`. Jira-only searches may use JQL and Confluence-only
  searches may use CQL when the assistant selects native syntax. The visual
  search box uses text search; GitHub phrases remain literal and repository-scoped.

## Limits, storage and recovery

GitHub search and the visual source lists return at most ten items per source;
assistant search summaries include at most three per source to preserve local
model context. Refine a search or read an exact locator for detail. GitHub reads
include the description and five earliest issue comments, up to twenty changed
files with patch excerpts, or twenty head-commit check runs. PR review comments,
legacy commit statuses, attachments and omitted binary/large patches are not a
complete review. A reported passing check does not mean Puddle executed a test.

Jira/Confluence use bounded server reads; comments, attachments, embeds and later
pages may be absent. Unknown search formats remain visible as incomplete text
instead of being presented as an empty result. Details are bounded to 12,000
characters; the model may further shorten tool content for its context window.
Requests use fixed trusted HTTPS hosts, reject redirects and cap response bodies
at 2 MB with the built-in transport. MCP supports JSON and SSE responses,
coalesced initialization, session renewal after an expired-session 404, and
rotating refresh tokens. Rate limits and access errors are shown for retry or
reconnection; writes and OAuth exchanges are not blindly retried.

Credentials, account metadata, repository selection and Atlassian site selection
stay in macOS Keychain and are excluded from workspace backups. Search/detail
results stay in memory unless used in chat. Retrieved text and source receipts
may remain in saved conversations and exported backups. Disconnecting clears
credentials and current connector results; it does not erase past chats or revoke
the provider's grant. Revoke tokens/access on the provider as needed.

Inference stays on the configured loopback model, but connector authentication,
queries and reads go to GitHub or Atlassian. Puddle does not upload local project
files to these connectors, index entire accounts, sync in the background, create
issues, edit pages, comment, merge PRs or trigger CI. Demo mode does not use real
work accounts. GitHub Enterprise and Atlassian Data Center are not supported.

Fixture tests cover authentication, read boundaries, refresh/session recovery,
partial failures, receipts and secret exclusion. Real-account consent, company
approval and the provider's live response shapes still need an interactive
acceptance pass before a production release claim. Atlassian's
[supported tool catalog](https://developer.atlassian.com/cloud/rovo-mcp/guides/supported-tools/)
is the compatibility reference.
