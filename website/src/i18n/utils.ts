import { locales, defaultLocale, type Locale } from "./ui";

const codes = locales as readonly string[];

export function localeFromPath(pathname: string): Locale {
  const seg = pathname.split("/")[1];
  return codes.includes(seg) ? (seg as Locale) : defaultLocale;
}

/** Same page path but under a different locale. */
export function swapLocale(pathname: string, to: Locale): string {
  const parts = pathname.split("/");
  if (codes.includes(parts[1])) parts[1] = to;
  else parts.splice(1, 0, to);
  const out = parts.join("/");
  return out.endsWith("/") || out.includes(".") ? out : out + "/";
}

/** Build a locale-prefixed path, e.g. withLocale("pt-br", "/docs/") -> "/pt-br/docs/". */
export function withLocale(lang: Locale, path = "/"): string {
  const p = path.startsWith("/") ? path : "/" + path;
  return "/" + lang + p;
}
