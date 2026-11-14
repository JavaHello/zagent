# Web search and fetching

Two tools read the web: `web_search` finds pages, and `web_fetch` reads one.
Neither goes through `curl`, and neither has to: a page is fetched, and the
markup around its words is dropped before the words reach the model.

Both tools ask for a URL with `GET` and nothing else, which is reading. A
request that needs a method, headers or a body — an API call — is
[`bash`](tools.md#bash) with `curl`, or the API's own client.

```
❯ what do the Zig 0.14 release notes say about the build system?
  ⚙ web_search zig 0.14 release notes build system · limit 5
  ✓
    1. Zig 0.14.0 Release Notes
       https://ziglang.org/download/0.14.0/release-notes.html
       Declarations, build system, ...
  ⚙ web_fetch https://ziglang.org/download/0.14.0/release-notes.html
  ✓
    # Zig 0.14.0 Release Notes
    ...
```

## `web_search`

| Argument | Required | Description                                        |
|----------|----------|----------------------------------------------------|
| `query`  | yes      | What to search for                                 |
| `limit`  | no       | How many results to return, 1–20; the default is 8 |

The answer is a numbered list: each result names its title, its address and the
snippet that says what it is about. A search that finds nothing says so; a
service that refuses is an error result naming the status.

**Where the results come from is configuration.**

- With `WEB_SEARCH_URL` set, the query is put to that endpoint. The URL is a
  template: `{query}` is replaced by the percent-encoded query and `{limit}` by
  the number asked for, and when the template names no `{query}`, the query is
  added to its query string as `q=`.
- `WEB_SEARCH_KEY`, when set, travels as `Authorization: Bearer <key>`.
- The answer is read for its results whatever the service calls them: JSON is
  searched for the first array of objects that name an address (`url`, `link`
  or `href`, with `title`/`name` and `content`/`description`/`snippet` beside
  it), an HTML results page is parsed the way DuckDuckGo's own is, and a
  service that answers with plain text has that text handed over as it was
  written.

```ini
# A SearXNG instance that answers JSON needs no key.
WEB_SEARCH_URL=https://searx.example.com/search?q={query}&format=json
# A service that takes one gets it as a bearer token.
WEB_SEARCH_KEY=your-service-key
```

With nothing configured the query goes to DuckDuckGo's own results page, which
takes no key — that is what makes it the fallback. It is asked for with a text
browser's user agent, because DuckDuckGo answers a browser with a page that
needs JavaScript to show a result and a text browser with the results
themselves. An answer that holds no results — a challenge page, most often —
is reported as an error saying so, and naming the settings that would send the
query to a service instead.

## `web_fetch`

| Argument | Required | Description                        |
|----------|----------|------------------------------------|
| `url`    | yes      | The full URL, including the scheme |

An HTML page comes back as the markdown a reader would have copied out of it:

- the document's `<title>` names the page in a `# ` line above its text;
- headings become `#`, `##` and so on, paragraphs keep their blank line, list
  items keep their dash;
- a link is written as `[its words](its address)`, with a relative address
  resolved against the page it was found on;
- `<pre>` becomes a fenced code block, and inline `<code>` is backticked;
- scripts, styles, the document head and the tags themselves are dropped, and
  entities (`&amp;`, `&nbsp;`, `&#8212;`) are decoded.

A response that is text but not HTML — JSON, XML, plain text, markdown — is
handed over as it was written. A body that is not text at all is refused: this
tool reads pages, and a download is [`bash`](tools.md#bash) with `curl`.

**A fetch service can be configured.** With `WEB_FETCH_URL` set, the page is
asked for through that service instead, and the service's answer is what comes
back, unchanged — a reader service already returns the text it was asked for.
`{url}` in the template is replaced by the page's address, and a template with
no `{url}` has the address appended to its path. `WEB_FETCH_KEY`, when set,
travels as `Authorization: Bearer <key>`.

```ini
# A reader service that turns a page into markdown for you.
WEB_FETCH_URL=https://r.jina.ai/
WEB_FETCH_KEY=your-service-key
```

## Five behaviours worth knowing

- **Failures.** A connection, TLS, URL or deadline failure is a tool error. An
  HTTP status is an answer: `web_fetch` reports it as an error result whose text
  is the status line and the page it came with, so the model can see what the
  server said.
- **Redirects.** A request follows up to five of them. A request that carries a
  credential does not follow any: the credential would be handed to whatever
  host the redirect names, so the status is reported instead.
- **Deadlines.** A request is given 180 seconds in all; a server that takes the
  request and says nothing is stopped rather than holding the session.
- **Limits.** 8 MiB of a response body is read, and at most 256 KiB of a page
  becomes text; a longer page says where it stopped. A result larger than 8 KiB
  is cached by the same cache every tool's long output goes through, see
  [Tools](tools.md#output-limit).
- **No sandbox.** Requests inherit the host's network access and proxy
  settings, see [Security and state](security.md).
