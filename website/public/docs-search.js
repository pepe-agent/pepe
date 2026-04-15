(() => {
  const normalize = (value) =>
    value
      .normalize("NFD")
      .replace(/\p{Diacritic}/gu, "")
      .toLowerCase();

  const excerpt = (text, tokens) => {
    const haystack = normalize(text);
    const firstIndex = tokens.reduce((best, token) => {
      const index = haystack.indexOf(token);
      return index === -1 ? best : Math.min(best, index);
    }, Number.POSITIVE_INFINITY);

    if (!Number.isFinite(firstIndex)) return text.slice(0, 150);

    const start = Math.max(0, firstIndex - 55);
    const end = Math.min(text.length, firstIndex + 155);
    return `${start > 0 ? "..." : ""}${text.slice(start, end)}${end < text.length ? "..." : ""}`;
  };

  const wordsOf = (value) => normalize(value).match(/[a-z0-9]+/g) || [];

  const editDistanceAtMost = (left, right, limit) => {
    if (Math.abs(left.length - right.length) > limit) return false;

    let previous = Array.from({ length: right.length + 1 }, (_, index) => index);

    for (let i = 1; i <= left.length; i += 1) {
      const current = [i];
      let rowBest = current[0];

      for (let j = 1; j <= right.length; j += 1) {
        const cost = left[i - 1] === right[j - 1] ? 0 : 1;
        const value = Math.min(
          previous[j] + 1,
          current[j - 1] + 1,
          previous[j - 1] + cost,
        );

        current[j] = value;
        rowBest = Math.min(rowBest, value);
      }

      if (rowBest > limit) return false;
      previous = current;
    }

    return previous[right.length] <= limit;
  };

  const fuzzyIncludes = (value, token) => {
    if (value.includes(token)) return true;
    if (token.length < 4) return false;

    const limit = token.length >= 9 ? 2 : 1;
    return wordsOf(value).some((word) => {
      if (word.length < 4) return false;
      if (word.includes(token) || token.includes(word)) return true;
      const prefix = word.slice(0, Math.min(word.length, token.length + limit));
      if (editDistanceAtMost(prefix, token, limit)) return true;
      return editDistanceAtMost(word, token, limit);
    });
  };

  const tokenScore = (value, token, exactScore, fuzzyScore) => {
    if (value.includes(token)) return exactScore;
    return fuzzyIncludes(value, token) ? fuzzyScore : 0;
  };

  const scoreItem = (item, tokens) => {
    const title = normalize(item.title);
    const description = normalize(item.description);
    const text = normalize(item.text);

    if (!tokens.every((token) => fuzzyIncludes(title, token) || fuzzyIncludes(description, token) || fuzzyIncludes(text, token))) {
      return 0;
    }

    return tokens.reduce((score, token) => {
      return (
        score +
        tokenScore(title, token, 8, 5) +
        tokenScore(description, token, 4, 2) +
        tokenScore(text, token, 1, 0.5)
      );
    }, 0);
  };

  const updateActiveResult = (results, activeIndex) => {
    const links = Array.from(results.querySelectorAll("a"));

    links.forEach((link, index) => {
      const active = index === activeIndex;
      link.setAttribute("aria-selected", active ? "true" : "false");
      if (active) link.scrollIntoView({ block: "nearest" });
    });
  };

  const renderResults = (root, results, matches, tokens) => {
    results.replaceChildren();
    root.dataset.activeIndex = "-1";

    if (matches.length === 0) {
      const empty = document.createElement("div");
      empty.className = "doc-search-empty";
      empty.textContent = root.dataset.emptyLabel || "No results";
      results.append(empty);
      results.hidden = false;
      return;
    }

    for (const item of matches.slice(0, 8)) {
      const link = document.createElement("a");
      link.href = item.href;
      link.setAttribute("role", "option");
      link.setAttribute("aria-selected", "false");

      const title = document.createElement("strong");
      title.textContent = item.title;

      const snippet = document.createElement("span");
      snippet.textContent = excerpt(item.text, tokens);

      link.append(title, snippet);
      results.append(link);
    }

    results.hidden = false;
  };

  const initSearch = (root) => {
    const input = root.querySelector("[data-doc-search-input]");
    const results = root.querySelector("[data-doc-search-results]");
    if (!input || !results) return;

    let indexPromise;

    const loadIndex = () => {
      indexPromise ||= fetch(root.dataset.indexUrl)
        .then((response) => {
          if (!response.ok) throw new Error(`Search index failed: ${response.status}`);
          return response.json();
        })
        .then((payload) => payload.items || []);

      return indexPromise;
    };

    input.addEventListener("input", async () => {
      const query = input.value.trim();

      if (query.length < 2) {
        results.hidden = true;
        results.replaceChildren();
        return;
      }

      results.hidden = false;
      results.textContent = root.dataset.loadingLabel || "Searching...";

      try {
        const tokens = normalize(query).split(/\s+/).filter(Boolean);
        const items = await loadIndex();
        const matches = items
          .map((item) => ({ ...item, score: scoreItem(item, tokens) }))
          .filter((item) => item.score > 0)
          .sort((a, b) => b.score - a.score || a.title.localeCompare(b.title));

        renderResults(root, results, matches, tokens);
      } catch {
        results.textContent = root.dataset.errorLabel || "Search unavailable";
      }
    });

    input.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        input.value = "";
        results.hidden = true;
        results.replaceChildren();
        root.dataset.activeIndex = "-1";
        return;
      }

      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        const links = Array.from(results.querySelectorAll("a"));
        if (results.hidden || links.length === 0) return;

        event.preventDefault();
        const direction = event.key === "ArrowDown" ? 1 : -1;
        const current = Number.parseInt(root.dataset.activeIndex || "-1", 10);
        const next = (current + direction + links.length) % links.length;

        root.dataset.activeIndex = String(next);
        updateActiveResult(results, next);
        return;
      }

      if (event.key === "Enter") {
        const links = Array.from(results.querySelectorAll("a"));
        const activeIndex = Number.parseInt(root.dataset.activeIndex || "-1", 10);
        const selected = links[activeIndex] || links[0];

        if (selected) {
          event.preventDefault();
          selected.click();
        }
      }
    });

    document.addEventListener("click", (event) => {
      if (!root.contains(event.target)) results.hidden = true;
    });
  };

  document.querySelectorAll("[data-doc-search]").forEach(initSearch);
})();
