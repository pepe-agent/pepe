// Optional HTTP Basic Auth gate in front of the static site.
//
// It is active only when the `SITE_PASSWORD` variable is set on the Worker
// (Cloudflare dashboard -> the Worker -> Settings -> Variables and Secrets).
// With it set, every request needs the right user/password; unset, the site is
// open. `SITE_USER` is optional (defaults to "pepe").
//
// This runs before assets because wrangler.jsonc sets assets.run_worker_first.

// Paths that must stay reachable by `curl | sh` even while the site is
// password-gated - a script can't type a Basic Auth password.
const UNGATED_PATHS = new Set(["/install.sh"]);

export default {
  async fetch(request, env) {
    const password = env.SITE_PASSWORD;
    const { pathname } = new URL(request.url);

    if (password && !UNGATED_PATHS.has(pathname)) {
      const expectedUser = env.SITE_USER || "pepe";
      const header = request.headers.get("Authorization") || "";
      const [scheme, encoded] = header.split(" ");

      let ok = false;
      if (scheme === "Basic" && encoded) {
        const decoded = atob(encoded);
        const sep = decoded.indexOf(":");
        const user = decoded.slice(0, sep);
        const pass = decoded.slice(sep + 1);
        ok = user === expectedUser && pass === password;
      }

      if (!ok) {
        return new Response("Authentication required.", {
          status: 401,
          headers: {
            "WWW-Authenticate": 'Basic realm="Pepe", charset="UTF-8"',
            "content-type": "text/plain; charset=utf-8",
          },
        });
      }
    }

    // Authorized (or no password set): serve the built static site.
    return env.ASSETS.fetch(request);
  },
};
