# HTTP requests

`http` fetches a URL or calls an API without going through `curl`, returning the
status line, the response headers, and the body:

```
❯ fetch https://httpbin.org/json and tell me the content type
  ⚙ http {"url":"https://httpbin.org/json"}
  ✓
    HTTP/1.1 200 OK
    Date: Mon, 28 Sep 2026 06:21:24 GMT
    Content-Type: application/json
    Content-Length: 429
    ...

    {"slideshow": {"title": "Sample Slide Show", ...}}
```

| Argument  | Required | Description                                                          |
|-----------|----------|----------------------------------------------------------------------|
| `url`     | yes      | The full URL, including the scheme                                    |
| `method`  | no       | `GET` (the default), `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS` |
| `headers` | no       | Request headers as name/value pairs                                   |
| `body`    | no       | Request body, for a method that takes one                             |
| `save_to` | no       | Write the body to this file instead of returning it                   |

No `Content-Type` is invented for you: set it in `headers` when you send a JSON
body.

## Four behaviours worth knowing

- **Downloads.** `save_to` streams the body straight into the file, so a large
  or binary response is written intact rather than mangled by the text path —
  the response text replaces the body with `Saved N bytes to 'path'`.
- **Redirects.** A request that sends no body follows up to five of them.
  `POST`, `PUT`, and `PATCH` cannot be replayed once their body is on the wire,
  so a redirect to one of those comes back as-is for the agent to follow.
- **Failures.** A connection, TLS, or URL failure is a tool error. An HTTP
  status never is — a `404` is an answer, and the status line says so.
- **Limits.** The response text is capped at 32 KB, and `std.http` offers no
  timeout setting, so a server that accepts a connection and then never answers
  hangs the request the way `curl` without `--max-time` does.

Requests inherit the host's network access and proxy settings; there is no
sandbox, see [Security and state](security.md).
