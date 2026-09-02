(function () {
  "use strict";

  var ARCHES = ["aarch64", "arm", "i686", "x86_64"];

  // Repository layout mirrors repo.json (kept in sync with the publish step).
  var REPOS = [
    { key: "packages", name: "termux-main", distribution: "stable", component: "main", label: "termux-main (main)" },
    { key: "root-packages", name: "termux-root", distribution: "root", component: "stable", label: "termux-root (root)" },
    { key: "x11-packages", name: "termux-x11", distribution: "x11", component: "main", label: "termux-x11 (x11)" }
  ];

  // Absolute base of the gh-pages site (always ends with '/').
  var BASE = (function () {
    var p = location.pathname;
    if (p.charAt(p.length - 1) === "/") return p;
    var i = p.lastIndexOf("/");
    return p.slice(0, i + 1);
  })();

  var state = {
    raw: [],           // [{name, version, arch, ...}]
    grouped: {},       // name -> {name, desc, repo, versions: {ver: {archInfo, file: {arch->filename}}}}
    repos: {}          // repoKey -> {dist, comp, base}
  };

  var el = {};
  function $(id) { return document.getElementById(id); }
  function on(elm, ev, fn) { elm.addEventListener(ev, fn); }

  function setStatus(msg) { el.status.textContent = msg || ""; }
  function showErr(msg) { setStatus(msg); }

  /* ---------- Parsing Debian Packages stanzas ---------- */
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
      if (line.charAt(0) === " " && cur) { // continuation
        cur[cur.fld] = (cur[cur.fld] || "") + "\n" + line.slice(1).replace(/^\s+/, " ");
        continue;
      }
      var idx = line.indexOf(":");
      if (idx < 0) continue;
      var fld = line.slice(0, idx);
      var val = line.slice(idx + 1).replace(/^\s+/, "");
      if (fld === "Package") {
        if (cur) entries.push(cur);
        cur = { Package: val, Version: "", Architecture: "", Description: "", Filename: "", Depends: "" };
        cur.fld = fld; cur[cur.fld] = val;
      } else if (cur) {
        cur.fld = fld;
        cur[fld] = val;
      }
    }
    if (cur) entries.push(cur);
    return entries;
  }

  /* ---------- Version comparison (dpkg-style, simplified) ---------- */
  function compareVersions(a, b) {
    function parts(v) {
      return String(v).replace(/-[^-]*$/, ":").split(/[.:+~]/);
    }
    var pa = parts(a), pb = parts(b);
    var n = Math.max(pa.length, pb.length);
    for (var k = 0; k < n; k++) {
      var xa = isNaN(parseInt(pa[k], 10)) ? pa[k] : parseInt(pa[k], 10);
      var xb = isNaN(parseInt(pb[k], 10)) ? pb[k] : parseInt(pb[k], 10);
      if (xa > xb) return 1;
      if (xa < xb) return -1;
    }
    return 0;
  }

  /* ---------- Fetch all repos / arches ---------- */
  function groupRepos() {
    REPOS.forEach(function (r) {
      state.repos[r.name] = { distribution: r.distribution, component: r.component, label: r.label, key: r.key };
    });
  }

  function repoUrl(pkg) {
    var r = state.repos[pkg.repo];
    return BASE + "apt/" + pkg.repo + "/dists/" + r.distribution + "/" + r.component + "/binary-" + pkg.arch + "/Packages";
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

  /* ---------- Aggregate into package groups ---------- */
  function buildGrouped() {
    var g = {};
    state.raw.forEach(function (rec) {
      var key = rec.name;
      if (!g[key]) g[key] = { name: rec.name, desc: "", repo: rec.repo, versions: {} };
      var grp = g[key];
      grp.desc = grp.desc || rec.desc;
      if (!grp.versions[rec.version]) {
        grp.versions[rec.version] = { archFiles: {}, archs: {}, isAll: false };
      }
      var v = grp.versions[rec.version];
      v.archFiles[rec.arch] = rec.filename;
      if (rec.arch === "all") {
        v.isAll = true;
        ARCHES.forEach(function (a) { v.archs[a] = a; });
      } else if (ARCHES.indexOf(rec.arch) !== -1) {
        v.archs[rec.arch] = rec.arch;
      }
    });
    state.grouped = g;
  }

  /* ---------- Query/filter ---------- */
  function filteredGroups() {
    var q = (el.search.value || "").trim().toLowerCase();
    var repoFilter = el.repoFilter.value;
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

  function archSet(grp) {
    // Latest version determines displayed arches.
    var versions = Object.keys(grp.versions);
    versions.sort(compareVersions);
    var latest = grp.versions[versions[versions.length - 1]];
    var set = {};
    ARCHES.forEach(function (a) { if (latest.archs[a]) set[a] = a; });
    set.isAll = !!latest.isAll;
    set.hasPartial = Object.keys(set).length > 0 && Object.keys(set).length < ARCHES.length;
    return set;
  }

  function latestOf(grp) {
    var versions = Object.keys(grp.versions);
    versions.sort(compareVersions);
    return versions[versions.length - 1];
  }

  /* ---------- Rendering ---------- */
  function renderDots(set, wrap) {
    wrap.innerHTML = "";
    ARCHES.forEach(function (a) {
      var d = document.createElement("span");
      d.className = "dot" + (set[a] ? " on" : "") + (set.isAll && set[a] ? " all" : "");
      d.title = a + (set[a] ? "" : " (unavailable)");
      wrap.appendChild(d);
    });
  }

  function renderList() {
    var groups = filteredGroups();
    el.list.innerHTML = "";
    el.empty.hidden = groups.length > 0;
    groups.forEach(function (grp) {
      var li = document.createElement("li");
      li.className = "pkg";

      var left = document.createElement("div");
      var top = document.createElement("div");
      top.className = "pkg-top";
      var nn = document.createElement("span");
      nn.className = "pkg-name";
      nn.textContent = grp.name;
      var ver = document.createElement("span");
      ver.className = "pkg-version";
      ver.textContent = latestOf(grp);
      var repo = document.createElement("span");
      repo.className = "pkg-repo";
      repo.textContent = state.repos[grp.repo].label;
      top.appendChild(nn); top.appendChild(ver); top.appendChild(repo);
      var desc = document.createElement("div");
      desc.className = "pkg-desc";
      desc.textContent = (grp.desc || "").split("\n")[0] || "&nbsp;";
      left.appendChild(top); left.appendChild(desc);

      var side = document.createElement("div");
      side.className = "pkg-side";
      var dotsWrap = document.createElement("div");
      dotsWrap.className = "arch-dots";
      dotsWrap.title = "Available architectures";
      renderDots(archSet(grp), dotsWrap);
      var dl = document.createElement("button");
      dl.className = "btn btn-ghost";
      dl.textContent = "Download";
      side.appendChild(dotsWrap); side.appendChild(dl);

      li.appendChild(left); li.appendChild(side);
      li.addEventListener("click", function (e) {
        if (e.target === dl) { openDetail(grp); return; }
        openDetail(grp);
      });
      dl.addEventListener("click", function (e) { e.stopPropagation(); openDetail(grp); });

      el.list.appendChild(li);
    });
  }

  function repoBase(name) { return BASE + "apt/" + name; }

  function openDetail(grp) {
    el.dlgTitle.textContent = grp.name;
    var body = el.dlgBody;
    body.innerHTML = "";

    var field = document.createElement("p");
    field.className = "dlg-field";
    field.textContent = (grp.desc || "").split("\n")[0] || "";
    body.appendChild(field);

    var versions = Object.keys(grp.versions);
    versions.sort(compareVersions).reverse();

    var verWrap = document.createElement("div");
    verWrap.className = "dlg-versions";
    versions.forEach(function (v) {
      var row = document.createElement("div");
      row.className = "dlg-version";
      var vname = document.createElement("span");
      vname.className = "vname";
      vname.textContent = grp.name + "_" + v;
      var dotsWrap = document.createElement("div");
      dotsWrap.className = "arch-dots";
      renderDots(grp.versions[v], dotsWrap);
      var rowSide = document.createElement("div");
      rowSide.style.cssText = "display:flex;align-items:center;gap:10px;flex-wrap:wrap;";
      rowSide.appendChild(dotsWrap);
      row.appendChild(vname); row.appendChild(rowSide);
      verWrap.appendChild(row);
    });
    body.appendChild(verWrap);

    var install = document.createElement("button");
    install.className = "btn btn-primary";
    install.textContent = "Copy install command";
    install.addEventListener("click", function () {
      copyText("apt install " + grp.name);
    });
    var dl = document.createElement("button");
    dl.className = "btn";
    dl.textContent = "Download .deb";
    dl.addEventListener("click", function () {
      var set = archSet(grp);
      var fileName;
      var latestVer = latestOf(grp);
      var v = grp.versions[latestVer];
      if (set.isAll) {
        fileName = v.archFiles["all"];
      } else {
        var arch = ARCHES.filter(function (a) { return v.archFiles[a]; })[0];
        fileName = v.archFiles[arch];
      }
      if (!fileName) { showErr("No .deb available for download."); return; }
      var href = repoBase(grp.repo) + "/" + fileName;
      var a = document.createElement("a");
      a.href = href; a.download = fileName.split("/").pop(); a.rel = "noopener";
      document.body.appendChild(a); a.click(); a.remove();
    });
    var actions = document.createElement("div");
    actions.className = "dlg-actions";
    actions.appendChild(install); actions.appendChild(dl);
    body.appendChild(actions);

    el.dialog.showModal();
  }

  /* ---------- Setup guide ---------- */
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
      navigator.clipboard.writeText(text).then(flash, fallback);
    } else {
      fallback(); flash();
    }
  }

  function flash() {
    // signal copy happened (can't easily target button here); rely on clipboard.
  }

  /* ---------- Hydrate ---------- */
  function hydrate() {
    var nRepos = REPOS.length;
    var names = Object.keys(state.grouped).length;
    el.statPkgs.textContent = names;
    el.statRepos.textContent = nRepos;
    el.statArchs.textContent = ARCHES.length;
    renderList();
    setStatus(names + " packages indexed across " + nRepos + " repositories.");
    buildSources();
  }

  /* ---------- Init ---------- */
  function init() {
    el = {
      search: $("search"), repoFilter: $("repo-filter"),
      status: $("status"), list: $("pkg-list"), empty: $("empty"),
      statPkgs: $("stat-pkgs"), statRepos: $("stat-repos"), statArchs: $("stat-archs"),
      dlgTitle: $("dlg-title"), dlgBody: $("dlg-body"), dialog: $("detail-dialog"),
      codeSources: $("code-sources"), dlgClose: $("dlg-close")
    };

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

    var debounce;
    el.search.addEventListener("input", function () {
      clearTimeout(debounce);
      debounce = setTimeout(renderList, 120);
    });
    el.repoFilter.addEventListener("change", renderList);

    el.dlgClose.addEventListener("click", function () { el.dialog.close(); });
    el.dialog.addEventListener("click", function (e) {
      if (e.target === el.dialog) el.dialog.close();
    });

    // Step copy buttons
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
