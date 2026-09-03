(function () {
  "use strict";

  var ARCHES = ["aarch64", "arm", "i686", "x86_64"];

  var REPOS = [
    { key: "packages", name: "termux-main", distribution: "stable", component: "main", label: "termux-main (main)" },
    { key: "root-packages", name: "termux-root", distribution: "root", component: "stable", label: "termux-root (root)" },
    { key: "x11-packages", name: "termux-x11", distribution: "x11", component: "main", label: "termux-x11 (x11)" }
  ];

  var BASE = (function () {
    var p = location.pathname;
    if (p.charAt(p.length - 1) === "/") return p;
    var i = p.lastIndexOf("/");
    return p.slice(0, i + 1);
  })();

  var state = {
    raw: [],
    grouped: {},
    repos: {},
    page: 1,
    perPage: 10,
    searchQuery: "",
    repoFilter: "all"
  };

  var el = {};
  function $(id) { return document.getElementById(id); }

  function setStatus(msg) { el.status.textContent = msg || ""; }
  function showErr(msg) { setStatus(msg); }

  /* ---------- Parsing Debian Packages Stanzas ---------- */
  function parsePackages(text) {
    var entries = [];
    var cur = null;
    var lines = text.split(/\n/);
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (line === "") {
        if (cur) { entries.push(cur); cur = null; }
        continue;
      }
      if (line.charAt(0) === " " && cur) {
        cur[cur.fld] = (cur[cur.fld] || "") + "\n" + line.slice(1).replace(/^\s+/, " ");
        continue;
      }
      var idx = line.indexOf(":");
      if (idx < 0) continue;
      var fld = line.slice(0, idx);
      var val = line.slice(idx + 1).replace(/^\s+/, "");
      if (fld === "Package") {
        if (cur) entries.push(cur);
        cur = { Package: val, Version: "", Architecture: "", Description: "", Filename: "", Depends: "", Size: "" };
        cur.fld = fld; cur[cur.fld] = val;
      } else if (cur) {
        cur.fld = fld;
        cur[fld] = val;
      }
    }
    if (cur) entries.push(cur);
    return entries;
  }

  /* ---------- Akurat Dpkg-Style Version Comparison ---------- */
  function parseDpkgVersion(verStr) {
    var v = String(verStr || "").trim();
    var epoch = 0;
    var colonIdx = v.indexOf(":");
    if (colonIdx !== -1) {
      epoch = parseInt(v.slice(0, colonIdx), 10) || 0;
      v = v.slice(colonIdx + 1);
    }
    var upstream = v;
    var revision = "";
    var hyphenIdx = v.lastIndexOf("-");
    if (hyphenIdx !== -1) {
      upstream = v.slice(0, hyphenIdx);
      revision = v.slice(hyphenIdx + 1);
    }
    return { epoch: epoch, upstream: upstream, revision: revision };
  }

  function compareDpkgParts(a, b) {
    if (a === b) return 0;
    var i = 0, j = 0;
    while (i < a.length || j < b.length) {
      while ((i < a.length && isNaN(parseInt(a.charAt(i), 10))) || (j < b.length && isNaN(parseInt(b.charAt(j), 10)))) {
        var ca = i < a.length ? a.charCodeAt(i) : 0;
        var cb = j < b.length ? b.charCodeAt(j) : 0;
        if (ca === 126) ca = -1;
        if (cb === 126) cb = -1;
        if (ca !== cb) return ca > cb ? 1 : -1;
        i++; j++;
      }
      var numA = 0, hasNumA = false;
      while (i < a.length && !isNaN(parseInt(a.charAt(i), 10))) {
        numA = numA * 10 + parseInt(a.charAt(i), 10);
        i++; hasNumA = true;
      }
      var numB = 0, hasNumB = false;
      while (j < b.length && !isNaN(parseInt(b.charAt(j), 10))) {
        numB = numB * 10 + parseInt(b.charAt(j), 10);
        j++; hasNumB = true;
      }
      if (hasNumA || hasNumB) {
        if (numA !== numB) return numA > numB ? 1 : -1;
      }
    }
    return 0;
  }

  function compareVersions(verA, verB) {
    var vA = parseDpkgVersion(verA);
    var vB = parseDpkgVersion(verB);
    if (vA.epoch !== vB.epoch) return vA.epoch > vB.epoch ? 1 : -1;
    var compUp = compareDpkgParts(vA.upstream, vB.upstream);
    if (compUp !== 0) return compUp;
    return compareDpkgParts(vA.revision, vB.revision);
  }

  /* ---------- Helper Formatter Ukuran File ---------- */
  function formatBytes(bytes) {
    if (!bytes || isNaN(bytes)) return "";
    var b = parseInt(bytes, 10);
    if (b < 1024) return b + " B";
    if (b < 1048576) return (b / 1024).toFixed(1) + " KB";
    return (b / 1048576).toFixed(1) + " MB";
  }

  /* ---------- Perfect Deep Linking & URL State Sync ---------- */
  function readUrlParams() {
    var params = new URLSearchParams(window.location.search);
    state.searchQuery = params.get("q") || "";
    state.repoFilter = params.get("repo") || "all";
    state.page = parseInt(params.get("page"), 10) || 1;
    state.perPage = parseInt(params.get("perPage"), 10) || 10;
  }

  function updateUrlParams(pushHistory) {
    var params = new URLSearchParams();
    if (state.searchQuery) params.set("q", state.searchQuery);
    if (state.repoFilter !== "all") params.set("repo", state.repoFilter);
    if (state.page > 1) params.set("page", state.page);
    if (state.perPage !== 10) params.set("perPage", state.perPage);

    var queryString = params.toString();
    var newUrl = window.location.pathname + (queryString ? "?" + queryString : "") + window.location.hash;

    if (pushHistory) {
      window.history.pushState(null, "", newUrl);
    } else {
      window.history.replaceState(null, "", newUrl);
    }
  }

  /* ---------- Smooth Scroll Ke Kontainer Paket ---------- */
  function scrollToPackages() {
    var target = $("packages");
    if (target) {
      var top = target.getBoundingClientRect().top + window.pageYOffset - 70;
      window.scrollTo({ top: top, behavior: "smooth" });
    }
  }

  /* ---------- Fetch Repos & Arches ---------- */
  function groupRepos() {
    REPOS.forEach(function (r) {
      state.repos[r.name] = { distribution: r.distribution, component: r.component, label: r.label, key: r.key };
    });
  }

  function collect(pkgs) {
    pkgs.forEach(function (p) {
      var rec = {
        name: p.Package,
        version: p.Version,
        arch: p.Architecture,
        desc: p.Description || "",
        repo: p._repo,
        depends: p.Depends || "",
        filename: p.Filename || "",
        size: p.Size || ""
      };
      state.raw.push(rec);
    });
  }

  function loadAll() {
    setStatus("Loading package data&hellip;");
    var jobs = [];
    REPOS.forEach(function (r) {
      var arches = ARCHES.concat(["all"]);
      arches.forEach(function (arch) {
        var url = BASE + "apt/" + r.name + "/dists/" + r.distribution + "/" + r.component + "/binary-" + arch + "/Packages";
        jobs.push(
          fetch(url)
            .then(function (res) {
              if (!res.ok) return [];
              return res.text();
            })
            .then(function (text) {
              var entries = parsePackages(text);
              entries.forEach(function (e) { e._repo = r.name; });
              return entries;
            })
            .catch(function () { return []; })
        );
      });
    });
    return Promise.all(jobs).then(function (results) {
      results.forEach(function (entries) { collect(entries); });
      buildGrouped();
      hydrate();
    });
  }

  /* ---------- Agregasi Paket ---------- */
  function buildGrouped() {
    var g = {};
    state.raw.forEach(function (rec) {
      var key = rec.name;
      if (!g[key]) g[key] = { name: rec.name, desc: "", repo: rec.repo, versions: {} };
      var grp = g[key];
      grp.desc = grp.desc || rec.desc;
      if (!grp.versions[rec.version]) {
        grp.versions[rec.version] = { archFiles: {}, archs: {}, isAll: false, depends: rec.depends, size: rec.size };
      }
      var v = grp.versions[rec.version];
      v.archFiles[rec.arch] = rec.filename;
      v.size = v.size || rec.size;
      v.depends = v.depends || rec.depends;

      if (rec.arch === "all") {
        v.isAll = true;
        ARCHES.forEach(function (a) { v.archs[a] = a; });
      } else if (ARCHES.indexOf(rec.arch) !== -1) {
        v.archs[rec.arch] = rec.arch;
      }
    });
    state.grouped = g;
  }

  /* ---------- Query Filter ---------- */
  function filteredGroups() {
    var q = (state.searchQuery || "").trim().toLowerCase();
    var repoFilter = state.repoFilter;
    var out = [];
    Object.keys(state.grouped).forEach(function (name) {
      var grp = state.grouped[name];
      if (repoFilter !== "all" && grp.repo !== repoFilter) return;
      if (q) {
        var hay = (name + " " + grp.desc).toLowerCase();
        if (hay.indexOf(q) === -1) return;
      }
      out.push(grp);
    });
    out.sort(function (a, b) { return a.name.localeCompare(b.name); });
    return out;
  }

  function latestOf(grp) {
    var versions = Object.keys(grp.versions);
    versions.sort(compareVersions);
    return versions[versions.length - 1];
  }

  function repoBase(name) { return BASE + "apt/" + name; }

  /* ---------- Render Paginasi ---------- */
  function renderPagination(totalItems) {
    var totalPages = Math.ceil(totalItems / state.perPage) || 1;
    if (state.page > totalPages) state.page = totalPages;

    el.pagination.innerHTML = "";
    if (totalItems <= state.perPage) return;

    var prevBtn = document.createElement("button");
    prevBtn.className = "page-btn";
    prevBtn.textContent = "← Prev";
    prevBtn.disabled = state.page === 1;
    prevBtn.addEventListener("click", function () {
      if (state.page > 1) {
        state.page--;
        updateUrlParams(true);
        renderList(true);
      }
    });

    var info = document.createElement("span");
    info.className = "page-info";
    info.textContent = "Page " + state.page + " of " + totalPages;

    var nextBtn = document.createElement("button");
    nextBtn.className = "page-btn";
    nextBtn.textContent = "Next →";
    nextBtn.disabled = state.page === totalPages;
    nextBtn.addEventListener("click", function () {
      if (state.page < totalPages) {
        state.page++;
        updateUrlParams(true);
        renderList(true);
      }
    });

    el.pagination.appendChild(prevBtn);
    el.pagination.appendChild(info);
    el.pagination.appendChild(nextBtn);
  }

  /* ---------- Render Daftar Paket ---------- */
  function renderList(shouldScroll) {
    var allGroups = filteredGroups();
    var totalItems = allGroups.length;

    var start = (state.page - 1) * state.perPage;
    var end = start + state.perPage;
    var pageGroups = allGroups.slice(start, end);

    el.list.innerHTML = "";
    el.empty.hidden = totalItems > 0;

    // Trigger animasi Fade In halus
    el.list.classList.remove("fade-in");
    void el.list.offsetWidth; // Reflow
    el.list.classList.add("fade-in");

    pageGroups.forEach(function (grp) {
      var li = document.createElement("li");
      li.className = "pkg";

      var latestVer = latestOf(grp);
      var vObj = grp.versions[latestVer];

      // 1. Header & Meta Paket
      var header = document.createElement("div");
      header.className = "pkg-header";

      var topRow = document.createElement("div");
      topRow.className = "pkg-top-row";

      var nameEl = document.createElement("span");
      nameEl.className = "pkg-name";
      nameEl.textContent = grp.name;

      var repoEl = document.createElement("span");
      repoEl.className = "pkg-repo";
      repoEl.textContent = state.repos[grp.repo].label;

      topRow.appendChild(nameEl);
      topRow.appendChild(repoEl);

      var metaRow = document.createElement("div");
      metaRow.className = "pkg-meta-row";

      var verEl = document.createElement("span");
      verEl.className = "pkg-version";
      verEl.textContent = latestVer;
      metaRow.appendChild(verEl);

      if (vObj.size) {
        var sizeEl = document.createElement("span");
        sizeEl.className = "pkg-size-badge";
        sizeEl.textContent = formatBytes(vObj.size);
        metaRow.appendChild(sizeEl);
      }

      header.appendChild(topRow);
      header.appendChild(metaRow);

      // 2. Deskripsi
      var desc = document.createElement("p");
      desc.className = "pkg-desc";
      desc.textContent = (grp.desc || "").split("\n")[0] || "Tidak ada deskripsi.";

      // 3. Dependensi
      var depsWrap = null;
      if (vObj.depends) {
        depsWrap = document.createElement("div");
        depsWrap.className = "pkg-deps";
        var label = document.createElement("span");
        label.className = "pkg-deps-label";
        label.textContent = "Depends: ";
        depsWrap.appendChild(label);
        depsWrap.appendChild(document.createTextNode(vObj.depends));
      }

      // 4. Aksi Kartu
      var actions = document.createElement("div");
      actions.className = "pkg-actions";

      var cmdRow = document.createElement("div");
      cmdRow.className = "pkg-cmd-row";
      var cmdCode = document.createElement("code");
      cmdCode.textContent = "apt install " + grp.name;
      var copyBtn = document.createElement("button");
      copyBtn.className = "copy-btn";
      copyBtn.textContent = "Copy";
      copyBtn.addEventListener("click", function () {
        copyText("apt install " + grp.name);
        copyBtn.textContent = "Copied!";
        setTimeout(function () { copyBtn.textContent = "Copy"; }, 1200);
      });
      cmdRow.appendChild(cmdCode);
      cmdRow.appendChild(copyBtn);

      var dlGroup = document.createElement("div");
      dlGroup.className = "pkg-dl-group";
      var dlLabel = document.createElement("span");
      dlLabel.className = "pkg-dl-label";
      dlLabel.textContent = "Download (.deb):";

      var dlBtns = document.createElement("div");
      dlBtns.className = "pkg-dl-btns";

      var availArches = Object.keys(vObj.archFiles);

      if (availArches.length === 0) {
        var noDl = document.createElement("span");
        noDl.style.fontSize = "11px";
        noDl.style.color = "var(--text-mute)";
        noDl.textContent = "N/A";
        dlBtns.appendChild(noDl);
      } else {
        availArches.forEach(function (arch) {
          var btn = document.createElement("button");
          btn.className = "dl-btn";
          btn.textContent = arch;
          btn.title = "Download .deb untuk " + arch;
          btn.addEventListener("click", function () {
            var fileName = vObj.archFiles[arch];
            if (!fileName) return;
            var href = repoBase(grp.repo) + "/" + fileName;
            var a = document.createElement("a");
            a.href = href;
            a.download = fileName.split("/").pop();
            a.rel = "noopener";
            document.body.appendChild(a);
            a.click();
            a.remove();
          });
          dlBtns.appendChild(btn);
        });
      }

      dlGroup.appendChild(dlLabel);
      dlGroup.appendChild(dlBtns);

      actions.appendChild(cmdRow);
      actions.appendChild(dlGroup);

      li.appendChild(header);
      li.appendChild(desc);
      if (depsWrap) li.appendChild(depsWrap);
      li.appendChild(actions);

      el.list.appendChild(li);
    });

    renderPagination(totalItems);

    if (shouldScroll) {
      scrollToPackages();
    }
  }

  /* ---------- Setup Guide Sources ---------- */
  function buildSources() {
    var lines = REPOS.map(function (r) {
      return "deb [signed-by=$PREFIX/etc/apt/keyrings/apexstudio-packages.asc] https://apex-studio-dev.github.io/termux-packages/apt/" + r.name + " " + r.distribution + " " + r.component;
    });
    var pre = el.codeSources;
    pre.textContent = lines.join("\n");
    pre.classList.add("pre-wrap");
  }

  function copyText(text) {
    function fallback() {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed"; ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy"); } catch (e) {}
      document.body.removeChild(ta);
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).catch(fallback);
    } else {
      fallback();
    }
  }

  /* ---------- Theme Toggle ---------- */
  function initTheme() {
    var savedTheme = localStorage.getItem("theme");
    if (savedTheme) {
      document.documentElement.setAttribute("data-theme", savedTheme);
      updateThemeIcon(savedTheme);
    } else {
      var isDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
      updateThemeIcon(isDark ? "dark" : "light");
    }

    el.themeToggle.addEventListener("click", function () {
      var current = document.documentElement.getAttribute("data-theme");
      if (!current) {
        current = window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
      }
      var nextTheme = current === "dark" ? "light" : "dark";
      document.documentElement.setAttribute("data-theme", nextTheme);
      localStorage.setItem("theme", nextTheme);
      updateThemeIcon(nextTheme);
    });
  }

  function updateThemeIcon(theme) {
    el.themeToggle.textContent = theme === "dark" ? "🌙" : "☀️";
  }

  /* ---------- Sync UI & Hydrate ---------- */
  function syncUiWithState() {
    el.search.value = state.searchQuery;
    el.repoFilter.value = state.repoFilter;
    el.perPageFilter.value = String(state.perPage);
  }

  function hydrate() {
    var nRepos = REPOS.length;
    var names = Object.keys(state.grouped).length;
    el.statPkgs.textContent = names;
    el.statRepos.textContent = nRepos;
    el.statArchs.textContent = ARCHES.length;
    
    syncUiWithState();
    renderList(false);
    setStatus(names + " packages indexed across " + nRepos + " repositories.");
    buildSources();
  }

  /* ---------- Init ---------- */
  function init() {
    el = {
      search: $("search"),
      repoFilter: $("repo-filter"),
      perPageFilter: $("per-page-filter"),
      themeToggle: $("theme-toggle"),
      status: $("status"), list: $("pkg-list"), empty: $("empty"),
      pagination: $("pagination"),
      statPkgs: $("stat-pkgs"), statRepos: $("stat-repos"), statArchs: $("stat-archs"),
      codeSources: $("code-sources")
    };

    initTheme();
    readUrlParams();
    groupRepos();

    var sel = el.repoFilter;
    var optAll = document.createElement("option");
    optAll.value = "all"; optAll.textContent = "All repositories";
    sel.appendChild(optAll);
    REPOS.forEach(function (r) {
      var o = document.createElement("option");
      o.value = r.name; o.textContent = r.label;
      sel.appendChild(o);
    });

    window.addEventListener("popstate", function () {
      readUrlParams();
      syncUiWithState();
      renderList(false);
    });

    var debounce;
    el.search.addEventListener("input", function () {
      clearTimeout(debounce);
      debounce = setTimeout(function () {
        state.searchQuery = el.search.value;
        state.page = 1;
        updateUrlParams(false);
        renderList(false);
      }, 120);
    });

    el.repoFilter.addEventListener("change", function () {
      state.repoFilter = el.repoFilter.value;
      state.page = 1;
      updateUrlParams(true);
      renderList(false);
    });

    el.perPageFilter.addEventListener("change", function () {
      state.perPage = parseInt(el.perPageFilter.value, 10) || 10;
      state.page = 1;
      updateUrlParams(true);
      renderList(false);
    });

    Array.prototype.forEach.call(document.querySelectorAll("[data-copy-target]"), function (btn) {
      var targetId = btn.getAttribute("data-copy-target");
      var pre = document.getElementById(targetId);
      btn.addEventListener("click", function () {
        copyText(pre.textContent);
        var old = btn.textContent;
        btn.textContent = "Copied!";
        setTimeout(function () { btn.textContent = old; }, 1200);
      });
    });

    loadAll().catch(function (err) { showErr("Failed to load package data: " + err.message); });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
