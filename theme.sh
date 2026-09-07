#!/bin/bash
# Aerium identity pass (sourced from build.sh inside chromium/src, after
# patch.sh): product rename, privacy defaults, and battery efficiency.
# Visual theming is left stock so Android's own dynamic-color/dark-theme
# settings work as expected instead of being overridden.

# `sed -i` succeeds and changes nothing when its pattern stops matching, so a
# Chromium version bump that renames or reflows a targeted line silently drops
# the corresponding Aerium change - the build stays green and the feature is
# just missing from the APK. `sed_i` is a drop-in replacement that fails the
# build instead. Use it for every substitution whose absence would be a
# behaviour regression rather than a cosmetic one.
sed_i() {
    # A sed invocation can name several trailing files (theme.sh has one that
    # patches both worker fetch-context implementations at once), so the
    # targets are derived positionally: skip flags, the first non-flag
    # argument is the script, everything after it is a file.
    #
    # Splitting them by testing `-e "$arg"` instead - which this used to do -
    # is wrong twice over. A target whose path upstream renamed gets
    # reclassified as part of the script, so the failure reads "no existing
    # sed target" instead of naming the file that moved. Worse, it made every
    # sed_i invisible to devutils/verify-seds.sh: that script collects targets
    # in a first pass over an *empty* tree, so nothing existed, files[] came
    # back empty, and sed_i returned before calling sed at all. The targets
    # were never collected, never fetched, and never evaluated - leaving the
    # substitutions reserved for behaviour regressions as the only ones with
    # no version-bump safety net.
    local -a files=() expr=()
    local arg script_seen=0
    for arg in "$@"; do
        case "$arg" in
            -*) expr+=("$arg"); continue ;;
        esac
        if [ "$script_seen" = 0 ]; then
            script_seen=1
            expr+=("$arg")
            continue
        fi
        files+=("$arg")
    done
    if [ "${#files[@]}" -eq 0 ]; then
        echo "[aerium] FATAL: no sed target in: $*" >&2
        return 1
    fi

    # A missing target is reported but does not short-circuit the sed call:
    # verify-seds learns which paths a substitution wants by intercepting that
    # call, and it needs to hear about the missing ones most of all.
    local f rc=0
    local -a before_sums=()
    for f in "${files[@]}"; do
        if [ -e "$f" ]; then
            before_sums+=("$(cksum < "$f")")
        else
            echo "[aerium] FATAL: sed target does not exist: $f" >&2
            echo "[aerium]        upstream probably moved this file - see theme.sh" >&2
            before_sums+=("")
            rc=1
        fi
    done
    sed -i "$@" || rc=1
    local i=0
    for f in "${files[@]}"; do
        if [ -e "$f" ] && [ -n "${before_sums[$i]}" ] \
           && [ "${before_sums[$i]}" = "$(cksum < "$f")" ]; then
            echo "[aerium] FATAL: sed changed nothing in $f" >&2
            echo "[aerium]        expression: ${expr[*]}" >&2
            echo "[aerium]        upstream probably moved this code - see theme.sh" >&2
            rc=1
        fi
        i=$((i + 1))
    done
    return $rc
}

# --- Product name in every UI string source (.grd/.grdp/.xtb). Vanadium's
# branding patches already renamed their subset; this sweep catches the rest
# (e.g. "About Chromium" strings living inside <if expr> branches). Changed
# source texts get new grit IDs, so affected strings fall back to English in
# non-English locales.
grep -rl --include='*.grd' --include='*.grdp' --include='*.xtb' 'Chromium' \
    chrome components ui extensions content 2>/dev/null | while read -r f; do
    sed -i 's/The Chromium Authors/Dioide/g; s/Chromium/Aerium/g' "$f"
done

# --- The copyright line under Settings -> About Aerium -> Legal information.
# The sweep above rewrites "The Chromium Authors" to Dioide, but this string
# names Google LLC instead, so it survived as "Copyright 2026 Google LLC" on
# a screen where every other name had already been rebranded.
#
# sed_i rather than sed: if a Chromium bump reflows this line the build should
# stop and say so, not quietly ship Google's name in Aerium's about screen.
# The <ph> element is kept exactly as upstream writes it - grit requires the
# %1$d formatter to sit inside a <ph>, and moving it out is what broke an
# earlier build.
sed_i 's|Copyright <ph name="year">%1$d<ex>2014</ex></ph> Google LLC. All rights reserved.|Aerium. Copyright <ph name="year">%1$d<ex>2014</ex></ph> Dioide. All rights reserved.|' \
    chrome/browser/ui/android/strings/android_chrome_strings.grd

# --- Ungoogled-style privacy default: disable Safe Browsing by default. It
# is the main recurring Google phone-home on Android (URL/reputation pings);
# ungoogled-chromium removes it at build level. Left toggleable in
# Settings -> Privacy and security for users who want it.
sed -i 's/prefs::kSafeBrowsingEnabled, true,/prefs::kSafeBrowsingEnabled, false,/' \
    components/safe_browsing/core/common/safe_browsing_prefs.cc

# --- Use the Android Autofill framework by default so third-party password
# managers (Bitwarden etc.) fill web forms natively instead of relying on
# flaky accessibility-based compatibility mode. User-changeable in
# Settings -> Autofill services. This matters here because Aerium ships no
# built-in passwords/autofill UI to fall back on; Chrome still falls back to
# its own engine automatically when no non-Google third-party autofill
# service is configured system-wide - see
# AutofillClientProviderUtils.getAndroidAutofillFrameworkAvailability().
sed -i 's/registry->RegisterBooleanPref(kAutofillUsingPlatformAutofill, false);/registry->RegisterBooleanPref(kAutofillUsingPlatformAutofill, true);/' \
    components/autofill/core/common/autofill_prefs.cc

# --- Stop platform autofill switching itself off after a few launches.
#
# The pref flipped above is not only read, it is written back. On every
# profile construction AutofillClientProvider computes the current
# availability and stores the result in the same pref, while the Java side
# treats that pref as one of its two routes to AVAILABLE. That makes it a
# latch. One launch where the autofill service does not resolve - the
# AutofillManager not ready yet, or getAutofillServiceComponentName()
# momentarily null - writes false, and the only automatic way back is the
# saved-package route, which needs the package to have been recorded on an
# earlier run and to still match the current service.
#
# This is a known upstream behaviour, not a theory: Chromium counts how often
# it happens, in the Autofill.ResetAutofillPrefToChrome histogram, and its own
# comment there says the pref is reset when platform autofill "isn't allowed
# or doesn't fulfill all preconditions".
#
# On stock Chrome the user recovers in Settings -> Autofill services. Aerium
# deliberately ships no autofill settings UI, so there is nothing to recover
# with: third-party autofill works for the first few launches and then never
# again. That matches the reported symptom, and it reproduces on the upstream
# fork for the same reason.
#
# Only writing the pref when it is true costs nothing. Every durable
# restriction - enterprise policy, an unsupported platform, Google being the
# selected service - is re-checked inside
# getAndroidAutofillFrameworkAvailability() on every single call and decides
# the outcome there regardless of what this pref holds. The pref only needs to
# carry the intent, and the intent here is always true.
sed_i '/^  \/\/ Ensure the pref is reset if platform autofill is restricted\.$/,/^                    uses_platform_autofill_);$/c\
  \/\/ Aerium: never write this pref false. Upstream stores the computed\
  \/\/ availability here on every profile construction, and the Java side\
  \/\/ reads it back as one of two routes to AVAILABLE, so a single launch\
  \/\/ where the autofill service fails to resolve latches third-party\
  \/\/ autofill off for good. Aerium has no autofill settings UI to turn it\
  \/\/ back on, so the latch would be permanent. Durable restrictions are\
  \/\/ re-checked in getAndroidAutofillFrameworkAvailability() on every call\
  \/\/ and still win, so keeping the stored intent true changes nothing else.\
  if (uses_platform_autofill_) {\
    prefs->SetBoolean(prefs::kAutofillUsingPlatformAutofill,\
                      uses_platform_autofill_);\
  }' chrome/browser/ui/autofill/autofill_client_provider.cc

# --- ... and stop it latching for the session, either.
#
# The block above stops the availability answer being written to disk as false.
# It does not stop it being cached in memory as false, and that is the same bug
# one scope smaller.
#
# uses_platform_autofill_ is a const member computed exactly once, in the
# constructor, from a single call to getAndroidAutofillFrameworkAvailability().
# AutofillClientProvider is a KeyedService, and its factory selects
# ProfileSelection::kRedirectedToOriginal for regular profiles - upstream even
# leaves a TODO there asking whether OTR should get its own - so there is one
# instance per browser session, shared by every profile in the family, and
# CreateClientForWebContents() hands every WebContents a client picked from that
# one answer.
#
# So the constructor runs at the first tab of the session, and whatever the
# framework says at that instant decides the whole session. If AutofillManager
# has not come up yet - the case the block above already documents - every tab
# opened afterwards gets ChromeAutofillClient, including tabs opened minutes
# later when the service has long since resolved. Aerium ships no autofill
# settings UI, so nothing can undo it; the only recovery is to restart the
# browser and hope the race falls the other way.
#
# Upstream does not have to care, because stock Chrome has Settings -> Autofill
# services to force the issue. It also already re-asks per surface where it
# cannot cache: isAutofillEnabledForCct() calls
# getAndroidAutofillFrameworkAvailability() fresh for every Custom Tab rather
# than reading this member. Re-asking is a JNI call and a few pref reads, and
# upstream is willing to pay it per CCT.
#
# So: re-ask while the answer is no. The member latches on and never off, which
# is deliberate and asymmetric:
#
#   - false is the state that is broken here. In this build it means no autofill
#     at all, not "Chrome fills instead", because patch.sh removes the built-in
#     passwords and autofill surfaces. There is nothing to lose by leaving it.
#   - true is the state worth protecting. Re-checking on every call would let a
#     single transient failure mid-session flip a working browser back to the
#     dead state - reintroducing the flake in the other direction, which is
#     exactly what the pref fix above was for.
#
# Durable restrictions still win, because they are re-evaluated inside
# getAndroidAutofillFrameworkAvailability() on every call: enterprise policy,
# an unsupported platform, and Google being the selected service all return a
# non-AVAILABLE status, so promotion cannot happen while any of them holds.
#
# Honest about scope: this is a real latch and this removes it. It is not proven
# to be the cause of the "autofill misses in a normal tab but works in an
# incognito one" report - the shared-provider design above means both tabs are
# handed the same answer, so a same-session asymmetry has to come from somewhere
# else. It is fixed because it is wrong on its own, and because a browser with
# no autofill UI cannot afford a state it cannot leave.
#
# The header carries two claims that this makes false - "always of the same type
# across all WebContents instances" and "constant once this provider has been
# created" - so both are rewritten rather than left to mislead the next reader.
sed_i 's|^#include "components/keyed_service/core/keyed_service.h"$|#include "base/memory/raw_ptr.h"\n&|' \
    chrome/browser/ui/autofill/autofill_client_provider.h

sed_i 's|^// always of the same type across all WebContents instances\.$|// of the same type across every WebContents created once the answer settles.\n// Aerium: that answer is no longer fixed at construction - see\n// CreateClientForWebContents(), which re-asks while it is false.|' \
    chrome/browser/ui/autofill/autofill_client_provider.h

sed_i '/^  \/\/ The return value is constant once this provider has been created\. The$/,/^  const bool uses_platform_autofill_;$/c\
  \/\/ Aerium: returns true iff platform autofill should be used instead of\
  \/\/ built-in autofill. No longer constant - it latches on and never off. See\
  \/\/ CreateClientForWebContents().\
  bool uses_platform_autofill() const { return uses_platform_autofill_; }\
\
 private:\
  \/\/ Aerium: not const any more. CreateClientForWebContents() promotes this\
  \/\/ once the framework answers, so one unlucky check at the first tab of the\
  \/\/ session no longer decides the session.\
  bool uses_platform_autofill_;\
  \/\/ Aerium: kept so the re-check is possible at all. Owned by the Profile,\
  \/\/ which outlives this KeyedService.\
  const raw_ptr<PrefService> prefs_;' \
    chrome/browser/ui/autofill/autofill_client_provider.h

# The anchor is the closing line of the initialiser list, not the
# UsesVirtualViewStructureForAutofill line above it, because Vanadium patch 0217
# rewrites that line. Upstream ends the list with
#
#     UsesVirtualViewStructureForAutofill(CHECK_DEREF(prefs))) {
#
# and 0217 splits it, appending `&& prefs->GetBoolean(...)` inside an IS_ANDROID
# guard and moving the close onto its own `    ) {` line. Anchoring on the
# upstream form matched pristine Chromium and nothing in the tree the build
# sees, which is what failed runs 146 and 148. devutils/verify-seds.sh reported
# OK for it and also listed this file under "Targets Vanadium also patches - an
# OK here is about pristine Chromium, not about the tree the build sees". That
# warning is the whole answer and it was already on screen.
sed_i 's|^    ) {$|    ),\n      prefs_(prefs) {|' \
    chrome/browser/ui/autofill/autofill_client_provider.cc

sed_i 's|^  if (uses_platform_autofill()) {$|#if BUILDFLAG(IS_ANDROID)\n  // Aerium: re-ask while the answer is no. The constructor asked once, at the\n  // first tab of the session, and a framework that was not ready yet would\n  // otherwise pin every later tab to the built-in client - which in this build\n  // means no autofill at all, and no settings UI to recover with. Latches on\n  // and never off: promoting a dead state is free, demoting a working one is\n  // the flake this is meant to remove. The pref clause mirrors Vanadium patch\n  // 0217, which ANDs the same pref into the constructor - without it a\n  // promotion here could reach a state the constructor would have refused.\n  if (!uses_platform_autofill_ \&\&\n      UsesVirtualViewStructureForAutofill(CHECK_DEREF(prefs_.get())) \&\&\n      prefs_->GetBoolean(prefs::kAutofillUsingPlatformAutofill)) {\n    uses_platform_autofill_ = true;\n    // Same two side effects the constructor performs when it settles on true,\n    // so the saved package and the shared pref other apps read do not stay\n    // describing the state we just left.\n    Java_AutofillClientProviderUtils_updatePackageUsedForAutofill(\n        base::android::AttachCurrentThread(), prefs_.get(), true);\n    SetSharedPrefForSettingsContentProvider(true);\n  }\n#endif  // BUILDFLAG(IS_ANDROID)\n&|' \
    chrome/browser/ui/autofill/autofill_client_provider.cc

# --- Stop Settings crashing on open. patch.sh deletes the six autofill and
# password entries (orders 11-17) from main_preferences.xml, but MainSettings
# .java still expects the XML to define them. Both branches of
# updateAutofillPreferences() call addPreferenceIfAbsent(), which returns
# mAllPreferences.get(key) - and mAllPreferences is populated by
# cachePreferences() walking the inflated XML, so once the entries are gone
# that lookup is null. The assumeNonNull() guarding it does not actually
# check anything (build/android/.../NullUtil.java: "Since it does not
# actually check", it just returns its argument), so the null reaches
# setOnPreferenceClickListener() and the fragment dies with an NPE the
# instant Settings is opened. That is the crash in the published
# 151.0.7922.71 APK.
#
# Rewritten to only remove, which is idempotent and null-safe: correct
# whether or not the XML still defines the entries, so the perl in patch.sh
# quietly failing to match cannot resurrect the crash - it would only put the
# entries back in settings search.
#
# The two helpers are deleted rather than left behind, because Chromium
# builds Java with treat_warnings_as_errors and errorprone.py maps every
# check to a warning (-XepAllErrorsAsWarnings) without disabling
# UnusedMethod, so an uncalled private method would fail the build.
# maybeStartPasswordsExportFlow() is kept and still called: it reads fragment
# arguments and touches none of the removed preferences. Unused imports are
# fine - RemoveUnusedImports is in errorprone.py's disable list.
# The same six things are also reachable from the three-dot menu, which is a
# separate surface from Settings and was still offering all of them: a
# "Passwords and autofill" parent item whose submenu holds Google Password
# Manager, Payment methods, and Addresses and more. Removing the preferences
# from main_preferences.xml did nothing to this menu.
#
# The gate is one predicate, so that is what changes. Deleting the block that
# adds the item would leave buildPasswordsAndAutofillParentItem() - and the
# three submenu builders it calls - referenced by nothing, and Chromium builds
# Java with treat_warnings_as_errors while errorprone maps UnusedMethod to a
# warning, so dead private methods fail the build. Returning false keeps every
# call site in place and simply never reaches them.
# --- chrome://aerium-first-run - the onboarding page, shown once on the very
# first launch.
#
# The desktop repos get this from ungoogled-chromium's ungoogled_first_run.h,
# which Aerium then extends. Android has no ungoogled layer and no
# StartupBrowserCreator, so neither the page nor the AddFirstRunTabs() call
# that opens it exists here - both halves are built rather than ported.
#
# The page is header-only, the same shape as the desktop chrome://aerium page:
# a DefaultWebUIConfig plus an inline URLDataSource needs no BUILD.gn entry, no
# .cc and no TypeScript, which keeps a page of static text out of the resource
# pipeline entirely.
#
# What is deliberately NOT carried over is the desktop page's preset chooser.
# On desktop it exists because the browser ships with Chromium's defaults and
# the page is what changes them. On Android the same decisions are compiled in
# by this script - Safe Browsing, network prediction, HTTPS-First, the search
# engine list - so a preset button would mostly re-apply settings the build
# already made. Several of the prefs it writes (background mode, the memory
# and battery saver tiers, Aerium's own clear-on-exit pref) do not exist on
# Android at all. So the page explains what was decided instead of offering to
# decide it again.
cat > chrome/browser/ui/webui/aerium_first_run.h <<'AERIUM_FIRST_RUN_H'
#ifndef CHROME_BROWSER_UI_WEBUI_AERIUM_FIRST_RUN_H_
#define CHROME_BROWSER_UI_WEBUI_AERIUM_FIRST_RUN_H_

#include <string>

#include "base/memory/ref_counted_memory.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/url_data_source.h"
#include "content/public/browser/web_ui.h"
#include "content/public/browser/web_ui_controller.h"
#include "content/public/browser/webui_config.h"

// chrome://aerium-first-run - shown once, on the first launch after install.
// ChromeTabbedActivity::createInitialTab opens this instead of the New Tab
// Page when the AERIUM_FIRST_RUN_PAGE_SHOWN preference is still unset.
class AeriumFirstRunDataSource : public content::URLDataSource {
 public:
  AeriumFirstRunDataSource() = default;
  AeriumFirstRunDataSource(const AeriumFirstRunDataSource&) = delete;
  AeriumFirstRunDataSource& operator=(const AeriumFirstRunDataSource&) = delete;
  ~AeriumFirstRunDataSource() override = default;

  // Defined below the class rather than here. The chromium-style clang
  // plugin rejects a virtual method whose non-empty body is written inside
  // the class declaration - it forces every translation unit that includes
  // the header to carry the code. Writing the definitions out-of-line keeps
  // the page header-only, which is the whole point of this file, and is what
  // the plugin actually asks for.
  std::string GetSource() override;
  std::string GetMimeType(const GURL& url) override;

  void StartDataRequest(const GURL& url,
                        const content::WebContents::Getter& wc_getter,
                        GotDataCallback callback) override;
};

inline std::string AeriumFirstRunDataSource::GetSource() {
  return "aerium-first-run";
}

inline std::string AeriumFirstRunDataSource::GetMimeType(const GURL& url) {
  return "text/html";
}

inline void AeriumFirstRunDataSource::StartDataRequest(
    const GURL& url,
    const content::WebContents::Getter& wc_getter,
    content::URLDataSource::GotDataCallback callback) {
  std::move(callback).Run(
      base::MakeRefCounted<base::RefCountedString>(std::string(
          R"AERIUMHTML(<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Welcome to Aerium</title>
<style>
  :root {
    --bg: #f6f8fc; --card: #ffffff; --ink: #14203f; --muted: #4a5878;
    --line: #dde4f0; --accent: #2c6bae; --chip: #eaf1fa;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0d1428; --card: #141d38; --ink: #e9f1fb; --muted: #9fb0d0;
      --line: #24304f; --accent: #7fc4e4; --chip: #1b2747;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--ink);
    font: 16px/1.55 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    -webkit-text-size-adjust: 100%;
  }
  main { max-width: 44rem; margin: 0 auto; padding: 1.5rem 1.1rem 3rem; }
  header { text-align: center; padding: 1rem 0 0.5rem; }
  .mark { width: 84px; height: 84px; }
  h1 { font-size: 1.6rem; line-height: 1.25; margin: 0.75rem 0 0.35rem; }
  .lede { color: var(--muted); margin: 0 0 1.5rem; }
  section {
    background: var(--card); border: 1px solid var(--line);
    border-radius: 14px; padding: 1rem 1.1rem; margin: 0 0 0.9rem;
  }
  h2 { font-size: 1.05rem; margin: 0 0 0.5rem; }
  p { margin: 0 0 0.6rem; }
  p:last-child, ul:last-child { margin-bottom: 0; }
  ul { margin: 0 0 0.6rem; padding-left: 1.15rem; }
  li { margin: 0.25rem 0; }
  a { color: var(--accent); }
  .chips { display: flex; flex-wrap: wrap; gap: 0.4rem; margin: 0.15rem 0 0; padding: 0; list-style: none; }
  .chips li {
    background: var(--chip); border-radius: 999px;
    font-size: 0.85rem; margin: 0;
  }
  /* The padding lives on the anchor, not the li, so the whole pill is the
     tap target rather than just the width of the words. */
  .chips a {
    display: block; padding: 0.45rem 0.9rem; border-radius: inherit;
    color: var(--accent); text-decoration: none;
  }
  .chips a:hover, .chips a:focus-visible {
    background: var(--accent); color: var(--card);
  }
  .note { color: var(--muted); font-size: 0.9rem; }
  footer { text-align: center; color: var(--muted); font-size: 0.85rem; margin-top: 1.5rem; }
</style>
<main>
  <header>
    <svg class="mark" viewBox="0 0 512 512" aria-hidden="true">
      <path d="M 330 384.17 L 149.1 488.61 A 256 256 0 0 1 108 47.12 L 108 256 A 148 148 0 0 0 330 384.17 Z" fill="#1B2C5E"/>
      <path d="M 108 256 L 108 47.12 A 256 256 0 0 1 510.9 232.27 L 330 127.83 A 148 148 0 0 0 108 256 Z" fill="#2A4485"/>
      <path d="M 330 127.83 L 510.9 232.27 A 256 256 0 0 1 149.1 488.61 L 330 384.17 A 148 148 0 0 0 330 127.83 Z" fill="#111C42"/>
      <circle cx="256" cy="256" r="134" fill="#E9F1FB"/>
      <circle cx="256" cy="256" r="104" fill="#2C6BAE"/>
      <circle cx="238" cy="236" r="82" fill="#4C97CF"/>
      <circle cx="222" cy="218" r="46" fill="#7FC4E4"/>
    </svg>
    <h1>Welcome to Aerium</h1>
    <p class="lede">A Chromium build with the Google plumbing taken out. Here is what it already did for you, and the two things worth setting up yourself.</p>
  </header>

  <section>
    <h2>Already decided for you</h2>
    <p>These are compiled into the build, not toggles someone hoped you would find:</p>
    <ul>
      <li><strong>Safe Browsing is off.</strong> It was the main recurring call home &mdash; every URL you visit, checked against Google.</li>
      <li><strong>Nothing is preloaded or predicted.</strong> Pages, DNS and links are fetched when you ask for them, which is also easier on the battery.</li>
      <li><strong>HTTPS-First is on</strong> in its balanced mode, so plain HTTP is upgraded where a site supports it.</li>
      <li><strong>Global Privacy Control is sent</strong> on every request &mdash; a legally recognised opt-out under CCPA.</li>
      <li><strong>The search engine list is privacy-first</strong>, with Startpage as the default and DuckDuckGo, Brave Search, Mojeek, Qwant, Ecosia and degoog alongside it.</li>
      <li><strong>Translate is gone</strong>, along with the settings entry and its search index.</li>
    </ul>
  </section>

  <section>
    <h2>Passwords and autofill</h2>
    <p>Aerium ships no password manager, no saved payment methods and no stored addresses, and the settings and menu entries for them are removed rather than merely hidden.</p>
    <p>Instead, web forms are filled by <strong>whichever autofill service you have chosen in Android</strong>. Set one in <em>Settings &rsaquo; Passwords &amp; accounts &rsaquo; Autofill service</em>. Any of these work well:</p>
    <ul class="chips">
      <li><a href="https://bitwarden.com" rel="noreferrer">Bitwarden</a></li>
      <li><a href="https://proton.me/pass" rel="noreferrer">Proton Pass</a></li>
      <li><a href="https://www.keepassdx.com" rel="noreferrer">KeePassDX</a></li>
    </ul>
    <p class="note" style="margin-top:0.7rem">A dedicated manager also fills apps, not just this browser, and your vault outlives any one browser.</p>
  </section>

  <section>
    <h2>Extensions</h2>
    <p>This build supports extensions, which stock Chrome on Android does not. A content blocker such as uBlock Origin is the single most useful thing to add.</p>
    <p>An extension can also own the New Tab page, which is how you change what it looks like &mdash; Aerium has no built-in setting for a custom background because <a href="https://chromewebstore.google.com/detail/tablissng/dlaogejjiafeobgofajdlkkhjlignalk">TablissNG</a> already does it better than a setting would, with your own images or a fresh photo each time.</p>
  </section>

  <section>
    <h2>Secure DNS</h2>
    <p>Turn it on in <a href="chrome://settings/privacy">Privacy and security</a> and pick a resolver you trust. It keeps the names of the sites you visit away from your network and your carrier.</p>
  </section>

  <section>
    <h2>Updates</h2>
    <p>There is no auto-updater and no Play Store listing, so security updates are not automatic. New builds are published on GitHub &mdash; check occasionally, or subscribe to releases to be told.</p>
    <p><a href="https://github.com/aerium-browser/aerium-browser-android/releases">github.com/aerium-browser/aerium-browser-android/releases</a></p>
  </section>

  <section>
    <h2>Where this build comes from</h2>
    <p>Aerium for Android is built on <a href="https://github.com/GrapheneOS/Vanadium">Vanadium</a>, the hardened Chromium from GrapheneOS, with Aerium's own changes on top. Everything is public: the patches, the scripts that apply them, and the CI that produced the file you installed.</p>
  </section>

  <footer>You can reach this page again at any time from chrome://aerium-first-run</footer>
</main>
)AERIUMHTML")));
}

class AeriumFirstRun;

class AeriumFirstRunUIConfig
    : public content::DefaultWebUIConfig<AeriumFirstRun> {
 public:
  AeriumFirstRunUIConfig()
      : DefaultWebUIConfig("chrome", "aerium-first-run") {}
};

class AeriumFirstRun : public content::WebUIController {
 public:
  explicit AeriumFirstRun(content::WebUI* web_ui)
      : content::WebUIController(web_ui) {
    content::URLDataSource::Add(Profile::FromWebUI(web_ui),
                                std::make_unique<AeriumFirstRunDataSource>());
  }
  AeriumFirstRun(const AeriumFirstRun&) = delete;
  AeriumFirstRun& operator=(const AeriumFirstRun&) = delete;
};

#endif  // CHROME_BROWSER_UI_WEBUI_AERIUM_FIRST_RUN_H_
AERIUM_FIRST_RUN_H

# Registered inside the IS_ANDROID arm of both lists, next to the webapks
# entries, so it exists only where it is reachable.
sed_i 's|#include "chrome/browser/ui/webui/webapks/webapks_ui.h"|&\n#include "chrome/browser/ui/webui/aerium_first_run.h"|' \
    chrome/browser/ui/webui/chrome_web_ui_configs.cc
sed_i 's|  map.AddWebUIConfig(std::make_unique<WebApksUIConfig>());|&\n  map.AddWebUIConfig(std::make_unique<AeriumFirstRunUIConfig>());|' \
    chrome/browser/ui/webui/chrome_web_ui_configs.cc

# The "have we greeted this install yet" flag. Chromium keeps its
# SharedPreferences keys in one registry and validates membership in tests and
# debug builds, so the key is added to both the constants and getKeysInUse()
# rather than only where it is read. The Chrome.<Feature>.<Key> shape is the
# format that validation expects for new keys.
CPK=chrome/browser/preferences/android/java/src/org/chromium/chrome/browser/preferences/ChromePreferenceKeys.java
sed_i 's|    public static final String FIRST_RUN_FLOW_COMPLETE = "first_run_flow";|    /** Whether the Aerium first-run page has been shown for this install. */\n    public static final String AERIUM_FIRST_RUN_PAGE_SHOWN =\n            "Chrome.Aerium.FirstRunPageShown";\n\n&|' \
    $CPK
sed_i 's|^                ADAPTIVE_TOOLBAR_CUSTOMIZATION_ENABLED,$|                AERIUM_FIRST_RUN_PAGE_SHOWN,\n&|' \
    $CPK

# The trigger. createInitialTab() is where Android picks the New Tab Page or
# the homepage for a cold start with no tabs to restore, which is the closest
# thing here to the desktop AddFirstRunTabs() call. Never in incognito, and the
# flag is written before the tab is launched so a crash on the way cannot leave
# it greeting on every launch.
sed_i 's|        getTabCreator(incognito).launchUrl(url, TabLaunchType.FROM_STARTUP);|        // Aerium: greet once, on the first launch after install.\n        if (!incognito\n                \&\& !ChromeSharedPreferences.getInstance()\n                        .readBoolean(\n                                ChromePreferenceKeys.AERIUM_FIRST_RUN_PAGE_SHOWN, false)) {\n            ChromeSharedPreferences.getInstance()\n                    .writeBoolean(ChromePreferenceKeys.AERIUM_FIRST_RUN_PAGE_SHOWN, true);\n            url = "chrome://aerium-first-run/";\n        }\n&|' \
    chrome/android/java/src/org/chromium/chrome/browser/ChromeTabbedActivity.java

# --- Let the system autofill service win even when it is Google's.
#
# Stock Chromium refuses to delegate to Autofill with Google: if the selected
# system service is AWG, getAndroidAutofillFrameworkAvailability() returns
# ANDROID_AUTOFILL_SERVICE_IS_GOOGLE and AutofillClientProvider falls back to
# ChromeAutofillClient - the browser's own engine. On a device set to Google,
# forms would be filled by Aerium rather than by the service the user chose,
# which is the opposite of what this build wants.
#
# Vanadium already removes it. Patch 0254 ("remove unused separate autofill
# status") deletes AWG_COMPONENT_NAME and both of its call sites, so by the
# time this script runs there is nothing left to strip - an earlier version of
# this block tried to strip it anyway and killed the build on its own guard.
#
# What is left here is the assertion, which is the part that actually needs to
# survive a bump: if Vanadium ever drops 0254, the exception comes back and
# Aerium silently starts filling forms itself on Google-configured devices.
# That is a behaviour regression no compiler would catch, so check the outcome
# rather than redo the work.
AUTOFILL_UTILS=chrome/browser/autofill/android/java/src/org/chromium/chrome/browser/autofill/AutofillClientProviderUtils.java
if [ -e $AUTOFILL_UTILS ] \
   && grep -q 'ANDROID_AUTOFILL_SERVICE_IS_GOOGLE' $AUTOFILL_UTILS; then
    echo "[aerium] FATAL: the AWG exception is back in" \
         "AutofillClientProviderUtils.java - Vanadium patch 0254 no longer" \
         "removes it." >&2
    echo "[aerium]        Without it gone, a device whose system autofill" \
         "service is Google falls back to the browser's own engine instead" \
         "of delegating. Strip the ANDROID_AUTOFILL_SERVICE_IS_GOOGLE branch" \
         "of getAndroidAutofillFrameworkAvailability() here." >&2
    return 1
fi

TABBED_MENU=chrome/android/java/src/org/chromium/chrome/browser/tabbed_mode/TabbedAppMenuPropertiesDelegate.java
sed_i '/^    private boolean shouldShowPasswordsAndAutofillParentItem() {$/,/^    }$/c\
    private boolean shouldShowPasswordsAndAutofillParentItem() {\
        \/\/ Aerium ships no password, payment or address storage UI, so the\
        \/\/ menu entry that leads to it - and its Google Password Manager,\
        \/\/ Payment methods and Addresses and more children - are never\
        \/\/ built. Web forms are filled by the system autofill service.\
        return false;\
    }' $TABBED_MENU

MAIN_SETTINGS=chrome/android/java/src/org/chromium/chrome/browser/settings/MainSettings.java
sed_i '/^    private void updateAutofillPreferences() {$/,/^    }$/c\
    private void updateAutofillPreferences() {\
        \/\/ Aerium ships no autofill or password storage UI, and patch.sh\
        \/\/ removes these entries from main_preferences.xml so settings\
        \/\/ search does not index them either. Removal is null-safe; the\
        \/\/ upstream add\/find calls were not, once the XML entries were gone.\
        removePreferenceIfPresent(PREF_AUTOFILL_AND_PASSWORDS);\
        removePreferenceIfPresent(PREF_AUTOFILL_SECTION);\
        removePreferenceIfPresent(PREF_PASSWORDS);\
        removePreferenceIfPresent(PREF_AUTOFILL_PAYMENTS);\
        removePreferenceIfPresent(PREF_AUTOFILL_ADDRESSES);\
        removePreferenceIfPresent(PREF_AUTOFILL_OPTIONS);\
\
        maybeStartPasswordsExportFlow();\
    }' $MAIN_SETTINGS
sed_i '/^    private void updateAutofillAndPasswords() {$/,/^    }$/d' $MAIN_SETTINGS
sed_i '/^    \/\/ TODO(crbug.com\/482988366): Remove this method once the Autofill and passwords feature is$/,/^    }$/d' \
    $MAIN_SETTINGS
# The second crash site, and the one the rewrite above does not reach.
# setManagedPreferenceDelegateForPreference() is the other reader of
# mAllPreferences, with the same do-nothing assumeNonNull() in front of the
# dereference, and onCreatePreferences calls it for PREF_PASSWORDS
# unconditionally - so Settings would still have died on open with only
# updateAutofillPreferences() fixed. Its other two call sites pass keys whose
# entries survive, so the helper itself stays.
sed_i '/^        \/\/ TODO(crbug.com\/40242060): Remove the passwords managed subtitle for local and UPM$/,/^        setManagedPreferenceDelegateForPreference(PREF_PASSWORDS);$/d' \
    $MAIN_SETTINGS

# --- Battery efficiency pass. Aerium takes its name from aerogel, the
# world's lightest solid, so keeping the browser light on battery is a brand
# commitment, not just an optimization. Each change below flips a single
# feature/pref default; all remain user-changeable where a settings UI exists.
# Verified against Chromium 151.0.7922.71 source at each file path below.

# Disable network prediction/preloading (prefetching links, DNS, etc. on
# page load) by default - trades a little latency for meaningfully less
# background radio/network activity. User-changeable in
# Settings -> Privacy and security -> Preload pages.
sed -i 's/static_cast<int>(NetworkPredictionOptions::kDefault),/static_cast<int>(NetworkPredictionOptions::kDisabled),/' \
    chrome/browser/preloading/preloading_prefs.cc

# Disable Optimization Guide (hints fetching + on-device target prediction
# model downloads/updates) - periodic background network chatter with no
# user-facing toggle on Android.
sed -i 's/BASE_FEATURE(kOptimizationHints, base::FEATURE_ENABLED_BY_DEFAULT);/BASE_FEATURE(kOptimizationHints, base::FEATURE_DISABLED_BY_DEFAULT);/; s/BASE_FEATURE(kOptimizationTargetPrediction, base::FEATURE_ENABLED_BY_DEFAULT);/BASE_FEATURE(kOptimizationTargetPrediction, base::FEATURE_DISABLED_BY_DEFAULT);/' \
    components/optimization_guide/core/optimization_guide_features.cc

# Disable Domain Reliability (periodic diagnostic beacons to Google about
# request failures/latency on Google-owned domains).
sed -i 's/registry->RegisterBooleanPref(prefs::kDomainReliabilityAllowedByPolicy, true);/registry->RegisterBooleanPref(prefs::kDomainReliabilityAllowedByPolicy, false);/' \
    components/domain_reliability/domain_reliability_prefs.cc

# Disable Interest Feed V2 (the Discover feed on the New Tab Page) - a
# recurring background JobScheduler task that fetches articles even when
# the feed isn't being looked at.
sed -i 's/BASE_FEATURE(kInterestFeedV2, base::FEATURE_ENABLED_BY_DEFAULT);/BASE_FEATURE(kInterestFeedV2, base::FEATURE_DISABLED_BY_DEFAULT);/' \
    components/feed/feed_feature_list.cc

# Disable Safety Hub's background password-check job (a periodic
# JobScheduler task, roughly weekly, that runs even without the Safety
# Hub settings page ever being opened).
sed -i 's/BASE_FEATURE(kSafetyHub, base::FEATURE_ENABLED_BY_DEFAULT);/BASE_FEATURE(kSafetyHub, base::FEATURE_DISABLED_BY_DEFAULT);/' \
    components/safety_check/features.cc

# --- Auto-darken web content, offered but off. Chromium already implements
# this end to end: RadioButtonGroupThemePreference draws a "darken websites"
# checkbox under Settings -> Appearance -> Theme whenever the theme is Dark or
# System default, and ThemeSettingsFragment already reads and writes it through
# WebContentsDarkModeController. The whole feature is wired and simply hidden
# behind a disabled flag, so this exposes it rather than building anything.
#
# On an OLED panel the display is usually the largest single power draw, and
# web content is most of the screen - the browser's own chrome is a small strip
# at the top. Darkening pages is therefore where the real saving is, which is
# why it is worth offering at all.
#
# It has to be TWO changes, not one. Enabling the feature alone would turn auto
# dark ON for everyone, because the content setting's registered default is
# derived from the feature's own param:
#
#   const auto auto_dark_web_content_setting =
#       content_settings::kDarkenWebsitesCheckboxOptOut.Get()
#           ? CONTENT_SETTING_ALLOW
#           : CONTENT_SETTING_BLOCK;
#
# and opt_out ships as true. Setting it false makes the default BLOCK, so the
# checkbox appears unchecked and darkening only happens if asked for. Auto dark
# misrenders some sites, so it must never be the default.
#
# The BASE_FEATURE macro is split across two lines, hence the N to pull the
# second line into the pattern space before substituting.
sed_i '/BASE_FEATURE(kDarkenWebsitesCheckboxInThemesSetting,/{N;s/base::FEATURE_DISABLED_BY_DEFAULT/base::FEATURE_ENABLED_BY_DEFAULT/}' \
    components/content_settings/core/common/features.cc
sed_i 's|"opt_out", true};|"opt_out", false};|' \
    components/content_settings/core/common/features.cc

# --- Pure black (AMOLED) surfaces. On an OLED panel a black pixel is switched
# off and draws no power, while Chromium's dark theme paints #1F1F1F - about
# 12% grey - so every pixel stays lit. Aerium is named after aerogel and the
# battery pass above already trims background CPU and radio work; the display
# is the one large draw it never touched.
#
# This is possible cheaply because of how Chromium 152 resolves colour.
# semantic_colors_dynamic.xml routes the surfaces through Material 3 theme
# attributes rather than fixed values:
#
#   <macro name="default_bg_color">?attr/colorSurface</macro>
#   <macro name="settings_bg_color">?attr/colorSurfaceContainerHigh</macro>
#
# so overriding those attributes in a theme overlay repaints the toolbar, the
# New Tab Page, settings, sheets and cards at once, and can be switched on and
# off per launch instead of being baked in.
#
# Every surface role goes to #000000, including the overflow menu, the cards
# inside settings and the progress-bar track. Those three float over or sit on
# another surface, so black-on-black leaves them without an edge - that is a
# deliberate trade, taking the boundary in exchange for the pixels being off.
# elevationOverlayEnabled is turned off because Material's elevation overlay
# lightens a surface in proportion to its elevation, which would put the grey
# straight back.
sed_i 's|^</resources>$|    <!-- Aerium: see theme.sh. Pure black for OLED panels. -->\n    <style name="ThemeOverlay.BrowserUI.AeriumPureBlack" parent="">\n        <item name="android:colorBackground">@android:color/black</item>\n        <item name="colorSurface">@android:color/black</item>\n        <item name="colorSurfaceDim">@android:color/black</item>\n        <item name="colorSurfaceContainerLowest">@android:color/black</item>\n        <item name="colorSurfaceContainerLow">@android:color/black</item>\n        <item name="colorSurfaceContainer">@android:color/black</item>\n        <item name="colorSurfaceContainerHigh">@android:color/black</item>\n        <item name="colorSurfaceBright">@android:color/black</item>\n        <item name="colorSurfaceContainerHighest">@android:color/black</item>\n        <item name="elevationOverlayEnabled">false</item>\n    </style>\n&|' \
    components/browser_ui/styles/android/java/res/values/themes.xml


# The toggle. theme_preferences.xml holds only the radio group, so the switch
# goes in beside it rather than into RadioButtonGroupThemePreference, whose
# checkbox is an accessory view reparented under the selected radio button -
# a mechanism worth staying out of for a setting that is not per-theme.
sed_i 's|^</PreferenceScreen>$|    <org.chromium.components.browser_ui.settings.ChromeSwitchPreference\n        android:key="aerium_pure_black"\n        android:title="@string/aerium_pure_black_title"\n        android:summary="@string/aerium_pure_black_summary" />\n&|' \
    chrome/browser/ui/android/night_mode/java/res/xml/theme_preferences.xml

TSF=chrome/browser/ui/android/night_mode/java/src/org/chromium/chrome/browser/night_mode/settings/ThemeSettingsFragment.java
sed_i 's|^import org.chromium.chrome.browser.preferences.ChromeSharedPreferences;$|import org.chromium.chrome.browser.preferences.ChromePreferenceKeys;\n&|' \
    $TSF
sed_i 's|^import org.chromium.components.browser_ui.settings.CustomDividerFragment;$|import org.chromium.components.browser_ui.settings.ChromeSwitchPreference;\n&|' \
    $TSF
sed_i 's|^        // TODO(crbug.com/40198953): Notify feature engagement system that settings were opened.$|        // Aerium: pure black surfaces. Stored in shared preferences rather than\n        // a profile pref because it is read in Activity.onCreate, before the\n        // profile is available. Default on: it only takes effect in dark mode,\n        // which the user has already chosen, and a battery feature nobody finds\n        // is not one.\n        ChromeSwitchPreference pureBlack =\n                (ChromeSwitchPreference) findPreference("aerium_pure_black");\n        if (pureBlack != null) {\n            pureBlack.setChecked(\n                    sharedPreferencesManager.readBoolean(\n                            ChromePreferenceKeys.AERIUM_PURE_BLACK, true));\n            pureBlack.setOnPreferenceChangeListener(\n                    (preference, newValue) -> {\n                        sharedPreferencesManager.writeBoolean(\n                                ChromePreferenceKeys.AERIUM_PURE_BLACK, (boolean) newValue);\n                        // Surfaces are chosen when an Activity is themed, so the\n                        // change lands on the next one rather than repainting this\n                        // screen underneath the switch that just moved.\n                        showRestartSnackbar();\n                        return true;\n                    });\n        }\n\n&|' \
    $TSF

# The overlay is applied per Activity. applyThemeOverlays() runs inside
# onCreate before super.onCreate, which is where Chromium already applies its
# dynamic-colour and density overlays - and after initializeNightModeStateProvider(),
# so the night-mode state is known. Applying last means it wins over the
# Material You palette, which otherwise supplies the surfaces on Android 12+.
#
# Shared preferences rather than a profile pref: this is read before the
# profile exists.
CBACA=chrome/android/java/src/org/chromium/chrome/browser/ChromeBaseAppCompatActivity.java
sed_i 's|^import org.chromium.chrome.browser.night_mode.NightModeUtils;$|&\nimport org.chromium.chrome.browser.preferences.ChromePreferenceKeys;\nimport org.chromium.chrome.browser.preferences.ChromeSharedPreferences;|' \
    $CBACA
sed_i 's|^        if (StyleUtils.shouldApplyDesktopDensity()) {$|        // Aerium: pure black surfaces on OLED. Applied last so it overrides the\n        // dynamic-colour palette above, and only in dark mode - there is nothing\n        // to blacken in a light theme.\n        if (getNightModeStateProvider().isInNightMode()\n                \&\& ChromeSharedPreferences.getInstance()\n                        .readBoolean(ChromePreferenceKeys.AERIUM_PURE_BLACK, true)) {\n            applySingleThemeOverlay(R.style.ThemeOverlay_BrowserUI_AeriumPureBlack);\n        }\n\n&|' \
    $CBACA

# The key itself. Same registry and the same getKeysInUse() list the first-run
# flag was added to - Chromium validates membership in tests and debug builds.
sed_i 's|    public static final String FIRST_RUN_FLOW_COMPLETE = "first_run_flow";|    /** Whether Aerium paints pure black surfaces while in dark mode. */\n    public static final String AERIUM_PURE_BLACK = "Chrome.Aerium.PureBlack";\n\n&|' \
    $CPK
sed_i 's|^                ADAPTIVE_TOOLBAR_CUSTOMIZATION_ENABLED,$|                AERIUM_PURE_BLACK,\n&|' \
    $CPK

# The two strings for the switch.
sed_i 's|^      <message name="IDS_THEME_SETTINGS" desc="Title for the Theme settings.*|      <message name="IDS_AERIUM_PURE_BLACK_TITLE" desc="Title of the switch in Appearance - Theme that paints the browser pure black instead of dark grey.">\n        Pure black\n      </message>\n      <message name="IDS_AERIUM_PURE_BLACK_SUMMARY" desc="Summary under the Pure black switch explaining what it does and why.">\n        Use true black instead of dark grey in dark mode. Saves power on OLED screens, where black pixels are switched off.\n      </message>\n&|' \
    chrome/browser/ui/android/strings/android_chrome_strings.grd

# --- AMOLED backgrounds for darkened web pages. Turning on "Darken websites"
# above does not give black pages: Blink inverts lightness in LAB space and
# then floors near-black greys at #121212 on purpose. dark_mode_color_filter.cc
# says why - "Further darken dark grays to match the primary surface color
# recommended by the material design guidelines".
#
# Following the pipeline for a white page: L=100, inverted by
# lab.x = min(110 - lab.x, 100) to L=10, back to sRGB as 27.5/255, then
# AdjustGray sees a neutral grey inside (18/255, 32/255) and clamps it to
# 18/255 - #121212 exactly. Every white and near-white page lands there.
#
# Dropping the floor to zero sends that same band to #000000 instead, so a
# darkened page is off pixels rather than Material's dark surface. The upper
# threshold is left alone: it decides which greys are treated as near-black at
# all, and widening it would flatten a page background into the cards sitting
# on it. Pages that are already light grey rather than white (#F1F1F1 inverts
# to about #252525) stay outside the band and keep their own separation.
#
# This rides the existing "Darken websites" switch rather than adding a third
# one. That switch is off by default and is already the separate control for
# web content; making its output black is what an OLED panel wants, and a
# grey-vs-black choice underneath it would mean plumbing a new setting from
# Java through the renderer into Blink for a distinction nobody asks for.
sed_i 's|    static const float kAdjustedBrightness = 18.0f / 255.0f;|    // Aerium: 0 instead of 18/255 - see theme.sh. Pure black, not Material grey.\n    static const float kAdjustedBrightness = 0.0f;|' \
    third_party/blink/renderer/platform/graphics/dark_mode_color_filter.cc

# --- Blacken sites that ship their own dark theme. Off by default.
#
# Force dark does not touch these sites, and that is correct: its classifiers
# are brightness-gated (150 for foreground, 205 for background, set in
# dark_mode_settings_builder.cc), so a site whose background is already dark
# falls below the threshold and is left alone rather than inverted back to
# light. What it keeps, though, is the site's own grey - GitHub is #0d1117,
# YouTube #181818 - and on an OLED panel every one of those pixels is lit.
#
# So: when the classifier declines to invert a background and the colour is
# already near black, pull it the rest of the way to #000000. Anything lighter
# is left alone, which keeps a genuinely mid-grey background distinct from the
# cards drawn on it.
#
# This cannot be a live setting. DarkModeFilter is built once per renderer
# process from GetCurrentDarkModeSettings(), itself a function-static, so
# nothing about force dark's tuning can change without a new process - even
# Chromium's own thresholds are fixed at startup. It is therefore a
# base::Feature appended to the command line before native starts, and the
# switch says so. Features propagate to renderers on their own, which a plain
# switch would not.
sed_i 's|  int background_brightness_threshold = 0;|&\n  // Aerium: pull near-black backgrounds the classifier skips to #000000.\n  bool blacken_dark_backgrounds = false;|' \
    third_party/blink/renderer/platform/graphics/dark_mode_settings.h

DMSB=third_party/blink/renderer/platform/graphics/dark_mode_settings_builder.cc
sed_i 's|#include "base/command_line.h"|&\n#include "base/feature_list.h"|' $DMSB
sed_i 's|const constexpr int kDefaultForegroundBrightnessThreshold = 150;|// Aerium: see theme.sh. Named "AeriumBlackenDarkBackgrounds" on the command\n// line, which is what ChromeApplicationImpl appends when the setting is on.\nBASE_FEATURE(kAeriumBlackenDarkBackgrounds, base::FEATURE_DISABLED_BY_DEFAULT);\n\n&|' $DMSB
sed_i 's|      Clamp<int>(kDefaultBackgroundBrightnessThreshold, 0, 255);|&\n  settings.blacken_dark_backgrounds =\n      base::FeatureList::IsEnabled(kAeriumBlackenDarkBackgrounds);|' $DMSB

sed_i 's|    sk_sp<cc::ColorFilter> image_filter;|&\n    // Aerium: see theme.sh.\n    bool blacken_dark_backgrounds = false;|' \
    third_party/blink/renderer/platform/graphics/dark_mode_filter.h

DMF=third_party/blink/renderer/platform/graphics/dark_mode_filter.cc
sed_i 's|  image_classifier = std::make_unique<DarkModeImageClassifier>();|&\n  blacken_dark_backgrounds = settings.blacken_dark_backgrounds;|' $DMF
# The fold itself. Uses the weights DarkModeColorClassifier::CalculateColorBrightness
# uses, so "how dark is this" means the same thing here as it does to the
# classifier that just declined the colour.
sed_i 's%const size_t kMaxCacheSize = 1024u;%&\n\n// Aerium: pull a background the classifier declined to invert toward black.\n//\n// The classifier is InvertHighBrightnessColorsClassifier(205): it inverts\n// backgrounds BRIGHTER than 205 and returns everything else untouched. That\n// is the whole reason a dark site stays grey. A site at #313338 is too dark\n// to invert and too light for any near-black clamp, so both paths pass it\n// through and Discord renders exactly as it always did.\n//\n// So scale instead of clamping: new brightness = old * (old / 205), a\n// gamma-2 fold anchored where the classifier takes over. #0d1117 lands on\n// #010101, #181818 on #030303, #313338 on #0d0d0d - black to the eye - while\n// a genuinely mid-grey #787878 only reaches #464646 and stays distinguishable\n// from the black behind it. Continuous at the anchor, so nothing jumps as a\n// colour crosses 205.\n//\n// Channels are scaled together rather than the lightness being rewritten, so\n// a tinted surface keeps its tint on the way down.\nSkColor4f AeriumFoldTowardBlack(const SkColor4f\& color) {\n  const float brightness =\n      0.299f * color.fR + 0.587f * color.fG + 0.114f * color.fB;\n  constexpr float kAnchor = 205.0f / 255.0f;\n  if (brightness <= 0.0f || brightness >= kAnchor) {\n    return color;\n  }\n  const float scale = brightness / kAnchor;\n  return SkColor4f{color.fR * scale, color.fG * scale, color.fB * scale,\n                   color.fA};\n}%' $DMF

# The call site: after the classifier has declined, not before it. A colour the
# classifier DOES invert has already been sent to near-black by the LAB
# inversion plus the zeroed AdjustGray floor above, and folding it twice would
# take a light page's cards down with its background.
sed_i '/^        immutable_.color_filter.get(), color);$/{N;s%^        immutable_.color_filter.get(), color);\n  }$%        immutable_.color_filter.get(), color);\n  }\n\n  // Aerium: see theme.sh. A background the classifier left alone is folded\n  // toward black rather than returned as it came in. Deliberately AFTER the\n  // classifier, not before: a colour it does invert has already been taken to\n  // near black by the LAB inversion and the zeroed AdjustGray floor above, and\n  // folding that a second time would drag a light page'"'"'s cards down with its\n  // background.\n  if (immutable_.blacken_dark_backgrounds \&\& role == ElementRole::kBackground) {\n    return AeriumFoldTowardBlack(color);\n  }%}' $DMF

# The contrast heuristic assumed #121212 behind everything, which stops being
# true the moment the fold lands. AdjustDarkenColor uses it to decide whether a
# border is already readable and may be darkened further; told the wrong
# background it keeps borders lighter than they need to be.
sed_i 's%  const SkColor4f\& background = \[\&contrast_background\]() {%  const SkColor4f\& background = [\&contrast_background, this]() {%' $DMF
sed_i 's%      return SkColor4f::FromColor(SK_ColorDark);%      // Aerium: follow the fold - see theme.sh.\n      return immutable_.blacken_dark_backgrounds\n                 ? SkColors::kBlack\n                 : SkColor4f::FromColor(SK_ColorDark);%' $DMF

# The canvas underneath all of it. StyleEngine hardcodes the base background
# for any page whose root colour scheme resolves to dark:
#
#     color_scheme_background_ =
#         root_color_scheme == mojom::blink::ColorScheme::kLight
#             ? Color::kWhite
#             : Color(0x12, 0x12, 0x12);
#
# That colour is painted behind the document and never goes near DarkModeFilter
# - it is not a CSS background, it is what the viewport is cleared to. So on a
# site that declares color-scheme: dark and leaves its body background alone,
# every pixel the user sees is #121212 and there is nothing in the paint path
# to fold. The switch was working and the page was still grey.
SE=third_party/blink/renderer/core/css/style_engine.cc
sed_i 's|#include "third_party/blink/renderer/platform/geometry/physical_size.h"|&\n#include "third_party/blink/renderer/platform/graphics/dark_mode_settings_builder.h"|' $SE
sed_i 's|            : Color(0x12, 0x12, 0x12);|            : (GetCurrentDarkModeSettings().blacken_dark_backgrounds\n                   ? Color::kBlack\n                   : Color(0x12, 0x12, 0x12));|' $SE


# The key, the startup hook and the switch.
sed_i 's|    public static final String FIRST_RUN_FLOW_COMPLETE = "first_run_flow";|    /** Whether Aerium blackens sites that ship their own dark theme. */\n    public static final String AERIUM_BLACKEN_DARK_SITES = "Chrome.Aerium.BlackenDarkSites";\n\n&|' \
    $CPK
sed_i 's|^                ADAPTIVE_TOOLBAR_CUSTOMIZATION_ENABLED,$|                AERIUM_BLACKEN_DARK_SITES,\n&|' \
    $CPK

CAI=chrome/android/java/src/org/chromium/chrome/browser/ChromeApplicationImpl.java
sed_i 's|^import org.chromium.base.CommandLine;$|&\nimport org.chromium.chrome.browser.preferences.ChromePreferenceKeys;\nimport org.chromium.chrome.browser.preferences.ChromeSharedPreferences;|' \
    $CAI
sed_i 's|            FontPreloader.getInstance().load(getApplication());|&\n\n            // Aerium: the renderer fixes its dark-mode settings at process\n            // start, so this has to be on the command line before native\n            // comes up rather than flipped live. Merged into any existing\n            // value instead of overwriting whatever else asked for features.\n            if (ChromeSharedPreferences.getInstance()\n                    .readBoolean(ChromePreferenceKeys.AERIUM_BLACKEN_DARK_SITES, false)) {\n                CommandLine commandLine = CommandLine.getInstance();\n                String existing = commandLine.getSwitchValue("enable-features");\n                String merged =\n                        (existing == null \|\| existing.isEmpty())\n                                ? "AeriumBlackenDarkBackgrounds"\n                                : existing + ",AeriumBlackenDarkBackgrounds";\n                commandLine.appendSwitchWithValue("enable-features", merged);\n            }|' \
    $CAI

sed_i 's|^</PreferenceScreen>$|    <org.chromium.components.browser_ui.settings.ChromeSwitchPreference\n        android:key="aerium_blacken_dark_sites"\n        android:title="@string/aerium_blacken_dark_sites_title"\n        android:summary="@string/aerium_blacken_dark_sites_summary" />\n&|' \
    chrome/browser/ui/android/night_mode/java/res/xml/theme_preferences.xml

# --- Say that blackening dark sites depends on darkening websites at all.
#
# "Blacken dark sites" only changes how force dark paints, so with "Darken
# websites" unchecked - which is how Aerium ships, see the auto dark block
# above - it does precisely nothing, and the switch gives no hint of that. The
# report that prompted this was three sites, none of them black, with the
# switch on: the setting was doing exactly what it was built to do and there
# was nothing on screen to say why that was nothing.
#
# So it is greyed out while auto dark is off, and its summary says which
# checkbox turns it back on. The state is refreshed from the theme preference's
# change listener, which is where the checkbox is committed, so ticking
# "Darken websites" enables this switch without leaving the screen.
sed_i 's|^    private boolean mWebContentsDarkModeEnabled;$|&\n\n    // Aerium: see theme.sh. Held as a field so the darken-websites checkbox\n    // can re-enable it from the theme preference'"'"'s change listener.\n    private @Nullable ChromeSwitchPreference mBlackenDarkSites;\n\n    private void updateBlackenDarkSitesEnabled() {\n        if (mBlackenDarkSites == null) return;\n        mBlackenDarkSites.setEnabled(mWebContentsDarkModeEnabled);\n        mBlackenDarkSites.setSummary(\n                mWebContentsDarkModeEnabled\n                        ? R.string.aerium_blacken_dark_sites_summary\n                        : R.string.aerium_blacken_dark_sites_needs_auto_dark);\n    }|' \
    $TSF
sed_i 's|^                    int theme = (int) newValue;$|                    updateBlackenDarkSitesEnabled();\n&|' $TSF

sed_i 's|^        // TODO(crbug.com/40198953): Notify feature engagement system that settings were opened.$|        mBlackenDarkSites = (ChromeSwitchPreference) findPreference("aerium_blacken_dark_sites");\n        if (mBlackenDarkSites != null) {\n            mBlackenDarkSites.setChecked(\n                    sharedPreferencesManager.readBoolean(\n                            ChromePreferenceKeys.AERIUM_BLACKEN_DARK_SITES, false));\n            mBlackenDarkSites.setOnPreferenceChangeListener(\n                    (preference, newValue) -> {\n                        sharedPreferencesManager.writeBoolean(\n                                ChromePreferenceKeys.AERIUM_BLACKEN_DARK_SITES,\n                                (boolean) newValue);\n                        showRestartSnackbar();\n                        return true;\n                    });\n            updateBlackenDarkSitesEnabled();\n        }\n\n&|' \
    $TSF

sed_i 's|^      <message name="IDS_AERIUM_PURE_BLACK_TITLE" desc=|      <message name="IDS_AERIUM_BLACKEN_DARK_SITES_TITLE" desc="Title of the switch that also blackens websites which already have their own dark theme.">\n        Blacken dark sites\n      </message>\n      <message name="IDS_AERIUM_BLACKEN_DARK_SITES_SUMMARY" desc="Summary under the Blacken dark sites switch. Mentions that a restart is needed.">\n        Extend darkening to sites that ship their own dark theme, so their dark grey becomes true black too. Restart Aerium to apply.\n      </message>\n      <message name="IDS_AERIUM_BLACKEN_DARK_SITES_NEEDS_AUTO_DARK" desc="Summary shown in place of the usual one when the Blacken dark sites switch is greyed out, naming the checkbox that has to be ticked first.">\n        Turn on Darken websites above to use this.\n      </message>\n&|' \
    chrome/browser/ui/android/strings/android_chrome_strings.grd

# --- Make the blacken switch reach sites that ship their own dark theme.
#
# The switch above did nothing on YouTube or Reddit, and the reason sits
# upstream of the filter rather than in it. ComputedStyle::ForceDark() is
#
#     DarkColorScheme() && ColorSchemeForced()
#
# and ComputedStyleBuilder::SetUsedColorScheme computes the second as
#
#     forced_scheme = (!has_dark && dark_scheme) || (force_dark && !prefers_dark)
#
# A site that declares color-scheme: dark, read with night mode on, has both
# has_dark and prefers_dark true, so neither clause fires - the scheme is dark
# because the page asked for it, not because we forced it. ForceDark() is
# false, DarkModeFilter is never consulted, and the clamp above never runs.
#
# A site with no color-scheme declaration has has_dark false, so the first
# clause fires and the clamp does run. That is exactly the split observed:
# eksisozluk went black, YouTube and Reddit kept their own grey.
#
# So when the setting is on, a dark scheme counts as forced even where the page
# chose it, which is what puts the filter in the paint path. Gated on
# force_dark too, so "Darken websites" being off still switches all of this off
# rather than leaving the filter running by itself.
#
# ColorSchemeForced() has exactly one reader in the tree - ForceDark() - so
# nothing else about how the page is styled changes.
CSTYLE=third_party/blink/renderer/core/style/computed_style.cc
sed_i 's|#include "third_party/blink/renderer/platform/graphics/graphics_context.h"|#include "third_party/blink/renderer/platform/graphics/dark_mode_settings_builder.h"\n&|' \
    $CSTYLE
sed_i 's|^  SetColorSchemeForced(forced_scheme);$|  // Aerium: see theme.sh. A page that ships its own dark theme is skipped by\n  // force dark, which is where the blacken switch lives, so treat its dark\n  // scheme as forced when that switch is on.\n  if (force_dark \&\& dark_scheme \&\&\n      GetCurrentDarkModeSettings().blacken_dark_backgrounds) {\n    forced_scheme = true;\n  }\n\n&|' \
    $CSTYLE

# Engaging force dark on a page that is already dark means its images go
# through the filter too, and those are the one thing on such a page that is
# not meant to be darkened - a photo on YouTube is already the right colour.
# The classifier would leave photographs alone (ShouldApplyFilterToImage only
# accepts kIcon and kSeparator), but icons drawn on a dark page are light and
# inverting them would be wrong, so images are skipped outright. Chromium has
# the same switch for its own reasons in AutoDarkModeSkipImages; this reuses
# that exit rather than adding a second one.
sed_i 's|  if (RuntimeEnabledFeatures::AutoDarkModeSkipImagesEnabled()) {|  // Aerium: see theme.sh - never filter images when blackening dark sites.\n  if (immutable_.blacken_dark_backgrounds \|\|\n      RuntimeEnabledFeatures::AutoDarkModeSkipImagesEnabled()) {|' $DMF

# --- Tell the user a restart is needed, and offer to do it.
#
# Neither switch can take effect where it is flipped. Pure black is chosen when
# an Activity is themed, so it lands on the next one; blacken dark sites is a
# command-line feature the renderer reads once at process start. Leaving that
# to a line of summary text means the setting looks broken until the user
# happens to restart.
#
# A snackbar rather than a dialog, and the relaunch on a button rather than
# automatic: restarting the browser out from under someone who was mid-session
# to apply a colour preference is worse than the wrong colour for a minute.
sed_i 's|^import android.content.Context;$|import android.app.Activity;\n&|' $TSF
sed_i 's|^import org.chromium.chrome.browser.settings.ChromeBaseSettingsFragment;$|&\nimport org.chromium.chrome.browser.lifetime.ApplicationLifetime;\nimport org.chromium.chrome.browser.ui.messages.snackbar.Snackbar;\nimport org.chromium.chrome.browser.ui.messages.snackbar.SnackbarManager;\nimport org.chromium.chrome.browser.ui.messages.snackbar.SnackbarManager.SnackbarManageable;|' \
    $TSF
sed_i '/^    @Override$/{N;s|^    @Override\n    public void onCreatePreferences|    // Aerium: see theme.sh. Long enough to read and act on. The instanceof is\n    // not defensive padding - this fragment is reachable from more than one\n    // host, and only a SnackbarManageable one can show it; the interface\n    // itself promises a non-null manager, so there is nothing further to\n    // check.\n    private static final int RESTART_SNACKBAR_DURATION_MS = 10000;\n\n    private void showRestartSnackbar() {\n        Activity activity = getActivity();\n        if (!(activity instanceof SnackbarManageable)) return;\n        SnackbarManager manager = ((SnackbarManageable) activity).getSnackbarManager();\n        manager.showSnackbar(\n                Snackbar.make(\n                                getString(R.string.aerium_restart_to_apply),\n                                new SnackbarManager.SnackbarController() {\n                                    @Override\n                                    public void onAction(@Nullable Object actionData) {\n                                        ApplicationLifetime.terminate(true);\n                                    }\n                                },\n                                Snackbar.TYPE_ACTION,\n                                Snackbar.UMA_UNKNOWN)\n                        .setAction(getString(R.string.aerium_relaunch), null)\n                        .setDuration(RESTART_SNACKBAR_DURATION_MS));\n    }\n\n    @Override\n    public void onCreatePreferences|}' \
    $TSF

# The snackbar and the restart come from targets night_mode did not depend on.
# Neither depends back on night_mode, so this adds no cycle.
#
# Both go in at the settings:java line because it is the only dep in this file
# that appears once - flags:java and preferences:java are each repeated in the
# two test targets, and sed would have added the dep to those as well. It
# leaves lifetime one line out of alphabetical order, which gn build does not
# mind; only `gn format` would, and nothing in this pipeline runs it.
sed_i 's|^    "//chrome/browser/settings:java",$|    "//chrome/browser/lifetime/android:java",\n&\n    "//chrome/browser/ui/messages/android:java",|' \
    chrome/browser/ui/android/night_mode/BUILD.gn

sed_i 's|^      <message name="IDS_AERIUM_BLACKEN_DARK_SITES_TITLE" desc=|      <message name="IDS_AERIUM_RESTART_TO_APPLY" desc="Text of the bar shown after changing an appearance setting that only takes effect once the browser has been restarted.">\n        Restart Aerium to apply this change\n      </message>\n      <message name="IDS_AERIUM_RELAUNCH" desc="Button on that bar which closes and reopens the browser.">\n        Relaunch\n      </message>\n&|' \
    chrome/browser/ui/android/strings/android_chrome_strings.grd

# --- Incognito follows the pure black switch too.
#
# ChromeColors reaches for a fixed baseline colour whenever isIncognito is set,
# in three places:
#
#     return isIncognito
#             ? context.getColor(R.color.default_bg_color_dark)
#             : SemanticColorUtils.getDefaultBgColor(context);
#
# The second branch resolves the default_bg_color macro to ?attr/colorSurface,
# which is what the overlay above replaces - so normal tabs go black. The first
# branch is a colour resource and deliberately ignores the dynamic palette, so
# that incognito looks the same on every device. That also puts it out of reach
# of the overlay, leaving incognito on Chromium's dark grey while every other
# surface is black.
#
# So the overlay names a colour for it, and ChromeColors reads that instead.
# Read defensively rather than through MaterialColors.getColor: the attribute
# only exists while the overlay is applied, and these three are called with
# whatever context the caller has - including ones themed from outside
# browser_ui. Missing attribute means the upstream colour, exactly as before,
# rather than an exception.
#
# It follows the switch, and with it the night-mode gate: incognito in a light
# theme keeps its grey. That is the same rule the rest of the overlay follows
# and a browser being run for its OLED behaviour is not in a light theme.
sed_i 's|    <!-- Aerium: see theme.sh. Pure black for OLED panels. -->|    <!-- Aerium: set by the overlay below and read by ChromeColors, so that\n         incognito - which ignores the dynamic palette by design - follows the\n         pure black switch as well. Absent whenever the overlay is not\n         applied, which is what makes the fallback there the upstream colour. -->\n    <attr name="aeriumIncognitoBgColor" format="color" />\n\n&|' \
    components/browser_ui/styles/android/java/res/values/themes.xml
sed_i 's|        <item name="colorSurfaceContainerHighest">@android:color/black</item>|&\n        <item name="aeriumIncognitoBgColor">@android:color/black</item>|' \
    components/browser_ui/styles/android/java/res/values/themes.xml

CC=components/browser_ui/styles/android/java/src/org/chromium/components/browser_ui/styles/ChromeColors.java
sed_i 's|^import android.content.res.ColorStateList;$|&\nimport android.util.TypedValue;|' $CC
sed_i 's|^    private static final String TAG = "ChromeColors";$|&\n\n    /**\n     * Aerium: the incognito colour named by the pure black overlay, or {@code\n     * fallbackColorRes} when that overlay is not on this context'"'"'s theme. See\n     * theme.sh.\n     */\n    private static @ColorInt int incognitoSurfaceColor(\n            Context context, @ColorRes int fallbackColorRes) {\n        TypedValue value = new TypedValue();\n        if (context.getTheme().resolveAttribute(R.attr.aeriumIncognitoBgColor, value, true)\n                \&\& value.type >= TypedValue.TYPE_FIRST_COLOR_INT\n                \&\& value.type <= TypedValue.TYPE_LAST_COLOR_INT) {\n            return value.data;\n        }\n        return context.getColor(fallbackColorRes);\n    }|' \
    $CC
sed_i 's|^                ? context.getColor(R.color.toolbar_background_incognito)$|                ? incognitoSurfaceColor(context, R.color.toolbar_background_incognito)|' $CC
sed_i 's|^                ? context.getColor(R.color.default_bg_color_dark)$|                ? incognitoSurfaceColor(context, R.color.default_bg_color_dark)|' $CC
sed_i 's|^            return context.getColor(R.color.default_bg_color_dark);$|            return incognitoSurfaceColor(context, R.color.default_bg_color_dark);|' $CC

# The bottom bar is a different helper class, and was missed.
#
# Reported on issue #5: with the bottom bar on, incognito stays Chromium's dark
# grey while everything else follows the pure black switch. The bar is not
# themed by the block above because it does not go through ChromeColors at all.
# BottomBarUtils.getBottomBarBackgroundColor() calls
# IncognitoColors.getColorSurfaceContainerHigh(), and IncognitoColors is a
# second class with exactly the same shape as ChromeColors: the non-incognito
# branch goes through SemanticColorUtils, which resolves a theme attribute and
# therefore picks the overlay up, while the incognito branch reaches for a fixed
# gm3_baseline_*_dark colour resource that no overlay can reach.
#
# Which of its methods follow the switch is decided by a rule rather than by
# what the reporter happened to look at: a getter follows if the attribute its
# non-incognito branch resolves is one the overlay blackens. That is true of the
# five surface getters below and of nothing else in the file.
#
# getInteractableChipBgColor is deliberately left alone even though it names the
# same resource as getColorSurfaceContainerHigh. Its light-mode branch resolves
# colorInteractableChipBg, which the overlay does not touch, and a chip painted
# the same black as the surface behind it is an invisible chip. That is also why
# the container-high substitution below is scoped to its own method instead of
# matching the line, which appears twice.
IC=components/browser_ui/styles/android/java/src/org/chromium/components/browser_ui/styles/IncognitoColors.java
sed_i 's|^import android.content.res.ColorStateList;$|&\nimport android.util.TypedValue;|' $IC
sed_i 's|^import androidx.annotation.ColorInt;$|&\nimport androidx.annotation.ColorRes;|' $IC
sed_i 's|^public class IncognitoColors {$|&\n    /**\n     * Aerium: the incognito colour named by the pure black overlay, or {@code\n     * fallbackColorRes} when that overlay is not on this context'"'"'s theme. The\n     * same helper as the one in ChromeColors, and read just as defensively -\n     * these are called with whatever context the caller has. See theme.sh.\n     */\n    private static @ColorInt int aeriumIncognitoSurface(\n            Context context, @ColorRes int fallbackColorRes) {\n        TypedValue value = new TypedValue();\n        if (context.getTheme().resolveAttribute(R.attr.aeriumIncognitoBgColor, value, true)\n                \&\& value.type >= TypedValue.TYPE_FIRST_COLOR_INT\n                \&\& value.type <= TypedValue.TYPE_LAST_COLOR_INT) {\n            return value.data;\n        }\n        return context.getColor(fallbackColorRes);\n    }\n|' \
    $IC
sed_i 's|^                ? context.getColor(R.color.gm3_baseline_surface_dark)$|                ? aeriumIncognitoSurface(context, R.color.gm3_baseline_surface_dark)|' $IC
sed_i 's|^                ? context.getColor(R.color.gm3_baseline_surface_bright_dark)$|                ? aeriumIncognitoSurface(context, R.color.gm3_baseline_surface_bright_dark)|' $IC
sed_i 's|^                ? context.getColor(R.color.gm3_baseline_surface_container_highest_dark)$|                ? aeriumIncognitoSurface(context, R.color.gm3_baseline_surface_container_highest_dark)|' $IC
sed_i 's|^                ? context.getColor(R.color.gm3_baseline_surface_container_low_dark)$|                ? aeriumIncognitoSurface(context, R.color.gm3_baseline_surface_container_low_dark)|' $IC
# Scoped to getColorSurfaceContainerHigh, because the chip getter names the
# same resource and must keep it.
sed_i '/^    public static @ColorInt int getColorSurfaceContainerHigh(Context context, boolean isIncognito) {$/,/^    }$/s|^                ? context.getColor(R.color.gm3_baseline_surface_container_high_dark)$|                ? aeriumIncognitoSurface(context, R.color.gm3_baseline_surface_container_high_dark)|' \
    $IC

# --- The same overlay on the pre-inflated toolbar.
#
# There are two applyThemeOverlays in the tree. The one above, on
# ChromeBaseAppCompatActivity, is the one every Activity runs. WarmupManager
# has its own - its own TODO admits the duplication - and it applies only the
# elegant-text-height and font-family overlays, because those were all it ever
# needed.
#
# WarmupManager inflates the toolbar hierarchy before an Activity exists, and
# where that pre-inflated hierarchy is taken up - Custom Tabs in particular -
# its views resolve colours against the warmup context, which has no pure black
# overlay on it. The result is a grey toolbar over black content on exactly the
# launches the warmup path is there to speed up.
#
# The night-mode state comes from the global provider rather than the context
# Configuration, because the app'"'"'s own light/dark choice does not reach an
# application context'"'"'s Configuration - only the system setting does, and the
# two disagree whenever someone has set the browser to Dark on a light phone.
#
# Applied first here rather than last, unlike the Activity path. The two
# overlays beside it set text attributes and nothing about surfaces, so there
# is no ordering to preserve.
WM=chrome/android/java/src/org/chromium/chrome/browser/WarmupManager.java
sed_i 's|^import org.chromium.chrome.browser.flags.ChromeFeatureList;$|&\nimport org.chromium.chrome.browser.night_mode.GlobalNightModeStateProviderHolder;\nimport org.chromium.chrome.browser.preferences.ChromePreferenceKeys;\nimport org.chromium.chrome.browser.preferences.ChromeSharedPreferences;|' \
    $WM
sed_i 's|^    static void applyThemeOverlays(Context context) {$|&\n        // Aerium: see theme.sh. The Activity path applies this too; a view\n        // inflated here is themed before any Activity exists, so it has to be\n        // applied on both or a warm start comes up grey.\n        if (GlobalNightModeStateProviderHolder.getInstance().isInNightMode()\n                \&\& ChromeSharedPreferences.getInstance()\n                        .readBoolean(ChromePreferenceKeys.AERIUM_PURE_BLACK, true)) {\n            context.getTheme().applyStyle(R.style.ThemeOverlay_BrowserUI_AeriumPureBlack, true);\n        }\n|' \
    $WM

# --- Aerium's own palette, the Android half of the desktop brand work.
#
# Chromium Android takes its colours from the wallpaper on Android 12 and up
# (DynamicColors.applyToActivityIfAvailable), so the browser looks like
# whatever picture is behind it rather than like itself. Brave does not do
# that and neither should this: a brand that changes with the wallpaper is not
# a brand. Below Android 12 the same call is a no-op and the baseline palette
# shows through, so today Aerium has two different unbranded looks.
#
# The values are the desktop ones, unchanged, so the two platforms agree: the
# same #2C6BAE seed, the same pale ladder in light, the same DEEP navy ladder
# in dark that replaced the first, too-light attempt.
#
# Surfaces and the primary role only. On-colours, secondary, tertiary, error
# and the outlines are left to the baseline palette, for the same reason the
# desktop mixer leaves them to the generated one: Chromium tuned its contrast
# against surfaces of these lightnesses, and re-deriving readability by hand
# buys nothing. Baseline on-surface is near-black in light and near-white in
# dark, which is right over both ladders.
#
# Only the wallpaper branch is replaced, not shouldApplyDynamicColors(). The
# branch above it honours a colour the user picked for the New Tab Page, and
# taking that away to install a brand would be answering a question nobody
# asked. So: their choice first, ours instead of the wallpaper's.
#
# Dark surfaces here are what shows when Pure black is switched off. With it
# on, the AeriumPureBlack overlay is applied after this one and takes the
# surfaces to black, leaving the primary from here - which is the intended
# stack: brand accent on an OLED-black ground.
sed_i 's|^</resources>$|    <!-- Aerium: see theme.sh. The desktop palette, applied to Android. -->\n    <style name="ThemeOverlay.BrowserUI.AeriumBrandLight" parent="">\n        <item name="colorPrimary">#2C6BAE</item>\n        <item name="colorOnPrimary">#FFFFFF</item>\n        <item name="colorPrimaryContainer">#D8E6F5</item>\n        <item name="colorOnPrimaryContainer">#0B2138</item>\n        <item name="colorSurface">#F2F7FD</item>\n        <item name="colorSurfaceDim">#DCE7F4</item>\n        <item name="colorSurfaceBright">#FFFFFF</item>\n        <item name="colorSurfaceContainerLowest">#FFFFFF</item>\n        <item name="colorSurfaceContainerLow">#F7FAFE</item>\n        <item name="colorSurfaceContainer">#E9F1FB</item>\n        <item name="colorSurfaceContainerHigh">#E1ECF9</item>\n        <item name="colorSurfaceContainerHighest">#D8E6F5</item>\n    </style>\n\n    <style name="ThemeOverlay.BrowserUI.AeriumBrandDark" parent="">\n        <item name="colorPrimary">#7FC4E4</item>\n        <item name="colorOnPrimary">#06283D</item>\n        <item name="colorPrimaryContainer">#1B2A57</item>\n        <item name="colorOnPrimaryContainer">#D8E6F5</item>\n        <item name="colorSurface">#0E1834</item>\n        <item name="colorSurfaceDim">#060B16</item>\n        <item name="colorSurfaceBright">#1B2A57</item>\n        <item name="colorSurfaceContainerLowest">#060B16</item>\n        <item name="colorSurfaceContainerLow">#0A1226</item>\n        <item name="colorSurfaceContainer">#141F44</item>\n        <item name="colorSurfaceContainerHigh">#1B2A57</item>\n        <item name="colorSurfaceContainerHighest">#22376E</item>\n    </style>\n\n&|' \
    components/browser_ui/styles/android/java/res/values/themes.xml

sed_i 's|^            DynamicColors.applyToActivityIfAvailable(this);$|            // Aerium: our palette rather than the wallpaper'"'"'s - see theme.sh.\n            // Applied on every OS version, where the call it replaces did\n            // nothing below Android 12.\n            applySingleThemeOverlay(\n                    getNightModeStateProvider().isInNightMode()\n                            ? R.style.ThemeOverlay_BrowserUI_AeriumBrandDark\n                            : R.style.ThemeOverlay_BrowserUI_AeriumBrandLight);|' \
    $CBACA
# That was the file's only use of the DynamicColors class - the NTP branch
# above goes through NtpCustomizationUtils - so the import has to go with it or
# the Java build fails on an unused import.
sed_i '/^import com\.google\.android\.material\.color\.DynamicColors;$/d' $CBACA

# The pre-inflated CCT hierarchy needs it for the same reason it needed the
# black overlay, and upstream says so itself at the top of the Activity copy:
# "if you're adding new overlays here, it's quite likely they're needed in
# WarmupManager". Brand first, black second, matching the Activity order.
sed_i 's|^        // Aerium: see theme.sh. The Activity path applies this too; a view$|        // Aerium: the brand palette, ahead of the black one so black still\n        // wins on surfaces. See theme.sh.\n        context.getTheme()\n                .applyStyle(\n                        GlobalNightModeStateProviderHolder.getInstance().isInNightMode()\n                                ? R.style.ThemeOverlay_BrowserUI_AeriumBrandDark\n                                : R.style.ThemeOverlay_BrowserUI_AeriumBrandLight,\n                        /* force= */ true);\n\n&|' \
    $WM

# --- Drop the XR feature module. Worth ~20 MB of the APK, for a feature four
# separate gn args already turn off.
#
# args.gn sets enable_vr, enable_arcore, enable_openxr and enable_cardboard all
# false, and the shipped APK nevertheless contains:
#
#     18.64 MB  lib/arm64-v8a/libimpress_api_jni.so
#      0.70 MB  lib/arm64-v8a/libandroidx.xr.arcore.openxr.so
#      0.56 MB  lib/arm64-v8a/libandroidx.xr.runtime.openxr.so
#      0.10 MB  lib/arm64-v8a/libarcore_sdk_jni.so
#      0.07 MB  lib/arm64-v8a/libarcore_sdk_c.so
#
# measured off the central directory of the published 152.0.7977.54 build.
#
# Those five names appear in exactly one place in the tree - the
# loadable_modules_64_bit list of xr_module_desc - and they arrive as a dynamic
# feature module rather than as ordinary deps, which is why the gn args do not
# reach them: the args gate Chromium's own XR code, while the module carries
# prebuilt AARs (androidx.xr, Google's impress, the ARCore client). A bundle
# would deliver that module on demand; a monolithic APK packs it in
# unconditionally.
#
# So the module is removed from the list the APK is built from. chrome_java
# keeps its :xr_java dependency, which is only the module-installer bridge and
# pulls none of the AARs, so nothing stops compiling; at runtime the module is
# simply not installed, which is a state the installer already handles because
# it is the normal state for a DFM.
#
# Nothing here affects startup. It removes code that was never loaded - four
# args say the features behind it are off - and a smaller APK is marginally
# kinder to page cache, not worse.
sed_i '/^  xr_module_desc,$/d' \
    chrome/android/modules/chrome_feature_modules.gni

# --- Keep media playing when the browser goes to the background.
#
# Chromium suspends media in a hidden page on Android. The path is
# WebMediaPlayerImpl::ShouldPausePlaybackWhenHidden(), which ends in
#
#     if (IsBackgroundSuspendEnabled(this)) {
#       return !preserve_audio || (IsResumeBackgroundVideosEnabled() &&
#                                  !allow_background_video_playback_);
#     }
#     ...
#     return !preserve_audio;
#
# and IsBackgroundSuspendEnabled() is exactly one command-line switch away
# from false:
#
#     bool IsBackgroundSuspendEnabled(const WebMediaPlayerImpl* wmpi) {
#       if (base::CommandLine::ForCurrentProcess()->HasSwitch(
#               switches::kDisableBackgroundMediaSuspend)) {
#         return false;
#       }
#       return wmpi->IsBackgroundMediaSuspendEnabled();
#     }
#
# With it set, a hidden player falls through to `return !preserve_audio` and
# anything with unmuted audio keeps playing. A muted video still pauses, which
# is the right answer - nobody is listening to it, and letting it run would
# burn battery for a picture no one can see.
#
# A switch rather than a feature this time, and unusually it needs no plumbing:
# the value is read in the renderer, and content/browser/renderer_host/
# render_process_host_impl.cc already carries kDisableBackgroundMediaSuspend in
# the kSwitchNames list it copies from the browser command line into every
# renderer it spawns. Appending it before native starts is enough.
#
# No setting for it. "Media keeps playing" is what a browser should do; making
# it optional would mean shipping the wrong behaviour by default and hoping
# people find the switch.
sed_i 's|            FontPreloader.getInstance().load(getApplication());|&\n\n            // Aerium: media keeps playing when the browser is backgrounded or\n            // the screen goes off - see theme.sh. Read in the renderer, and\n            // forwarded there by content on its own, so setting it here is\n            // the whole change. Behind a switch now, because it is a behaviour\n            // change people can reasonably want either way. Defaulted on: that\n            // is what this build has always done.\n            if (ChromeSharedPreferences.getInstance()\n                    .readBoolean(ChromePreferenceKeys.AERIUM_BACKGROUND_PLAYBACK, true)) {\n                CommandLine.getInstance().appendSwitch("disable-background-media-suspend");\n            }|' \
    $CAI

# --- The other half of background playback: pages that pause themselves.
#
# Disabling media suspend keeps the pipeline alive, but plenty of sites stop
# their own video the moment the Page Visibility API says the tab went away -
# a `visibilitychange` listener calling video.pause(), or a poll of
# `document.visibilityState`. YouTube is the famous one. The decoder is
# perfectly happy to keep going; the page has simply told it to stop.
#
# The extensions people install to work around this all do the same three
# things: force `document.hidden` to false, force `document.visibilityState`
# to "visible", and swallow the `visibilitychange` event. Doing it in the
# engine means no extension to install, no per-site script injection, and
# nothing in the page for a site to notice.
#
# It is still a lie told to a web page, so it is kept as small as a lie can
# be. Three separate limits:
#
#   * Only while the page is actually making sound. PageScheduler already
#     tracks that - it is what lights up the tab's audio indicator - and it
#     holds the state for a few seconds after the sound stops, so a brief gap
#     between tracks does not flip the page back. A silent background tab is
#     told the plain truth, exactly as before.
#   * Only the two web-facing accessors. Document::IsPageVisible(), which the
#     rest of Blink reads to decide about animations, throttling, canvas and
#     compositing, is left completely alone - so a backgrounded page still
#     costs what it always did. The two callers inside
#     DidChangeVisibilityState() that happened to go through hidden() are
#     moved onto IsPageVisible() so they keep seeing the truth too.
#   * Only on the way out. Becoming visible is always announced, so a page
#     that paused itself for reasons of its own still learns the user is
#     back, and a page that is being unloaded is told the truth throughout.
DOCUMENT_CC=third_party/blink/renderer/core/dom/document.cc

sed_i 's|#include "third_party/blink/renderer/platform/scheduler/public/frame_or_worker_scheduler.h"|&\n#include "third_party/blink/renderer/platform/scheduler/public/page_scheduler.h"|' \
    $DOCUMENT_CC

sed_i 's|^V8VisibilityState Document::visibilityState() const {$|namespace {\n\n// Aerium: whether this document should be told it is visible when it is not.\n// True for a backgrounded page that is still playing sound to someone. See\n// theme.sh for why the test is drawn exactly here.\nbool AeriumAudibleInBackground(const Document\& document) {\n  if (document.IsPageVisible() \|\| document.UnloadStarted()) {\n    return false;\n  }\n  LocalFrame* frame = document.GetFrame();\n  if (!frame \|\| !frame->GetPage()) {\n    return false;\n  }\n  PageScheduler* page_scheduler = frame->GetPage()->GetPageScheduler();\n  return page_scheduler \&\& page_scheduler->IsAudioPlaying();\n}\n\n}  // namespace\n\n&|' \
    $DOCUMENT_CC

sed_i 's|^  return !IsPageVisible();$|  // Aerium: audible in the background counts as visible - see theme.sh.\n  if (AeriumAudibleInBackground(*this)) {\n    return false;\n  }\n&|' \
    $DOCUMENT_CC

sed_i '/^  DispatchEvent(\*Event::CreateBubble(event_type_names::kVisibilitychange));$/,/^      \*Event::CreateBubble(event_type_names::kWebkitvisibilitychange));$/c\
  // Aerium: a page that went to the background while playing sound has been\
  // told it is still visible, so the event that would contradict that is\
  // withheld. Becoming visible is always announced. See theme.sh.\
  if (!AeriumAudibleInBackground(*this)) {\
    DispatchEvent(*Event::CreateBubble(event_type_names::kVisibilitychange));\
    // Also send out the deprecated version until it can be removed.\
    DispatchEvent(\
        *Event::CreateBubble(event_type_names::kWebkitvisibilitychange));\
  }' \
    $DOCUMENT_CC

# The two internal readers below wanted the real state and only used hidden()
# because it was the shorter spelling; point them at the source instead.
sed_i 's|^  if (hidden() && canvas_font_cache_)$|  if (!IsPageVisible() \&\& canvas_font_cache_)|' \
    $DOCUMENT_CC

sed_i 's|^    interactive_detector->OnPageHiddenChanged(hidden());$|    interactive_detector->OnPageHiddenChanged(!IsPageVisible());|' \
    $DOCUMENT_CC

# --- HTTPS-First Balanced Mode by default: upgrades navigations to HTTPS
# when a site is expected to support it, without the disruptive full-site
# interstitials of strict HTTPS-Only Mode. Stock Chromium ships this off,
# with a gradual auto-enable heuristic for "typically secure" users that is
# itself feature-flagged off at this version - so nobody gets it without
# this flip. User-changeable in Settings -> Privacy and security -> Security.
sed -i 's/prefs::kHttpsFirstBalancedMode, false,/prefs::kHttpsFirstBalancedMode, true,/' \
    chrome/browser/ui/browser_ui_prefs.cc

# --- Global Privacy Control (https://w3c.github.io/gpc/). Chromium 152
# implements this itself, in third_party/blink/renderer/modules/
# global_privacy_control/ - a directory that does not exist at 151. Aerium
# used to add the whole feature by hand: the navigator.globalPrivacyControl
# IDL attribute, its Navigator member, and the Sec-GPC header at all four
# request paths. All six substitutions are gone, because upstream now covers
# every one of them.
#
# Keeping ours was not merely redundant, it broke the build. Upstream declares
# the attribute on a mixin that Navigator includes, so our navigator.idl line
# became a second declaration on the same interface and the generated bindings
# failed to compile: "redefinition of GlobalPrivacyControlAttributeGetCallback"
# in v8_navigator.cc, one definition from each. Run 81 died on it after 1h36m.
#
# What replaces them is one flag. Upstream gates both halves of the feature on
# blink::features::kGlobalPrivacyControlForce: the JS property through the
# GlobalPrivacyControl runtime feature it implies, and the header itself
# through IsGlobalPrivacyControlEnabled(), which
# browser_initiated_resource_request.cc consults at the same call site our sed
# used to patch - it even removes and re-sets the header the same way. The
# runtime feature ships off, so it is turned on here.
#
# Behaviour is unchanged from Aerium's own version: sent unconditionally, no
# per-site toggle. The ipc_utils.cc navigation-header allowlist needs no
# widening either, since 152 added net::HttpRequestHeaders::kSecGPC to it.
#
# Desktop is still on 151 and keeps its hand-written GPC patches. When Linux
# and Windows move to 152 they will hit this same collision and need the same
# treatment.
sed_i '/^      name: "GlobalPrivacyControlForce",$/a\
      status: "stable",' \
    third_party/blink/renderer/platform/runtime_enabled_features.json5

# --- Widevine, toggleable and off by default (Brave-style). Aerium doesn't
# bundle Google's proprietary CDM binary, but the interface is compiled in
# (enable_widevine defaults to true for is_android and would default to true
# for Chrome-branded desktop builds too - see third_party/widevine/cdm/
# widevine.gni). Registering it unconditionally means every DRM-gated site
# can silently probe for it, so gate registration on a new chrome://flags
# entry instead. No ungoogled-chromium existing_switch_flag_entries.h here
# (Vanadium isn't ungoogled-chromium-based), so the flag is added directly
# to the main kFeatureEntries array.
#
# The switch this gate reads is now set from two places, and both are fine
# because both land before native starts or before the CDM is registered:
# this flag, and the DRM switch on Settings -> Advanced -> Media, which
# ChromeApplicationImpl turns into the same --enable-widevine. The Media
# switch is the one to point people at; the flag predates it and still works.
#
# Worth noting why the flag works here and did not on desktop. Android
# registers CDMs from BrowserMainLoop::PostCreateThreads, which is after
# ChromeBrowserMainParts has turned flags into switches. On Linux the CDM has
# to be loaded before the zygote is sandboxed, which is before any of that -
# so the identical flag there was dead, and the desktop repos gate on a Local
# State pref read in PreCreateThreads instead.
sed -i '/^const FeatureEntry kFeatureEntries\[\] = {$/a\
    {"enable-widevine",\
     "Enable Widevine DRM",\
     "Registers the Widevine CDM so DRM-protected sites can play back content. Off by default - Aerium flag.",\
     kOsAll, SINGLE_VALUE_TYPE("enable-widevine")},
' chrome/browser/about_flags.cc
sed -i '/^  AddWidevine(cdms);$/c\
  // Off by default - Aerium doesn'"'"'t bundle Google'"'"'s proprietary CDM, and\
  // registering it unconditionally means every DRM-gated site can silently\
  // probe for it. Users who want DRM playback turn it on at\
  // chrome://flags/#enable-widevine.\
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("enable-widevine")) {\
    AddWidevine(cdms);\
  }' chrome/common/media/cdm_registration.cc

# --- extension-mime-request-handling flag: controls how CRX/User Script
# MIME-type downloads are handled (silently treat as a regular file, or
# always prompt before installing). This flag doesn't exist on Vanadium at
# all - it's added by ungoogled-chromium's own
# add-flag-to-configure-extension-downloading.patch, which Windows/Linux get
# for free via their shared ungoogled-chromium core, but Vanadium carries no
# ungoogled-chromium patches. Ported here in full (flag definition + the
# behavior it gates) rather than skipped, for parity across all three
# platforms. Verified against Chromium 151.0.7922.71 source.
#
# Choice array + flag entry go straight into about_flags.cc's
# kFeatureEntries, same as the enable-widevine flag above - no separate
# ungoogled_flag_choices.h/ungoogled_flag_entries.h indirection needed since
# Vanadium isn't ungoogled-chromium-based.
sed -i '/^const FeatureEntry kFeatureEntries\[\] = {$/i\
const FeatureEntry::Choice kExtensionHandlingChoices[] = {\
    {flags_ui::kGenericExperimentChoiceDefault, "", ""},\
    {"Download as regular file",\
     "extension-mime-request-handling",\
     "download-as-regular-file"},\
    {"Always prompt for install",\
     "extension-mime-request-handling",\
     "always-prompt-for-install"},\
};\
' chrome/browser/about_flags.cc
sed -i '/^const FeatureEntry kFeatureEntries\[\] = {$/a\
    {"extension-mime-request-handling",\
     "Handling of extension MIME type requests",\
     "Used when deciding how to handle a request for a CRX or User Script MIME type. Aerium flag, ported from ungoogled-chromium.",\
     kOsAll, MULTI_VALUE_TYPE(kExtensionHandlingChoices)},\
' chrome/browser/about_flags.cc

# The behavior the flag gates: skip the install-confirmation prompt for
# trusted-site extension downloads unless "always prompt for install" is
# selected, and treat CRX/user-script downloads as regular files when
# "download as regular file" is selected.
sed -i '/^#include "extensions\/buildflags\/buildflags.h"$/i\
#include "extensions/browser/extension_util.h"' \
    chrome/browser/download/download_target_determiner.cc
sed -i '/^  \/\/ Don.t prompt for extension downloads if the installation site is allow$/,/^    return DownloadConfirmationReason::NONE;$/c\
  if (!extensions::util::ShouldDownloadAsRegularFile()) {\
    // Don'"'"'t prompt for extension downloads.\
    if (download_crx_util::IsTrustedExtensionDownload(GetProfile(), *download_) ||\
        filename.MatchesExtension(extensions::kExtensionFileExtension))\
      return DownloadConfirmationReason::NONE;\
  }' chrome/browser/download/download_target_determiner.cc
sed -i '/^bool ExtensionManagement::IsOffstoreInstallAllowed($/,/^    const GURL\& referrer_url) const {$/{/^    const GURL\& referrer_url) const {$/a\
  const base::CommandLine\& command_line =\
      *base::CommandLine::ForCurrentProcess();\
  if (command_line.HasSwitch("extension-mime-request-handling") \&\&\
      command_line.GetSwitchValueASCII("extension-mime-request-handling") ==\
      "always-prompt-for-install") {\
    return true;\
  }
}' chrome/browser/extensions/extension_management.cc
sed -i '/^bool IsExtensionDownload(const download::DownloadItem\& download_item) {$/i\
bool ShouldDownloadAsRegularFile() {\
    const base::CommandLine\& command_line =\
        *base::CommandLine::ForCurrentProcess();\
    return command_line.HasSwitch("extension-mime-request-handling") \&\&\
        command_line.GetSwitchValueASCII("extension-mime-request-handling") ==\
        "download-as-regular-file";\
}\
' extensions/browser/extension_util.cc
# 152 dropped the UserScript::IsURLUserScript() arm of this condition, so the
# old multi-line anchor is gone; the check is now a single line.
sed -i '/^  if (download_item.GetMimeType() == Extension::kMimeType) {$/{n
s/^    return true;$/    return !ShouldDownloadAsRegularFile();/
}' extensions/browser/extension_util.cc
sed -i '/^\/\/ Returns true if this is an extension download\. This also considers user$/i\
// Returns true if the user wants all extensions to be downloaded as regular\
// files.\
bool ShouldDownloadAsRegularFile();\
' extensions/browser/extension_util.h

# Seed the flag on by default at "Always prompt for install" (@2) - a
# security backstop, not an opt-in feature the way the rest of Aerium's
# privacy flags are treated, so it stays the one silently-seeded default.
# Matches Windows/Linux's default-flags.patch exactly (same shared file).
sed -i 's/^  registry->RegisterListPref(prefs::kAboutFlagsEntries);$/  \/\/ Silently seed just this one flag by default (security backstop - don'"'"'t\
  \/\/ silently download-and-run a CRX\/user-script MIME type without asking\
  \/\/ first). Aerium'"'"'s other recommended privacy flags are listed as opt-in\
  \/\/ choices instead, so picking them is a visible decision.\
  base::ListValue default_flags;\
  default_flags.Append("extension-mime-request-handling@2");\
  registry->RegisterListPref(prefs::kAboutFlagsEntries,\
                             std::move(default_flags));/' \
    components/webui/flags/pref_service_flags_storage.cc

# --- The logo in the search widget.
#
# Reported against this build: the icon in the widget's search bar sits on a
# white tile and looks small and off-centre inside it. Both symptoms are one
# line. quick_action_search_widget_{medium,small,xsmall}_layout.xml all set
#
#     android:src="@mipmap/app_icon"
#
# which is the LAUNCHER icon. When this was written res/icons.sh drew that as a
# legacy, non-adaptive bitmap on a flat white field with the mark at 54% of the
# file's width, and the widget inherited both: the field filled the icon slot
# and the mark shrank to just over half of it.
#
# That script no longer paints a field and now draws the mark at 100%, so the
# symptom this fixed is gone at the source. The dedicated drawable stays anyway,
# and stays for its second reason rather than its first: a launcher icon is
# built for a 108dp adaptive canvas with a 72dp safe zone, and a widget slot has
# no safe zone, so pointing the widget at the launcher icon would still give up
# a third of the box to margin the widget does not need.
#
# Nothing about the layout is wrong, which is worth saying because "not well
# aligned" points at the layout: the medium bar is 50dp tall with a 28dp icon
# and 11dp margins above and below, so the slot is centred to the pixel. It is
# the picture inside the slot that is small and surrounded by white.
#
# So the widget gets a drawable that is only the logo: no field, and no
# safe-zone scaling, so the mark fills the box it is given.
#
# Derived from res/layered_app_icon_foreground.xml rather than written out
# again. That file already carries the artwork as vector paths, and this repo
# already maintains two copies of the same geometry by hand - that one and
# themed_app_icon.xml, which differ on purpose and document why. A third would
# be the one that quietly drifts. What has to come off is its <group>, which
# exists only to scale the mark to 0.36 and centre it inside the 108dp adaptive
# canvas of which a launcher shows the middle 72dp. A widget icon has no safe
# zone to respect, so the group goes and the paths stay untouched.
AERIUM_QAS=chrome/browser/ui/android/quickactionsearchwidget/java/res
AERIUM_QAS_ICON=$AERIUM_QAS/drawable/aerium_widget_icon.xml
if [ -e "$SCRIPT_DIR/res/layered_app_icon_foreground.xml" ] && [ -d "$AERIUM_QAS/drawable" ]; then
    sed -e 's|android:width="108dp"|android:width="24dp"|' \
        -e 's|android:height="108dp"|android:height="24dp"|' \
        -e '/^  <group$/,/^      android:translateY="163.84">$/d' \
        -e '/^  <\/group>$/d' \
        "$SCRIPT_DIR/res/layered_app_icon_foreground.xml" > "$AERIUM_QAS_ICON"

    # Check the outcome, not the substitution. A sed range that stops matching
    # would leave the <group> in place and the icon would come out at 36% of
    # its box - the same too-small mark, only now without the white field to
    # make it obvious that something is wrong.
    _src_paths=$(grep -c '<path' "$SCRIPT_DIR/res/layered_app_icon_foreground.xml")
    _out_paths=$(grep -c '<path' "$AERIUM_QAS_ICON")
    if grep -q 'group' "$AERIUM_QAS_ICON"; then
        echo "[aerium] FATAL: the adaptive-icon <group> survived into" \
             "$AERIUM_QAS_ICON - the widget logo would be scaled to 0.36" >&2
        return 1
    fi
    if [ "$_src_paths" != "$_out_paths" ]; then
        echo "[aerium] FATAL: $AERIUM_QAS_ICON has $_out_paths paths where" \
             "layered_app_icon_foreground.xml has $_src_paths - the range" \
             "delete took artwork with it" >&2
        return 1
    fi
    if ! grep -q 'android:width="24dp"' "$AERIUM_QAS_ICON"; then
        echo "[aerium] FATAL: $AERIUM_QAS_ICON kept the 108dp launcher canvas" >&2
        return 1
    fi
fi

# The resource list is explicit rather than a glob, so a drawable that is not
# named here is not compiled in and R.drawable has no field for it - the same
# trap as chrome_java_resources.gni further up this script.
sed_i 's|^    "java/res/drawable/hairline_border.xml",$|    "java/res/drawable/aerium_widget_icon.xml",\n&|' \
    chrome/browser/ui/android/quickactionsearchwidget/BUILD.gn

# All three sizes carry the same line. Done one sed per file rather than one
# sed over three, so that if upstream restyles one layout the failure names
# which one.
for _qas_layout in medium small xsmall; do
    sed_i 's|^            android:src="@mipmap/app_icon" />$|            android:src="@drawable/aerium_widget_icon" />|' \
        $AERIUM_QAS/layout/quick_action_search_widget_${_qas_layout}_layout.xml
done

# --- The "Select DNS provider" menu in Settings > Security.
#
# What that menu shows is DohProviderEntry::GetList() filtered twice, in
# secure_dns_util.cc: ProvidersForCountry keeps an entry whose display_globally
# is true or whose display_countries names the user's country, and
# SelectEnabledProviders then keeps the ones whose base::Feature is on. An
# entry has to survive both. That is why two of the three changes below are one
# word each - those entries were already present, already named, already
# carrying a privacy policy, and still never appeared for anyone.
#
#   * Quad9 has ui_name "Quad9 (9.9.9.9)", a privacy policy, and
#     display_globally already true, behind a feature that ships
#     FEATURE_DISABLED_BY_DEFAULT. It cleared the country filter and then died
#     at the feature filter, every time.
#   * NextDNS ships display_globally=false with display_countries={"US"},
#     though its endpoint - https://chromium.dns.nextdns.io - is the same one
#     everywhere. Outside the US the entry existed and stayed invisible.
#   * Mullvad is not in upstream's list at all.
#
# The Google removal is here and not in the desktop patch because Android is
# not ungoogled-chromium: this file arrives exactly as upstream wrote it.
# Vanadium does not touch it either - none of its patches mention
# doh_provider_entry.cc. ungoogled's own core/ungoogled-chromium/doh-changes.patch
# already drops both Google entries on desktop, so the desktop patch is
# generated against a tree where they are gone. Without this block Android
# would be the one build in the project still offering "Google (Public DNS)".
#
# Mullvad's endpoints, plain-53 IPs and DoT hostnames come from Mullvad's own
# documentation at https://mullvad.net/en/help/dns-over-https-and-dns-over-tls
# rather than from memory, and both DoH endpoints were checked to answer. Two
# variants rather than all six: the unfiltered resolver and the ad-blocking
# one. The plain-53 IPs are not decoration - they are the automatic upgrade
# mapping behind kDnsOverHttpsUpgrade, which ships ENABLED on Android, so a
# device whose system resolver is already 194.242.2.2 gets upgraded to DoH with
# nothing configured. Desktop has that feature disabled by ungoogled, so there
# the same IPs sit inert.
#
# The entries live in a file rather than inline in the perl because the text is
# full of braces and quotes, and a perl program embedded in a shell
# single-quoted string is exactly where an escaping mistake hides. This way the
# perl program contains no quoting of its own and the block is a plain heredoc.
AERIUM_DOH_FILE=$(mktemp)
export AERIUM_DOH_FILE
cat > "$AERIUM_DOH_FILE" <<'AERIUM_DOH_ENTRIES'
       {
           "Mullvad",
           MAKE_STATIC_STORAGE_BASE_FEATURE(kDohProviderMullvad,
                                            base::FEATURE_ENABLED_BY_DEFAULT),
           {"194.242.2.2", "2a07:e340::2"},
           /*dns_over_tls_hostnames=*/{"dns.mullvad.net"},
           "https://dns.mullvad.net/dns-query",
           /*ui_name=*/"Mullvad DNS",
           /*privacy_policy=*/"https://mullvad.net/en/help/no-logging-data-policy",
           /*display_globally=*/true,
           /*display_countries=*/{},
       },
       {
           "MullvadAdblock",
           MAKE_STATIC_STORAGE_BASE_FEATURE(kDohProviderMullvadAdblock,
                                            base::FEATURE_ENABLED_BY_DEFAULT),
           {"194.242.2.3", "2a07:e340::3"},
           /*dns_over_tls_hostnames=*/{"adblock.dns.mullvad.net"},
           "https://adblock.dns.mullvad.net/dns-query",
           /*ui_name=*/"Mullvad DNS (ad blocking)",
           /*privacy_policy=*/"https://mullvad.net/en/help/no-logging-data-policy",
           /*display_globally=*/true,
           /*display_countries=*/{},
       },
AERIUM_DOH_ENTRIES
perl -0777 -pi -e '
    BEGIN {
        local $/;
        open my $fh, "<", $ENV{AERIUM_DOH_FILE}
            or die "[aerium] FATAL: cannot read the Mullvad entries file\n";
        $ins = <$fh>;
    }
    for my $id ("Google", "GoogleDns64") {
        s{ {7}\{\n {11}"\Q$id\E",\n.*?\n {7}\},\n}{}s
            or die "[aerium] FATAL: no \"$id\" entry in doh_provider_entry.cc "
                 . "- upstream renamed or restructured the DoH provider list\n";
    }
    s{( {7}\{\n {11}"NextDns",\n)}{$ins$1}
        or die "[aerium] FATAL: no NextDns entry to insert Mullvad before\n";
    s{(/\*ui_name=\*/"NextDNS",\n {11}/\*privacy_policy=\*/"https://nextdns.io/privacy",\n {11}/\*display_globally=\*/)false(,\n {11}/\*display_countries=\*/\{)"US"(\},)}{$1 . "true" . $2 . $3}e
        or die "[aerium] FATAL: NextDNS is no longer US-only in the way this "
             . "expected - re-read the entry before changing it\n";
    s{("Quad9Secure",\n {11}MAKE_STATIC_STORAGE_BASE_FEATURE\(kDohProviderQuad9Secure,\n {44}base::FEATURE_)DISABLED(_BY_DEFAULT\))}{$1 . "ENABLED" . $2}e
        or die "[aerium] FATAL: the Quad9Secure feature is no longer disabled "
             . "by default - upstream may have fixed this; drop the change\n";
' net/dns/public/doh_provider_entry.cc
rm -f "$AERIUM_DOH_FILE"
unset AERIUM_DOH_FILE

# --- Default search engines: replace every per-country engine list with one
# fixed privacy-focused set - DuckDuckGo (default), Startpage, Brave Search,
# Mojeek, Qwant, Ecosia, degoog and the two DuckDuckGo no-JS variants. Brave,
# Mojeek, Qwant and Ecosia are upstream entries already
# (ids 109, 103, 94 and 101), so they cost a list entry each and no new
# definition; only the DuckDuckGo variants and degoog needed defining. Stock keeps
# Google-led per-country lists; ungoogled-style builds leave the user with a
# broken/absent default until they configure one manually. Any other engine
# can still be added by hand in settings.
#
# Mechanics (verified against Chromium 151.0.7922.71 source):
# - prepopulated_engines.json is the master engine list (startpage already
#   exists upstream, id 113, with a bundled icon; the DuckDuckGo variants and
#   degoog are new entries). New IDs take the free slots just above
#   upstream's highest (116), with kMaxPrepopulatedEngineID raised to match -
#   exactly what the comment above that constant instructs.
#   kCurrentDataVersion is raised so profiles created by earlier builds pick
#   up the new list on update.
#
#   IDs must stay <= 1000. Using 1001+ to dodge upstream collisions (which an
#   earlier revision did) breaks two Chromium invariants:
#     * template_url_data.cc GenerateGUID() only emits the deterministic sync
#       GUID for prepopulate_id in [1, 1000]; above that each construction
#       gets a random UUID, which is precisely what the deterministic GUID
#       exists to avoid ("to make sure sync doesn't incur in duplicates for
#       prepopulated engines"), so synced profiles accumulate duplicate rows
#       and duplicate keywords for the same engine.
#     * search_engine_choice_service.cc treats
#       prepopulate_id > kMaxPrepopulatedEngineID as "distribution custom
#       engine"; raising the constant to 1003 to cover 1001+ IDs disabled
#       that classification for genuinely custom engines too.
#   On a Chromium bump, check whether upstream claimed 117-119; if so move
#   ours to the next free IDs below 1000.
# - regional_settings.json's "ZZ" element is the fallback list for countries
#   without their own entry; GetRegionalSettings() in
#   regional_capabilities_utils.cc is redirected to always use it
#   (CountryId() == "ZZ" == unknown country, see country_codes.h), which
#   makes the ZZ list the single list for every country.
# - GetPrepopulatedFallbackSearch() in template_url_prepopulate_data.cc picks
#   the engine it looks up by ID first, falling back to the list head;
#   and it already points at duckduckgo.id here, because Vanadium's
#   0114-set-default-search-engine-to-DuckDuckGo.patch retargets the stock
#   google.id lookup. That is the default we want, so this script leaves it
#   alone. The desktop repos have no Vanadium and name duckduckgo.id in their
#   own patch instead.
SE_DEFS=third_party/search_engines_data/resources/definitions
sed_i '/^    "ecosia": {$/i\
    "duckduckgo_html": {\
      "name": "DuckDuckGo HTML",\
      "keyword": "html.duckduckgo.com",\
      "favicon_url": "https://duckduckgo.com/favicon.ico",\
      "search_url": "https://html.duckduckgo.com/html/?q={searchTerms}",\
      "suggest_url": "https://duckduckgo.com/ac/?q={searchTerms}\&type=list",\
      "type": "SEARCH_ENGINE_DUCKDUCKGO",\
      "id": 117\
    },\
\
    "duckduckgo_lite": {\
      "name": "DuckDuckGo Lite",\
      "keyword": "lite.duckduckgo.com",\
      "favicon_url": "https://duckduckgo.com/favicon.ico",\
      "search_url": "https://lite.duckduckgo.com/lite/?q={searchTerms}",\
      "suggest_url": "https://duckduckgo.com/ac/?q={searchTerms}\&type=list",\
      "type": "SEARCH_ENGINE_DUCKDUCKGO",\
      "id": 118\
    },\
' $SE_DEFS/prepopulated_engines.json
# degoog replaces SearXNG, and deliberately reuses its id. Chromium keys a
# prepopulated engine's row in the profile keyword database by prepopulate_id,
# so keeping 119 turns the SearXNG row shipped in earlier builds INTO the
# degoog row on update, rather than leaving an orphan beside a new one.
#
# The URLs are the ones degoog publishes in its own OpenSearch document at
# https://degoog.org/opensearch.xml, not guessed from the address bar. All
# three were fetched and checked: /search?q= returns 200, the suggest endpoint
# returns well-formed OpenSearch JSON (["priv",["privalia", ...]]), and the
# favicon is a real 15 KB image/x-icon.
#
# Anchored on "duckduckgo" rather than on "seznam" as searx was, so the entry
# lands in alphabetical order (daum, degoog, duckduckgo, ...). JSON key order
# has no effect on behaviour; this is only so the file stays readable.
sed_i '/^    "duckduckgo": {$/i\
    "degoog": {\
      "name": "degoog",\
      "keyword": "degoog.org",\
      "favicon_url": "https://degoog.org/public/favicon/favicon.ico",\
      "search_url": "https://degoog.org/search?q={searchTerms}",\
      "suggest_url": "https://degoog.org/api/suggest/opensearch?q={searchTerms}",\
      "type": "SEARCH_ENGINE_OTHER",\
      "id": 119\
    },\
' $SE_DEFS/prepopulated_engines.json
# kCurrentDataVersion decides whether Chromium re-merges the prepopulated
# engine list into an existing profile's keyword database: the merge runs
# only when this value is above the one recorded in that database, and
# components/search_engines/util.cc DCHECKs that it never moves backwards
# ("If a data change happened, it should not cause a version downgrade").
# The three engines added above therefore reach an already-installed profile
# only if this number rises.
#
# It used to be hardcoded, which was a slow-acting trap of exactly the kind
# sed_i exists to catch, except no sed_i could catch it: upstream's own value
# climbs about one per milestone (209 at 151, 210 at 152), so a fixed number
# is overtaken eventually, and on that day the write silently becomes a
# downgrade. The substitution still changes the file, so it still reports as
# applied - the refresh just stops happening.
#
# Deriving it from upstream with a constant offset removes the cliff: it can
# never be overtaken, and it only decreases if upstream's does. The offset
# started at 41, reproducing the 251 this used to hardcode, so no
# already-shipped profile saw its version go backwards.
#
# It is 43 now, for 253, and that is a fix as much as a bump. The merge is
# gated on a strict inequality - template_url_prepopulate_data_resolver.cc
# returns nullopt unless keywords_metadata.builtin_keyword_data_version is
# strictly BELOW kCurrentDataVersion - so a value that stays put reaches
# nobody who already has a profile. Adding Brave, Mojeek, Qwant and Ecosia
# left the offset at 41, which meant existing installs would have kept the
# old five-engine list; only a fresh profile would have seen the new ones.
# Raising it now delivers those four as well as this change.
#
# So: raise this whenever the engine list changes, not only when an id is
# added. A new entry that nothing merges is invisible.
SE_DATA_VERSION_OFFSET=44
SE_DATA_VERSION=
# The engines inserted above claim ids 117-119, sitting immediately above
# upstream's highest (116 at both 151 and 152). Unlike the data version these
# ids cannot be derived, and must not be: Chromium stores a prepopulated
# engine's id in the profile's keyword database, so renumbering them between
# releases would orphan the rows existing installs already hold instead of
# updating them. That makes the range something upstream can walk into but we
# cannot walk away from, so it is checked rather than computed.
AERIUM_FIRST_ENGINE_ID=117
AERIUM_MAX_ENGINE_ID=119
# All of this is guarded on the file existing rather than failing outright
# when it is absent, because devutils/verify-seds.sh sources this over an
# empty tree to collect sed targets. Returning early there would cut the
# collection short and drop every substitution below this line from the check.
if [ -e $SE_DEFS/prepopulated_engines.json ]; then
    SE_DATA_VERSION=$(grep -o '"kCurrentDataVersion": [0-9]\+' \
        $SE_DEFS/prepopulated_engines.json | grep -o '[0-9]\+' || true)
    if [ -z "$SE_DATA_VERSION" ]; then
        echo "[aerium] FATAL: no kCurrentDataVersion in" \
             "$SE_DEFS/prepopulated_engines.json - upstream renamed it?" >&2
        return 1
    fi

    SE_MAX_ENGINE_ID=$(grep -o '"kMaxPrepopulatedEngineID": [0-9]\+' \
        $SE_DEFS/prepopulated_engines.json | grep -o '[0-9]\+' || true)
    if [ -z "$SE_MAX_ENGINE_ID" ]; then
        echo "[aerium] FATAL: no kMaxPrepopulatedEngineID in" \
             "$SE_DEFS/prepopulated_engines.json - upstream renamed it?" >&2
        return 1
    fi
    # Upstream reaching 117 means one of its engines now wears an id Aerium
    # also hands out, and nothing downstream would notice: two entries with
    # one id is a data conflict, not a build error.
    if [ "$SE_MAX_ENGINE_ID" -ge "$AERIUM_FIRST_ENGINE_ID" ]; then
        echo "[aerium] FATAL: upstream kMaxPrepopulatedEngineID is now" \
             "$SE_MAX_ENGINE_ID, which collides with the ids Aerium adds" \
             "($AERIUM_FIRST_ENGINE_ID-$AERIUM_MAX_ENGINE_ID)." >&2
        echo "[aerium]        Renumber the engines inserted in theme.sh above" \
             "upstream's range and move both constants with them. Existing" \
             "profiles keep the old ids, so treat that as a migration." >&2
        return 1
    fi
    # And the constants only mean anything if they still describe the blobs
    # inserted above, which carry their ids literally.
    _id=$AERIUM_FIRST_ENGINE_ID
    while [ "$_id" -le "$AERIUM_MAX_ENGINE_ID" ]; do
        if ! grep -qE "\"id\": $_id,?$" $SE_DEFS/prepopulated_engines.json
        then
            echo "[aerium] FATAL: no engine with id $_id in" \
                 "$SE_DEFS/prepopulated_engines.json - theme.sh's added" \
                 "engines and AERIUM_FIRST/MAX_ENGINE_ID have drifted apart" >&2
            return 1
        fi
        _id=$((_id + 1))
    done
fi
sed_i 's/"kMaxPrepopulatedEngineID": [0-9]\+,/"kMaxPrepopulatedEngineID": '"$AERIUM_MAX_ENGINE_ID"',/; s/"kCurrentDataVersion": [0-9]\+/"kCurrentDataVersion": '"$((SE_DATA_VERSION + SE_DATA_VERSION_OFFSET))"'/; s/"name": "startpage",/"name": "Startpage",/' \
    $SE_DEFS/prepopulated_engines.json
sed_i '/^    "ZZ": {$/,/^    }$/{s/^        "&google",$/        "\&duckduckgo",\n        "\&startpage",\n        "\&brave",\n        "\&mojeek",\n        "\&qwant",\n        "\&ecosia",\n        "\&degoog",\n        "\&duckduckgo_lite",\n        "\&duckduckgo_html"/; /^        "&bing",$/d; /^        "&yahoo"$/d}' \
    $SE_DEFS/regional_settings.json
sed_i 's|auto iter = TemplateURLPrepopulateData::kRegionalSettings.find(country_id);|// Aerium: every country gets the same privacy-focused engine list - the\n  // "ZZ" default in regional_settings.json - instead of per-country\n  // Google-led lists.\n  auto iter = TemplateURLPrepopulateData::kRegionalSettings.find(CountryId());|' \
    components/regional_capabilities/regional_capabilities_utils.cc
# No sed for the default engine. Vanadium's own
# 0114-set-default-search-engine-to-DuckDuckGo.patch already points
# GetPrepopulatedFallbackSearch at duckduckgo.id, which is what we want, so the
# right change here is the absence of one - an override that rewrites a value to
# the value it already has is a sed that breaks the day upstream agrees with us.
# The desktop repos have no Vanadium, so their patch names duckduckgo.id itself.

# --- Fingerprint protection parity with Windows: canvas image-data noise,
# canvas measureText noise, get*ClientRect*() noise, and WebGL renderer/
# vendor spoofing. Windows ships these as user-toggleable ungoogled-chromium/
# bromite chrome://flags entries seeded on by default; Vanadium has no
# equivalent flags-extension mechanism and no components/ungoogled switches
# target, so instead of porting the command-line-switch delivery machinery,
# these are wired as always-on via runtime_enabled_features.json5's
# status:"stable" (compile-time default-on, verified against Chromium
# 151.0.7922.71 source: no flag needed, no extra BUILD.gn deps needed).
sed -i '/^  data: \[$/a\
    {\
      name: "FingerprintingClientRectsNoise",\
      status: "stable",\
    },\
    {\
      name: "FingerprintingCanvasMeasureTextNoise",\
      status: "stable",\
    },\
    {\
      name: "FingerprintingCanvasImageDataNoise",\
      status: "stable",\
    },' \
    third_party/blink/renderer/platform/runtime_enabled_features.json5

# get*ClientRect*() noise: precompute a per-document scale factor, applied to
# Element.getClientRects()/getBoundingClientRect() and Range.getClientRects()/
# getBoundingClientRect() readouts.
sed -i '/^#include "base\/notreached.h"$/a\
#include "base/rand_util.h"' \
    third_party/blink/renderer/core/dom/document.cc
sed -i '/^  DCHECK(agent_);$/a\
  if (RuntimeEnabledFeatures::FingerprintingClientRectsNoiseEnabled()) {\
    // Precompute -0.0003% to 0.0003% noise factor for get*ClientRect*() fingerprinting\
    noise_factor_x_ = 1 + (base::RandDouble() - 0.5) * 0.000003;\
    noise_factor_y_ = 1 + (base::RandDouble() - 0.5) * 0.000003;\
  }' \
    third_party/blink/renderer/core/dom/document.cc
sed -i '/^SelectorQueryCache& Document::GetSelectorQueryCache() {$/i\
double Document::GetNoiseFactorX() {\
  return noise_factor_x_;\
}\
\
double Document::GetNoiseFactorY() {\
  return noise_factor_y_;\
}\
' \
    third_party/blink/renderer/core/dom/document.cc
sed -i '/^  V8VisibilityState visibilityState() const;$/i\
  // Values for get*ClientRect fingerprint deception\
  double GetNoiseFactorX();\
  double GetNoiseFactorY();\
' \
    third_party/blink/renderer/core/dom/document.h
sed -i '/^  base::ElapsedTimer start_time_;$/a\
\
  double noise_factor_x_ = 1;\
  double noise_factor_y_ = 1;' \
    third_party/blink/renderer/core/dom/document.h
sed -i '/^    result.emplace_back(quad.BoundingBox());$/i\
    if (RuntimeEnabledFeatures::FingerprintingClientRectsNoiseEnabled()) {\
      quad.Scale(GetDocument().GetNoiseFactorX(), GetDocument().GetNoiseFactorY());\
    }' \
    third_party/blink/renderer/core/dom/element.cc
sed -i '/AdjustRectForScrollAndAbsoluteZoom(result,/{n;a\
  if (RuntimeEnabledFeatures::FingerprintingClientRectsNoiseEnabled()) {\
    result.Scale(GetDocument().GetNoiseFactorX(), GetDocument().GetNoiseFactorY());\
  }
}' \
    third_party/blink/renderer/core/dom/element.cc
sed -i '/^  return MakeGarbageCollected<DOMRectList>(quads);$/i\
  if (RuntimeEnabledFeatures::FingerprintingClientRectsNoiseEnabled()) {\
    for (gfx::QuadF\& quad : quads) {\
      quad.Scale(owner_document_->GetNoiseFactorX(), owner_document_->GetNoiseFactorY());\
    }\
  }\
' \
    third_party/blink/renderer/core/dom/range.cc
sed -i 's/^  return DOMRect::FromRectF(BoundingRect());$/  auto rect = BoundingRect();\
  if (RuntimeEnabledFeatures::FingerprintingClientRectsNoiseEnabled()) {\
    rect.Scale(owner_document_->GetNoiseFactorX(), owner_document_->GetNoiseFactorY());\
  }\
  return DOMRect::FromRectF(rect);/' \
    third_party/blink/renderer/core/dom/range.cc

# Canvas measureText() noise: scale the returned TextMetrics by the same
# per-document factor.
sed -i '/^ private:$/i\
  void Shuffle(const double factor);\
' \
    third_party/blink/renderer/core/html/canvas/text_metrics.h
sed -i '/^void TextMetrics::Update(const Font\* font,$/i\
void TextMetrics::Shuffle(const double factor) {\
  // x-direction\
  width_ *= factor;\
  actual_bounding_box_left_ *= factor;\
  actual_bounding_box_right_ *= factor;\
\
  // y-direction\
  font_bounding_box_ascent_ *= factor;\
  font_bounding_box_descent_ *= factor;\
  actual_bounding_box_ascent_ *= factor;\
  actual_bounding_box_descent_ *= factor;\
  em_height_ascent_ *= factor;\
  em_height_descent_ *= factor;\
  baselines_->setAlphabetic(baselines_->alphabetic() * factor);\
  baselines_->setHanging(baselines_->hanging() * factor);\
  baselines_->setIdeographic(baselines_->ideographic() * factor);\
}\
' \
    third_party/blink/renderer/core/html/canvas/text_metrics.cc
sed -i '/^\/\/ IWYU pragma: no_include "base\/numerics\/clamped_math.h"$/a\
\
#include "third_party/blink/renderer/core/offscreencanvas/offscreen_canvas.h"\
#include "third_party/blink/renderer/core/frame/local_dom_window.h"' \
    third_party/blink/renderer/modules/canvas/canvas2d/base_rendering_context_2d.cc
sed -i 's/^  return MakeGarbageCollected<TextMetrics>($/  TextMetrics* text_metrics = MakeGarbageCollected<TextMetrics>(/' \
    third_party/blink/renderer/modules/canvas/canvas2d/base_rendering_context_2d.cc
sed -i 's/^      host->GetPlainTextPainter());$/      host->GetPlainTextPainter());\
\
  \/\/ Scale text metrics if enabled\
  if (RuntimeEnabledFeatures::FingerprintingCanvasMeasureTextNoiseEnabled()) {\
    if (HostAsOffscreenCanvas()) {\
      if (auto* window = DynamicTo<LocalDOMWindow>(GetTopExecutionContext())) {\
        if (window->GetFrame() \&\& window->GetFrame()->GetDocument())\
          text_metrics->Shuffle(window->GetFrame()->GetDocument()->GetNoiseFactorX());\
      }\
    } else if (canvas) {\
      text_metrics->Shuffle(canvas->GetDocument().GetNoiseFactorX());\
    }\
  }\
  return text_metrics;/' \
    third_party/blink/renderer/modules/canvas/canvas2d/base_rendering_context_2d.cc

# Canvas image-data noise: slightly perturb up to 10 pixels of ImageData
# readback (getImageData/toBlob/toDataURL) - imperceptible visually, breaks
# byte-for-byte canvas fingerprint hashing.
sed -i 's/^  include_dirs = \[\]$/  include_dirs = [\
    "\/\/third_party\/skia\/include\/private", # For shuffler in graphics\/static_bitmap_image.cc\
  ]/' \
    third_party/blink/renderer/platform/BUILD.gn
# The shuffler's per-pixel writes are raw pointer arithmetic, which Chromium
# 150's unsafe-buffers plugin rejects as -Werror under Vanadium's
# warnings-as-errors build (ungoogled-chromium-windows compiles the identical
# upstream bromite code only because it sets treat_warnings_as_errors=false).
# File-level opt-out is the mechanism docs/unsafe_buffers.md prescribes.
sed -i '/^#include "third_party\/blink\/renderer\/platform\/graphics\/static_bitmap_image.h"$/i\
#ifdef UNSAFE_BUFFERS_BUILD\
// The Bromite canvas shuffler below does raw per-pixel pointer arithmetic.\
#pragma allow_unsafe_buffers\
#endif\
' \
    third_party/blink/renderer/platform/graphics/static_bitmap_image.cc
sed -i '/^#include "base\/numerics\/checked_math.h"$/i\
#include "base/rand_util.h"\
#include "base/logging.h"' \
    third_party/blink/renderer/platform/graphics/static_bitmap_image.cc
sed -i '/^#include "third_party\/blink\/renderer\/platform\/transforms\/affine_transform.h"$/i\
#include "third_party/blink/renderer/platform/runtime_enabled_features.h"' \
    third_party/blink/renderer/platform/graphics/static_bitmap_image.cc
sed -i '/^#include "third_party\/skia\/include\/core\/SkSurface.h"$/a\
#include "third_party/skia/src/core/SkColorData.h"' \
    third_party/blink/renderer/platform/graphics/static_bitmap_image.cc
sed -i '/^}  \/\/ namespace blink$/i\
// set the component to maximum-delta if it is >= maximum, or add to existing color component (color + delta)\
#define shuffleComponent(color, max, delta) ( (color) >= (max) ? ((max)-(delta)) : ((color)+(delta)) )\
\
#define writable_addr(T, p, stride, x, y) (T*)((const char *)p + y * stride + x * sizeof(T))\
\
void StaticBitmapImage::ShuffleSubchannelColorData(const void *addr, const SkImageInfo\& info, int srcX, int srcY) {\
  auto w = info.width() - srcX, h = info.height() - srcY;\
\
  // skip tiny images; info.width()/height() can also be 0\
  if ((w < 8) || (h < 8)) {\
    return;\
  }\
\
  // generate the first random number here\
  double shuffleX = base::RandDouble();\
\
  // cap maximum pixels to change\
  auto pixels = (w + h) / 128;\
  if (pixels > 10) {\
    pixels = 10;\
  } else if (pixels < 2) {\
    pixels = 2;\
  }\
\
  auto colorType = info.colorType();\
  auto fRowBytes = info.minRowBytes(); // stride\
\
  DLOG(INFO) << "BRM: ShuffleSubchannelColorData() w=" << w << " h=" << h << " colorType=" << colorType << " fRowBytes=" << fRowBytes;\
\
  // second random number (for y/height)\
  double shuffleY = base::RandDouble();\
\
  // calculate random coordinates using bisection\
  auto currentW = w, currentH = h;\
  for(;pixels >= 0; pixels--) {\
    int x = currentW * shuffleX, y = currentH * shuffleY;\
\
    // calculate randomisation amounts for each RGB component\
    uint8_t shuffleR = base::RandIntInclusive(0, 4);\
    uint8_t shuffleG = (shuffleR + x) % 4;\
    uint8_t shuffleB = (shuffleG + y) % 4;\
\
    // manipulate pixel data to slightly change the R, G, B components\
    switch (colorType) {\
      case kAlpha_8_SkColorType:\
      {\
         auto *pixel = writable_addr(uint8_t, addr, fRowBytes, x, y);\
         auto r = SkColorGetR(*pixel), g = SkColorGetG(*pixel), b = SkColorGetB(*pixel), a = SkColorGetA(*pixel);\
\
         r = shuffleComponent(r, UINT8_MAX-1, shuffleR);\
         g = shuffleComponent(g, UINT8_MAX-1, shuffleG);\
         b = shuffleComponent(b, UINT8_MAX-1, shuffleB);\
         // alpha is left unchanged\
\
         *pixel = SkColorSetARGB(a, r, g, b);\
      }\
      break;\
      case kGray_8_SkColorType:\
      {\
         auto *pixel = writable_addr(uint8_t, addr, fRowBytes, x, y);\
         *pixel = shuffleComponent(*pixel, UINT8_MAX-1, shuffleB);\
      }\
      break;\
      case kRGB_565_SkColorType:\
      {\
         auto *pixel = writable_addr(uint16_t, addr, fRowBytes, x, y);\
         unsigned    r = SkPacked16ToR32(*pixel);\
         unsigned    g = SkPacked16ToG32(*pixel);\
         unsigned    b = SkPacked16ToB32(*pixel);\
\
         r = shuffleComponent(r, 31, shuffleR);\
         g = shuffleComponent(g, 63, shuffleG);\
         b = shuffleComponent(b, 31, shuffleB);\
\
         unsigned r16 = (r \& SK_R16_MASK) << SK_R16_SHIFT;\
         unsigned g16 = (g \& SK_G16_MASK) << SK_G16_SHIFT;\
         unsigned b16 = (b \& SK_B16_MASK) << SK_B16_SHIFT;\
\
         *pixel = r16 | g16 | b16;\
      }\
      break;\
      case kARGB_4444_SkColorType:\
      {\
         auto *pixel = writable_addr(uint16_t, addr, fRowBytes, x, y);\
         auto a = SkGetPackedA4444(*pixel), r = SkGetPackedR4444(*pixel), g = SkGetPackedG4444(*pixel), b = SkGetPackedB4444(*pixel);\
\
         r = shuffleComponent(r, 15, shuffleR);\
         g = shuffleComponent(g, 15, shuffleG);\
         b = shuffleComponent(b, 15, shuffleB);\
         // alpha is left unchanged\
\
         unsigned a4 = (a \& 0xF) << SK_A4444_SHIFT;\
         unsigned r4 = (r \& 0xF) << SK_R4444_SHIFT;\
         unsigned g4 = (g \& 0xF) << SK_G4444_SHIFT;\
         unsigned b4 = (b \& 0xF) << SK_B4444_SHIFT;\
\
         *pixel = r4 | b4 | g4 | a4;\
      }\
      break;\
      case kRGBA_8888_SkColorType:\
      {\
         auto *pixel = writable_addr(uint32_t, addr, fRowBytes, x, y);\
         auto a = SkGetPackedA32(*pixel), r = SkGetPackedR32(*pixel), g = SkGetPackedG32(*pixel), b = SkGetPackedB32(*pixel);\
\
         r = shuffleComponent(r, UINT8_MAX-1, shuffleR);\
         g = shuffleComponent(g, UINT8_MAX-1, shuffleG);\
         b = shuffleComponent(b, UINT8_MAX-1, shuffleB);\
         // alpha is left unchanged\
\
         *pixel = (a << SK_A32_SHIFT) | (r << SK_R32_SHIFT) |\
                  (g << SK_G32_SHIFT) | (b << SK_B32_SHIFT);\
      }\
      break;\
      case kBGRA_8888_SkColorType:\
      {\
         auto *pixel = writable_addr(uint32_t, addr, fRowBytes, x, y);\
         auto a = SkGetPackedA32(*pixel), b = SkGetPackedR32(*pixel), g = SkGetPackedG32(*pixel), r = SkGetPackedB32(*pixel);\
\
         r = shuffleComponent(r, UINT8_MAX-1, shuffleR);\
         g = shuffleComponent(g, UINT8_MAX-1, shuffleG);\
         b = shuffleComponent(b, UINT8_MAX-1, shuffleB);\
         // alpha is left unchanged\
\
         *pixel = (a << SK_BGRA_A32_SHIFT) | (r << SK_BGRA_R32_SHIFT) |\
                  (g << SK_BGRA_G32_SHIFT) | (b << SK_BGRA_B32_SHIFT);\
      }\
      break;\
      default:\
         // the remaining formats are not expected to be used in Chromium\
         LOG(WARNING) << "BRM: ShuffleSubchannelColorData(): Ignoring pixel format";\
         return;\
    }\
\
    // keep bisecting or reset current width/height as needed\
    if (x == 0) {\
       currentW = w;\
    } else {\
       currentW = x;\
    }\
    if (y == 0) {\
       currentH = h;\
    } else {\
       currentH = y;\
    }\
  }\
}\
\
#undef writable_addr\
#undef shuffleComponent\
' \
    third_party/blink/renderer/platform/graphics/static_bitmap_image.cc
sed -i '/^  bool IsStaticBitmapImage() const override { return true; }$/i\
  static void ShuffleSubchannelColorData(const void *addr, const SkImageInfo\& info, int srcX, int srcY);\
' \
    third_party/blink/renderer/platform/graphics/static_bitmap_image.h
sed -i '/^#include "jpeglib.h"  \/\/ for JPEG_MAX_DIMENSION$/a\
#include "third_party/blink/renderer/platform/graphics/static_bitmap_image.h"\
#include "third_party/blink/renderer/platform/runtime_enabled_features.h"' \
    third_party/blink/renderer/platform/image-encoders/image_encoder.cc
sed -i '/^                          double quality) {$/a\
  if (RuntimeEnabledFeatures::FingerprintingCanvasImageDataNoiseEnabled()) {\
    // shuffle subchannel color data within the pixmap\
    StaticBitmapImage::ShuffleSubchannelColorData(src.writable_addr(), src.info(), 0, 0);\
  }' \
    third_party/blink/renderer/platform/image-encoders/image_encoder.cc

# getImageData() noise (separate call site from toBlob/toDataURL above).
sed -i '/^      DCHECK(!bounds.intersect(SkIRect::MakeXYWH(sx, sy, sw, sh)));$/a\
    }\
    if (read_pixels_successful \&\& RuntimeEnabledFeatures::FingerprintingCanvasImageDataNoiseEnabled()) {\
      StaticBitmapImage::ShuffleSubchannelColorData(image_data_pixmap.addr(), image_data_pixmap.info(), sx, sy);' \
    third_party/blink/renderer/modules/canvas/canvas2d/base_rendering_context_2d.cc

# WebGL renderer/vendor spoofing: return generic strings for
# WEBGL_debug_renderer_info instead of the real GPU string (a strong
# fingerprinting signal). Self-contained BASE_FEATURE, no flags UI needed
# on Android - always on, matching the "Blank" choice Windows seeds by
# default (empty renderer/vendor strings).
sed -i '/^namespace blink::features {$/a\
\
BASE_FEATURE(kSpoofWebGLInfo, "SpoofWebGLInfo", base::FEATURE_ENABLED_BY_DEFAULT);\
const char kSpoofWebGLRenderer[] = "renderer";\
const char kSpoofWebGLVendor[] = "vendor";\
const base::FeatureParam<std::string> kSpoofWebGLRendererParam{\&kSpoofWebGLInfo, kSpoofWebGLRenderer, " "};\
const base::FeatureParam<std::string> kSpoofWebGLVendorParam{\&kSpoofWebGLInfo, kSpoofWebGLVendor, " "};' \
    third_party/blink/common/features.cc
sed -i '/^namespace features {$/a\
BLINK_COMMON_EXPORT BASE_DECLARE_FEATURE(kSpoofWebGLInfo);\
BLINK_COMMON_EXPORT extern const char kSpoofWebGLRenderer[];\
BLINK_COMMON_EXPORT extern const char kSpoofWebGLVendor[];\
BLINK_COMMON_EXPORT extern const base::FeatureParam<std::string> kSpoofWebGLRendererParam;\
BLINK_COMMON_EXPORT extern const base::FeatureParam<std::string> kSpoofWebGLVendorParam;' \
    third_party/blink/public/common/features.h
sed -i '/^    case WebGLDebugRendererInfo::kUnmaskedRendererWebgl:$/{n;n;i\
        if (base::FeatureList::IsEnabled(blink::features::kSpoofWebGLInfo))\
          return WebGLAny(script_state, String(blink::features::kSpoofWebGLRendererParam.Get()));
}' \
    third_party/blink/renderer/modules/webgl/webgl_rendering_context_base.cc
sed -i '/^    case WebGLDebugRendererInfo::kUnmaskedVendorWebgl:$/{n;n;i\
        if (base::FeatureList::IsEnabled(blink::features::kSpoofWebGLInfo))\
          return WebGLAny(script_state, String(blink::features::kSpoofWebGLVendorParam.Get()));
}' \
    third_party/blink/renderer/modules/webgl/webgl_rendering_context_base.cc

# --- The About page points at Aerium rather than nowhere.
#
# The desktop repos do this in chrome/common/url_constants.h, where
# kChromiumProjectURL backs the project link on chrome://settings/help. Android
# has no such link: its About screen is a Java settings fragment with three
# rows - application version, OS version, legal information - and no route back
# to the project at all. So this adds the row rather than repointing one.
#
# Opened in a Custom Tab through CustomTabActivity.showInfoPage, which is what
# Chromium itself uses for settings links. An <intent> element in the XML would
# have been shorter but hands the URL to the system, which can put a chooser in
# front of it or send it to a different browser entirely - a link to this
# build's own project should open in this build.
ACS=chrome/android/java/src/org/chromium/chrome/browser/about_settings/AboutChromeSettings.java
sed_i 's|^import org.chromium.chrome.browser.settings.ChromeBaseSettingsFragment;$|import org.chromium.chrome.browser.customtabs.CustomTabActivity;\n&|' \
    $ACS
sed_i 's|^    private static final String PREF_LEGAL_INFORMATION = "legal_information";$|&\n\n    // Aerium: see theme.sh.\n    private static final String PREF_AERIUM_PROJECT = "aerium_project";\n    private static final String AERIUM_PROJECT_URL = "https://aerium-browser.github.io";|' \
    $ACS
sed_i 's|^        p.setSummary(getString(R.string.legal_information_summary, currentYear));$|&\n\n        // Aerium: see theme.sh. Opened in a Custom Tab so a link to this\n        // build'"'"'s own project cannot be answered by a different browser.\n        Preference project = findPreference(PREF_AERIUM_PROJECT);\n        if (project != null) {\n            project.setOnPreferenceClickListener(\n                    preference -> {\n                        CustomTabActivity.showInfoPage(getActivity(), AERIUM_PROJECT_URL);\n                        return true;\n                    });\n        }|' \
    $ACS

sed_i 's|^</PreferenceScreen>$|    <Preference\n        android:key="aerium_project"\n        android:title="@string/aerium_project_title"\n        android:summary="@string/aerium_project_summary" />\n&|' \
    chrome/android/java/res/xml/about_chrome_preferences.xml

sed_i 's|^      <message name="IDS_AERIUM_PURE_BLACK_TITLE" desc=|      <message name="IDS_AERIUM_PROJECT_TITLE" desc="Title of the About-page row that opens the browser project'"'"'s own website.">\n        Aerium project\n      </message>\n      <message name="IDS_AERIUM_PROJECT_SUMMARY" desc="Summary under that row: the address it opens.">\n        aerium-browser.github.io\n      </message>\n&|' \
    chrome/browser/ui/android/strings/android_chrome_strings.grd

# --- chrome://aerium - every change this build makes to upstream Chromium.
#
# A one-person fork asks people to trust a binary nobody has audited. This is
# the smallest honest answer to that: the browser can show its own distance
# from upstream Chromium, grouped by where each change came from, with the
# number of files each one edits.
#
# The desktop repos generate their table from the patch series files. Android
# has no series: Vanadium arrives as 309 .patch files that build.sh filters and
# rebrands before git am, and Aerium's own changes are substitutions inside
# patch.sh and theme.sh rather than diffs. So the manifest is generated from
# both - devutils/generate_patch_manifest.py reads the patch files as they
# stand after the filtering, and reads the scripts through
# devutils/collect-targets.sh, which sources them with sed and perl stubbed out
# and records what each call would have written to.
#
# Deriving the counts that way rather than writing them down is the entire
# point. A hand-maintained list would be worth nothing here, because the
# failure it exists to rule out is precisely a change nobody mentioned - and a
# heading with no substitutions under it is dropped, while substitutions under
# no heading are listed as unsectioned rather than disappearing.
#
# Header-only, like aerium_first_run.h next to it: a DefaultWebUIConfig plus an
# inline URLDataSource needs no BUILD.gn entry, no .cc and no TypeScript. The
# virtual methods are defined below the class for the reason that file records
# - the chromium-style plugin rejects a virtual method with a non-empty body
# written inside the class.
#
# The generated .inc is included with no fallback on purpose. If the generator
# did not run, this fails to compile. The alternative - an empty list - would
# render a page claiming this build changes nothing about Chromium, which is
# the one statement it must never make.
cat > chrome/browser/ui/webui/aerium_patches.h <<'AERIUM_PATCHES_H'
#ifndef CHROME_BROWSER_UI_WEBUI_AERIUM_PATCHES_H_
#define CHROME_BROWSER_UI_WEBUI_AERIUM_PATCHES_H_

#include <iterator>
#include <string>
#include <string_view>
#include <vector>

#include "base/memory/ref_counted_memory.h"
#include "base/strings/escape.h"
#include "base/strings/strcat.h"
#include "base/strings/string_number_conversions.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/url_data_source.h"
#include "content/public/browser/web_ui.h"
#include "content/public/browser/web_ui_controller.h"
#include "content/public/browser/webui_config.h"

// One row of the generated manifest. Declared before the include below, which
// is a plain initialiser list referring to this type.
struct AeriumPatchEntry {
  const char* group;
  const char* name;
  const char* summary;
  int files;
};

// Generated during the build by devutils/generate_patch_manifest.py. A missing
// file here is a hard compile error by design.
#include "chrome/browser/ui/webui/aerium_patch_manifest.inc"

class AeriumPatchesDataSource : public content::URLDataSource {
 public:
  AeriumPatchesDataSource() = default;
  AeriumPatchesDataSource(const AeriumPatchesDataSource&) = delete;
  AeriumPatchesDataSource& operator=(const AeriumPatchesDataSource&) = delete;
  ~AeriumPatchesDataSource() override = default;

  std::string GetSource() override;
  std::string GetMimeType(const GURL& url) override;

  void StartDataRequest(const GURL& url,
                        const content::WebContents::Getter& wc_getter,
                        GotDataCallback callback) override;

 private:
  static std::vector<std::string_view> GroupsInOrder();
  static std::string BuildPage();
};

inline std::string AeriumPatchesDataSource::GetSource() {
  return "aerium";
}

inline std::string AeriumPatchesDataSource::GetMimeType(const GURL& url) {
  return "text/html";
}

inline void AeriumPatchesDataSource::StartDataRequest(
    const GURL& url,
    const content::WebContents::Getter& wc_getter,
    content::URLDataSource::GotDataCallback callback) {
  std::move(callback).Run(
      base::MakeRefCounted<base::RefCountedString>(BuildPage()));
}

// Group names in order of first appearance, so the page follows the order the
// changes are actually applied in rather than an alphabetical one that would
// imply the stacking does not matter. It does: theme.sh routinely edits what a
// Vanadium patch produced.
inline std::vector<std::string_view> AeriumPatchesDataSource::GroupsInOrder() {
  std::vector<std::string_view> groups;
  for (const AeriumPatchEntry& entry : kAeriumPatches) {
    bool seen = false;
    for (std::string_view group : groups) {
      if (group == entry.group) {
        seen = true;
        break;
      }
    }
    if (!seen) {
      groups.emplace_back(entry.group);
    }
  }
  return groups;
}

inline std::string AeriumPatchesDataSource::BuildPage() {
  // Everything interpolated below comes from our own patch files and scripts
  // rather than from anything the page can be navigated with, but it is
  // escaped anyway: a patch description is prose, and prose acquires angle
  // brackets.
  std::string html = base::StrCat({
      R"(<!doctype html>
<title>What this build changes</title>
<meta name="color-scheme" content="light dark">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta charset="utf-8">
<style>
 @import url(chrome://resources/css/text_defaults_md.css);
 html{color:#202124; background:white; line-height:1.35}
 a{color:#1967d2}
 h1{margin:0; padding:.6em 0 .2em; font-size:1.5em}
 h2{margin:0; padding:1.2em 0 .4em; font-size:1.05em}
 section{width:min(60em,92vw); margin:2em auto}
 .lede{color:#5f6368}
 .count{color:#5f6368; font-variant-numeric:tabular-nums}
 table{border-collapse:collapse; width:100%}
 td{padding:.5em .4em; border-top:.063em solid #f0f0f0; vertical-align:top}
 td.n{font-family:monospace; font-size:.85em; word-break:break-all;
      max-width:11em}
 td.f{text-align:right; white-space:nowrap; color:#5f6368;
      font-variant-numeric:tabular-nums; width:1%}
 @media(prefers-color-scheme:dark){
  html{color:#e8eaed; background:#202124}
  a{color:#8ab4f8}
  .lede,.count,td.f{color:#9aa0a6}
  td{border-top:.063em solid #3f4042}
 }
</style>
<section>
 <h1>What this build changes</h1>
 <p class="lede">Aerium for Android is Chromium )",
      base::EscapeForHTML(std::string(kAeriumChromiumVersion)),
      (std::string(kAeriumBuildNumber).empty()
           ? std::string()
           : base::StrCat({" (build ",
                           base::EscapeForHTML(
                               std::string(kAeriumBuildNumber)),
                           ")"})),
      R"( with the changes below
 applied, in this order: GrapheneOS's Vanadium patches first, then Aerium's own
 build scripts on top. The list is generated during the build from the patch
 files and from the scripts themselves, so it is what was actually applied
 rather than a description maintained by hand.</p>
 <p class="lede">The right-hand column counts the files each entry edits. A
 dash means the set is decided while the build runs and cannot be counted
 ahead of it.</p>
 <p class="count">)",
      base::NumberToString(std::size(kAeriumPatches)),
      R"( entries.</p>
</section>
)"});

  for (std::string_view group : GroupsInOrder()) {
    int in_group = 0;
    for (const AeriumPatchEntry& entry : kAeriumPatches) {
      if (group == entry.group) {
        ++in_group;
      }
    }
    base::StrAppend(&html, {"<section>\n <h2>",
                            base::EscapeForHTML(std::string(group)),
                            "</h2>\n <p class=\"count\">",
                            base::NumberToString(in_group),
                            "</p>\n <table>\n"});
    for (const AeriumPatchEntry& entry : kAeriumPatches) {
      if (group != entry.group) {
        continue;
      }
      base::StrAppend(
          &html,
          {"  <tr><td class=\"n\">",
           base::EscapeForHTML(std::string(entry.name)), "</td><td>",
           base::EscapeForHTML(std::string(entry.summary)),
           "</td><td class=\"f\">",
           entry.files ? base::NumberToString(entry.files)
                       : std::string("&mdash;"),
           "</td></tr>\n"});
    }
    base::StrAppend(&html, {" </table>\n</section>\n"});
  }
  return html;
}

class AeriumPatches;

class AeriumPatchesUIConfig : public content::DefaultWebUIConfig<AeriumPatches> {
 public:
  AeriumPatchesUIConfig() : DefaultWebUIConfig("chrome", "aerium") {}
};

class AeriumPatches : public content::WebUIController {
 public:
  explicit AeriumPatches(content::WebUI* web_ui)
      : content::WebUIController(web_ui) {
    content::URLDataSource::Add(Profile::FromWebUI(web_ui),
                                std::make_unique<AeriumPatchesDataSource>());
  }
  AeriumPatches(const AeriumPatches&) = delete;
  AeriumPatches& operator=(const AeriumPatches&) = delete;
};

#endif  // CHROME_BROWSER_UI_WEBUI_AERIUM_PATCHES_H_
AERIUM_PATCHES_H

sed_i 's|#include "chrome/browser/ui/webui/webapks/webapks_ui.h"|&\n#include "chrome/browser/ui/webui/aerium_patches.h"|' \
    chrome/browser/ui/webui/chrome_web_ui_configs.cc
sed_i 's|  map.AddWebUIConfig(std::make_unique<WebApksUIConfig>());|&\n  map.AddWebUIConfig(std::make_unique<AeriumPatchesUIConfig>());|' \
    chrome/browser/ui/webui/chrome_web_ui_configs.cc

# --- chrome://aerium-extensions - install a .crx that is already on the device.
#
# The two commits before this one got a .crx that is DOWNLOADED to install. A
# .crx already sitting on the phone still had no way in, which is the half of
# android issue 14 those left open, and the half people actually ask for: they
# have the file, from a release page or a friend or their own build, and the
# browser will not take it.
#
# Built as an inline URLDataSource plus a DefaultWebUIConfig, the same shape as
# chrome://aerium above it - no BUILD.gn entry, no .cc, no TypeScript. A page
# rather than a settings row because it needs a WebContents to hang the install
# prompt on, and a WebUI page is one that is guaranteed to be in the foreground
# at the moment the user asks.
#
# No JNI anywhere in this, which is the point of doing it this way.
# ui::SelectFileDialog already has an Android implementation - it is what
# <input type=file> uses - so the picker, the permission handling and the
# Activity result plumbing are all upstream's. chrome.send() carries the button
# press from the page to the controller, and the controller is C++.
#
# Content URIs are the one part that needs real care. Android hands back a
# content:// path, not a filesystem one, and CrxInstaller opens what it is given
# with ordinary file APIs. base::FilePath::IsContentUri() identifies those and
# base/android/content_uri_utils.h reads them, so the file is copied into the
# profile directory first and the installer is pointed at the copy. The copy
# runs on the thread pool because it touches the disk; everything else here is
# UI thread.
#
# off_store_install_allow_reason is set for the same reason the download path
# sets it: a .crx from a file is by definition not from a store, and without it
# CrxInstaller refuses with "can only be installed from the Chrome Web Store".
# The prompt is still built and the user still agrees to the permissions - this
# changes where an extension may come from, not whether it is announced.
cat > chrome/browser/ui/webui/aerium_extensions.h <<'AERIUM_EXTENSIONS_H'
// Copyright 2026 The Aerium Authors
// Aerium: generated by theme.sh. See that script for why this exists.

#ifndef CHROME_BROWSER_UI_WEBUI_AERIUM_EXTENSIONS_H_
#define CHROME_BROWSER_UI_WEBUI_AERIUM_EXTENSIONS_H_

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/containers/span.h"
#include "base/files/file.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/memory/ref_counted_memory.h"
#include "base/memory/weak_ptr.h"
#include "base/task/thread_pool.h"
#include "base/values.h"
#include "build/build_config.h"
#include "chrome/browser/extensions/extension_install_prompt.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/select_file_policy/chrome_select_file_policy.h"
#include "content/public/browser/url_data_source.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_ui.h"
#include "content/public/browser/web_ui_controller.h"
#include "content/public/browser/webui_config.h"
#include "extensions/browser/crx_installer.h"
#include "extensions/browser/install_prompt_data.h"
#include "extensions/common/constants.h"
#include "extensions/common/extension.h"
#include "services/network/public/mojom/content_security_policy.mojom.h"
#include "ui/shell_dialogs/select_file_dialog.h"
#include "ui/shell_dialogs/selected_file_info.h"

class AeriumExtensionsDataSource : public content::URLDataSource {
 public:
  AeriumExtensionsDataSource() = default;
  ~AeriumExtensionsDataSource() override = default;

  std::string GetSource() override;
  void StartDataRequest(const GURL& url,
                        const content::WebContents::Getter& wc_getter,
                        content::URLDataSource::GotDataCallback callback)
      override;
  std::string GetMimeType(const GURL& url) override;
  std::string GetContentSecurityPolicy(
      network::mojom::CSPDirectiveName directive) override;
};

inline std::string AeriumExtensionsDataSource::GetSource() {
  return "aerium-extensions";
}

inline std::string AeriumExtensionsDataSource::GetMimeType(const GURL& url) {
  return "text/html";
}

// The page carries one inline script - the click handler that calls
// chrome.send. The default policy for a URLDataSource forbids inline script, so
// script-src is relaxed for this host only and every other directive is left to
// the default implementation.
inline std::string AeriumExtensionsDataSource::GetContentSecurityPolicy(
    network::mojom::CSPDirectiveName directive) {
  if (directive == network::mojom::CSPDirectiveName::ScriptSrc) {
    return "script-src 'self' 'unsafe-inline';";
  }
  return content::URLDataSource::GetContentSecurityPolicy(directive);
}

inline void AeriumExtensionsDataSource::StartDataRequest(
    const GURL& url,
    const content::WebContents::Getter& wc_getter,
    content::URLDataSource::GotDataCallback callback) {
  static constexpr char kPage[] = R"(<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Install an extension</title>
<style>
 html{font:100%/1.5 system-ui, sans-serif; color:#202124; background:#fff;
      margin:0 auto; max-width:46em; padding:1.5em 1.25em 3em}
 h1{font-size:1.35em; margin:0 0 .35em}
 p{margin:0 0 1em; color:#5f6368}
 button{font:inherit; font-weight:600; color:#fff; background:#1b2c5e;
        border:0; border-radius:.5em; padding:.7em 1.1em; cursor:pointer}
 button:active{opacity:.85}
 #s{margin-top:1em; min-height:1.5em}
 @media(prefers-color-scheme:dark){
  html{color:#e8eaed; background:#202124}
  p{color:#9aa0a6}
  button{background:#8ab4f8; color:#202124}
 }
</style>
<h1>Install an extension from a file</h1>
<p>Choose a <code>.crx</code> file that is already on this device. Aerium will
show you the permissions it asks for before anything is installed.</p>
<button id="b">Choose a file</button>
<p id="s"></p>
<script>
 const b = document.getElementById('b');
 const s = document.getElementById('s');
 b.addEventListener('click', () => {
   s.textContent = '';
   chrome.send('aeriumPickExtension');
 });
 window.aeriumInstallStatus = (text) => { s.textContent = text; };
</script>
)";
  std::move(callback).Run(
      base::MakeRefCounted<base::RefCountedString>(std::string(kPage)));
}

class AeriumExtensions : public content::WebUIController,
                         public ui::SelectFileDialog::Listener {
 public:
  explicit AeriumExtensions(content::WebUI* web_ui);
  AeriumExtensions(const AeriumExtensions&) = delete;
  AeriumExtensions& operator=(const AeriumExtensions&) = delete;
  ~AeriumExtensions() override;

  // ui::SelectFileDialog::Listener:
  void FileSelected(const ui::SelectedFileInfo& file, int index) override;
  void FileSelectionCanceled() override;

 private:
  void HandlePick(const base::Value::List& args);
  void InstallFrom(const base::FilePath& path);
  void OnCopied(const base::FilePath& copy, bool ok);
  void Status(const std::string& text);

  scoped_refptr<ui::SelectFileDialog> dialog_;
  base::WeakPtrFactory<AeriumExtensions> weak_factory_{this};
};

inline AeriumExtensions::AeriumExtensions(content::WebUI* web_ui)
    : content::WebUIController(web_ui) {
  content::URLDataSource::Add(
      Profile::FromWebUI(web_ui),
      std::make_unique<AeriumExtensionsDataSource>());
  web_ui->RegisterMessageCallback(
      "aeriumPickExtension",
      base::BindRepeating(&AeriumExtensions::HandlePick,
                          base::Unretained(this)));
}

inline AeriumExtensions::~AeriumExtensions() {
  if (dialog_) {
    dialog_->ListenerDestroyed();
  }
}

inline void AeriumExtensions::Status(const std::string& text) {
  web_ui()->CallJavascriptFunctionUnsafe("aeriumInstallStatus",
                                         base::Value(text));
}

inline void AeriumExtensions::HandlePick(const base::Value::List& args) {
  if (dialog_) {
    return;
  }
  content::WebContents* web_contents = web_ui()->GetWebContents();
  if (!web_contents) {
    return;
  }
  dialog_ = ui::SelectFileDialog::Create(
      this, std::make_unique<ChromeSelectFilePolicy>(web_contents));
  if (!dialog_) {
    Status("This device has no file picker available.");
    return;
  }
  ui::SelectFileDialog::FileTypeInfo file_types;
  file_types.extensions.push_back(
      {extensions::kExtensionFileExtension + 1});
  dialog_->SelectFile(ui::SelectFileDialog::SELECT_OPEN_FILE, std::u16string(),
                      base::FilePath(), &file_types, 0,
                      base::FilePath::StringType(),
                      web_contents->GetTopLevelNativeWindow(), nullptr);
}

inline void AeriumExtensions::FileSelectionCanceled() {
  dialog_.reset();
}

inline void AeriumExtensions::FileSelected(const ui::SelectedFileInfo& file,
                                           int index) {
  dialog_.reset();
  const base::FilePath& path =
      file.local_path.empty() ? file.file_path : file.local_path;
  if (path.empty()) {
    Status("That file could not be read.");
    return;
  }

#if BUILDFLAG(IS_ANDROID)
  // A picked file arrives as a content:// URI far more often than not, and
  // CrxInstaller opens what it is handed with ordinary file APIs. Copy it into
  // the profile directory first and install the copy.
  if (path.IsContentUri()) {
    Profile* profile = Profile::FromWebUI(web_ui());
    base::FilePath copy =
        profile->GetPath().AppendASCII("aerium-picked-extension.crx");
    Status("Reading the file...");
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE,
        {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
        base::BindOnce(
            [](base::FilePath from, base::FilePath to) {
              base::File in(from, base::File::FLAG_OPEN |
                                     base::File::FLAG_READ);
              if (!in.IsValid()) {
                return false;
              }
              base::File out(to, base::File::FLAG_CREATE_ALWAYS |
                                     base::File::FLAG_WRITE);
              if (!out.IsValid()) {
                return false;
              }
              // The span overloads, not the char*/int ones: those are
              // annotated UNSAFE_BUFFER_USAGE and this directory is not on
              // the exempt list in build/config/unsafe_buffers_paths.txt, so
              // calling them here would not compile.
              std::vector<uint8_t> buffer(64 * 1024);
              while (true) {
                const std::optional<size_t> read =
                    in.ReadAtCurrentPos(base::span(buffer));
                if (!read.has_value()) {
                  return false;
                }
                if (*read == 0u) {
                  return true;
                }
                if (!out.WriteAtCurrentPosAndCheck(
                        base::span(buffer).first(*read))) {
                  return false;
                }
              }
            },
            path, copy),
        base::BindOnce(&AeriumExtensions::OnCopied,
                       weak_factory_.GetWeakPtr(), copy));
    return;
  }
#endif  // BUILDFLAG(IS_ANDROID)

  InstallFrom(path);
}

inline void AeriumExtensions::OnCopied(const base::FilePath& copy, bool ok) {
  if (!ok) {
    Status("That file could not be read.");
    return;
  }
  InstallFrom(copy);
}

inline void AeriumExtensions::InstallFrom(const base::FilePath& path) {
  content::WebContents* web_contents = web_ui()->GetWebContents();
  if (!web_contents) {
    return;
  }
  Profile* profile = Profile::FromWebUI(web_ui());
  scoped_refptr<extensions::CrxInstaller> installer =
      extensions::CrxInstaller::Create(
          profile,
          std::make_unique<ExtensionInstallPrompt>(
              web_contents,
              std::make_unique<extensions::InstallPromptData>(
                  extensions::InstallPromptData::UNSET_PROMPT_TYPE)));
  // A file is never a store install, and without this CrxInstaller refuses it
  // with "can only be installed from the Chrome Web Store".
  installer->set_off_store_install_allow_reason(
      extensions::CrxInstaller::OffStoreInstallAllowedFromSettingsPage);
  installer->set_error_on_unsupported_requirements(true);
  installer->InstallCrx(path);
  Status("Checking the extension...");
}

class AeriumExtensionsUIConfig
    : public content::DefaultWebUIConfig<AeriumExtensions> {
 public:
  AeriumExtensionsUIConfig()
      : DefaultWebUIConfig("chrome", "aerium-extensions") {}
};

#endif  // CHROME_BROWSER_UI_WEBUI_AERIUM_EXTENSIONS_H_
AERIUM_EXTENSIONS_H

# Registered next to chrome://aerium, anchored on the lines the block above just
# inserted rather than on upstream's, so the two stay in a fixed order.
sed_i 's|#include "chrome/browser/ui/webui/aerium_patches.h"|&\n#include "chrome/browser/ui/webui/aerium_extensions.h"|' \
    chrome/browser/ui/webui/chrome_web_ui_configs.cc
sed_i 's|  map.AddWebUIConfig(std::make_unique<AeriumPatchesUIConfig>());|&\n  map.AddWebUIConfig(std::make_unique<AeriumExtensionsUIConfig>());|' \
    chrome/browser/ui/webui/chrome_web_ui_configs.cc

# The About screen is where someone goes to find out what they are running, so
# it is where the answer belongs. Opened through CustomTabActivity.showInfoPage
# like the project link above it: that path marks the intent trusted and starts
# CustomTabActivity directly, rather than handing a chrome:// URL to the
# system dispatcher, which patch.sh deliberately limits to network URLs.
sed_i 's|^    private static final String AERIUM_PROJECT_URL = "https://aerium-browser.github.io";$|&\n    private static final String PREF_AERIUM_PATCHES = "aerium_patches";\n    private static final String AERIUM_PATCHES_URL = "chrome://aerium";|' \
    $ACS
sed_i 's|^        Preference project = findPreference(PREF_AERIUM_PROJECT);$|        Preference patches = findPreference(PREF_AERIUM_PATCHES);\n        if (patches != null) {\n            patches.setOnPreferenceClickListener(\n                    preference -> {\n                        CustomTabActivity.showInfoPage(getActivity(), AERIUM_PATCHES_URL);\n                        return true;\n                    });\n        }\n\n&|' \
    $ACS

sed_i 's|^    <Preference$|    <Preference\n        android:key="aerium_patches"\n        android:title="@string/aerium_patches_title"\n        android:summary="@string/aerium_patches_summary" />\n&|' \
    chrome/android/java/res/xml/about_chrome_preferences.xml

sed_i 's|^      <message name="IDS_AERIUM_PROJECT_TITLE" desc=|      <message name="IDS_AERIUM_PATCHES_TITLE" desc="Title of the About-page row that opens the list of changes this build makes to Chromium.">\n        What this build changes\n      </message>\n      <message name="IDS_AERIUM_PATCHES_SUMMARY" desc="Summary under that row.">\n        Every patch applied on top of upstream Chromium\n      </message>\n&|' \
    chrome/browser/ui/android/strings/android_chrome_strings.grd

# --- Delete browsing data when you close Aerium.
#
# The desktop repos have had this since aerium-clear-browsing-data-on-exit: a
# master toggle in Settings with the eight standard data-type categories under
# it, hanging off the shutdown deletion Chromium already implements in
# ChromeBrowsingDataLifetimeManager::ClearBrowsingDataForOnExitPolicy().
#
# The C++ half ports across almost unchanged, because that manager is built on
# Android and is already Android-aware - it enumerates TabModelList rather than
# browser windows when it needs the open tabs. The prefs and the mask are
# copied from the desktop patch deliberately, so an identical selection deletes
# identical things on both platforms.
#
# Three things do NOT port.
#
# The condition. Desktop widens an expression ungoogled-chromium already
# widened for its #clear-data-on-exit flag; that flag does not exist here, so
# the Aerium clause is added to the stock expression instead.
#
# The settings UI. Desktop is WebUI, Android is a preference fragment, so the
# eight checkboxes and the screen they live on are written rather than ported.
#
# The trigger. This is the real difference. Desktop calls the deletion from
# ProfileManager when the last browser window for a profile closes; that call
# site is inside a !IS_ANDROID region and has no Android equivalent, because
# Android has no window close and no guaranteed exit at all - a process can be
# killed with no callback of any kind. So there are two triggers, and between
# them a session's data does not survive the session:
#
#   1. On a clean close, ChromeTabbedActivity.onDestroyInternal sets a request
#      pref, which this manager observes and answers by running the deletion.
#      A pref rather than a new JNI method: the manager already holds a
#      PrefChangeRegistrar, and Java can write any registered pref by name, so
#      the signal costs nothing to add and nothing to build.
#
#      Guarded on isFinishing() && !isChangingConfigurations(): onDestroy also
#      runs when the activity is merely being recreated - a rotation, a theme
#      change - and wiping someone's cookies because they turned their phone
#      sideways would be indefensible.
#
#   2. If the process dies before that, the deletion never runs. So the manager
#      also marks kClearBrowsingDataOnExitDeletionPending at construction
#      whenever the toggle is on, which is the flag Chromium's own
#      ProfileManager already checks on the next launch - upstream code, upstream
#      semantics, no new path. The data is then cleared at the next start, before
#      the user does anything with it.
#
# Together those mean the toggle's promise holds however the browser ended, at
# the cost of one redundant deletion after a clean close, which has nothing left
# to delete.
BDPREFS=components/browsing_data/core/pref_names.h
sed_i 's|^inline constexpr char kClearBrowsingDataOnExitList\[\] =$|// Aerium: master switch for the "Delete browsing data when you close Aerium"\n// screen in Settings > Privacy and security. Kept separate from the policy\n// list below, which stays enterprise-owned; the two are ORed at shutdown.\ninline constexpr char kAeriumClearBrowsingDataOnExit[] =\n    "browser.clear_data.aerium_clear_on_exit";\n\n// Aerium: set by the Java side when the browser is closing for real, and\n// observed by ChromeBrowsingDataLifetimeManager, which clears it and runs the\n// deletion. Android has no window-close call site to hang that on - see\n// theme.sh.\ninline constexpr char kAeriumClearOnExitRequested[] =\n    "browser.clear_data.aerium_on_exit.requested";\n\n// Aerium: which data types that switch deletes. One boolean per\n// browsing_data::PolicyDataType category, mirroring the shape Chromium\n// already uses for the Delete-browsing-data dialog'"'"'s own kDelete* prefs.\n// Deliberately NOT the kDelete* prefs themselves: those hold the dialog'"'"'s\n// last-used checkbox state, and reusing them would let a one-off manual\n// deletion silently reconfigure what happens on every future shutdown.\ninline constexpr char kAeriumClearOnExitBrowsingHistory[] =\n    "browser.clear_data.aerium_on_exit.browsing_history";\ninline constexpr char kAeriumClearOnExitDownloadHistory[] =\n    "browser.clear_data.aerium_on_exit.download_history";\ninline constexpr char kAeriumClearOnExitCookies[] =\n    "browser.clear_data.aerium_on_exit.cookies";\ninline constexpr char kAeriumClearOnExitCache[] =\n    "browser.clear_data.aerium_on_exit.cache";\ninline constexpr char kAeriumClearOnExitFormData[] =\n    "browser.clear_data.aerium_on_exit.form_data";\ninline constexpr char kAeriumClearOnExitPasswords[] =\n    "browser.clear_data.aerium_on_exit.passwords";\ninline constexpr char kAeriumClearOnExitSiteSettings[] =\n    "browser.clear_data.aerium_on_exit.site_settings";\ninline constexpr char kAeriumClearOnExitHostedAppData[] =\n    "browser.clear_data.aerium_on_exit.hosted_apps_data";\n\n&|' \
    $BDPREFS

sed_i 's|^  registry->RegisterListPref(kClearBrowsingDataOnExitList);$|&\n  // Aerium: master switch off by default. The per-type defaults reproduce the\n  // set the desktop toggle ships with, so the two platforms behave the same on\n  // a fresh profile. Passwords, site settings and hosted app data stay off - a\n  // switch whose label promises a clean slate must not quietly destroy saved\n  // sign-ins or per-site permissions unless it was asked to.\n  registry->RegisterBooleanPref(kAeriumClearBrowsingDataOnExit, false);\n  registry->RegisterBooleanPref(kAeriumClearOnExitRequested, false);\n  registry->RegisterBooleanPref(kAeriumClearOnExitBrowsingHistory, true);\n  registry->RegisterBooleanPref(kAeriumClearOnExitDownloadHistory, true);\n  registry->RegisterBooleanPref(kAeriumClearOnExitCookies, true);\n  registry->RegisterBooleanPref(kAeriumClearOnExitCache, true);\n  registry->RegisterBooleanPref(kAeriumClearOnExitFormData, true);\n  registry->RegisterBooleanPref(kAeriumClearOnExitPasswords, false);\n  registry->RegisterBooleanPref(kAeriumClearOnExitSiteSettings, false);\n  registry->RegisterBooleanPref(kAeriumClearOnExitHostedAppData, false);|' \
    components/browsing_data/core/pref_names.cc

CBDLM=chrome/browser/browsing_data/chrome_browsing_data_lifetime_manager.cc
sed_i 's%^uint64_t GetOriginTypeMask(const base::ListValue\& data_types) {$%// Aerium: the removal mask for the "Delete browsing data when you close\n// Aerium" screen, assembled from the per-type checkboxes on it. The type ->\n// mask mapping is deliberately the same one GetRemoveMask() uses for\n// browsing_data::PolicyDataType, so the screen and the enterprise\n// ClearBrowsingDataOnExit policy clear identical things for identical\n// selections.\nuint64_t AeriumOnExitRemoveMask(PrefService* prefs) {\n  uint64_t result = 0;\n  if (prefs->GetBoolean(\n          browsing_data::prefs::kAeriumClearOnExitBrowsingHistory)) {\n    result |= chrome_browsing_data_remover::DATA_TYPE_HISTORY;\n  }\n  if (prefs->GetBoolean(\n          browsing_data::prefs::kAeriumClearOnExitDownloadHistory)) {\n    result |= content::BrowsingDataRemover::DATA_TYPE_DOWNLOADS;\n  }\n  if (prefs->GetBoolean(browsing_data::prefs::kAeriumClearOnExitCookies)) {\n    result |= chrome_browsing_data_remover::DATA_TYPE_SITE_DATA;\n  }\n  if (prefs->GetBoolean(browsing_data::prefs::kAeriumClearOnExitCache)) {\n    result |= content::BrowsingDataRemover::DATA_TYPE_CACHE;\n  }\n  if (prefs->GetBoolean(browsing_data::prefs::kAeriumClearOnExitFormData)) {\n    result |= chrome_browsing_data_remover::DATA_TYPE_FORM_DATA;\n  }\n  if (prefs->GetBoolean(browsing_data::prefs::kAeriumClearOnExitPasswords)) {\n    result |= chrome_browsing_data_remover::DATA_TYPE_PASSWORDS;\n  }\n  if (prefs->GetBoolean(browsing_data::prefs::kAeriumClearOnExitSiteSettings)) {\n    result |= chrome_browsing_data_remover::DATA_TYPE_CONTENT_SETTINGS;\n  }\n  if (prefs->GetBoolean(\n          browsing_data::prefs::kAeriumClearOnExitHostedAppData)) {\n    result |= chrome_browsing_data_remover::DATA_TYPE_SITE_DATA;\n  }\n  return result;\n}\n\n// Aerium: origin-type companion to AeriumOnExitRemoveMask(), mirroring\n// GetOriginTypeMask() below - only cookies/site data and hosted app data are\n// origin-scoped.\nuint64_t AeriumOnExitOriginTypeMask(PrefService* prefs) {\n  uint64_t result = 0;\n  if (prefs->GetBoolean(browsing_data::prefs::kAeriumClearOnExitCookies)) {\n    result |= content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB;\n  }\n  if (prefs->GetBoolean(\n          browsing_data::prefs::kAeriumClearOnExitHostedAppData)) {\n    result |= content::BrowsingDataRemover::ORIGIN_TYPE_PROTECTED_WEB;\n  }\n  return result;\n}\n\n&%' \
    $CBDLM

sed_i 's|^  if (!data_types.empty() \&\&$|  // Aerium: the same shutdown path, driven by the Settings screen as well as\n  // by enterprise policy. A mask of zero means the master switch is on but\n  // every type was unchecked, which must stay a no-op rather than a deletion\n  // of nothing that still flips the pending-deletion pref.\n  PrefService* aerium_prefs = profile_->GetPrefs();\n  const uint64_t aerium_remove_mask =\n      aerium_prefs->GetBoolean(\n          browsing_data::prefs::kAeriumClearBrowsingDataOnExit)\n          ? AeriumOnExitRemoveMask(aerium_prefs)\n          : 0;\n  const bool aerium_on_exit = aerium_remove_mask != 0;\n\n  if (aerium_on_exit \|\| (!data_types.empty() \&\&|' \
    $CBDLM
sed_i 's|^          profile_, browsing_data::prefs::kClearBrowsingDataOnExitList))) {$|          profile_, browsing_data::prefs::kClearBrowsingDataOnExitList)))) {|' \
    $CBDLM
sed_i 's|^                            GetRemoveMask(data_types),$|                            GetRemoveMask(data_types) \| aerium_remove_mask,|' \
    $CBDLM
sed_i 's|^                            GetOriginTypeMask(data_types),$|                            GetOriginTypeMask(data_types) \|\n                                (aerium_on_exit ? AeriumOnExitOriginTypeMask(\n                                                      aerium_prefs)\n                                                : 0),|' \
    $CBDLM

# The two triggers described above. Both live in the constructor: the observer
# that answers a clean close, and the mark that covers a process that never
# gets one.
sed_i 's%^  // When the service is instantiated, wait a few minutes after Chrome startup$%  // Aerium: see theme.sh. Android has no window-close call site, so the Java\n  // side asks for the deletion through a pref and this answers it. Written\n  // back to false first so a second close asks again rather than finding the\n  // request already set.\n  pref_change_registrar_.Add(\n      browsing_data::prefs::kAeriumClearOnExitRequested,\n      base::BindRepeating(\n          [](ChromeBrowsingDataLifetimeManager* manager) {\n            PrefService* prefs = manager->profile_->GetPrefs();\n            if (!prefs->GetBoolean(\n                    browsing_data::prefs::kAeriumClearOnExitRequested)) {\n              return;\n            }\n            prefs->SetBoolean(\n                browsing_data::prefs::kAeriumClearOnExitRequested, false);\n            // Aerium: the greylist goes first and goes unconditionally.\n            // Session-only is a promise made per site, so it must not depend\n            // on the delete-on-exit switch being on - see theme.sh.\n            manager->AeriumClearSessionOnlySites();\n            // keep_browser_alive is what makes the observer clear the\n            // pending-deletion flag when the removal finishes, which is\n            // exactly what a clean close should do. The ScopedKeepAlive it\n            // also controls on desktop is compiled out on Android, so this\n            // is the only thing it does here.\n            manager->ClearBrowsingDataForOnExitPolicy(\n                /*keep_browser_alive=*/true);\n          },\n          base::Unretained(this)));\n\n&%' \
    $CBDLM

# --- The screen itself.
cat > chrome/android/java/res/xml/aerium_clear_on_exit_preferences.xml <<'AERIUM_COE_XML'
<?xml version="1.0" encoding="utf-8"?>
<!-- Aerium: see theme.sh. -->
<PreferenceScreen xmlns:android="http://schemas.android.com/apk/res/android">
    <org.chromium.components.browser_ui.settings.ChromeSwitchPreference
        android:key="aerium_clear_on_exit_switch"
        android:title="@string/aerium_clear_on_exit_switch_title"
        android:summary="@string/aerium_clear_on_exit_switch_summary"
        android:persistent="false" />
    <PreferenceCategory
        android:key="aerium_clear_on_exit_types"
        android:title="@string/aerium_clear_on_exit_types_title">
        <org.chromium.components.browser_ui.settings.ChromeBaseCheckBoxPreference
            android:key="aerium_on_exit_browsing_history"
            android:title="@string/aerium_clear_on_exit_history"
            android:persistent="false" />
        <org.chromium.components.browser_ui.settings.ChromeBaseCheckBoxPreference
            android:key="aerium_on_exit_download_history"
            android:title="@string/aerium_clear_on_exit_downloads"
            android:persistent="false" />
        <org.chromium.components.browser_ui.settings.ChromeBaseCheckBoxPreference
            android:key="aerium_on_exit_cookies"
            android:title="@string/aerium_clear_on_exit_cookies"
            android:persistent="false" />
        <org.chromium.components.browser_ui.settings.ChromeBaseCheckBoxPreference
            android:key="aerium_on_exit_cache"
            android:title="@string/aerium_clear_on_exit_cache"
            android:persistent="false" />
        <org.chromium.components.browser_ui.settings.ChromeBaseCheckBoxPreference
            android:key="aerium_on_exit_form_data"
            android:title="@string/aerium_clear_on_exit_form_data"
            android:persistent="false" />
        <org.chromium.components.browser_ui.settings.ChromeBaseCheckBoxPreference
            android:key="aerium_on_exit_passwords"
            android:title="@string/aerium_clear_on_exit_passwords"
            android:persistent="false" />
        <org.chromium.components.browser_ui.settings.ChromeBaseCheckBoxPreference
            android:key="aerium_on_exit_site_settings"
            android:title="@string/aerium_clear_on_exit_site_settings"
            android:persistent="false" />
        <org.chromium.components.browser_ui.settings.ChromeBaseCheckBoxPreference
            android:key="aerium_on_exit_hosted_apps_data"
            android:title="@string/aerium_clear_on_exit_hosted_apps"
            android:persistent="false" />
    </PreferenceCategory>
    <Preference
        android:key="aerium_site_rules"
        android:title="@string/aerium_site_rules_title"
        android:summary="@string/aerium_site_rules_summary"
        android:fragment="org.chromium.chrome.browser.browsing_data.AeriumSiteRulesFragment" />
</PreferenceScreen>
AERIUM_COE_XML

cat > chrome/android/java/src/org/chromium/chrome/browser/browsing_data/AeriumClearOnExitFragment.java <<'AERIUM_COE_JAVA'
// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package org.chromium.chrome.browser.browsing_data;

import android.os.Bundle;

import androidx.preference.Preference;

import org.chromium.base.supplier.MonotonicObservableSupplier;
import org.chromium.base.supplier.ObservableSuppliers;
import org.chromium.base.supplier.SettableMonotonicObservableSupplier;
import org.chromium.build.annotations.NullMarked;
import org.chromium.build.annotations.Nullable;
import org.chromium.chrome.R;
import org.chromium.chrome.browser.settings.ChromeBaseSettingsFragment;
import org.chromium.chrome.browser.settings.search.ChromeBaseSearchIndexProvider;
import org.chromium.components.browser_ui.settings.ChromeBaseCheckBoxPreference;
import org.chromium.components.browser_ui.settings.ChromeSwitchPreference;
import org.chromium.components.browser_ui.settings.SettingsFragment;
import org.chromium.components.browser_ui.settings.SettingsUtils;
import org.chromium.components.prefs.PrefService;
import org.chromium.components.user_prefs.UserPrefs;

/**
 * Aerium: the "Delete browsing data when you close Aerium" screen. See theme.sh.
 *
 * <p>The prefs are written straight through PrefService rather than persisted by the preference
 * framework, which is why every entry in the XML is android:persistent="false" - the values have to
 * live where ChromeBrowsingDataLifetimeManager reads them, in the profile's PrefService, not in
 * SharedPreferences.
 */
@NullMarked
public class AeriumClearOnExitFragment extends ChromeBaseSettingsFragment {
    // Must match the keys in aerium_clear_on_exit_preferences.xml.
    private static final String PREF_SWITCH = "aerium_clear_on_exit_switch";
    private static final String PREF_TYPES = "aerium_clear_on_exit_types";
    private static final String PREF_SITE_RULES = "aerium_site_rules";

    // Must match components/browsing_data/core/pref_names.h.
    private static final String PREF_CLEAR_ON_EXIT = "browser.clear_data.aerium_clear_on_exit";

    /** Preference key paired with the profile pref it reads and writes. */
    private static final String[][] TYPES = {
        {"aerium_on_exit_browsing_history", "browser.clear_data.aerium_on_exit.browsing_history"},
        {"aerium_on_exit_download_history", "browser.clear_data.aerium_on_exit.download_history"},
        {"aerium_on_exit_cookies", "browser.clear_data.aerium_on_exit.cookies"},
        {"aerium_on_exit_cache", "browser.clear_data.aerium_on_exit.cache"},
        {"aerium_on_exit_form_data", "browser.clear_data.aerium_on_exit.form_data"},
        {"aerium_on_exit_passwords", "browser.clear_data.aerium_on_exit.passwords"},
        {"aerium_on_exit_site_settings", "browser.clear_data.aerium_on_exit.site_settings"},
        {"aerium_on_exit_hosted_apps_data", "browser.clear_data.aerium_on_exit.hosted_apps_data"},
    };

    private final SettableMonotonicObservableSupplier<String> mPageTitle =
            ObservableSuppliers.createMonotonic();

    private @Nullable Preference mTypes;
    private @Nullable Preference mSiteRules;

    @Override
    public void onCreatePreferences(@Nullable Bundle savedInstanceState, @Nullable String rootKey) {
        SettingsUtils.addPreferencesFromResource(this, R.xml.aerium_clear_on_exit_preferences);
        mPageTitle.set(getString(R.string.aerium_clear_on_exit_title));

        PrefService prefs = UserPrefs.get(getProfile());
        mTypes = findPreference(PREF_TYPES);
        mSiteRules = findPreference(PREF_SITE_RULES);

        ChromeSwitchPreference onExit = (ChromeSwitchPreference) findPreference(PREF_SWITCH);
        if (onExit != null) {
            onExit.setChecked(prefs.getBoolean(PREF_CLEAR_ON_EXIT));
            onExit.setOnPreferenceChangeListener(
                    (preference, newValue) -> {
                        prefs.setBoolean(PREF_CLEAR_ON_EXIT, (boolean) newValue);
                        updateTypesVisible((boolean) newValue);
                        return true;
                    });
        }

        for (String[] type : TYPES) {
            ChromeBaseCheckBoxPreference box =
                    (ChromeBaseCheckBoxPreference) findPreference(type[0]);
            if (box == null) continue;
            String prefName = type[1];
            box.setChecked(prefs.getBoolean(prefName));
            box.setOnPreferenceChangeListener(
                    (preference, newValue) -> {
                        prefs.setBoolean(prefName, (boolean) newValue);
                        return true;
                    });
        }

        updateTypesVisible(prefs.getBoolean(PREF_CLEAR_ON_EXIT));
    }

    /**
     * The list of types says nothing while the switch above it is off, so it is hidden rather than
     * left offering choices that decide nothing. The exceptions screen goes with it for the same
     * reason - there is nothing to make an exception to.
     */
    private void updateTypesVisible(boolean enabled) {
        if (mTypes != null) mTypes.setVisible(enabled);
        if (mSiteRules != null) mSiteRules.setVisible(enabled);
    }

    @Override
    public MonotonicObservableSupplier<String> getPageTitle() {
        return mPageTitle;
    }

    @Override
    public @SettingsFragment.AnimationType int getAnimationType() {
        return SettingsFragment.AnimationType.PROPERTY;
    }

    public static final ChromeBaseSearchIndexProvider SEARCH_INDEX_DATA_PROVIDER =
            new ChromeBaseSearchIndexProvider(
                    AeriumClearOnExitFragment.class.getName(),
                    R.xml.aerium_clear_on_exit_preferences);
}
AERIUM_COE_JAVA

sed_i 's|^  "java/src/org/chromium/chrome/browser/browsing_data/BrowsingDataCounterBridge.java",$|  "java/src/org/chromium/chrome/browser/browsing_data/AeriumClearOnExitFragment.java",\n&|' \
    chrome/android/chrome_java_sources.gni

# The layout is enumerated too - chrome_app_java_resources takes its sources
# from this list rather than globbing the directory, so a res/xml file that is
# not named here is simply not compiled into the APK and R.xml has no field for
# it.
sed_i 's|^  "java/res/xml/appearance_preferences.xml",$|  "java/res/xml/aerium_clear_on_exit_preferences.xml",\n&|' \
    chrome/android/chrome_java_resources.gni

sed_i 's|^        android:fragment="org.chromium.chrome.browser.browsing_data.ClearBrowsingDataFragment" />$|&\n    <Preference\n        android:key="aerium_clear_on_exit"\n        android:title="@string/aerium_clear_on_exit_title"\n        android:summary="@string/aerium_clear_on_exit_summary"\n        android:fragment="org.chromium.chrome.browser.browsing_data.AeriumClearOnExitFragment" />|' \
    chrome/android/java/res/xml/privacy_preferences.xml
# Registered in the settings-search index registry as well. That is not only
# about search: the registry is the one place that names every settings
# fragment in code, and a fragment reached solely through android:fragment in
# an XML file is invisible to R8, which would strip the class and turn opening
# the screen into a ClassNotFoundException.
SIPR=chrome/android/java/src/org/chromium/chrome/browser/settings/search/SearchIndexProviderRegistry.java
sed_i 's|^import org.chromium.chrome.browser.browsing_data.ClearBrowsingDataFragment;$|import org.chromium.chrome.browser.browsing_data.AeriumClearOnExitFragment;\n&|' \
    $SIPR
sed_i 's|^                    AboutChromeSettings.SEARCH_INDEX_DATA_PROVIDER,$|&\n                    AeriumClearOnExitFragment.SEARCH_INDEX_DATA_PROVIDER,|' \
    $SIPR

# The two triggers. The first is the clean close; the second marks the session
# as owing a deletion so a process that is killed without ever reaching
# onDestroy is cleaned up at the next launch instead - that flag is the one
# Chromium's own ProfileManager already checks at startup, so the catch-up is
# upstream code with upstream semantics and no second path.
#
# The mark is written after native initialisation rather than from the manager's
# constructor, and that ordering is the whole point: ProfileManager makes its
# check while the profile is still loading, so a flag set any earlier would be
# consumed by the check it is meant to arm for NEXT time, and every launch would
# re-delete data a clean close had already deleted. By the time an activity has
# finished native initialisation, that check is behind us.
#
# The observer clears the flag when a close-time deletion completes, and the
# else branch of ClearBrowsingDataForOnExitPolicy clears it once the switch is
# turned off, so it never outlives the setting.
sed_i 's|^import org.chromium.components.prefs.PrefChangeRegistrar;$|&\nimport org.chromium.components.prefs.PrefService;|' \
    chrome/android/java/src/org/chromium/chrome/browser/ChromeTabbedActivity.java
sed_i 's|^            recordFirstAppLaunchTimestampIfNeeded();$|&\n\n            // Aerium: see theme.sh. Mark this session as owing a deletion, so a\n            // process killed without an onDestroy is cleaned up at the next\n            // launch. Here rather than earlier because ProfileManager checks\n            // this flag while the profile is still loading.\n            if (ProfileManager.isInitialized()) {\n                PrefService aeriumStartPrefs =\n                        UserPrefs.get(ProfileManager.getLastUsedRegularProfile());\n                if (aeriumStartPrefs.getBoolean("browser.clear_data.aerium_clear_on_exit")) {\n                    aeriumStartPrefs.setBoolean(\n                            "browser.clear_data.clear_on_exit_pending", true);\n                }\n            }|' \
    chrome/android/java/src/org/chromium/chrome/browser/ChromeTabbedActivity.java
sed_i 's|^    public void onDestroyInternal() {$|&\n        // Aerium: see theme.sh. isFinishing() with no configuration change is\n        // what separates the browser being closed from the activity being\n        // recreated - onDestroy runs for a rotation too, and wiping someone'"'"'s\n        // cookies because they turned their phone sideways would be\n        // indefensible. The pref is the signal; the deletion itself is run by\n        // ChromeBrowsingDataLifetimeManager, which observes it.\n        if (isFinishing() \&\& !isChangingConfigurations() \&\& ProfileManager.isInitialized()) {\n            PrefService aeriumPrefs =\n                    UserPrefs.get(ProfileManager.getLastUsedRegularProfile());\n            if (aeriumPrefs.getBoolean("browser.clear_data.aerium_clear_on_exit")) {\n                aeriumPrefs.setBoolean("browser.clear_data.aerium_on_exit.requested", true);\n            }\n        }\n|' \
    chrome/android/java/src/org/chromium/chrome/browser/ChromeTabbedActivity.java

sed_i 's|^      <message name="IDS_AERIUM_PATCHES_TITLE" desc=|      <message name="IDS_AERIUM_CLEAR_ON_EXIT_TITLE" desc="Title of the settings screen that deletes browsing data every time the browser is closed.">\n        Delete browsing data on exit\n      </message>\n      <message name="IDS_AERIUM_CLEAR_ON_EXIT_SUMMARY" desc="Summary under that entry on the Privacy and security screen.">\n        Choose what is deleted every time you close Aerium\n      </message>\n      <message name="IDS_AERIUM_CLEAR_ON_EXIT_SWITCH_TITLE" desc="Title of the master switch on that screen.">\n        Delete on exit\n      </message>\n      <message name="IDS_AERIUM_CLEAR_ON_EXIT_SWITCH_SUMMARY" desc="Summary under the master switch, saying when the deletion happens.">\n        The types below are deleted when you close Aerium. If the browser is closed by the system before that happens, they are deleted the next time it starts.\n      </message>\n      <message name="IDS_AERIUM_CLEAR_ON_EXIT_TYPES_TITLE" desc="Header above the list of data types.">\n        What to delete\n      </message>\n      <message name="IDS_AERIUM_CLEAR_ON_EXIT_HISTORY" desc="Data type: pages visited.">\n        Browsing history\n      </message>\n      <message name="IDS_AERIUM_CLEAR_ON_EXIT_DOWNLOADS" desc="Data type: the list of downloaded files, not the files themselves.">\n        Download history\n      </message>\n      <message name="IDS_AERIUM_CLEAR_ON_EXIT_COOKIES" desc="Data type: cookies and other site storage. Signs you out of sites.">\n        Cookies and site data\n      </message>\n      <message name="IDS_AERIUM_CLEAR_ON_EXIT_CACHE" desc="Data type: the HTTP cache.">\n        Cached images and files\n      </message>\n      <message name="IDS_AERIUM_CLEAR_ON_EXIT_FORM_DATA" desc="Data type: text remembered from web forms.">\n        Autofill form data\n      </message>\n      <message name="IDS_AERIUM_CLEAR_ON_EXIT_PASSWORDS" desc="Data type: saved sign-in details.">\n        Saved passwords\n      </message>\n      <message name="IDS_AERIUM_CLEAR_ON_EXIT_SITE_SETTINGS" desc="Data type: per-site permissions such as camera or location.">\n        Site settings\n      </message>\n      <message name="IDS_AERIUM_CLEAR_ON_EXIT_HOSTED_APPS" desc="Data type: data belonging to installed web apps.">\n        Hosted app data\n      </message>\n&|' \
    chrome/browser/ui/android/strings/android_chrome_strings.grd
# --- Never sit on the launch screen forever.
#
# Chromium blocks ChromeTabbedActivity's first draw on purpose, so a cold start
# does not flash an empty toolbar before the initial tab is ready.
# AppLaunchDrawBlocker installs an OnPreDrawListener that returns false until
# one of two conditions fires - onActiveTabAvailable() for the initial-tab
# case, and IncognitoRestoreAppLaunchDrawBlocker's unblock runnable for the
# incognito-restore case - and returning false from onPreDraw cancels the draw
# pass.
#
# Neither condition has a deadline. If either never arrives - a restored NTP
# tab whose onContentChanged never fires, an initial tab creation that does not
# happen because PartnerBrowserCustomizations never calls back, an observer
# that throws on the way - the process is alive and healthy and simply never
# paints, so Android keeps showing the launcher icon on the splash screen.
# That is the "stuck on the Aerium logo" report: not a crash, since there is no
# dialog and no restart, and not a frozen UI thread, since input still reaches
# it - just a first frame that never comes.
#
# Chromium can afford an unbounded wait because Finch can turn the blocker off
# in the field within hours; a self-built browser cannot. So the wait gets an
# upper bound - the blocker's own
# Android.AppLaunchDrawBlocker.ActiveTabAvailable histogram is measured in
# hundreds of milliseconds, so a launch that is merely slow still gets the
# flicker-free start the blocker exists to provide, while a launch that is
# broken shows the browser instead of the logo. The worst case this can cause
# is the flash of empty toolbar the feature was written to avoid, which is a
# far better failure than never starting.
#
# The bound was five seconds and is now two, because five turned out to be a
# per-launch cost rather than an emergency brake. ChromeTabbedActivity decides
# whether to wait like this:
#
#   if (isTabNtp && !currentTab.isNativePage() && !isTabWebUiNtp) {
#       currentTab.addObserver(... onContentChanged -> onActiveTabAvailable());
#   } else {
#       mAppLaunchDrawBlocker.onActiveTabAvailable();
#   }
#
# An extension-provided new tab page keeps chrome://newtab as its virtual URL,
# so isTabNtp is true; it is not a native page, so isNativePage() is false; and
# isTabWebUiNtp only covers the WebUI override, gated on sUseWebUiNtpAndroid
# and a Google default search engine. So it takes the waiting branch and sits
# there until the extension's page commits - which on a cold start, for an
# extension that fetches anything, is seconds.
#
# Upstream already knows this shape of hang. The comment beside isTabWebUiNtp
# reads "The WebUI NTP is not a native Tab, so we don't wait for it to be
# created, otherwise it hangs the rendering thread." An extension NTP is not a
# native tab either; the guard simply does not cover it.
#
# Two seconds is still several times the normal path. The complete fix is to
# not wait at all when the new tab page comes from an extension, which needs a
# signal for that at the point the decision is made - the tab has committed
# nothing yet, so its URL cannot answer it. Worth doing, and worth doing with a
# device to test against rather than by inference.
#
# invalidate() matters as much as the flags. onPreDraw is only consulted when
# something asks for a draw, and the reason nothing is on screen is precisely
# that nothing is asking; flipping the booleans alone would leave the deadline
# waiting for a draw pass that may never be scheduled.
ALDB=chrome/android/java/src/org/chromium/chrome/browser/ui/AppLaunchDrawBlocker.java
sed_i 's|^import org.chromium.base.supplier.MonotonicObservableSupplier;$|&\nimport org.chromium.base.task.PostTask;\nimport org.chromium.base.task.TaskTraits;|' \
    $ALDB
sed_i 's|^    private final long mStartTime;$|&\n\n    /**\n     * Aerium: upper bound on how long the launch draw may stay blocked. See\n     * theme.sh - without it a condition that never fires means a browser that\n     * never paints.\n     */\n    private static final long AERIUM_DRAW_BLOCK_TIMEOUT_MS = 5000;\n\n    /** Aerium: whether the deadline above has been armed for this launch. */\n    private boolean mAeriumDrawUnblockScheduled;|' \
    $ALDB
sed_i 's|^        mBlockDrawForIncognitoRestore = true;$|&\n        aeriumScheduleDrawUnblock();|' \
    $ALDB
sed_i 's|^            mBlockDrawForInitialTab = true;$|&\n            aeriumScheduleDrawUnblock();|' \
    $ALDB
sed_i 's|^    /\*\* Should be called when the initial tab is available. \*/$|    /**\n     * Aerium: arms the deadline described in theme.sh. Armed once, the first\n     * time either client blocks the draw, and never cancelled - the whole\n     * point is that it fires even when the condition it covers for does not.\n     */\n    private void aeriumScheduleDrawUnblock() {\n        if (mAeriumDrawUnblockScheduled) return;\n        mAeriumDrawUnblockScheduled = true;\n        PostTask.postDelayedTask(\n                TaskTraits.UI_DEFAULT,\n                () -> {\n                    if (!mBlockDrawForInitialTab \&\& !mBlockDrawForIncognitoRestore) return;\n                    // Recorded before the flags are flipped, and split so\n                    // that chrome://histograms says WHICH condition failed to\n                    // arrive. There is no logcat on a shipped build, and this\n                    // is the only evidence a user can read back.\n                    RecordHistogram.recordBooleanHistogram(\n                            "Android.AppLaunchDrawBlocker.AeriumTimedOut.InitialTab",\n                            mBlockDrawForInitialTab);\n                    RecordHistogram.recordBooleanHistogram(\n                            "Android.AppLaunchDrawBlocker.AeriumTimedOut.IncognitoRestore",\n                            mBlockDrawForIncognitoRestore);\n                    mBlockDrawForInitialTab = false;\n                    mBlockDrawForIncognitoRestore = false;\n                    // onPreDraw is only consulted when something asks for a\n                    // draw, and nothing is asking - that is why the screen is\n                    // still empty. Ask for one.\n                    mViewSupplier.get().invalidate();\n                },\n                AERIUM_DRAW_BLOCK_TIMEOUT_MS);\n    }\n\n&|' \
    $ALDB

# --- The incognito overflow menu, black like every other surface.
#
# ChromeTabbedActivity.applyThemeOverlays() ends with:
#
#     if (isIncognitoWindow()) {
#         // This overlay is for incognito windowing. Any overlay that attempts
#         // to change color roles should be placed before this call in order to
#         // not alter incognito coloring.
#         applySingleThemeOverlay(R.style.ThemeOverlay_BrowserUI_TabbedMode_Incognito);
#     }
#
# and that overlay is color_palette_dark_attributes() - the whole Material
# baseline dark palette, colorSurface through colorSurfaceContainerHighest.
# The pure black overlay is applied inside super.applyThemeOverlays(), so in an
# incognito window it is applied first and then overwritten, exactly as the
# comment above warns.
#
# Most incognito surfaces still came out black anyway, because the pure black
# section further up patches ChromeColors to read aeriumIncognitoBgColor - an
# attribute the incognito overlay does not define, so it survives. Anything
# that resolves a stock Material role instead does not: the overflow menu
# background is popupBgShape -> popup_bg_shape_24dp -> @macro/menu_bg_color ->
# ?attr/colorSurfaceBright, which the incognito overlay has just put back to
# Material's dark grey. Hence a black browser with a grey three-dot menu.
#
# Re-applying afterwards is what the upstream comment actually asks for, and it
# fixes every role at once rather than adding a second one-off attribute for
# the menu - dialogs, bottom sheets and cards in incognito were grey for the
# same reason and are covered by the same two lines.
#
# Gated identically to the copy in ChromeBaseAppCompatActivity, so the switch
# still turns it off; incognito is always dark, so the night mode half of the
# gate is always true here.
sed_i 's|^            applySingleThemeOverlay(R.style.ThemeOverlay_BrowserUI_TabbedMode_Incognito);$|&\n            // Aerium: see theme.sh. The overlay above is the full Material\n            // baseline dark palette and it has just overwritten every colour\n            // role the pure black overlay set in super.applyThemeOverlays(),\n            // which is what left the overflow menu grey inside a black\n            // browser. Re-applied here, which is where the comment above says\n            // a colour overlay belongs.\n            if (getNightModeStateProvider().isInNightMode()\n                    \&\& ChromeSharedPreferences.getInstance()\n                            .readBoolean(ChromePreferenceKeys.AERIUM_PURE_BLACK, true)) {\n                applySingleThemeOverlay(R.style.ThemeOverlay_BrowserUI_AeriumPureBlack);\n            }|' \
    chrome/android/java/src/org/chromium/chrome/browser/ChromeTabbedActivity.java

# --- Payment methods, off and out of reach.
#
# The screens were already unreachable by navigation: patch.sh drops the six
# autofill and payment entries from main_preferences.xml, MainSettings removes
# whatever survives, and shouldShowPasswordsAndAutofillParentItem() returns
# false so the three-dot menu never builds the submenu that held Payment
# methods. What none of that touched is the storage itself or the settings
# search index.
#
# Storage first. kAutofillCreditCardEnabled defaults to true, so with no UI
# left to turn it off the browser was still offering to save cards and filling
# them into checkout forms - the behaviour the missing screen implies is gone.
# kAutofillPaymentCardBenefits follows it, and kCanMakePaymentEnabled is the
# "let sites check whether you have a payment method saved" switch, which is
# the one piece of this a web page can observe directly.
#
# Then the index. SearchIndexProviderRegistry.ALL_PROVIDERS is a list of every
# searchable fragment, and it still named the whole autofill cluster, so typing
# "payment" into Settings search found Payment methods and opened it - a screen
# with no entry point anywhere else in the browser. The payments rows go, and
# so do their siblings, for two reasons: the same argument applies to each of
# them (they are all screens patch.sh already removed), and leaving the
# "Autofill and passwords" parent behind would keep a searchable route to its
# children whether or not their own rows were gone.
#
# Removing rows here is also what keeps R8 honest - this registry is the only
# place naming these fragments in code, so once they are out of it the classes
# themselves can be dropped from the APK. That is safe precisely because every
# entry point is gone; a fragment nothing can start is a fragment nothing can
# fail to load.
sed_i 's|^      kAutofillCreditCardEnabled, true,$|      kAutofillCreditCardEnabled, false,|' \
    components/autofill/core/common/autofill_prefs.cc
sed_i 's|^      kAutofillPaymentCardBenefits, true,$|      kAutofillPaymentCardBenefits, false,|' \
    components/autofill/core/common/autofill_prefs.cc
# kCanMakePaymentEnabled is already false by the time this runs - Vanadium
# patch 0079 flips it - so there is nothing here to substitute, and a sed that
# tried would fail the build on its own no-op guard. What is worth keeping is
# the assertion: if Vanadium ever drops 0079, the switch comes back on with no
# settings UI in this build to turn it off, and a web page regains the ability
# to ask whether a payment method is saved. That is a behaviour regression no
# compiler would catch, so check the outcome rather than redo the work.
#
# Written as "is the pristine line still here" rather than "is the patched line
# missing", for the same reason patch.sh's autofill check is: devutils/verify-seds.sh
# sources this over a sparse tree where the file may not have been fetched at
# all, and a check phrased the other way round would fire on the absence of the
# file and stop the rest of this script from being verified.
PAYMENT_PREFS=components/payments/core/payment_prefs.cc
if [ -e $PAYMENT_PREFS ] && grep -q 'kCanMakePaymentEnabled, true,' $PAYMENT_PREFS; then
    echo "[aerium] FATAL: kCanMakePaymentEnabled is back to defaulting true in" \
         "$PAYMENT_PREFS - Vanadium patch 0079 no longer flips it. Sites can" \
         "now ask whether a payment method is saved, and Aerium ships no" \
         "settings screen to turn that off. Flip it here instead." >&2
    return 1
fi
sed_i -E '/^ +(AndroidPaymentAppsFragment|AutofillAndPasswordsFragment|AutofillBuyNowPayLaterFragment|AutofillCardBenefitsFragment|AutofillIdentityDocsFragment|AutofillOptionsFragment|AutofillPaymentMethodsFragment|AutofillPersonalContextFragment|AutofillProfilesFragment|AutofillShoppingFragment|AutofillTravelFragment|FinancialAccountsManagementFragment|NonCardPaymentMethodsManagementFragment)\.SEARCH_INDEX_DATA_PROVIDER,$/d' \
    $SIPR

# The last payment row left standing was not in the autofill cluster at all.
# Settings > Privacy and security still carried "Access payment methods"
# (IDS_CAN_MAKE_PAYMENT_TITLE), the switch behind PaymentRequest's
# canMakePayment(), because it lives in privacy_preferences.xml rather than in
# main_preferences.xml where patch.sh does its removals.
#
# It reads as a contradiction to anyone who opens that screen. The browser has
# no payment methods to access - every screen that could hold one is gone - so
# the row offers to let sites check a store that cannot exist. Worse, it is a
# live switch: the pref underneath is false (Vanadium patch 0079), and one tap
# turns it back on, restoring the one part of this whole area a web page can
# observe directly.
#
# So the row goes, matched by key the way patch.sh matches its own, and for the
# same reasons: an element found by key survives upstream adding or reordering
# attributes, [^<>] cannot run past the element it started in, and a key that
# matches nothing is fatal rather than skipped.
perl -0777 -pi -e '
    s{[ \t]*<[\w.]+\b[^<>]*?android:key="can_make_payment"[^<>]*?/>\n}{}s
        or die "[aerium] FATAL: no element with android:key=\"can_make_payment\" "
               . "in privacy_preferences.xml - upstream renamed or restructured "
               . "it\n";
' chrome/android/java/res/xml/privacy_preferences.xml

# And the Java that binds it. This is the half that matters: PrivacySettings
# reads the row twice, and only one of the two reads tolerates its absence.
# updatePreferences() already null-checks before calling setChecked; the
# constructor path does not, so findPreference returns null and
# setOnPreferenceChangeListener throws the moment Privacy and security is
# opened. That exact mismatch - an XML entry removed while the Java still
# expected it - is what made Settings crash on open in the 151 build, which
# patch.sh's own comment records.
#
# Guarding rather than deleting the three lines, because the guard is the shape
# upstream already uses two methods down for the same preference. If upstream
# ever restores the row, this code keeps working either way.
sed_i 's|^        canMakePaymentPref.setOnPreferenceChangeListener(this);$|        if (canMakePaymentPref != null) {\n            canMakePaymentPref.setOnPreferenceChangeListener(this);\n        }|' \
    chrome/android/java/src/org/chromium/chrome/browser/privacy/settings/PrivacySettings.java

# --- Put the SurfaceControl switch back in chrome://flags.
#
# Reported against this repo: on a Vivo X100 Ultra running Android 16, whose
# panel runs 1-120 Hz for other apps, the browser scrolls at 60. Two things are
# worth separating there.
#
# The browser is not asking for 60. WindowAndroid's only lever on the display
# is WindowManager.LayoutParams.preferredDisplayModeId, and it is left at 0 -
# no preference - unless a video wants a particular rate. What decides whether
# an LTPO panel ramps up is the system, from how the app's surface votes its
# frame rate, and OEM shells differ wildly in how they read that vote. That is
# why the reporter sees Edge and Opera behave differently on the same phone.
#
# Chromium 152 has the beginning of a real answer -
# UseFrameIntervalDeciderAdaptiveFrameRate implements Android 16's adaptive
# refresh rate API, mapping scroll velocity to a requested frame rate. It is
# off by default upstream, it is already exposed as #android-adaptive-frame-rate,
# and the reporter says turning it on changed nothing on their device. So its
# default is left alone: flipping an unfinished viz feature on for everyone, on
# the strength of one report where it demonstrably did not help, would be a
# change with no evidence behind it.
#
# What is worth doing is giving back the workaround that did work for them.
# AndroidSurfaceControl is still a feature and still enabled by default in
# gpu_finch_features.cc; what 152 removed is only its chrome://flags entry and
# its two description strings. So the toggle exists and nothing in the browser
# can reach it. Restoring the entry costs a few lines, changes no default, and
# hands anyone on a panel that behaves this way a switch they can try - which
# is precisely what an experiments page is for.
#
# ::features:: and not ::gpu::features::. gpu_finch_features.h opens `namespace
# gpu` only to forward-declare GpuFeatureInfo; every feature in it, this one
# included, lives in the GLOBAL `features` namespace. That is what the 236 other
# FEATURE_VALUE_TYPE entries in about_flags.cc use. The leading :: is worth
# keeping anyway: the flag table sits inside about_flags::{anonymous}, so an
# unqualified `features::` would break the day anything declares a nested one.
# about_flags.cc already includes the header at the top, so nothing else needed.
sed_i 's|^inline constexpr char kAndroidAdaptiveFrameRateName\[\] =$|inline constexpr char kAeriumAndroidSurfaceControlName[] =\n    "Android SurfaceControl";\ninline constexpr char kAeriumAndroidSurfaceControlDescription[] =\n    "Use SurfaceControl to composite the browser'"'"'s output, which lets the "\n    "system put it in a hardware overlay. Chromium enables this by default. "\n    "Turning it off changes how the browser presents frames, which on some "\n    "phones is what decides whether the panel runs above 60 Hz while "\n    "scrolling. Off costs power on most devices - only worth trying if this "\n    "one is capping the refresh rate.";\n\n&|' \
    chrome/browser/flag_descriptions.h
sed_i 's|^    {"android-adaptive-frame-rate",$|    {"android-surface-control",\n     flag_descriptions::kAeriumAndroidSurfaceControlName,\n     flag_descriptions::kAeriumAndroidSurfaceControlDescription, kOsAndroid,\n     FEATURE_VALUE_TYPE(::features::kAndroidSurfaceControl)},\n\n&|' \
    chrome/browser/about_flags.cc
# --- The site rules table: sites whose data survives the on-exit deletion.
#
# The desktop repos have this as Cookie AutoDelete's table - an expression per
# row, a list type, and a Keep checkbox per data type - backed by a list-of-
# dictionaries pref and a WebUI page. Two things about that do not port.
#
# The pref. Android's PrefService is exposed to Java as scalars only: getString,
# getBoolean, getInteger and their setters, and nothing that can read or write a
# list of dictionaries. Adding a JNI bridge for one settings screen is a lot of
# build surface for a table, so the rules live in a string pref holding the same
# JSON objects desktop stores natively. Java reads and writes the string; the
# C++ parses it with base::JSONReader. The object shape is deliberately
# identical to desktop's, so the two can be brought together later without a
# migration on either side.
#
# What a rule can protect. content::BrowsingDataRemover can only exclude sites
# from the types in FILTERABLE_DATA_TYPES, and browsing history, form data,
# passwords and site settings are not among them - there is no filtered history
# removal in this API at all. So a rule protects the three that are: cookies and
# site data, cached files, and download history. The screen says exactly that
# rather than offering eight checkboxes of which five would quietly do nothing.
#
# Regular expressions are not offered here either, and that is the same
# constraint seen from the other side. A kPreserve filter is a list of
# registrable domains; a regular expression cannot be turned into one without
# enumerating every origin holding data, which desktop can do from its own site
# data model and this has no equivalent for. A pattern is a site.
#
# Which also settles the subdomain question. AddRegisterableDomain() takes an
# eTLD+1 - it DCHECKs anything else that is not an IP literal or a single-label
# host - so a rule for mail.example.com protects example.com and everything
# under it. Widening rather than narrowing is the safe direction for a rule
# whose job is to stop a deletion, and the screen says so in as many words.
#
# Header-only, and the same reasoning as aerium_first_run.h and
# aerium_patches.h: one translation unit includes this, so inline definitions
# need no .cc and no BUILD.gn entry, which keeps a hundred lines of parsing out
# of the resource and build pipeline entirely.
cat > chrome/browser/browsing_data/aerium_site_rules.h <<'AERIUM_SITE_RULES_H'
// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CHROME_BROWSER_BROWSING_DATA_AERIUM_SITE_RULES_H_
#define CHROME_BROWSER_BROWSING_DATA_AERIUM_SITE_RULES_H_

#include <stdint.h>

#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>

#include "base/json/json_reader.h"
#include "base/strings/string_util.h"
#include "base/values.h"
#include "chrome/browser/browsing_data/chrome_browsing_data_remover_constants.h"
#include "components/browsing_data/core/pref_names.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browsing_data_remover.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "url/gurl.h"

// Aerium: the site rules table. See theme.sh for why this is a string pref
// holding JSON rather than the list-of-dictionaries pref the desktop repos
// use - Android's Java PrefService can only carry scalars, and the settings
// screen is written in Java.
namespace aerium_site_rules {

// The data types a rule can protect, and the keys the settings screen writes
// for them.
//
// Every one is in chrome_browsing_data_remover::FILTERABLE_DATA_TYPES, which is
// not a detail: handing an unfilterable type to a filtered removal trips a
// CHECK in ChromeBrowsingDataRemoverDelegate::RemoveEmbedderData() and takes
// release builds down with it. That is also why browsing history is absent -
// there is no filtered history removal in this API, so a rule cannot promise
// one.
struct TypeEntry {
  const char* key;
  uint64_t type;
};

inline constexpr TypeEntry kTypes[] = {
    {"site_data", chrome_browsing_data_remover::DATA_TYPE_SITE_DATA},
    {"cache", content::BrowsingDataRemover::DATA_TYPE_CACHE},
    {"downloads", content::BrowsingDataRemover::DATA_TYPE_DOWNLOADS},
};

// Strips the sugar people paste in - a leading "*." or "[*.]", a scheme, a
// trailing path - and returns the registrable domain of what is left, which is
// the only thing BrowsingDataFilterBuilder::AddRegisterableDomain() accepts.
// Empty when the pattern cannot be read as a site at all, in which case the
// rule is dropped: a rule that matches nothing is a smaller mistake than one
// that matches everything.
inline std::string RegistrableDomainFor(std::string_view pattern) {
  std::string host =
      base::ToLowerASCII(base::TrimWhitespaceASCII(pattern, base::TRIM_ALL));
  if (base::StartsWith(host, "[*.]")) {
    host = host.substr(4);
  } else if (base::StartsWith(host, "*.")) {
    host = host.substr(2);
  }
  const size_t scheme_end = host.find("://");
  if (scheme_end != std::string::npos) {
    host = host.substr(scheme_end + 3);
  }
  const size_t slash = host.find('/');
  if (slash != std::string::npos) {
    host = host.substr(0, slash);
  }
  while (!host.empty() && host.back() == '.') {
    host.pop_back();
  }
  if (host.empty()) {
    return std::string();
  }
  const GURL url("http://" + host + "/");
  if (!url.is_valid() || !url.has_host()) {
    return std::string();
  }
  const std::string domain = net::registry_controlled_domains::GetDomainAndRegistry(
      url, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  // An IP literal or a single-label host has no registrable domain, and
  // AddRegisterableDomain() takes both as themselves.
  return domain.empty() ? url.GetHost() : domain;
}

// The sites to spare, grouped by the set of data types that spares them.
//
// Grouped because the remover takes one mask per call while a rule names its
// own types, so the alternative is one removal per type. In practice people
// tick the same boxes on every row and this collapses to a single group; the
// grouping exists so that it degrades to at most three when they do not.
//
// `remove_mask` is what the deletion was going to remove anyway - a rule
// protecting a type nobody was deleting is not worth a removal call, and
// asking for one would delete that type from every OTHER site as a side
// effect, which is the opposite of what the row says.
inline std::map<uint64_t, std::set<std::string>> KeepGroups(
    PrefService* prefs,
    uint64_t remove_mask) {
  std::map<uint64_t, std::set<std::string>> groups;
  if (!prefs) {
    return groups;
  }
  const std::string raw =
      prefs->GetString(browsing_data::prefs::kAeriumOnExitSiteRules);
  if (raw.empty()) {
    return groups;
  }
  const std::optional<base::Value> parsed =
      base::JSONReader::Read(raw, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_list()) {
    return groups;
  }

  std::map<uint64_t, std::set<std::string>> by_type;
  for (const base::Value& entry : parsed->GetList()) {
    const base::DictValue* const dict = entry.GetIfDict();
    if (!dict) {
      continue;
    }
    const std::string* const pattern = dict->FindString("pattern");
    if (!pattern) {
      continue;
    }
    const std::string domain = RegistrableDomainFor(*pattern);
    if (domain.empty()) {
      continue;
    }
    // Aerium: only a keep rule spares a site from the on-exit sweep. An
    // ephemeral rule is the opposite instruction, and a session-only rule
    // explicitly wants the site gone at shutdown - sparing either here would
    // contradict the row.
    const std::string* const mode = dict->FindString("mode");
    if (mode && *mode != "keep") {
      continue;
    }
    const base::DictValue* const keep = dict->FindDict("keep");
    if (!keep) {
      continue;
    }
    for (const TypeEntry& type : kTypes) {
      if ((remove_mask & type.type) == 0) {
        continue;
      }
      if (keep->FindBool(type.key).value_or(false)) {
        by_type[type.type].insert(domain);
      }
    }
  }

  // Fold the types that spare exactly the same sites into one mask. Keyed on
  // the set rather than compared pairwise so this stays linear in the number of
  // types, which is three.
  std::map<std::set<std::string>, uint64_t> by_domains;
  for (const auto& entry : by_type) {
    if (entry.second.empty()) {
      continue;
    }
    by_domains[entry.second] |= entry.first;
  }
  for (const auto& entry : by_domains) {
    groups[entry.second] = entry.first;
  }
  return groups;
}

// The registrable domains of every rule in one mode.
//
// Same list and same folding as KeepGroups() above, deliberately: one table,
// three modes, one idea of what a site is. A row is exactly one mode, which is
// why KeepGroups() takes only "keep" and this takes only what it is asked for,
// and why a domain can never end up both kept and deleted.
//
// The modes:
//   keep       spared from the deletion when the browser closes. The default,
//              and what a row with no mode at all is.
//   session    kept while the browser runs and cleared at shutdown, whether or
//              not the delete-on-exit switch is on. Cookie AutoDelete's middle
//              tier: signed in while you work, not tomorrow.
//   ephemeral  cleared as soon as its last tab closes.
inline std::set<std::string> DomainsForMode(PrefService* prefs,
                                            std::string_view mode) {
  std::set<std::string> domains;
  if (!prefs) {
    return domains;
  }
  const std::string raw =
      prefs->GetString(browsing_data::prefs::kAeriumOnExitSiteRules);
  if (raw.empty()) {
    return domains;
  }
  const std::optional<base::Value> parsed =
      base::JSONReader::Read(raw, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_list()) {
    return domains;
  }
  for (const base::Value& entry : parsed->GetList()) {
    const base::DictValue* const dict = entry.GetIfDict();
    if (!dict) {
      continue;
    }
    const std::string* const entry_mode = dict->FindString("mode");
    // A row written before modes existed has no key and is a keep rule.
    const std::string_view resolved = entry_mode ? std::string_view(*entry_mode)
                                                 : std::string_view("keep");
    if (resolved != mode) {
      continue;
    }
    const std::string* const pattern = dict->FindString("pattern");
    if (!pattern) {
      continue;
    }
    const std::string domain = RegistrableDomainFor(*pattern);
    if (!domain.empty()) {
      domains.insert(domain);
    }
  }
  return domains;
}

// What an ephemeral rule removes.
//
// Cookies and site data always; the HTTP cache only if asked for. Both are in
// FILTERABLE_DATA_TYPES, which is the whole constraint - handing an unfilterable
// type to a filtered removal trips a CHECK in
// ChromeBrowsingDataRemoverDelegate::RemoveEmbedderData() and takes release
// builds down with it. That rules out history, form data and passwords here for
// exactly the reason it rules them out of the keep rules.
//
// Cache is off by default because clearing it every time a tab closes means
// re-fetching that site's images, fonts and scripts on the next visit - a speed
// and data cost that should be asked for rather than arrive in an update.
inline uint64_t EphemeralRemoveMask(PrefService* prefs) {
  uint64_t mask = chrome_browsing_data_remover::DATA_TYPE_SITE_DATA;
  if (prefs && prefs->GetBoolean(
                   browsing_data::prefs::kAeriumEphemeralClearCache)) {
    mask |= content::BrowsingDataRemover::DATA_TYPE_CACHE;
  }
  return mask;
}

}  // namespace aerium_site_rules

#endif  // CHROME_BROWSER_BROWSING_DATA_AERIUM_SITE_RULES_H_
AERIUM_SITE_RULES_H

# The pref itself, beside the rest of the on-exit set it belongs to. A string
# rather than a list because the settings screen that writes it is Java - see
# the note above. "[]" rather than "" as the default so a reader that does not
# guard the empty case still sees a well-formed empty table.
sed_i 's|^inline constexpr char kAeriumClearOnExitHostedAppData\[\] =$|// Aerium: the site rules table, as a JSON array of\n// {"pattern": ..., "mode": "keep", "session" or "ephemeral",\n//  "keep": {"site_data": bool, "cache": bool, "downloads": bool}}.\n// Same object shape as the desktop repos'"'"' native list pref, so the two can be\n// brought together later without migrating either. "mode" is absent on every\n// rule written before it existed and reads as "keep", which is what those rules\n// were, so there is nothing to migrate here either.\ninline constexpr char kAeriumOnExitSiteRules[] =\n    "browser.clear_data.aerium_on_exit.site_rules";\n\n// Aerium: whether clearing a site when its last tab closes takes the HTTP cache\n// with it. Off by default - see EphemeralRemoveMask() in\n// chrome/browser/browsing_data/aerium_site_rules.h.\ninline constexpr char kAeriumEphemeralClearCache[] =\n    "browser.clear_data.aerium_ephemeral_clear_cache";\n\n// Aerium: turns the table inside out. Every site is cleared when its last tab\n// closes, and the keep and session-only rows become the list of exceptions.\n// This is the model Cookie AutoDelete actually uses. Off by default, because\n// turning it on signs the user out of every site not named in the table - a\n// thing to opt into, never to receive in an update.\ninline constexpr char kAeriumEphemeralAllSites[] =\n    "browser.clear_data.aerium_ephemeral_all_sites";\n\n// Aerium: how long after a site loses its last tab before it is cleared.\n// Sign-in flows bounce through a provider in a tab that closes itself, and\n// OAuth popups close the moment they hand back a token, so clearing the instant\n// the count reaches zero can delete the cookie the redirect is about to need.\n// It also forgives closing a tab by accident. Clamped to 0-3600 where it is\n// read, so a hand-edited Preferences file cannot disable the feature with a\n// negative or enormous value.\ninline constexpr char kAeriumEphemeralDelaySeconds[] =\n    "browser.clear_data.aerium_ephemeral_delay_seconds";\n\n&|' \
    components/browsing_data/core/pref_names.h
sed_i 's|^  registry->RegisterBooleanPref(kAeriumClearOnExitHostedAppData, false);$|&\n  registry->RegisterStringPref(kAeriumOnExitSiteRules, "[]");\n  registry->RegisterBooleanPref(kAeriumEphemeralClearCache, false);\n  registry->RegisterBooleanPref(kAeriumEphemeralAllSites, false);\n  registry->RegisterIntegerPref(kAeriumEphemeralDelaySeconds, 10);|' \
    components/browsing_data/core/pref_names.cc

# The deletion honours them. Everything the rules do NOT protect still goes
# through the single unfiltered removal above; what they do protect is taken
# out of that mask and re-issued as one filtered removal per group, with the
# spared sites expressed as a kPreserve filter.
#
# Only the Aerium half of the mask is narrowed. GetRemoveMask(data_types) is the
# enterprise ClearBrowsingDataOnExitList policy and is left whole - a rule a
# user typed into Settings must not be able to opt a managed device out of its
# policy.
sed_i 's|#include "chrome/browser/browsing_data/chrome_browsing_data_remover_constants.h"|#include "chrome/browser/browsing_data/aerium_site_rules.h"\n&|' \
    $CBDLM
# aerium_site_rules.h pulls <map> in anyway, but a translation unit that uses
# std::map should say so rather than inherit it from whatever it included.
sed_i 's|^#include <limits>$|&\n#include <map>|' $CBDLM
sed_i 's|^  const bool aerium_on_exit = aerium_remove_mask != 0;$|&\n\n  // Aerium: the site rules table. Read once here because the mask handed to the\n  // unfiltered removal below has to have the protected types taken out of it\n  // before that call is made.\n  const std::map<uint64_t, std::set<std::string>> aerium_keep_groups =\n      aerium_on_exit ? aerium_site_rules::KeepGroups(aerium_prefs,\n                                                     aerium_remove_mask)\n                     : std::map<uint64_t, std::set<std::string>>();\n  uint64_t aerium_protected_mask = 0;\n  for (const auto\& aerium_group : aerium_keep_groups) {\n    aerium_protected_mask \|= aerium_group.first;\n  }|' \
    $CBDLM
sed_i 's|^                            GetRemoveMask(data_types) \| aerium_remove_mask,$|                            GetRemoveMask(data_types) \|\n                                (aerium_remove_mask \& ~aerium_protected_mask),|' \
    $CBDLM
sed_i 's|^                                keep_browser_alive));$|&\n\n    // Aerium: and the protected types, once per group, sparing the sites the\n    // rules name. base::Time() to base::Time::Max() and the same origin type\n    // mask as above, so a spared site is the only difference between these\n    // removals and the one before them.\n    for (const auto\& aerium_group : aerium_keep_groups) {\n      auto aerium_filter = content::BrowsingDataFilterBuilder::Create(\n          content::BrowsingDataFilterBuilder::Mode::kPreserve);\n      for (const std::string\& aerium_domain : aerium_group.second) {\n        aerium_filter->AddRegisterableDomain(aerium_domain);\n      }\n      remover->RemoveWithFilterAndReply(\n          base::Time(), base::Time::Max(), aerium_group.first,\n          GetOriginTypeMask(data_types) \|\n              AeriumOnExitOriginTypeMask(aerium_prefs),\n          std::move(aerium_filter),\n          BrowsingDataRemoverObserver::Create(\n              remover, /*filterable_deletion=*/true, profile_,\n              keep_browser_alive));\n    }|' \
    $CBDLM
# --- Reset a site as soon as its last tab closes.
#
# The site rules table answers "keep these when I quit". This is the opposite
# instruction for the same table - "never let this one persist at all" - for the
# account you do not want following you around but do not want to give up every
# other login to avoid. It is independent of the delete-on-exit switch, because
# it is a property of the site rather than of shutdown.
#
# One table, two modes, rather than a second screen. A row is a keep rule or an
# ephemeral rule, never both - KeepGroups() skips ephemeral rows and
# EphemeralDomains() skips everything else - and both fold their pattern through
# the same RegistrableDomainFor(), so the two modes cannot disagree about what
# counts as one site. Rules written before "mode" existed have no such key and
# read as "keep", which is what they were, so nothing needs migrating.
#
# Scope is cookies and storage, plus the cache if asked. Nothing else can be
# honestly offered: ChromeBrowsingDataRemoverDelegate::RemoveEmbedderData()
# CHECKs - not DCHECKs, so it aborts release builds too - that a filtered
# removal's mask is a subset of FILTERABLE_DATA_TYPES, and history, autofill,
# passwords and site settings are all outside it because their backends ignore
# the origin filter entirely.
#
# Where the desktop repos differ
# ------------------------------
# The desktop patch implements this half under #if !BUILDFLAG(IS_ANDROID),
# because it hangs off BrowserCollectionObserver and TabStripModelObserver and
# Android has neither. Android has the exact counterparts - TabModelListObserver
# for models coming and going, TabModelObserver for what happens inside one -
# so this is the same design against the other pair of interfaces, in the same
# class, for the same reason: ChromeBrowsingDataLifetimeManager already owns
# on-exit clearing for the profile, already holds the BrowsingDataRemover
# plumbing, and - most usefully - GetOpenedUrlsAndOngoingDownloads() already has
# an Android arm that walks TabModelList. Keeping both behaviours in one place
# is also what stops the on-exit and on-tab-close paths drifting apart.
#
# Which closure signal
# --------------------
# TabClosureCommitted() and AllTabsClosureCommitted(), not OnFinishingTabClosure().
# Android tab closes are undoable: closing a tab shows a snackbar and the tab
# comes back if it is tapped. Clearing on "finishing" would empty a site's
# cookies and then hand the user back a tab that is suddenly signed out, which
# is a worse outcome than clearing a few seconds later. The committed callbacks
# are documented as firing when the closure "can't be undone anymore", which is
# the moment the site really has no tab.
#
# The work is always posted rather than done inline, because at the point these
# fire the closing tab can still be reachable from the model and would count
# itself as open.
sed_i 's|^  "+chrome/browser/ui/android/tab_model/tab_model_list.h",$|&\n  // Aerium: the ephemeral half of the site rules table watches tab models\n  // appearing and disappearing, and closures inside them, to notice when a\n  // marked site has no tab left. The two headers above are already allowed;\n  // these are their observer interfaces.\n  "+chrome/browser/ui/android/tab_model/tab_model_list_observer.h",\n  "+chrome/browser/ui/android/tab_model/tab_model_observer.h",|' \
    chrome/browser/browsing_data/DEPS

BDLM_H=chrome/browser/browsing_data/chrome_browsing_data_lifetime_manager.h
sed_i 's|#include "components/keyed_service/core/keyed_service.h"|#include <set>\n\n&\n#include "chrome/browser/ui/android/tab_model/tab_model_list_observer.h"\n#include "chrome/browser/ui/android/tab_model/tab_model_observer.h"|' \
    $BDLM_H
sed_i 's|^class ChromeBrowsingDataLifetimeManager : public KeyedService {$|// Aerium: this class also drives the ephemeral half of the site rules table,\n// clearing a marked site the moment its last tab closes. See theme.sh.\nclass ChromeBrowsingDataLifetimeManager : public KeyedService,\n                                          public TabModelListObserver,\n                                          public TabModelObserver {|' \
    $BDLM_H
sed_i 's|^  // KeyedService:$|  // Aerium: TabModelListObserver. Both are pure virtual, so both are here even\n  // though only the removal matters - a model going away takes its tabs with\n  // it, which can be the event that leaves a site with none.\n  void OnTabModelAdded(TabModel* tab_model) override;\n  void OnTabModelRemoved(TabModel* tab_model) override;\n\n  // Aerium: TabModelObserver. Only the committed callbacks, because an\n  // uncommitted close can still be undone - see theme.sh.\n  void TabClosureCommitted(TabAndroid* tab) override;\n  void AllTabsClosureCommitted() override;\n  void OnTabModelDestroyed(TabModel\& tab_model) override;\n\n&|' \
    $BDLM_H
sed_i 's|^  // Deletes data that needs to be deleted, and schedules the next deletion.$|  // Aerium: starts observing every tab model that already exists for this\n  // profile. Called from the constructor - the service is created lazily, so\n  // models can and do exist before it does.\n  void AeriumObserveExistingTabModels();\n\n  // Aerium: observes one model, at most once.\n  void AeriumObserveTabModel(TabModel* tab_model);\n\n  // Aerium: clears cookies and storage for every ephemeral site that no longer\n  // has a tab open. Always posted rather than called straight from a tab-model\n  // notification, because at the point those fire the closing tab can still be\n  // reachable from the model and would count itself as open.\n  void AeriumClearClosedEphemeralSites();\n\n  // Aerium: posts the above after kAeriumEphemeralDelaySeconds. Every tab-model\n  // callback goes through this rather than posting for itself, so the delay and\n  // the cancellation are decided in one place.\n  void AeriumScheduleEphemeralClear();\n\n  // Aerium: the greylist - sites kept while the browser runs and dropped at\n  // shutdown. Called from the on-exit hook, outside every condition on the\n  // delete-on-exit switch.\n  void AeriumClearSessionOnlySites();\n\n  // Aerium: which models this service has called AddObserver() on, purely to\n  // keep that call idempotent. Treat every entry as possibly stale: a model\n  // can be destroyed without this service hearing about it, and an earlier\n  // version of this comment claimed otherwise, which is what issue #11\n  // crashed on. Nothing may dereference an entry - the only safe use is\n  // membership, and RemoveObserver() is called against models taken from\n  // TabModelList::models(), which by construction holds only live ones.\n  std::set<raw_ptr<TabModel>> aerium_observed_models_;\n\n&|' \
    $BDLM_H

BDLM_CC=chrome/browser/browsing_data/chrome_browsing_data_lifetime_manager.cc
sed_i 's|#include "chrome/browser/ui/android/tab_model/tab_model_list.h"|&\n#include "chrome/browser/ui/android/tab_model/tab_model_list_observer.h"\n#include "chrome/browser/ui/android/tab_model/tab_model_observer.h"|' \
    $BDLM_CC
# <algorithm> for std::clamp is already at the top of this file, so only the
# site-rules header is added here.
sed_i 's|#include "chrome/browser/browsing_data/chrome_browsing_data_remover_constants.h"|#include "chrome/browser/browsing_data/aerium_site_rules.h"\n&|' \
    $BDLM_CC

# Subscribe from the constructor, unsubscribe from Shutdown(). Shutdown() rather
# than the destructor because a KeyedService is told to let go of its
# dependencies there, and TabModelList outlives neither reliably.
sed_i 's|^  // When the service is instantiated, wait a few minutes after Chrome startup$|  // Aerium: see theme.sh. Watch for tab models appearing, and for closures in\n  // the ones already here.\n  TabModelList::AddObserver(this);\n  AeriumObserveExistingTabModels();\n\n&|' \
    $BDLM_CC
sed_i 's|^void ChromeBrowsingDataLifetimeManager::Shutdown() {$|&\n  // Aerium: see theme.sh.\n  TabModelList::RemoveObserver(this);\n  // Driven off the live list rather than off aerium_observed_models_,\n  // because an entry in that set is not proof the model still exists.\n  // This loop dereferencing a model that was already gone is the crash\n  // in issue #11.\n  //\n  // TabModelList::RemoveTabModel() erases a model from models() BEFORE\n  // it notifies, and it is called from ~TabModelJniBridge, so anything\n  // still in models() is alive and anything missing from it is not.\n  for (TabModel* aerium_live : TabModelList::models()) {\n    if (aerium_observed_models_.erase(aerium_live) > 0) {\n      aerium_live->RemoveObserver(this);\n    }\n  }\n  // Whatever is left belongs to models that died without telling us.\n  // Dropping those entries is all that is safe and all that is needed -\n  // their observer lists died with them.\n  aerium_observed_models_.clear();\n|' \
    $BDLM_CC

sed_i 's%^void ChromeBrowsingDataLifetimeManager::UpdateScheduledRemovalSettings() {$%// Aerium: the ephemeral half of the site rules table. See theme.sh.\nvoid ChromeBrowsingDataLifetimeManager::AeriumObserveExistingTabModels() {\n  for (TabModel* model : TabModelList::models()) {\n    AeriumObserveTabModel(model);\n  }\n}\n\nvoid ChromeBrowsingDataLifetimeManager::AeriumObserveTabModel(\n    TabModel* tab_model) {\n  if (!tab_model || tab_model->GetProfile() != profile_) {\n    return;\n  }\n  if (aerium_observed_models_.insert(tab_model).second) {\n    tab_model->AddObserver(this);\n  }\n}\n\nvoid ChromeBrowsingDataLifetimeManager::OnTabModelAdded(TabModel* tab_model) {\n  AeriumObserveTabModel(tab_model);\n}\n\nvoid ChromeBrowsingDataLifetimeManager::OnTabModelRemoved(TabModel* tab_model) {\n  // No RemoveObserver here, for exactly the reason OnTabModelDestroyed\n  // gives: TabModelList::RemoveTabModel() is called from\n  // ~TabModelJniBridge, so this runs while the model is being destroyed\n  // and the pointer must not be dereferenced. Dropping the entry is all\n  // that is safe.\n  aerium_observed_models_.erase(tab_model);\n  // A model leaving takes its tabs with it, which can be what leaves a site\n  // with none.\n  AeriumScheduleEphemeralClear();\n}\n\nvoid ChromeBrowsingDataLifetimeManager::OnTabModelDestroyed(\n    TabModel\& tab_model) {\n  // No RemoveObserver here: the model is being destroyed and is saying so to\n  // its observers. Dropping the entry is all that is needed, and all that is\n  // safe.\n  aerium_observed_models_.erase(\&tab_model);\n}\n\nvoid ChromeBrowsingDataLifetimeManager::TabClosureCommitted(TabAndroid* tab) {\n  AeriumScheduleEphemeralClear();\n}\n\nvoid ChromeBrowsingDataLifetimeManager::AllTabsClosureCommitted() {\n  AeriumScheduleEphemeralClear();\n}\n\n// Aerium: posted, and delayed - see kAeriumEphemeralDelaySeconds. Sign-in flows\n// bounce through a provider in a tab that closes itself, and OAuth popups close\n// the moment they hand back a token, so clearing the instant the tab count\n// reaches zero can delete the cookie the redirect is about to need.\n//\n// The weak pointer is the cancellation mechanism: Shutdown() invalidates the\n// factory, so a pending clear never runs against a half-destroyed profile.\n// Posting rather than clearing inline matters even at zero delay, because at\n// the point the tab-model callbacks fire the closing tab can still be reachable\n// from the model and would count itself as open.\nvoid ChromeBrowsingDataLifetimeManager::AeriumScheduleEphemeralClear() {\n  const int configured = profile_->GetPrefs()->GetInteger(\n      browsing_data::prefs::kAeriumEphemeralDelaySeconds);\n  content::GetUIThreadTaskRunner({})->PostDelayedTask(\n      FROM_HERE,\n      base::BindOnce(\n          \&ChromeBrowsingDataLifetimeManager::AeriumClearClosedEphemeralSites,\n          weak_ptr_factory_.GetWeakPtr()),\n      base::Seconds(std::clamp(configured, 0, 3600)));\n}\n\nvoid ChromeBrowsingDataLifetimeManager::AeriumClearClosedEphemeralSites() {\n  PrefService* const prefs = profile_->GetPrefs();\n  const bool all_sites =\n      prefs->GetBoolean(browsing_data::prefs::kAeriumEphemeralAllSites);\n  const std::set<std::string> ephemeral =\n      aerium_site_rules::DomainsForMode(prefs, "ephemeral");\n  if (!all_sites \&\& ephemeral.empty()) {\n    return;\n  }\n\n  // Folded exactly as the on-exit path folds its own, including the fallback to\n  // the bare host for an IP literal or a single-label name, so a rule means the\n  // same thing to both.\n  std::set<std::string> still_open;\n  for (const auto\& url : GetOpenedUrlsAndOngoingDownloads(profile_)) {\n    std::string domain = GetDomainAndRegistry(\n        url, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);\n    if (domain.empty()) {\n      domain = url.GetHost();\n    }\n    if (!domain.empty()) {\n      still_open.insert(domain);\n    }\n  }\n\n  content::BrowsingDataRemover* const remover =\n      profile_->GetBrowsingDataRemover();\n  const uint64_t mask = aerium_site_rules::EphemeralRemoveMask(prefs);\n\n  if (all_sites) {\n    // Expressed as what to spare rather than what to delete, because the set of\n    // domains holding data is not knowable from here - and listing it would be\n    // far larger than listing the handful being kept.\n    //\n    // Three things are spared. The keep rows, because the user said so. The\n    // session-only rows, because they survive until shutdown and this is not\n    // shutdown. And whatever still has a tab, because clearing a site out from\n    // under a tab displaying it signs the user out mid-session - the explicit\n    // list always protected open sites, and this path needs it more, since\n    // every site is now a candidate.\n    auto filter = content::BrowsingDataFilterBuilder::Create(\n        content::BrowsingDataFilterBuilder::Mode::kPreserve);\n    for (const std::string\& domain :\n         aerium_site_rules::DomainsForMode(prefs, "keep")) {\n      filter->AddRegisterableDomain(domain);\n    }\n    for (const std::string\& domain :\n         aerium_site_rules::DomainsForMode(prefs, "session")) {\n      filter->AddRegisterableDomain(domain);\n    }\n    for (const std::string\& domain : still_open) {\n      filter->AddRegisterableDomain(domain);\n    }\n    remover->RemoveWithFilterAndReply(\n        base::Time(), base::Time::Max(), mask,\n        content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB,\n        std::move(filter),\n        BrowsingDataRemoverObserver::Create(\n            remover, /*filterable_deletion=*/true, profile_,\n            /*keep_browser_alive=*/false));\n    return;\n  }\n\n  auto filter = content::BrowsingDataFilterBuilder::Create(\n      content::BrowsingDataFilterBuilder::Mode::kDelete);\n  bool any = false;\n  for (const std::string\& domain : ephemeral) {\n    if (still_open.contains(domain)) {\n      continue;\n    }\n    filter->AddRegisterableDomain(domain);\n    any = true;\n  }\n  if (!any) {\n    return;\n  }\n\n  remover->RemoveWithFilterAndReply(\n      base::Time(), base::Time::Max(), mask,\n      content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB,\n      std::move(filter),\n      BrowsingDataRemoverObserver::Create(remover, /*filterable_deletion=*/true,\n                                          profile_,\n                                          /*keep_browser_alive=*/false));\n}\n\n// Aerium: the greylist. Cleared at shutdown, before every condition in\n// ClearBrowsingDataForOnExitPolicy() and outside all of them - session-only is\n// a promise made per site, not a mode, so it should not require asking for a\n// general clean-out, and turning that clean-out off should not cancel it.\nvoid ChromeBrowsingDataLifetimeManager::AeriumClearSessionOnlySites() {\n  const std::set<std::string> session =\n      aerium_site_rules::DomainsForMode(profile_->GetPrefs(), "session");\n  if (session.empty()) {\n    return;\n  }\n  auto filter = content::BrowsingDataFilterBuilder::Create(\n      content::BrowsingDataFilterBuilder::Mode::kDelete);\n  for (const std::string\& domain : session) {\n    filter->AddRegisterableDomain(domain);\n  }\n  content::BrowsingDataRemover* const remover =\n      profile_->GetBrowsingDataRemover();\n  remover->RemoveWithFilterAndReply(\n      base::Time(), base::Time::Max(),\n      aerium_site_rules::EphemeralRemoveMask(profile_->GetPrefs()),\n      content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB,\n      std::move(filter),\n      BrowsingDataRemoverObserver::Create(remover, /*filterable_deletion=*/true,\n                                          profile_,\n                                          /*keep_browser_alive=*/true));\n}\n\n&%' \
    $BDLM_CC

echo "[aerium] ephemeral sites applied"


# --- The table itself.
#
# A screen rather than a dialog list, because a rule has four fields and a
# preference row can only carry two. The rows are built at runtime instead of
# being declared in XML - the whole point is that there is one per rule - so the
# XML holds only the "Add a site" row and the empty category the rules go into.
#
# The dialog is assembled in code rather than inflated, for the same reason the
# WebUI page is not being ported: a layout resource would have to be listed in
# chrome_java_resources.gni, compiled, and kept in step with a screen that is
# four widgets. AddExceptionPreference in components/browser_ui does inflate
# one, and it is worth more there - it has error colouring, a vibrator and a
# keyboard delegate. This has a text field and three checkboxes.
cat > chrome/android/java/res/xml/aerium_site_rules_preferences.xml <<'AERIUM_SR_XML'
<?xml version="1.0" encoding="utf-8"?>
<!-- Aerium: see theme.sh. The rule rows are added at runtime; only the two
     fixed entries are declared here. -->
<PreferenceScreen xmlns:android="http://schemas.android.com/apk/res/android">
    <Preference
        android:key="aerium_site_rules_add"
        android:title="@string/aerium_site_rules_add"
        android:persistent="false" />
    <PreferenceCategory
        android:key="aerium_site_rules_list"
        android:title="@string/aerium_site_rules_list_title" />
    <org.chromium.components.browser_ui.settings.ChromeSwitchPreference
        android:key="aerium_ephemeral_all_sites"
        android:title="@string/aerium_ephemeral_all_sites_title"
        android:summary="@string/aerium_ephemeral_all_sites_summary"
        android:persistent="false" />
    <org.chromium.components.browser_ui.settings.ChromeSwitchPreference
        android:key="aerium_ephemeral_clear_cache"
        android:title="@string/aerium_ephemeral_clear_cache_title"
        android:summary="@string/aerium_ephemeral_clear_cache_summary"
        android:persistent="false" />
    <Preference
        android:key="aerium_ephemeral_delay"
        android:title="@string/aerium_ephemeral_delay_title"
        android:persistent="false" />
</PreferenceScreen>
AERIUM_SR_XML

cat > chrome/android/java/src/org/chromium/chrome/browser/browsing_data/AeriumSiteRulesFragment.java <<'AERIUM_SR_JAVA'
// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package org.chromium.chrome.browser.browsing_data;

import android.content.Context;
import android.os.Bundle;
import android.text.InputType;
import android.text.TextUtils;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.RadioButton;
import android.widget.RadioGroup;

import androidx.appcompat.app.AlertDialog;
import androidx.preference.Preference;
import androidx.preference.PreferenceCategory;

import org.chromium.base.supplier.MonotonicObservableSupplier;
import org.chromium.base.supplier.ObservableSuppliers;
import org.chromium.base.supplier.SettableMonotonicObservableSupplier;
import org.chromium.build.annotations.NullMarked;
import org.chromium.build.annotations.Nullable;
import org.chromium.chrome.R;
import org.chromium.chrome.browser.settings.ChromeBaseSettingsFragment;
import org.chromium.chrome.browser.settings.search.ChromeBaseSearchIndexProvider;
import org.chromium.components.browser_ui.settings.ChromeSwitchPreference;
import org.chromium.components.browser_ui.settings.SettingsFragment;
import org.chromium.components.browser_ui.settings.SettingsUtils;
import org.chromium.components.prefs.PrefService;
import org.chromium.components.user_prefs.UserPrefs;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Aerium: the site rules table - sites whose data survives the on-exit deletion. See theme.sh.
 *
 * <p>The rules live in a single string pref holding a JSON array, because Android's PrefService is
 * exposed to Java as scalars only and there is no way from here to write the list-of-dictionaries
 * pref the desktop repos use. The object shape is the same on both, so the two can be brought
 * together later without migrating either.
 */
@NullMarked
public class AeriumSiteRulesFragment extends ChromeBaseSettingsFragment {
    // Must match the keys in aerium_site_rules_preferences.xml.
    private static final String PREF_ADD = "aerium_site_rules_add";
    private static final String PREF_LIST = "aerium_site_rules_list";

    // Must match components/browsing_data/core/pref_names.h.
    private static final String PREF_SITE_RULES = "browser.clear_data.aerium_on_exit.site_rules";

    // Must match aerium_site_rules::kTypes in
    // chrome/browser/browsing_data/aerium_site_rules.h. Only three, because those are the only
    // types content::BrowsingDataRemover can exclude a site from - see theme.sh.
    private static final String[] KEEP_KEYS = {"site_data", "cache", "downloads"};
    private static final int[] KEEP_LABELS = {
        R.string.aerium_site_rules_keep_site_data,
        R.string.aerium_site_rules_keep_cache,
        R.string.aerium_site_rules_keep_downloads,
    };

    private static final String KEY_PATTERN = "pattern";
    private static final String KEY_KEEP = "keep";

    // Aerium: a row is a keep rule or an ephemeral one. Absent means keep, which is what every
    // rule written before this existed was, so nothing needs migrating. Must match
    // aerium_site_rules.h.
    private static final String KEY_MODE = "mode";
    private static final String MODE_EPHEMERAL = "ephemeral";

    private static final String MODE_SESSION = "session";
    private static final String MODE_KEEP = "keep";

    // Must match components/browsing_data/core/pref_names.h.
    private static final String PREF_EPHEMERAL_CLEAR_CACHE =
            "browser.clear_data.aerium_ephemeral_clear_cache";
    private static final String PREF_EPHEMERAL_ALL_SITES =
            "browser.clear_data.aerium_ephemeral_all_sites";
    private static final String PREF_EPHEMERAL_DELAY =
            "browser.clear_data.aerium_ephemeral_delay_seconds";

    // Must match the keys in aerium_site_rules_preferences.xml.
    private static final String PREF_CLEAR_CACHE_KEY = "aerium_ephemeral_clear_cache";
    private static final String PREF_ALL_SITES_KEY = "aerium_ephemeral_all_sites";
    private static final String PREF_DELAY_KEY = "aerium_ephemeral_delay";

    // The browser clamps this to the same range when it reads it - see
    // AeriumScheduleEphemeralClear(). Repeated here so a value that would be clamped is
    // refused where it is typed rather than silently becoming something else.
    private static final int DELAY_MIN_SECONDS = 0;
    private static final int DELAY_MAX_SECONDS = 3600;

    private final SettableMonotonicObservableSupplier<String> mPageTitle =
            ObservableSuppliers.createMonotonic();

    private @Nullable PreferenceCategory mList;

    @Override
    public void onCreatePreferences(@Nullable Bundle savedInstanceState, @Nullable String rootKey) {
        SettingsUtils.addPreferencesFromResource(this, R.xml.aerium_site_rules_preferences);
        mPageTitle.set(getString(R.string.aerium_site_rules_title));

        mList = findPreference(PREF_LIST);

        Preference add = findPreference(PREF_ADD);
        if (add != null) {
            add.setOnPreferenceClickListener(
                    preference -> {
                        showRuleDialog(-1);
                        return true;
                    });
        }

        // Aerium: applies to the ephemeral rows only, so it lives under the table rather than in
        // the clear-on-exit screen. Not persistent: the value is a profile pref read and written
        // here, not an Android SharedPreference.
        ChromeSwitchPreference allSites = findPreference(PREF_ALL_SITES_KEY);
        if (allSites != null) {
            allSites.setChecked(
                    UserPrefs.get(getProfile()).getBoolean(PREF_EPHEMERAL_ALL_SITES));
            allSites.setOnPreferenceChangeListener(
                    (preference, newValue) -> {
                        UserPrefs.get(getProfile())
                                .setBoolean(PREF_EPHEMERAL_ALL_SITES, (boolean) newValue);
                        // A keep row is an exception in this mode rather than a protection,
                        // and describeKeep() says so, so the rows are rebuilt to pick that up.
                        rebuildList();
                        return true;
                    });
        }

        Preference delay = findPreference(PREF_DELAY_KEY);
        if (delay != null) {
            updateDelaySummary(delay);
            delay.setOnPreferenceClickListener(
                    preference -> {
                        showDelayDialog(preference);
                        return true;
                    });
        }

        ChromeSwitchPreference clearCache = findPreference(PREF_CLEAR_CACHE_KEY);
        if (clearCache != null) {
            clearCache.setChecked(
                    UserPrefs.get(getProfile()).getBoolean(PREF_EPHEMERAL_CLEAR_CACHE));
            clearCache.setOnPreferenceChangeListener(
                    (preference, newValue) -> {
                        UserPrefs.get(getProfile())
                                .setBoolean(PREF_EPHEMERAL_CLEAR_CACHE, (boolean) newValue);
                        return true;
                    });
        }

        rebuildList();
    }

    /**
     * Reads the pref back into rows. Called after every edit rather than mutating the rows in
     * place: the pref is the state, and rebuilding from it is what keeps the screen from drifting
     * away from what the deletion will actually read.
     */
    private void rebuildList() {
        if (mList == null) return;
        mList.removeAll();

        JSONArray rules = readRules();
        if (rules.length() == 0) {
            Preference empty = new Preference(getStyledContext());
            empty.setTitle(R.string.aerium_site_rules_empty);
            empty.setSelectable(false);
            mList.addPreference(empty);
            return;
        }

        for (int i = 0; i < rules.length(); i++) {
            JSONObject rule = rules.optJSONObject(i);
            if (rule == null) continue;
            final int index = i;
            Preference row = new Preference(getStyledContext());
            row.setTitle(rule.optString(KEY_PATTERN));
            row.setSummary(describeKeep(rule));
            row.setOnPreferenceClickListener(
                    preference -> {
                        showRuleDialog(index);
                        return true;
                    });
            mList.addPreference(row);
        }
    }

    /** "Cookies and site data, Cached images and files" - what this row actually protects. */
    private String describeKeep(JSONObject rule) {
        // Aerium: neither an ephemeral nor a session-only row protects anything; both say when
        // the site goes. Listing the keep checkboxes for one would describe a rule it does not
        // have.
        String mode = rule.optString(KEY_MODE);
        if (MODE_EPHEMERAL.equals(mode)) {
            return getString(R.string.aerium_site_rules_mode_ephemeral_summary);
        }
        if (MODE_SESSION.equals(mode)) {
            return getString(R.string.aerium_site_rules_mode_session_summary);
        }
        JSONObject keep = rule.optJSONObject(KEY_KEEP);
        StringBuilder summary = new StringBuilder();
        for (int i = 0; i < KEEP_KEYS.length; i++) {
            if (keep == null || !keep.optBoolean(KEEP_KEYS[i], false)) continue;
            if (summary.length() > 0) summary.append(", ");
            summary.append(getString(KEEP_LABELS[i]));
        }
        if (summary.length() == 0) {
            return getString(R.string.aerium_site_rules_keep_nothing);
        }
        // A keep row means something different once every site is being cleared: it is the
        // exception rather than a protection against a sweep the user may not even have turned
        // on. Saying so on the row is cheaper than expecting anyone to hold both switches in
        // their head.
        if (UserPrefs.get(getProfile()).getBoolean(PREF_EPHEMERAL_ALL_SITES)) {
            return getString(R.string.aerium_site_rules_keep_exception, summary.toString());
        }
        return summary.toString();
    }

    /**
     * The add and edit dialog, which are the same dialog - editing starts from the row's values and
     * offers Remove as well.
     *
     * @param index the rule being edited, or -1 to add one.
     */
    private void showRuleDialog(int index) {
        Context context = getStyledContext();
        JSONArray rules = readRules();
        JSONObject existing = index >= 0 ? rules.optJSONObject(index) : null;

        int padding =
                Math.round(24 * context.getResources().getDisplayMetrics().density);
        LinearLayout layout = new LinearLayout(context);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(padding, padding, padding, 0);

        EditText input = new EditText(context);
        input.setSingleLine(true);
        input.setHint(R.string.aerium_site_rules_hint);
        input.setInputType(
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        input.setLayoutParams(
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT));
        if (existing != null) input.setText(existing.optString(KEY_PATTERN));
        layout.addView(input);

        // Aerium: which question this row answers. Two radio buttons rather than a switch,
        // because they are not on/off versions of one another - "keep this when I quit" and
        // "clear this the moment its last tab closes" are opposite instructions, and a switch
        // labelled with one of them would make the other look like its absence.
        String existingMode = existing == null ? MODE_KEEP : existing.optString(KEY_MODE);

        RadioButton keepMode = new RadioButton(context);
        keepMode.setText(R.string.aerium_site_rules_mode_keep);
        RadioButton sessionMode = new RadioButton(context);
        sessionMode.setText(R.string.aerium_site_rules_mode_session);
        RadioButton ephemeralMode = new RadioButton(context);
        ephemeralMode.setText(R.string.aerium_site_rules_mode_ephemeral);
        RadioGroup modes = new RadioGroup(context);
        modes.setOrientation(RadioGroup.VERTICAL);
        modes.addView(keepMode);
        modes.addView(sessionMode);
        modes.addView(ephemeralMode);
        layout.addView(modes);

        JSONObject existingKeep = existing == null ? null : existing.optJSONObject(KEY_KEEP);
        LinearLayout keepBoxes = new LinearLayout(context);
        keepBoxes.setOrientation(LinearLayout.VERTICAL);
        layout.addView(keepBoxes);

        CheckBox[] boxes = new CheckBox[KEEP_KEYS.length];
        for (int i = 0; i < KEEP_KEYS.length; i++) {
            CheckBox box = new CheckBox(context);
            box.setText(KEEP_LABELS[i]);
            // A new rule keeps everything it can. Keep is the mode a new row starts in, and
            // someone who picked it means keep; the boxes are there to take things away again.
            box.setChecked(
                    existingKeep == null || existingKeep.optBoolean(KEEP_KEYS[i], false));
            boxes[i] = box;
            keepBoxes.addView(box);
        }

        // The checkboxes belong to the keep mode alone. Hidden rather than disabled in the other
        // mode: a greyed-out list of things this rule keeps, on a rule whose entire point is that
        // it keeps nothing, reads as a bug.
        modes.setOnCheckedChangeListener(
                (group, checkedId) ->
                        keepBoxes.setVisibility(
                                checkedId == keepMode.getId() ? View.VISIBLE : View.GONE));
        // Ids are assigned by addView above, so check() can only be called now.
        int checked = keepMode.getId();
        if (MODE_EPHEMERAL.equals(existingMode)) {
            checked = ephemeralMode.getId();
        } else if (MODE_SESSION.equals(existingMode)) {
            checked = sessionMode.getId();
        }
        modes.check(checked);

        AlertDialog.Builder builder =
                new AlertDialog.Builder(context, R.style.ThemeOverlay_BrowserUI_AlertDialog)
                        .setTitle(
                                existing == null
                                        ? R.string.aerium_site_rules_add
                                        : R.string.aerium_site_rules_edit)
                        .setView(layout)
                        .setPositiveButton(R.string.aerium_site_rules_save, null)
                        .setNegativeButton(android.R.string.cancel, null);
        if (existing != null) {
            builder.setNeutralButton(
                    R.string.aerium_site_rules_remove,
                    (dialog, which) -> {
                        removeRule(index);
                    });
        }

        AlertDialog dialog = builder.create();
        dialog.show();
        // Bound after show() so an unusable entry can be rejected without the dialog closing -
        // setPositiveButton's own listener always dismisses. The button exists from show()
        // onwards; the check is there because getButton() is free to say otherwise.
        Button positive = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
        if (positive == null) return;
        positive.setOnClickListener(
                        view -> {
                            String pattern = normalize(input.getText().toString());
                            if (pattern == null) {
                                input.setError(getString(R.string.aerium_site_rules_invalid));
                                return;
                            }
                            String mode = MODE_KEEP;
                            int picked = modes.getCheckedRadioButtonId();
                            if (picked == ephemeralMode.getId()) {
                                mode = MODE_EPHEMERAL;
                            } else if (picked == sessionMode.getId()) {
                                mode = MODE_SESSION;
                            }
                            saveRule(index, pattern, boxes, mode);
                            dialog.dismiss();
                        });
    }

    /**
     * Whether this can be read as a site at all. Deliberately loose: the real normalisation is
     * RegistrableDomainFor() in aerium_site_rules.h, which has a URL parser and the public suffix
     * list and this does not. All that matters here is refusing input the C++ would silently drop,
     * so that a rule the user typed cannot sit in the table doing nothing.
     */
    private @Nullable String normalize(String raw) {
        String host = raw.trim().toLowerCase(java.util.Locale.US);
        if (host.startsWith("[*.]")) {
            host = host.substring(4);
        } else if (host.startsWith("*.")) {
            host = host.substring(2);
        }
        int schemeEnd = host.indexOf("://");
        if (schemeEnd >= 0) host = host.substring(schemeEnd + 3);
        int slash = host.indexOf('/');
        if (slash >= 0) host = host.substring(0, slash);
        while (host.endsWith(".")) host = host.substring(0, host.length() - 1);
        if (TextUtils.isEmpty(host)) return null;
        if (host.contains(" ") || host.contains("*") || host.contains("/")) return null;
        return host;
    }

    private void saveRule(int index, String pattern, CheckBox[] boxes, String mode) {
        try {
            JSONObject keep = new JSONObject();
            for (int i = 0; i < KEEP_KEYS.length; i++) {
                keep.put(KEEP_KEYS[i], boxes[i].isChecked());
            }
            JSONObject rule = new JSONObject();
            rule.put(KEY_PATTERN, pattern);
            rule.put(KEY_KEEP, keep);
            // Aerium: written on both kinds of row so a rule that used to be ephemeral and was
            // changed back does not keep its old mode by omission. The keep map is written either
            // way, so switching a row back and forth does not lose its checkboxes.
            rule.put(KEY_MODE, mode);

            JSONArray rules = readRules();
            if (index >= 0 && index < rules.length()) {
                rules.put(index, rule);
            } else {
                rules.put(rule);
            }
            writeRules(rules);
        } catch (JSONException e) {
            // put() only throws on a NaN or infinite value, neither of which can appear here.
            return;
        }
        rebuildList();
    }

    private void removeRule(int index) {
        JSONArray rules = readRules();
        if (index < 0 || index >= rules.length()) return;
        rules.remove(index);
        writeRules(rules);
        rebuildList();
    }

    /** "10 seconds after the last tab closes" - the current value, on the row that changes it. */
    private void updateDelaySummary(Preference preference) {
        int seconds = UserPrefs.get(getProfile()).getInteger(PREF_EPHEMERAL_DELAY);
        preference.setSummary(
                seconds == 0
                        ? getString(R.string.aerium_ephemeral_delay_immediate)
                        : getString(R.string.aerium_ephemeral_delay_summary, seconds));
    }

    /**
     * The delay dialog. A number field rather than a slider or a fixed list, because the useful
     * values are not evenly spread - 0, 10 and 300 are all reasonable answers and a slider would
     * make the middle of that range easy and the ends hard.
     */
    private void showDelayDialog(Preference row) {
        Context context = getStyledContext();
        int padding = Math.round(24 * context.getResources().getDisplayMetrics().density);

        EditText input = new EditText(context);
        input.setSingleLine(true);
        input.setInputType(InputType.TYPE_CLASS_NUMBER);
        input.setText(String.valueOf(UserPrefs.get(getProfile()).getInteger(PREF_EPHEMERAL_DELAY)));
        LinearLayout layout = new LinearLayout(context);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(padding, padding, padding, 0);
        layout.addView(input);

        AlertDialog dialog =
                new AlertDialog.Builder(context, R.style.ThemeOverlay_BrowserUI_AlertDialog)
                        .setTitle(R.string.aerium_ephemeral_delay_title)
                        .setMessage(R.string.aerium_ephemeral_delay_desc)
                        .setView(layout)
                        .setPositiveButton(R.string.aerium_site_rules_save, null)
                        .setNegativeButton(android.R.string.cancel, null)
                        .create();
        dialog.show();
        Button positive = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
        if (positive == null) return;
        positive.setOnClickListener(
                view -> {
                    int seconds;
                    try {
                        seconds = Integer.parseInt(input.getText().toString().trim());
                    } catch (NumberFormatException e) {
                        // Includes the empty field, which would otherwise parse as nothing and be
                        // stored as 0 - that reads as "clear immediately", which is not what
                        // clearing the box means.
                        input.setError(getString(R.string.aerium_ephemeral_delay_invalid));
                        return;
                    }
                    if (seconds < DELAY_MIN_SECONDS || seconds > DELAY_MAX_SECONDS) {
                        input.setError(getString(R.string.aerium_ephemeral_delay_invalid));
                        return;
                    }
                    UserPrefs.get(getProfile()).setInteger(PREF_EPHEMERAL_DELAY, seconds);
                    updateDelaySummary(row);
                    dialog.dismiss();
                });
    }

    private JSONArray readRules() {
        PrefService prefs = UserPrefs.get(getProfile());
        try {
            return new JSONArray(prefs.getString(PREF_SITE_RULES));
        } catch (JSONException e) {
            // A pref that will not parse is one someone hand-edited. Showing an empty table is
            // better than showing nothing at all, and the next save replaces it.
            return new JSONArray();
        }
    }

    private void writeRules(JSONArray rules) {
        UserPrefs.get(getProfile()).setString(PREF_SITE_RULES, rules.toString());
    }

    private Context getStyledContext() {
        return getPreferenceManager().getContext();
    }

    @Override
    public MonotonicObservableSupplier<String> getPageTitle() {
        return mPageTitle;
    }

    @Override
    public @SettingsFragment.AnimationType int getAnimationType() {
        return SettingsFragment.AnimationType.PROPERTY;
    }

    public static final ChromeBaseSearchIndexProvider SEARCH_INDEX_DATA_PROVIDER =
            new ChromeBaseSearchIndexProvider(
                    AeriumSiteRulesFragment.class.getName(),
                    R.xml.aerium_site_rules_preferences);
}
AERIUM_SR_JAVA

sed_i 's|^  "java/src/org/chromium/chrome/browser/browsing_data/AeriumClearOnExitFragment.java",$|&\n  "java/src/org/chromium/chrome/browser/browsing_data/AeriumSiteRulesFragment.java",|' \
    chrome/android/chrome_java_sources.gni
sed_i 's|^  "java/res/xml/aerium_clear_on_exit_preferences.xml",$|&\n  "java/res/xml/aerium_site_rules_preferences.xml",|' \
    chrome/android/chrome_java_resources.gni
sed_i 's|^                    AeriumClearOnExitFragment.SEARCH_INDEX_DATA_PROVIDER,$|&\n                    AeriumSiteRulesFragment.SEARCH_INDEX_DATA_PROVIDER,|' \
    $SIPR
sed_i 's|^import org.chromium.chrome.browser.browsing_data.AeriumClearOnExitFragment;$|&\nimport org.chromium.chrome.browser.browsing_data.AeriumSiteRulesFragment;|' \
    $SIPR

sed_i 's|^      <message name="IDS_AERIUM_CLEAR_ON_EXIT_TITLE" desc=|      <message name="IDS_AERIUM_SITE_RULES_TITLE" desc="Title of the screen listing per-site rules saying when each site'"'"'s data is deleted.">\n        Site rules\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_SUMMARY" desc="Summary under the entry that opens that screen.">\n        When each site'"'"'s data is deleted\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_LIST_TITLE" desc="Header above the list of per-site rules.">\n        Sites\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_ADD" desc="Row that opens a dialog for adding a site, and the title of that dialog.">\n        Add a site\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_EDIT" desc="Title of the dialog shown when an existing site in the list is tapped.">\n        Edit site\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_EMPTY" desc="Shown in place of the list when no sites have been added.">\n        No rules yet. Every site follows the settings on the previous screen.\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_HINT" desc="Hint text in the site field, telling the user what to type.">\n        example.com - covers the whole site, subdomains included\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_INVALID" desc="Error shown under the site field when what was typed cannot be read as a site.">\n        Enter a site, such as example.com\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_SAVE" desc="Button that stores the site being added or edited.">\n        Save\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_REMOVE" desc="Button that deletes the site being edited from the list.">\n        Remove\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_KEEP_SITE_DATA" desc="Data type a kept site can hold on to: cookies and other site storage.">\n        Cookies and site data\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_KEEP_CACHE" desc="Data type a kept site can hold on to: cached files.">\n        Cached images and files\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_KEEP_DOWNLOADS" desc="Data type a kept site can hold on to: its entries in the download list.">\n        Download history\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_KEEP_NOTHING" desc="Summary on a row where every data type was unticked, so the row keeps nothing.">\n        Nothing kept\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_MODE_KEEP" desc="First of two options in the site dialog: this rule protects the site from the deletion that happens when the browser closes.">\n        Keep this site when Aerium closes\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_MODE_EPHEMERAL" desc="Second of two options in the site dialog: this rule clears the site as soon as its last tab is closed, rather than protecting it.">\n        Clear this site as soon as its last tab closes\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_MODE_EPHEMERAL_SUMMARY" desc="Summary shown on a row set to clear the site when its last tab closes.">\n        Cleared when its last tab closes\n      </message>\n      <message name="IDS_AERIUM_EPHEMERAL_CLEAR_CACHE_TITLE" desc="Title of the switch that makes tab-close clearing drop the cached files too.">\n        Also clear cached files\n      </message>\n      <message name="IDS_AERIUM_EPHEMERAL_CLEAR_CACHE_SUMMARY" desc="Summary under that switch. Says which rows it affects and what it costs.">\n        Applies to sites cleared when their last tab closes. Their images, fonts and scripts are fetched again on the next visit.\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_MODE_SESSION" desc="Middle of three options in the site dialog: the site stays signed in while the browser is running and is cleared when it closes.">\n        Keep this site until Aerium closes, then clear it\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_MODE_SESSION_SUMMARY" desc="Summary shown on a row set to be cleared when the browser closes.">\n        Cleared when Aerium closes\n      </message>\n      <message name="IDS_AERIUM_EPHEMERAL_ALL_SITES_TITLE" desc="Title of the switch that clears every site when its last tab closes, leaving the table as the list of exceptions.">\n        Clear every site when its last tab closes\n      </message>\n      <message name="IDS_AERIUM_EPHEMERAL_ALL_SITES_SUMMARY" desc="Summary under that switch. Warns that it signs the user out of everything not listed.">\n        The sites above become the exceptions. Everything else is signed out as soon as you close its last tab.\n      </message>\n      <message name="IDS_AERIUM_EPHEMERAL_DELAY_TITLE" desc="Row that opens a dialog for setting how long to wait after a tab closes before clearing the site.">\n        Wait before clearing\n      </message>\n      <message name="IDS_AERIUM_EPHEMERAL_DELAY_DESC" desc="Explanation in that dialog, saying why a delay is useful and what the range is.">\n        Sign-in pages often open a tab that closes itself, so clearing the instant a tab goes can delete a cookie that was about to be used. A short wait also forgives closing a tab by accident. 0 to 3600 seconds.\n      </message>\n      <message name="IDS_AERIUM_EPHEMERAL_DELAY_SUMMARY" desc="Summary on that row, naming the wait in seconds. The placeholder is a number.">\n        <ph name="SECONDS">%1$d<ex>10</ex></ph> seconds after the last tab closes\n      </message>\n      <message name="IDS_AERIUM_EPHEMERAL_DELAY_IMMEDIATE" desc="Summary on that row when the wait is set to zero.">\n        As soon as the last tab closes\n      </message>\n      <message name="IDS_AERIUM_EPHEMERAL_DELAY_INVALID" desc="Error shown under the field when the number typed is out of range or not a number.">\n        Enter a number of seconds between 0 and 3600\n      </message>\n      <message name="IDS_AERIUM_SITE_RULES_KEEP_EXCEPTION" desc="Summary on a keep row while every other site is being cleared on tab close. The placeholder is the list of data types the row keeps.">\n        Exception: <ph name="TYPES">%1$s<ex>Cookies and site data</ex></ph>\n      </message>\n&|' \
    chrome/browser/ui/android/strings/android_chrome_strings.grd
# --- Let an extension own the New Tab page on a phone.
#
# Chromium 152 has the whole mechanism for this and switches it off here.
# UrlConstantResolver.getNtpUrl() normally returns chrome-native://newtab/,
# which is intercepted early and drawn as a native Android View that no
# extension can reach. When an extension registers a chrome_url_overrides.newtab
# it instead returns chrome://newtab/, which goes through the C++ handler chain
# in ChromeContentBrowserClient::BrowserURLHandlerCreated() - policy first,
# then ExtensionUrlOverrides::HandleChromeURLOverride(), then Android's native
# page handler - so the extension wins and the native page is never built.
#
# All of that is gated on ChromeNativeUrlOverriding, which is
# FEATURE_DISABLED_BY_DEFAULT in chrome_feature_list.cc and defaults to
# BuildConfig.IS_DESKTOP_ANDROID on the Java side. That gate is upstream saying
# "extensions only exist on desktop Android" - which is the exact assumption
# this build is here to break. Aerium ships extensions on phones, so the
# feature they are gated behind should be on for phones too.
#
# Both halves have to move together. sChromeNativeUrlOverriding is a CachedFlag:
# it is read from SharedPreferences before native is up, seeded from the Java
# default on the very first launch and refreshed from the native value at the
# end of each one. Flipping only the native default would leave the first launch
# after install disagreeing with every launch after it; flipping only the Java
# default would leave every launch after the first disagreeing with the first.
#
# With it on, all three surfaces follow the extension without any further work,
# because each already asks the resolver rather than the constant:
# ChromeTabbedActivity.createInitialTab() for a cold start with no tabs to
# restore, HomepageManager.getNtpUrl() for the home button and for a homepage
# that is set to the New Tab page, and the new-tab action itself.
#
# Incognito is deliberately not included, and that is Chromium's rule rather
# than ours: GetOverridesForChromeURL() refuses new-tab overrides off the record
# outright - `url.host() != chrome::kChromeUINewTabHost` in its
# incognito_override_allowed test - so that the incognito explainer is always
# what an incognito new tab shows. Nothing here can or should change that.
sed_i 's|^BASE_FEATURE(kChromeNativeUrlOverriding, base::FEATURE_DISABLED_BY_DEFAULT);$|BASE_FEATURE(kChromeNativeUrlOverriding, base::FEATURE_ENABLED_BY_DEFAULT);|' \
    chrome/browser/flags/android/chrome_feature_list.cc
sed_i 's|^            newCachedFlag(CHROME_NATIVE_URL_OVERRIDING, BuildConfig.IS_DESKTOP_ANDROID);$|            newCachedFlag(CHROME_NATIVE_URL_OVERRIDING, /* defaultValue= */ true);|' \
    chrome/browser/flags/android/java/src/org/chromium/chrome/browser/flags/ChromeFeatureList.java
# --- "Is there a newer build of this?", asked once a day.
#
# Aerium has no update infrastructure and cannot have Chrome's: Omaha, Keystone
# and a distro package all assume a vendor with an update server, and an APK
# people sideload from a GitHub release has none of that. So someone who
# installed once has no way to learn that a security fix shipped except by
# remembering their own version number and going to look, which in practice
# means running an old browser indefinitely. That is the problem this solves,
# and it is a security problem before it is a convenience one.
#
# The C++ is byte-identical on all three platforms - only the repository it
# asks about changes, and that is chosen by BUILDFLAG inside the header. Written
# once and delivered three ways: a heredoc here, a patch on each desktop repo.
#
# Header-only again, and this time it buys more than tidiness. A KeyedService
# plus its factory in one header, included by exactly one translation unit, is a
# new service with no BUILD.gn edit, no .cc, and no entry in browser_prefs.cc -
# the factory's own RegisterProfilePrefs() carries the four prefs. The whole
# delta outside this file is two lines in
# chrome_browser_main_extra_parts_profiles.cc.
#
# What it deliberately does not do is install anything. Replacing a running
# binary is a different feature with a different risk profile - signature
# checking, an unknown-sources prompt, a download nobody asked for on mobile
# data - and shipping half of it would be worse than shipping none of it. This
# tells you and points at the release.
mkdir -p chrome/browser/aerium
cat > chrome/browser/aerium/aerium_update_checker.h <<'AERIUM_UPDATE_CHECKER_H'
// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CHROME_BROWSER_AERIUM_AERIUM_UPDATE_CHECKER_H_
#define CHROME_BROWSER_AERIUM_AERIUM_UPDATE_CHECKER_H_

#include <algorithm>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/types/expected.h"
#include "base/values.h"
#include "base/version.h"
#include "build/build_config.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_keyed_service_factory.h"
#include "components/keyed_service/core/keyed_service.h"
#include "components/pref_registry/pref_registry_syncable.h"
#include "components/prefs/pref_service.h"
#include "base/version_info/version_info.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/storage_partition.h"
#include "net/base/load_flags.h"
#include "net/http/http_request_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/data_decoder/public/cpp/data_decoder.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "url/gurl.h"

// Aerium: "is there a newer build of this?", asked once a day, of the one place
// that can answer it - the GitHub repository this binary is released from.
//
// Aerium has no update infrastructure. Chrome has Omaha on Windows, Keystone on
// Mac and a distro package on Linux; ungoogled-chromium and Vanadium have none
// of those, and neither does an AppImage or a sideloaded APK. So a user who
// installed once has no way to learn that a security fix shipped except by
// visiting the releases page and remembering their own version number, and in
// practice that means running an old browser indefinitely.
//
// What this deliberately does NOT do is download or install anything. Replacing
// a running binary is a different feature with a different risk profile -
// signature verification, an AppImage that has to rewrite itself, an elevated
// installer on Windows, an unknown-sources prompt on Android - and shipping
// half of it would be worse than shipping none. This tells you, and points at
// the release; the install is yours.
//
// The privacy cost is stated plainly on the switch that turns it off: one
// request a day to api.github.com, which sees an IP address and which platform
// repository was asked about. That is a real cost and it is why the switch
// exists. It is on by default because a browser that silently goes stale is a
// worse privacy outcome than a daily connection to a host the user is already
// trusting to distribute the binary.
namespace aerium_update {

// Whether to check at all. The one thing on this screen a user decides.
inline constexpr char kCheckEnabled[] = "aerium.update.check_enabled";

// When the last check completed, as microseconds since the Windows epoch, the
// representation base::Time serialises to. Stored rather than kept in memory so
// that restarting the browser five times in an hour does not check five times.
inline constexpr char kLastCheckTime[] = "aerium.update.last_check_time";

// The newest release found, and where to get it. Empty when this build is the
// newest one - so "is there an update" is "is this string non-empty", and a
// check that finds nothing clears a result that has been superseded.
inline constexpr char kLatestVersion[] = "aerium.update.latest_version";
inline constexpr char kLatestUrl[] = "aerium.update.latest_url";

inline constexpr base::TimeDelta kCheckInterval = base::Hours(24);

// Not at startup. The first two minutes belong to the page the user opened the
// browser for, and an update that has been available for a day can wait.
inline constexpr base::TimeDelta kStartupDelay = base::Minutes(2);

// A release body is a few kilobytes of JSON; a megabyte is far past anything
// legitimate and stops a compromised or confused endpoint from handing us an
// unbounded string to parse.
inline constexpr size_t kMaxResponseBytes = 1024 * 1024;

// Each platform asks about its own repository, because each publishes its own
// releases on its own cadence - a Linux AppImage and a Windows build of the
// same Chromium are different artifacts with different build numbers.
#if BUILDFLAG(IS_ANDROID)
inline constexpr char kLatestReleaseUrl[] =
    "https://api.github.com/repos/aerium-browser/aerium-browser-android/releases/latest";
#elif BUILDFLAG(IS_WIN)
inline constexpr char kLatestReleaseUrl[] =
    "https://api.github.com/repos/aerium-browser/aerium-browser-windows/releases/latest";
#else
inline constexpr char kLatestReleaseUrl[] =
    "https://api.github.com/repos/aerium-browser/aerium-browser-linux/releases/latest";
#endif

// Releases are tagged v<chromium version>, sometimes with a build suffix -
// "v152.0.7977.64" on Linux and Android, "v152.0.7977.64-b120" on Windows,
// where the suffix distinguishes two builds of the same Chromium. Only the
// dotted part is a version base::Version can compare, so the rest is cut off
// rather than guessed at. Returns an invalid Version for anything else, which
// the caller treats as "no answer" rather than as "no update".
//
// Which means a Windows rebuild of a Chromium version already installed is not
// reported, and that is not a gap that can be closed here: the binary knows the
// Chromium version it was built from and nothing about the run number that
// produced it, so -b118 has no way to recognise itself as older than -b120.
// Reporting it would mean telling every user on that Chromium that an update
// exists, every day, whether or not they already had it. A rebuild of the same
// Chromium is also not the case this feature is for - the reason to know your
// browser is stale is that a security fix shipped, and a security fix moves the
// version.
inline base::Version ParseReleaseTag(std::string_view tag) {
  std::string_view body = tag;
  if (!body.empty() && (body.front() == 'v' || body.front() == 'V')) {
    body.remove_prefix(1);
  }
  const size_t dash = body.find('-');
  if (dash != std::string_view::npos) {
    body = body.substr(0, dash);
  }
  return base::Version(std::string(body));
}

class AeriumUpdateChecker : public KeyedService {
 public:
  // Out of line, below, for the same reason Shutdown() is: this class holds a
  // unique_ptr, a timer and a WeakPtrFactory, which makes it "complex" to the
  // chromium-style plugin, and that plugin rejects a complex class whose
  // constructor or destructor body is written inside the class.
  explicit AeriumUpdateChecker(Profile* profile);
  AeriumUpdateChecker(const AeriumUpdateChecker&) = delete;
  AeriumUpdateChecker& operator=(const AeriumUpdateChecker&) = delete;
  ~AeriumUpdateChecker() override;

  // KeyedService:
  void Shutdown() override;

 private:
  void ScheduleNextCheck();
  void Check();
  void OnResponse(std::unique_ptr<std::string> body);
  void OnParsed(base::expected<base::Value, std::string> result);
  void Finish(const std::string& version, const std::string& url);

  const raw_ptr<Profile> profile_;
  std::unique_ptr<network::SimpleURLLoader> loader_;
  base::OneShotTimer timer_;
  base::WeakPtrFactory<AeriumUpdateChecker> weak_factory_{this};
};

inline AeriumUpdateChecker::AeriumUpdateChecker(Profile* profile)
    : profile_(profile) {
  ScheduleNextCheck();
}

inline AeriumUpdateChecker::~AeriumUpdateChecker() = default;

inline void AeriumUpdateChecker::Shutdown() {
  timer_.Stop();
  loader_.reset();
  weak_factory_.InvalidateWeakPtrs();
}

// Armed from the stored timestamp rather than from a fixed interval, so the
// answer to "when is the next check" survives a restart. A clock that has moved
// backwards - a timezone fix, a user setting the date - would otherwise park
// the next check arbitrarily far in the future, so a due time further away than
// the interval itself is treated as the interval.
inline void AeriumUpdateChecker::ScheduleNextCheck() {
  const base::Time last = base::Time::FromDeltaSinceWindowsEpoch(
      base::Microseconds(profile_->GetPrefs()->GetInt64(kLastCheckTime)));
  base::TimeDelta due = last + kCheckInterval - base::Time::Now();
  if (due > kCheckInterval) {
    due = kCheckInterval;
  }
  timer_.Start(FROM_HERE, std::max(due, kStartupDelay),
               base::BindOnce(&AeriumUpdateChecker::Check,
                              weak_factory_.GetWeakPtr()));
}

inline void AeriumUpdateChecker::Check() {
  // Read every time rather than cached at construction: turning the switch off
  // has to stop the next check, not the one after the browser is restarted.
  if (!profile_->GetPrefs()->GetBoolean(kCheckEnabled)) {
    // Still re-armed, so turning it back on does not require a restart.
    timer_.Start(FROM_HERE, kCheckInterval,
                 base::BindOnce(&AeriumUpdateChecker::Check,
                                weak_factory_.GetWeakPtr()));
    return;
  }

  constexpr net::NetworkTrafficAnnotationTag kAnnotation =
      net::DefineNetworkTrafficAnnotation("aerium_update_check", R"(
        semantics {
          sender: "Aerium update check"
          description:
            "Asks the GitHub repository this build of Aerium is released from "
            "whether a newer release exists, so the browser can tell the user "
            "that they are running an old version. Nothing is downloaded or "
            "installed; the result is a version number and a link."
          trigger:
            "Once every 24 hours while the browser is running, starting two "
            "minutes after startup."
          data:
            "None beyond the request itself. The server sees the requesting IP "
            "address and which platform repository was asked about."
          destination: WEBSITE
        }
        policy {
          cookies_allowed: NO
          setting:
            "Turned off with 'Check for updates' in Settings > About Aerium."
          policy_exception_justification: "Not implemented."
        })");

  auto request = std::make_unique<network::ResourceRequest>();
  request->url = GURL(kLatestReleaseUrl);
  request->method = "GET";
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  request->load_flags = net::LOAD_DISABLE_CACHE | net::LOAD_BYPASS_CACHE;
  request->headers.SetHeader(net::HttpRequestHeaders::kAccept,
                             "application/vnd.github+json");
  // GitHub rejects API requests with no User-Agent. Deliberately just the
  // product name: this request already tells the server which platform is
  // asking, and the exact build number would tell it more than it needs.
  request->headers.SetHeader(net::HttpRequestHeaders::kUserAgent, "Aerium");

  loader_ = network::SimpleURLLoader::Create(std::move(request), kAnnotation);
  loader_->SetRetryOptions(
      1, network::SimpleURLLoader::RETRY_ON_NETWORK_CHANGE);
  loader_->DownloadToString(
      profile_->GetDefaultStoragePartition()
          ->GetURLLoaderFactoryForBrowserProcess()
          .get(),
      base::BindOnce(
          [](base::WeakPtr<AeriumUpdateChecker> self,
             std::optional<std::string> body) {
            if (!self) {
              return;
            }
            self->OnResponse(body ? std::make_unique<std::string>(*body)
                                  : nullptr);
          },
          weak_factory_.GetWeakPtr()),
      kMaxResponseBytes);
}

inline void AeriumUpdateChecker::OnResponse(std::unique_ptr<std::string> body) {
  loader_.reset();
  if (!body) {
    // A failed check is still a check. Re-arming without recording the time
    // would retry every two minutes for as long as the network is down, which
    // is both useless and the most conspicuous thing this feature could do.
    Finish(profile_->GetPrefs()->GetString(kLatestVersion),
           profile_->GetPrefs()->GetString(kLatestUrl));
    return;
  }
  // Out of process. This is untrusted network data, and the isolated decoder is
  // what Chromium uses for exactly that; parsing it in the browser process
  // would put a JSON parser between an unauthenticated response and everything
  // the browser process can reach.
  data_decoder::DataDecoder::ParseJsonIsolated(
      *body, base::BindOnce(&AeriumUpdateChecker::OnParsed,
                            weak_factory_.GetWeakPtr()));
}

inline void AeriumUpdateChecker::OnParsed(
    base::expected<base::Value, std::string> result) {
  const std::string previous_version =
      profile_->GetPrefs()->GetString(kLatestVersion);
  const std::string previous_url = profile_->GetPrefs()->GetString(kLatestUrl);

  if (!result.has_value() || !result->is_dict()) {
    Finish(previous_version, previous_url);
    return;
  }
  const base::DictValue& release = result->GetDict();
  const std::string* tag = release.FindString("tag_name");
  if (!tag) {
    Finish(previous_version, previous_url);
    return;
  }
  // A draft or prerelease is not something to send a user to.
  if (release.FindBool("draft").value_or(false) ||
      release.FindBool("prerelease").value_or(false)) {
    Finish(std::string(), std::string());
    return;
  }

  const base::Version latest = ParseReleaseTag(*tag);
  // GetVersion() rather than parsing GetVersionNumber() ourselves: it is the
  // same string already turned into a Version, and it cannot come back invalid.
  const base::Version& current = version_info::GetVersion();
  if (!latest.IsValid() || !current.IsValid()) {
    Finish(previous_version, previous_url);
    return;
  }
  if (latest.CompareTo(current) <= 0) {
    // Up to date, and saying so is the point: this is what clears a result
    // that was true yesterday and is not true now that the user has updated.
    Finish(std::string(), std::string());
    return;
  }

  const std::string* html_url = release.FindString("html_url");
  Finish(*tag, html_url ? *html_url : std::string());
}

inline void AeriumUpdateChecker::Finish(const std::string& version,
                                        const std::string& url) {
  PrefService* const prefs = profile_->GetPrefs();
  prefs->SetString(kLatestVersion, version);
  prefs->SetString(kLatestUrl, url);
  prefs->SetInt64(
      kLastCheckTime,
      base::Time::Now().ToDeltaSinceWindowsEpoch().InMicroseconds());
  ScheduleNextCheck();
}

class AeriumUpdateCheckerFactory : public ProfileKeyedServiceFactory {
 public:
  static AeriumUpdateCheckerFactory* GetInstance();

  AeriumUpdateCheckerFactory(const AeriumUpdateCheckerFactory&) = delete;
  AeriumUpdateCheckerFactory& operator=(const AeriumUpdateCheckerFactory&) =
      delete;

 private:
  friend base::NoDestructor<AeriumUpdateCheckerFactory>;

  // Regular profiles only. An incognito window is not a different install, and
  // giving it its own checker would double the requests for no answer that the
  // regular profile does not already have.
  AeriumUpdateCheckerFactory()
      : ProfileKeyedServiceFactory(
            "AeriumUpdateChecker",
            ProfileSelections::Builder()
                .WithRegular(ProfileSelection::kOwnInstance)
                .WithGuest(ProfileSelection::kNone)
                .WithSystem(ProfileSelection::kNone)
                .WithAshInternals(ProfileSelection::kNone)
                .Build()) {}
  ~AeriumUpdateCheckerFactory() override = default;

  // Definitions are out of line because the chromium-style plugin rejects a
  // virtual method whose non-empty body is written inside the class - the same
  // reason aerium_first_run.h keeps its bodies below its declaration.
  std::unique_ptr<KeyedService> BuildServiceInstanceForBrowserContext(
      content::BrowserContext* context) const override;
  bool ServiceIsCreatedWithBrowserContext() const override;
  void RegisterProfilePrefs(
      user_prefs::PrefRegistrySyncable* registry) override;
};

inline AeriumUpdateCheckerFactory* AeriumUpdateCheckerFactory::GetInstance() {
  static base::NoDestructor<AeriumUpdateCheckerFactory> instance;
  return instance.get();
}

inline std::unique_ptr<KeyedService>
AeriumUpdateCheckerFactory::BuildServiceInstanceForBrowserContext(
    content::BrowserContext* context) const {
  return std::make_unique<AeriumUpdateChecker>(
      Profile::FromBrowserContext(context));
}

// Created with the profile rather than on first use, because nothing would ever
// ask for it: there is no call site, only a timer that has to be running.
inline bool AeriumUpdateCheckerFactory::ServiceIsCreatedWithBrowserContext()
    const {
  return true;
}

inline void AeriumUpdateCheckerFactory::RegisterProfilePrefs(
    user_prefs::PrefRegistrySyncable* registry) {
  registry->RegisterBooleanPref(kCheckEnabled, true);
  registry->RegisterInt64Pref(kLastCheckTime, 0);
  registry->RegisterStringPref(kLatestVersion, std::string());
  registry->RegisterStringPref(kLatestUrl, std::string());
}

}  // namespace aerium_update

#endif  // CHROME_BROWSER_AERIUM_AERIUM_UPDATE_CHECKER_H_
AERIUM_UPDATE_CHECKER_H

# Registered beside the browsing-data lifetime manager, which is the closest
# thing already here: another profile-scoped service that exists to run on a
# timer rather than to answer a call. ServiceIsCreatedWithBrowserContext() is
# what makes that work - nothing ever asks for this service, so if it were
# built lazily it would never be built at all.
CBMEPP=chrome/browser/profiles/chrome_browser_main_extra_parts_profiles.cc
sed_i 's|^#include "chrome/browser/browsing_data/chrome_browsing_data_lifetime_manager_factory.h"$|#include "chrome/browser/aerium/aerium_update_checker.h"\n&|' \
    $CBMEPP
sed_i 's|^  ChromeBrowsingDataLifetimeManagerFactory::GetInstance();$|  aerium_update::AeriumUpdateCheckerFactory::GetInstance();\n&|' \
    $CBMEPP

# --- and the switch, on the About screen, where the version it is checking is.
#
# Two rows. The switch says what the check costs before it says what it does,
# because "contacts GitHub once a day" is the part someone turning it off cares
# about. The result row exists only when there is a result: a permanent "you are
# up to date" is a line of furniture, while a row that appears when it has
# something to say is a message.
sed_i 's|^    private static final String PREF_AERIUM_PROJECT = "aerium_project";$|&\n    private static final String PREF_AERIUM_UPDATE_CHECK = "aerium_update_check";\n    private static final String PREF_AERIUM_UPDATE_AVAILABLE = "aerium_update_available";\n\n    // Must match chrome/browser/aerium/aerium_update_checker.h.\n    private static final String PREF_UPDATE_CHECK_ENABLED = "aerium.update.check_enabled";\n    private static final String PREF_UPDATE_LATEST_VERSION = "aerium.update.latest_version";\n    private static final String PREF_UPDATE_LATEST_URL = "aerium.update.latest_url";|' \
    $ACS
# Three imports, in the two places that keep the block sorted. Chromium checks
# import order in presubmit rather than in the build, so getting this wrong
# would compile - and then read as sloppy in every diff of this file forever.
sed_i 's|^import org.chromium.components.browser_ui.settings.EmbeddableSettingsPage;$|import org.chromium.components.browser_ui.settings.ChromeSwitchPreference;\n&|' \
    $ACS
sed_i 's|^import org.chromium.ui.widget.Toast;$|import org.chromium.components.prefs.PrefService;\nimport org.chromium.components.user_prefs.UserPrefs;\n&|' \
    $ACS
sed_i 's|^        Preference project = findPreference(PREF_AERIUM_PROJECT);$|        // Aerium: the update check. See theme.sh. The prefs are the profile'"'"'s,\n        // written by the checker in C++, so the switch is read and written\n        // through PrefService rather than persisted by the preference\n        // framework - which is why the XML entry is android:persistent="false".\n        PrefService updatePrefs = UserPrefs.get(getProfile());\n        ChromeSwitchPreference updateCheck =\n                (ChromeSwitchPreference) findPreference(PREF_AERIUM_UPDATE_CHECK);\n        if (updateCheck != null) {\n            updateCheck.setChecked(updatePrefs.getBoolean(PREF_UPDATE_CHECK_ENABLED));\n            updateCheck.setOnPreferenceChangeListener(\n                    (preference, newValue) -> {\n                        updatePrefs.setBoolean(PREF_UPDATE_CHECK_ENABLED, (boolean) newValue);\n                        return true;\n                    });\n        }\n\n        // Present only when there is something to say. An empty version is how\n        // the checker records "this build is the newest one", so it is also how\n        // a result that has been superseded disappears.\n        Preference updateAvailable = findPreference(PREF_AERIUM_UPDATE_AVAILABLE);\n        if (updateAvailable != null) {\n            String latest = updatePrefs.getString(PREF_UPDATE_LATEST_VERSION);\n            String latestUrl = updatePrefs.getString(PREF_UPDATE_LATEST_URL);\n            boolean haveUpdate = !latest.isEmpty() \&\& !latestUrl.isEmpty();\n            updateAvailable.setVisible(haveUpdate);\n            if (haveUpdate) {\n                updateAvailable.setSummary(latest);\n                updateAvailable.setOnPreferenceClickListener(\n                        preference -> {\n                            CustomTabActivity.showInfoPage(getActivity(), latestUrl);\n                            return true;\n                        });\n            }\n        }\n\n&|' \
    $ACS

# Inserted the same way the project row above was, before the closing tag, so
# the two land after it. Anchoring on "<Preference" would have matched every
# entry on the screen - sed replaces all of them - and put a copy of the switch
# above each one.
sed_i 's|^</PreferenceScreen>$|    <org.chromium.components.browser_ui.settings.ChromeSwitchPreference\n        android:key="aerium_update_check"\n        android:title="@string/aerium_update_check_title"\n        android:summary="@string/aerium_update_check_summary"\n        android:persistent="false" />\n    <Preference\n        android:key="aerium_update_available"\n        android:title="@string/aerium_update_available_title"\n        android:persistent="false" />\n&|' \
    chrome/android/java/res/xml/about_chrome_preferences.xml

sed_i 's|^      <message name="IDS_AERIUM_PROJECT_TITLE" desc=|      <message name="IDS_AERIUM_UPDATE_CHECK_TITLE" desc="Title of the About-screen switch that turns the daily update check on and off.">\n        Check for updates\n      </message>\n      <message name="IDS_AERIUM_UPDATE_CHECK_SUMMARY" desc="Summary under that switch. States the privacy cost first, then what the check is for.">\n        Asks GitHub once a day whether a newer Aerium has been released. Nothing is downloaded or installed. Turning this off means you will not be told when a security fix ships.\n      </message>\n      <message name="IDS_AERIUM_UPDATE_AVAILABLE_TITLE" desc="Title of the About-screen row that appears when a newer release exists. Tapping it opens that release.">\n        Update available\n      </message>\n&|' \
    chrome/browser/ui/android/strings/android_chrome_strings.grd
# --- Autofill that sometimes offers nothing: the renderer and the browser
# disagreeing about who is doing the autofilling.
#
# Reported as "on some websites autofill does not appear, neither as a popup nor
# inline in the keyboard". Both surfaces missing at once is the tell: that is not
# a UI problem, it is no autofill session being usable at all.
#
# Chromium decides once per profile, in AutofillClientProvider's constructor,
# whether to delegate to the Android Autofill framework. That single boolean has
# to reach two places:
#
#   * the browser, which uses it to build either AndroidAutofillClient or
#     ChromeAutofillClient for every WebContents; and
#   * the renderer, where AutofillAgent's constructor calls CreateConfig() on
#     RendererPreferences::uses_platform_autofill and gets one of two quite
#     different configurations - the delegating one turns off the keyboard
#     accessory, routes password suggestions through AutofillDriver instead of
#     letting PasswordAutofillAgent answer them, stops requiring a scroll before
#     focus is reported, and stops requiring a user gesture for value changes.
#
# Upstream keeps those two in step by force-writing the pref the renderer reads
# to whatever the browser decided, on every startup. Aerium stopped doing that,
# for a good reason: getAndroidAutofillFrameworkAvailability() treats the pref as
# one of its two routes to AVAILABLE, so writing false after a probe that failed
# once latched third-party autofill off permanently, and this build has no
# autofill settings screen to turn it back on again.
#
# The reason was right and the consequence was not. The probe has transient
# failure modes - UNKNOWN_ANDROID_AUTOFILL_SERVICE when the framework has not
# resolved the selected service yet, ANDROID_AUTOFILL_MANAGER_NOT_AVAILABLE if
# the system service is not up - and when one of those fires at profile
# construction the browser falls back to ChromeAutofillClient while the pref,
# now left alone, still says true. The renderer then configures itself for
# delegation that is not happening: no keyboard accessory, and password fields
# handed to a driver whose client is not expecting them. No popup, no inline
# row, and only on the launches where the probe happened to be slow - which from
# the outside looks like "some websites, sometimes".
#
# So the renderer is pointed at the decision instead of at the pref. Both halves
# now come from the same boolean by construction rather than by being written to
# the same place, the anti-latch fix above keeps working, and a launch where the
# probe fails degrades to Chrome's own autofill working properly rather than to
# neither autofill working at all.
#
# //chrome/browser/ui and //chrome/browser are the same target as far as
# includes go - chrome/browser/BUILD.gn says so in as many words where it sets
# up allow_circular_includes_from - so reaching for the factory here is not a
# layering violation.
RPU=chrome/browser/renderer_preferences_util.cc
sed_i 's|^#include "chrome/browser/profiles/profile.h"$|&\n#include "chrome/browser/ui/autofill/autofill_client_provider.h"\n#include "chrome/browser/ui/autofill/autofill_client_provider_factory.h"|' \
    $RPU
sed_i 's|^  prefs->uses_platform_autofill =$|  // Aerium: see theme.sh. This has to be the same boolean the browser used to\n  // pick the AutofillClient for this profile, not the pref that usually\n  // happens to equal it - the two diverge here, and a renderer configured for\n  // a delegation the browser is not performing offers no suggestions at all.\n&|' \
    $RPU
sed_i 's|^      pref_service->GetBoolean(autofill::prefs::kAutofillUsingPlatformAutofill);$|      autofill::AutofillClientProviderFactory::GetForProfile(profile)\n          .uses_platform_autofill();|' \
    $RPU

echo "[aerium] theme + rename pass applied"

# --- aerium:// - the browser's own pages under the browser's own name.
#
# aerium://settings, aerium://flags, aerium://version and every other chrome:
# host work. chrome:// is unchanged. The alias runs one way only: aerium: is
# rewritten to chrome: on the way into a navigation, and nothing rewrites
# chrome: back into aerium:.
#
# Four edits, the same four the desktop repositories carry as
# aerium-scheme.patch, so the behaviour does not differ by platform.
#
# The scheme is registered as standard. The comment above that list says a
# scheme only needs to be there to take part in the web platform, and that
# non-special URLs now parse a host on their own - true today, and a parser
# behaviour that has changed more than once. This scheme has exactly one job:
# aerium://settings has to split into a host and a path on every Chromium this
# ships on, because the rewrite replaces the scheme and keeps the rest. What the
# entry costs is an origin no document is ever committed in, since every aerium:
# URL has become a chrome: URL before anything loads it.
#
# ProfileIOData::IsHandledProtocol is what makes the omnibox go to
# aerium://settings rather than search for it: the scheme classifier asks that
# function first, and a scheme it does not know falls through to the
# external-protocol check, which answers "search" on Android.
#
# Nothing here lets a web page reach an internal page. A page navigating to
# aerium://settings is rewritten to chrome://settings and then blocked by
# exactly the check that blocks chrome://settings today, because the rewrite
# happens before the navigation is authorised, not after.
sed_i 's|^// "Learn more" URL for when profile settings are automatically reset.$|// Aerium: a second spelling of the chrome: scheme, so that the browser'"'"'s own\n// pages can be reached under the browser'"'"'s own name. See theme.sh - it is an\n// alias in one direction only, and no document ever commits under it.\ninline constexpr char kAeriumScheme[] = "aerium";\n\n&|' \
    chrome/common/url_constants.h
sed_i 's|^    chrome::kChromeNativeScheme,        chrome::kChromeSearchScheme,$|    chrome::kAeriumScheme,\n&|' \
    chrome/common/chrome_content_client.cc
sed_i 's|^      content::kChromeUIScheme,$|      chrome::kAeriumScheme,\n&|' \
    chrome/browser/profiles/profile_io_data.cc
sed_i 's|^// Handles the rewriting of the new tab page URL based on group policy.$|// Aerium: rewrite aerium://<rest> to chrome://<rest> and then get out of the\n// way. See theme.sh.\n//\n// The return value is false on purpose, including when the URL was rewritten.\n// RewriteURLIfNecessary stops at the first handler that returns true, so\n// claiming the URL here would mean chrome://settings never reaching\n// HandleWebUI and chrome://newtab never reaching HandleAndroidNativePageURL -\n// the alias would resolve the scheme and then skip everything that gives those\n// hosts their meaning. Mutating through the pointer and declining to claim the\n// URL is how a handler joins the chain rather than ending it; HandleViewSource\n// does the same on its error path.\n//\n// The displayed URL is not affected and does not need to be. The navigation\n// entry keeps the URL as it was typed as its virtual URL, copied before the\n// rewrite, so aerium://settings stays aerium://settings in the omnibox while\n// chrome:// stays chrome://, and neither spelling is rewritten into the other\n// behind the user'"'"'s back.\nbool HandleAeriumScheme(GURL* url, content::BrowserContext* browser_context) {\n  if (url->SchemeIs(chrome::kAeriumScheme)) {\n    GURL::Replacements replacements;\n    replacements.SetSchemeStr(content::kChromeUIScheme);\n    *url = url->ReplaceComponents(replacements);\n  }\n  return false;\n}\n\n&|' \
    chrome/browser/chrome_content_browser_client.cc
sed_i 's|^    BrowserURLHandler\* handler) {$|&\n  // Aerium: aerium://<host> is another spelling of chrome://<host>. First,\n  // ahead of every handler below, so that aerium://newtab and aerium://about\n  // reach the handlers that know what those mean.\n  handler->AddHandlerPair(\&HandleAeriumScheme,\n                          BrowserURLHandler::null_handler());\n|' \
    chrome/browser/chrome_content_browser_client.cc

echo "[aerium] aerium:// scheme applied"

# --- "A new Aerium is out" - as a notification, not only as a row you have to
# go and look at.
#
# The daily check and the About-screen switch already exist above; this is the
# telling. The checker writes three profile prefs in C++ and never touches the
# UI, so everything here is a reader of those prefs: a notification when they
# name a release the user has not been shown, and nothing at all when they do
# not.
#
# Chromium already has the right category for this. ChannelId.UPDATES is a
# predefined high-importance channel in the GENERAL group, and
# SystemNotificationType.UPDATES is an existing histogram enumerator; both exist
# for Chrome'"'"'s own updater and are dead in this build, which has none. Reusing
# them means Android can describe the notification to the user in its own
# settings - it can be silenced by itself, without silencing the browser - and
# it costs no new channel definition and no new histogram enumerator, which
# would otherwise mean editing enums.xml in a repository that does not have it.
#
# Once per release, not once per launch. That needs a record of what the user
# has already been shown, and it lives in SharedPreferences rather than in a
# fourth profile pref on purpose: "have I shown this notification" is Android UI
# state, not browser data, and keeping it out of the shared header is what lets
# aerium_update_checker.h stay byte-identical across the three platforms.
#
# What this deliberately does not do is wake the device. The checker is a
# KeyedService on a timer, so it only runs while the browser process is alive -
# in practice, two minutes after a launch. Someone who opens Aerium daily hears
# about a release the same day; someone who does not, hears about it when they
# next open it. Doing better means a BackgroundTaskScheduler job waking the
# device on a schedule to ask GitHub a question, which is a different feature
# with a different battery and privacy cost, and not obviously a better one for
# a browser that is not running.
mkdir -p chrome/android/java/src/org/chromium/chrome/browser/aerium
cat > chrome/android/java/src/org/chromium/chrome/browser/aerium/AeriumUpdateNotifier.java <<'AERIUM_UPDATE_NOTIFIER_JAVA'
// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package org.chromium.chrome.browser.aerium;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;

import org.chromium.base.ContextUtils;
import org.chromium.base.shared_preferences.SharedPreferencesManager;
import org.chromium.build.annotations.NullMarked;
import org.chromium.build.annotations.Nullable;
import org.chromium.chrome.R;
import org.chromium.chrome.browser.notifications.NotificationUmaTracker;
import org.chromium.chrome.browser.notifications.NotificationWrapperBuilderFactory;
import org.chromium.chrome.browser.notifications.channels.ChromeChannelDefinitions;
import org.chromium.chrome.browser.preferences.ChromePreferenceKeys;
import org.chromium.chrome.browser.preferences.ChromeSharedPreferences;
import org.chromium.chrome.browser.profiles.Profile;
import org.chromium.components.browser_ui.notifications.BaseNotificationManagerProxy;
import org.chromium.components.browser_ui.notifications.BaseNotificationManagerProxyFactory;
import org.chromium.components.browser_ui.notifications.NotificationMetadata;
import org.chromium.components.browser_ui.notifications.NotificationProxyUtils;
import org.chromium.components.browser_ui.notifications.NotificationWrapper;
import org.chromium.components.browser_ui.notifications.PendingIntentProvider;
import org.chromium.components.prefs.PrefChangeRegistrar;
import org.chromium.components.prefs.PrefService;
import org.chromium.components.user_prefs.UserPrefs;

/**
 * Aerium: tells the user, once per release, that a newer Aerium exists.
 *
 * <p>The finding is done in C++ - see chrome/browser/aerium/aerium_update_checker.h, which asks
 * GitHub once a day and writes the answer to three profile prefs. This class is only the telling.
 * It reads those prefs, posts a notification when they name a release the user has not been shown,
 * and opens that release when the notification is tapped.
 *
 * <p>Nothing is downloaded or installed, here or anywhere else in this feature.
 *
 * <p>The channel and the metrics type are Chromium's own ChannelId.UPDATES and
 * SystemNotificationType.UPDATES, which exist upstream for exactly this and are unused in this
 * build because it has no other update system. Reusing them means the notification arrives in a
 * category Android already knows how to describe to the user - it can be silenced on its own,
 * without silencing the rest of the browser - and it costs no new histogram enumerator.
 */
@NullMarked
public class AeriumUpdateNotifier implements PrefChangeRegistrar.PrefObserver {
    // Must match chrome/browser/aerium/aerium_update_checker.h.
    private static final String PREF_CHECK_ENABLED = "aerium.update.check_enabled";
    private static final String PREF_LATEST_VERSION = "aerium.update.latest_version";
    private static final String PREF_LATEST_URL = "aerium.update.latest_url";

    private static final String NOTIFICATION_TAG = "aerium_update";
    private static final int NOTIFICATION_ID = 1;

    private static @Nullable AeriumUpdateNotifier sInstance;

    private final Profile mProfile;

    // Held for the life of the process rather than for the life of an activity. The point of the
    // observer is to catch the check completing while the browser is open - it runs two minutes
    // after startup - and an activity-scoped observer would miss exactly the case where the user
    // launched the browser and left it alone.
    private final PrefChangeRegistrar mRegistrar;

    /**
     * Starts watching, and says anything there is to say about the state already on disk.
     *
     * <p>Called from deferred startup, so a release announcement never competes with the page the
     * user actually opened the browser for. Idempotent: later activities find the instance already
     * built and only re-check.
     */
    public static void initialize(Profile profile) {
        if (sInstance == null) {
            sInstance = new AeriumUpdateNotifier(profile);
        }
        sInstance.onPreferenceChange();
    }

    private AeriumUpdateNotifier(Profile profile) {
        mProfile = profile;
        mRegistrar = new PrefChangeRegistrar(UserPrefs.get(profile));
        mRegistrar.addObserver(PREF_LATEST_VERSION, this);
    }

    @Override
    public void onPreferenceChange() {
        PrefService prefs = UserPrefs.get(mProfile);
        BaseNotificationManagerProxy manager = BaseNotificationManagerProxyFactory.create();
        SharedPreferencesManager shared = ChromeSharedPreferences.getInstance();

        // Turning the switch off means stop telling me, including about whatever was already
        // found. An empty version is how the checker records "this build is the newest one", so it
        // is also how a notification for a release that has since been superseded is taken back.
        String version = prefs.getString(PREF_LATEST_VERSION);
        String url = prefs.getString(PREF_LATEST_URL);
        if (!prefs.getBoolean(PREF_CHECK_ENABLED) || version.isEmpty() || url.isEmpty()) {
            manager.cancel(NOTIFICATION_TAG, NOTIFICATION_ID);
            shared.removeKey(ChromePreferenceKeys.AERIUM_UPDATE_NOTIFIED_VERSION);
            return;
        }

        if (version.equals(
                shared.readString(ChromePreferenceKeys.AERIUM_UPDATE_NOTIFIED_VERSION, ""))) {
            return;
        }

        // Posting to a channel the user has blocked, or without the runtime notification
        // permission, silently does nothing. Recording the version as told-about in that case
        // would mean the user is never told, so the record is written only after the notification
        // has actually gone out - and the About screen keeps its own row either way.
        if (!NotificationProxyUtils.areNotificationsEnabled()) return;

        Context context = ContextUtils.getApplicationContext();
        Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
        // Kept inside this browser rather than handed to the system, which can put a chooser in
        // front of it or send it to a different browser entirely - the same reason the About row
        // opens the project link in a Custom Tab.
        intent.setPackage(context.getPackageName());

        NotificationWrapper notification =
                NotificationWrapperBuilderFactory.createNotificationWrapperBuilder(
                                ChromeChannelDefinitions.ChannelId.UPDATES,
                                new NotificationMetadata(
                                        NotificationUmaTracker.SystemNotificationType.UPDATES,
                                        NOTIFICATION_TAG,
                                        NOTIFICATION_ID))
                        .setContentTitle(
                                context.getString(R.string.aerium_update_notification_title))
                        .setContentText(
                                context.getString(
                                        R.string.aerium_update_notification_text, version))
                        .setContentIntent(
                                PendingIntentProvider.getActivity(
                                        context,
                                        /* requestCode= */ 0,
                                        intent,
                                        PendingIntent.FLAG_UPDATE_CURRENT))
                        .setSmallIcon(R.drawable.ic_chrome)
                        .setAutoCancel(true)
                        .setLocalOnly(true)
                        .buildNotificationWrapper();

        manager.notify(notification);
        NotificationUmaTracker.getInstance()
                .onNotificationShown(
                        NotificationUmaTracker.SystemNotificationType.UPDATES,
                        notification.getNotification());
        shared.writeString(ChromePreferenceKeys.AERIUM_UPDATE_NOTIFIED_VERSION, version);
    }
}
AERIUM_UPDATE_NOTIFIER_JAVA

# aerium/ sorts between about_settings/ and accessibility/, which is where the
# list keeps it.
sed_i 's|^  "java/src/org/chromium/chrome/browser/accessibility/AccessibilityTabHelper.java",$|  "java/src/org/chromium/chrome/browser/aerium/AeriumUpdateNotifier.java",\n&|' \
    chrome/android/chrome_java_sources.gni

# The SharedPreferences key, declared and registered the two ways
# ChromePreferenceKeys documents at the top of itself. Skipping the second step
# builds fine and then trips StrictPreferenceKeyChecker in any build with
# asserts on, which is every developer build and no release - the worst place
# for a mistake to wait.
sed_i 's|^    /\*\* Timestamp of last time ai feature availability was checked. \*/$|    /** The release the update notification has already told the user about. */\n    public static final String AERIUM_UPDATE_NOTIFIED_VERSION =\n            "Chrome.Aerium.UpdateNotifiedVersion";\n\n&|' \
    chrome/browser/preferences/android/java/src/org/chromium/chrome/browser/preferences/ChromePreferenceKeys.java
sed_i 's|^                AI_ASSISTANT_ANALYZE_ATTACHMENT_AVAILABILITY,$|                AERIUM_UPDATE_NOTIFIED_VERSION,\n&|' \
    chrome/browser/preferences/android/java/src/org/chromium/chrome/browser/preferences/ChromePreferenceKeys.java

# Started from deferred startup: the browser is up, the profile is loaded, and
# nothing the user is waiting for is still in flight. getOriginalProfile()
# rather than the supplier'"'"'s current profile, because the checker registers
# for regular profiles only and an incognito window must not be a second
# listener.
CTA=chrome/android/java/src/org/chromium/chrome/browser/ChromeTabbedActivity.java
sed_i 's|^import org.chromium.chrome.browser.app.ChromeActivity;$|import org.chromium.chrome.browser.aerium.AeriumUpdateNotifier;\n&|' \
    $CTA
sed_i 's|^        LauncherShortcutActivity.updateIncognitoShortcut(profile);$|&\n\n        // Aerium: see theme.sh. Tells the user about a newer release, if the\n        // daily check has found one and they have not been told yet.\n        AeriumUpdateNotifier.initialize(\n                getProfileProviderSupplier().get().getOriginalProfile());|' \
    $CTA

sed_i 's|^      <message name="IDS_AERIUM_UPDATE_AVAILABLE_TITLE" desc=|      <message name="IDS_AERIUM_UPDATE_NOTIFICATION_TITLE" desc="Title of the notification shown when a newer Aerium has been released.">\n        Update available\n      </message>\n      <message name="IDS_AERIUM_UPDATE_NOTIFICATION_TEXT" desc="Body of that notification. The placeholder is the release tag, and tapping the notification opens that release on GitHub.">\n        Aerium <ph name="VERSION">%1$s<ex>v152.0.7977.64</ex></ph> has been released. Tap to open the release on GitHub.\n      </message>\n&|' \
    chrome/browser/ui/android/strings/android_chrome_strings.grd

echo "[aerium] update notification applied"

# --- View page source, in the More tools submenu.
#
# Everything but the menu row already exists in 152. ids.xml declares
# view_source, KeyboardShortcuts maps VIEW_SOURCE onto it, and ChromeActivity
# handles it:
#
#     if (id == R.id.view_source
#             && !currentTab.isNativePage()
#             && DevToolsWindowAndroid.canViewSource(...)) {
#       currentTab.getWebContents().getMainFrame().viewSource();
#
# So the feature is built, tested and reachable - by a keyboard shortcut, on a
# phone, which is to say not reachable. The desktop has the row and Android
# does not, and that is the entire gap. Nothing here touches the action; it
# adds a way to ask for it.
#
# The guard repeats canViewSource() rather than trusting the handler's, because
# an item that appears and then does nothing when tapped is worse than one that
# is absent - view-source is refused on native pages and wherever the policy
# blocks DevTools, and both are states a user can be in.
MTIB=chrome/android/java/src/org/chromium/chrome/browser/tabbed_mode/MoreToolsItemBuilder.java
sed_i 's%    /\*\* Builds the "Dev tools" menu item. \*/%/**\n     * Returns whether the "View page source" menu item should be displayed.\n     *\n     * @param currentTab The current tab.\n     */\n    public boolean shouldShowViewSourceItem(@Nullable Tab currentTab) {\n        // Aerium: see theme.sh. No form-factor test, unlike dev tools - reading\n        // the markup of a page is not a tablet-sized activity.\n        if (currentTab == null || currentTab.isNativePage()) {\n            return false;\n        }\n\n        WebContents webContents = currentTab.getWebContents();\n        if (webContents == null) {\n            return false;\n        }\n\n        return DevToolsWindowAndroid.canViewSource(currentTab.getProfile(), webContents);\n    }\n\n    /** Builds the "View page source" menu item. */\n    public ListItem buildViewSourceItem() {\n        return AppMenuItemUtils.createStandardListItem(\n                AppMenuItemUtils.buildModelForStandardMenuItem(\n                        mContext,\n                        mAppMenuItemTheme,\n                        R.id.view_source,\n                        R.string.aerium_menu_view_source,\n                        Resources.ID_NULL,\n                        mIsMenuIconAtStart),\n                /* showIcon= */ false);\n    }\n\n&%' \
    $MTIB

# More tools is hidden entirely when every item in it would be hidden, so the
# new row has to join that test as well as the list.
sed_i 's%                || shouldShowDevToolsItem(currentTab)) {%                || shouldShowDevToolsItem(currentTab)\n                || shouldShowViewSourceItem(currentTab)) {%' \
    $MTIB

# Placed after Developer tools, which is where the desktop keeps it too.
sed_i '/^                    if (mMoreToolsItemBuilder.shouldShowDevToolsItem(currentTab)) {$/{N;N;s|                        submenuItems.add(mMoreToolsItemBuilder.buildDevToolsItem());\n                    }|                        submenuItems.add(mMoreToolsItemBuilder.buildDevToolsItem());\n                    }\n\n                    // Aerium: see theme.sh.\n                    if (mMoreToolsItemBuilder.shouldShowViewSourceItem(currentTab)) {\n                        submenuItems.add(mMoreToolsItemBuilder.buildViewSourceItem());\n                    }|}' \
    chrome/android/java/src/org/chromium/chrome/browser/tabbed_mode/TabbedAppMenuPropertiesDelegate.java

sed_i 's|      <message name="IDS_MENU_DEV_TOOLS" desc=|      <message name="IDS_AERIUM_MENU_VIEW_SOURCE" desc="Menu item that opens the HTML source of the current page in a new tab. [CHAR_LIMIT=27]">\n        View page source\n      </message>\n&|' \
    chrome/browser/ui/android/strings/android_chrome_strings.grd

echo "[aerium] view page source applied"

# --- Install an extension that is not on a store.
#
# Asked for repeatedly: a .crx from a GitHub release, or one already on the
# device, cannot be installed at all today. The reason is one line.
#
# ChromeDownloadManagerDelegate::ShouldOpenDownload() is the only place a
# downloaded CRX becomes an install, and it is gated on
# extensions::util::IsExtensionDownload(), which is
#
#     download_item.GetMimeType() == Extension::kMimeType
#
# GitHub serves every release asset as application/octet-stream. So a .crx from
# a GitHub release is not an extension download by that test, never reaches
# CrxInstaller, and lands in the Downloads folder as an inert file. The
# extension-mime-request-handling flag above does not help - it decides what to
# do with a CRX MIME type, and there is not one.
#
# So the filename is accepted as well as the MIME type, but only from a host
# this build already allows off-store installs from. That ordering matters. The
# alternative - accepting any .crx by name - would send files from arbitrary
# hosts into CrxInstaller, which refuses off-store installs it was not told to
# allow, turning a download that used to save into an error message. This way a
# trusted host is allowed to serve a .crx badly; it does not make new hosts
# trusted.
#
# Nothing installs silently: CreateCrxInstaller() builds an ExtensionInstallPrompt
# and the user still agrees to the permissions.
#
# Not done here, and worth being plain about: a .crx already sitting on the
# device still has no path in. That needs a file picker, a content:// URI copied
# somewhere CrxInstaller can read, and a JNI bridge to reach it - a bigger piece
# than this, and a separate one.
# Two source lines make up the condition, so both are pulled into the pattern
# space and replaced together.
sed_i '/^  if (extensions::util::IsExtensionDownload(\*item) \&\&$/{N;s%  if (extensions::util::IsExtensionDownload(\*item) \&\&\n      !extensions::WebstoreInstaller::GetAssociatedApproval(\*item)) {%  // Aerium: see theme.sh. A .crx whose host serves it as application/octet-stream\n  // rather than as an extension MIME type - which is what GitHub does for every\n  // release asset - is still a .crx, and refusing to install it means the only\n  // way to get an extension that is not on a store is no way at all.\n  //\n  // Narrow on purpose. It applies only when the host is already one this build\n  // allows off-store installs from, so this changes what a trusted host is\n  // allowed to serve, not which hosts are trusted. A .crx from anywhere else\n  // saves as a file exactly as before, rather than reaching CrxInstaller and\n  // being refused with an error where a download used to appear.\n  //\n  // The install prompt is unchanged: CreateCrxInstaller() builds one and the\n  // user still has to agree to the permissions.\n  const bool aerium_offstore_crx =\n      !extensions::util::IsExtensionDownload(*item) \&\&\n      item->GetTargetFilePath().MatchesExtension(\n          extensions::kExtensionFileExtension) \&\&\n      download_crx_util::OffStoreInstallAllowedByPrefs(profile_, *item);\n\n  if ((extensions::util::IsExtensionDownload(*item) || aerium_offstore_crx) \&\&\n      !extensions::WebstoreInstaller::GetAssociatedApproval(*item)) {%}' \
    chrome/browser/download/chrome_download_manager_delegate.cc

# --- ... and give that install prompt somewhere to appear.
#
# The block above gets a GitHub .crx as far as CrxInstaller. It still does not
# install, and issue 14 is the report: the file downloads and nothing happens.
# The missing half is upstream's, in download_crx_util.cc:
#
#   content::WebContents* web_contents = DownloadItemUtils::GetWebContents(...);
#   if (!web_contents) {
#     BrowserWindowInterface* browser = GetLastActiveBrowserWithProfile(...);
#     if (!browser) {
#   #if BUILDFLAG(IS_ANDROID)
#       // TODO(crbug.com/474161414): Implement fallback if no browser is found.
#       // Android does not have Browser implementation yet, but we are okay
#       // with not showing an installed dialog if no window is open.
#       return nullptr;
#
# So when the download has no live WebContents, Android has no second route to
# one - there is no Browser to ask - and CreateExtensionInstallPrompt returns
# nullptr. CrxInstaller is then handed no client, and the install that the block
# above worked to reach has no way to ask the user anything. On desktop the same
# branch creates a Browser and carries on.
#
# A download losing its WebContents is ordinary rather than exceptional: the
# association is to the tab that started it, and by the time ShouldOpenDownload
# runs at completion that tab may have navigated, been closed, or handed the
# transfer to Android's download manager.
#
# The fallback upstream leaves as a TODO is the obvious one, and Android has the
# pieces for it: TabModelList::models() is the list of open tab models,
# TabModel::GetProfile() says which profile each belongs to, and
# GetActiveWebContents() is the foreground tab. Take the first model matching
# this profile that has one.
#
# Deliberately placed BEFORE the browser lookup rather than replacing the
# nullptr return, so the desktop path is untouched and this only ever runs where
# upstream would already have given up. It cannot regress anything: the whole
# block is inside `if (!web_contents)`, so a download that still has its own
# WebContents keeps using it, exactly as now.
#
# The dialog itself is not the gap. ExtensionInstallPrompt::
# GetDefaultShowDialogCallback() is defined in the views implementation, and
# this build links, so views is compiled here and the prompt has somewhere to
# draw once it is given a WebContents.
sed_i 's|^#if !BUILDFLAG(IS_ANDROID)$|#if BUILDFLAG(IS_ANDROID)\n// Aerium: see theme.sh - used to find a WebContents for the extension install\n// prompt when the download no longer has one of its own.\n#include "chrome/browser/ui/android/tab_model/tab_model.h"\n#include "chrome/browser/ui/android/tab_model/tab_model_list.h"\n#endif\n&|' \
    chrome/browser/download/download_crx_util.cc

sed_i 's|^  if (!web_contents) {$|#if BUILDFLAG(IS_ANDROID)\n  // Aerium: see theme.sh. Upstream returns nullptr here on Android because it\n  // has no Browser to fall back to, which leaves CrxInstaller with no client\n  // and no way to prompt - a .crx then downloads and nothing happens. The\n  // foreground tab is a perfectly good place to show the dialog, so use it.\n  if (!web_contents) {\n    for (TabModel* model : TabModelList::models()) {\n      if (model \&\& model->GetProfile() == profile) {\n        web_contents = model->GetActiveWebContents();\n        if (web_contents) {\n          break;\n        }\n      }\n    }\n  }\n#endif  // BUILDFLAG(IS_ANDROID)\n&|' \
    chrome/browser/download/download_crx_util.cc


# --- The source URL of a download, shown and copyable.
#
# Downloads home already prints the domain in the caption line - UiUtils
# .generateGenericCaption() runs the URL through formatUrlForDisplayInNotification
# and truncates it to MAX_ORIGIN_LENGTH_FOR_DOWNLOAD_HOME_CAPTION - so you can
# see that a file came from example.com and nothing more. Which of the six
# links on that page it was, or what the query string carried, is not
# recoverable from the UI at all, and the OfflineItem has held the full URL the
# whole time.
#
# The row cannot show it: a full URL is longer than the title it would sit
# under. So it goes in the overflow menu next to Share and Delete, and the
# toast prints the URL rather than a confirmation - one tap both shows the
# link and puts it on the clipboard, which is what someone asking this question
# wants to do with it next.
#
# Menu items in this holder are keyed by their string resource id, which is
# what the delegate switches on, so a new item is a string plus two branches.
OIVH=chrome/browser/download/internal/android/java/src/org/chromium/chrome/browser/download/home/list/holder/OfflineItemViewHolder.java
sed_i 's|^import org.chromium.ui.listmenu.ListMenu;$|import org.chromium.ui.base.Clipboard;\n&|' $OIVH
sed_i 's|    private @Nullable Runnable mShowWarningBypassDialogCallback;|&\n\n    // Aerium: see theme.sh. Null when the item has no usable source URL, which\n    // is also what hides the menu row.\n    private @Nullable Runnable mCopySourceCallback;|' $OIVH

sed_i 's|        mRenameCallback =|        // Aerium: see theme.sh.\n        mCopySourceCallback =\n                (offlineItem.url != null \&\& offlineItem.url.isValid())\n                        ? () -> {\n                            String url = offlineItem.url.getSpec();\n                            Clipboard.getInstance().setText(offlineItem.title, url);\n                            Toast.makeText(mMore.getContext(), url, Toast.LENGTH_LONG).show();\n                        }\n                        : null;\n\n&|' $OIVH

sed_i 's|        if (mCanShare) listItems.add(buildSimpleMenuItem(R.string.share));|&\n        // Aerium: see theme.sh.\n        if (mCopySourceCallback != null) {\n            listItems.add(buildSimpleMenuItem(R.string.aerium_download_copy_source_url));\n        }|' $OIVH

sed_i 's|                    } else if (textId == R.string.menu_open_with) {|                    } else if (textId == R.string.aerium_download_copy_source_url) {\n                        // Aerium: see theme.sh.\n                        if (mCopySourceCallback != null) mCopySourceCallback.run();\n&|' $OIVH

sed_i 's|      <message name="IDS_MENU_DEV_TOOLS" desc=|      <message name="IDS_AERIUM_DOWNLOAD_COPY_SOURCE_URL" desc="Item in a downloaded file'"'"'s overflow menu. Shows the address the file was downloaded from and copies it to the clipboard. [CHAR_LIMIT=27]">\n        Copy source link\n      </message>\n&|' \
    chrome/browser/ui/android/strings/android_chrome_strings.grd

echo "[aerium] download source url applied"

# --- Hand a download to another app.
#
# Asked for repeatedly by people who use ADM, 1DM or IDM+ and want the browser
# to stop being the thing that fetches large files: those apps segment,
# resume across network changes, and survive the browser being killed, none of
# which Chromium's downloader does on a phone.
#
# The hook is upstream's own escape hatch. DownloadController::OnDownloadStarted
# already has a branch that hands a download somewhere else and drops
# Chromium's copy - it is how a PDF gets opened inline:
#
#     if (should_cancel_download) {
#       ScheduleRemoveDownloadItem(download_item);
#       download_item->RemoveObserver(this);
#       return;
#     }
#
# So this asks the same question first, in the same shape, and uses the same
# three lines to bow out.
#
# The decision is made in Java, not in native, and native only learns whether
# somebody took it. That is deliberate: the switch is a SharedPreference like
# the other Aerium Android switches, and pushing the test to the Java side
# means no new profile pref, no addition to the generated Pref enum, and no
# second place where "is this on" can be answered differently. The cost is one
# JNI call per download start.
#
# What cannot be carried across is authentication. DownloadItem exposes the
# URL, the MIME type and the referrer, and no cookie - so a download that only
# works while signed in will not work in another app. That is a property of
# handing a bare URL to a different process, not something this could fix, and
# the switch summary says so rather than letting people find out with a 403.
sed_i 's|^import org.jni_zero.CalledByNative;$|import android.content.ActivityNotFoundException;\nimport android.content.Context;\nimport android.content.Intent;\nimport android.content.pm.ResolveInfo;\nimport android.net.Uri;\nimport android.text.TextUtils;\n\n&|' \
    chrome/android/java/src/org/chromium/chrome/browser/download/DownloadController.java
sed_i 's|^import org.chromium.build.annotations.NullMarked;$|import org.chromium.base.ContextUtils;\n&|' \
    chrome/android/java/src/org/chromium/chrome/browser/download/DownloadController.java
sed_i 's|^import org.chromium.chrome.browser.pdf.PdfPage;$|import org.chromium.chrome.browser.preferences.ChromePreferenceKeys;\nimport org.chromium.chrome.browser.preferences.ChromeSharedPreferences;\n&|' \
    chrome/android/java/src/org/chromium/chrome/browser/download/DownloadController.java

sed_i 's%    static void enqueueDownloadManagerRequest(final DownloadInfo info) {%/**\n     * Aerium: see theme.sh. Offers the download to another app, and reports back\n     * whether one took it - native cancels its own download only if this is\n     * true, so every way of declining ends in an ordinary in-browser download.\n     */\n    @CalledByNative\n    private static boolean maybeOpenWithExternalApp(\n            GURL url, @JniType("std::string") String mimeType, GURL referrer) {\n        if (!ChromeSharedPreferences.getInstance()\n                .readBoolean(ChromePreferenceKeys.AERIUM_EXTERNAL_DOWNLOAD_MANAGER, false)) {\n            return false;\n        }\n        if (url == null || !url.isValid()) return false;\n\n        // Only ordinary web downloads. A blob:, data: or filesystem: URL means\n        // nothing outside the process that minted it, and handing one over\n        // would fail in the other app rather than here.\n        String scheme = url.getScheme();\n        if (!"http".equals(scheme) \&\& !"https".equals(scheme)) return false;\n\n        Context context = ContextUtils.getApplicationContext();\n        Intent intent = new Intent(Intent.ACTION_VIEW);\n        intent.setDataAndType(\n                Uri.parse(url.getSpec()),\n                TextUtils.isEmpty(mimeType) ? "application/octet-stream" : mimeType);\n        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);\n        if (referrer != null \&\& referrer.isValid()) {\n            intent.putExtra(Intent.EXTRA_REFERRER, Uri.parse(referrer.getSpec()));\n        }\n\n        // Never hand it to ourselves. Aerium registers for http and https VIEW\n        // intents, so without this test a type nothing else claims comes\n        // straight back in as a navigation and downloads again - the same file,\n        // in a loop, with the switch on. A chooser resolves to the system\n        // resolver rather than to us, so several handlers still reach the user.\n        ResolveInfo resolved = context.getPackageManager().resolveActivity(intent, 0);\n        if (resolved == null\n                || resolved.activityInfo == null\n                || context.getPackageName().equals(resolved.activityInfo.packageName)) {\n            return false;\n        }\n\n        try {\n            context.startActivity(intent);\n            return true;\n        } catch (ActivityNotFoundException | SecurityException e) {\n            return false;\n        }\n    }\n\n&%' \
    chrome/android/java/src/org/chromium/chrome/browser/download/DownloadController.java

DLC=chrome/browser/download/android/download_controller.cc
sed_i 's|^void DownloadController::OnDownloadStarted(DownloadItem\* download_item) {$|&\n  // Aerium: see theme.sh. Offered to another app before anything else looks at\n  // it; if one takes it, this download is dropped the way the PDF branch below\n  // drops its own.\n  {\n    JNIEnv* env = base::android::AttachCurrentThread();\n    if (Java_DownloadController_maybeOpenWithExternalApp(\n            env, url::GURLAndroid::FromNativeGURL(env, download_item->GetURL()),\n            download_item->GetMimeType(),\n            url::GURLAndroid::FromNativeGURL(\n                env, download_item->GetReferrerUrl()))) {\n      ScheduleRemoveDownloadItem(download_item);\n      download_item->RemoveObserver(this);\n      return;\n    }\n  }\n|' $DLC

# The switch, in Settings > Downloads, next to the other two.
sed_i 's|^</PreferenceScreen>$|    <org.chromium.components.browser_ui.settings.ChromeSwitchPreference\n        android:key="aerium_external_download_manager"\n        android:title="@string/aerium_external_download_manager_title"\n        android:summary="@string/aerium_external_download_manager_summary" />\n\n&|' \
    chrome/browser/download/android/java/res/xml/download_preferences.xml

DLS=chrome/browser/download/android/java/src/org/chromium/chrome/browser/download/settings/DownloadSettings.java
sed_i 's|^import org.chromium.chrome.browser.preferences.Pref;$|import org.chromium.chrome.browser.preferences.ChromePreferenceKeys;\nimport org.chromium.chrome.browser.preferences.ChromeSharedPreferences;\n&|' $DLS
sed_i 's|    public static final String PREF_AUTO_OPEN_PDF_ENABLED = "auto_open_pdf_enabled";|&\n\n    // Aerium: see theme.sh.\n    public static final String PREF_AERIUM_EXTERNAL_DOWNLOAD_MANAGER =\n            "aerium_external_download_manager";|' $DLS
sed_i 's|    private ChromeSwitchPreference mAutoOpenPdfEnabledPref;|&\n    private ChromeSwitchPreference mAeriumExternalDownloadManagerPref;|' $DLS
sed_i 's|        mLocationChangePref.setDownloadLocationHelper(new DownloadLocationHelperImpl(getProfile()));|&\n\n        // Aerium: see theme.sh. Inserted here rather than after the auto-open-PDF\n        // block below, because that block is an if/else and appending to either\n        // arm would put this inside a branch.\n        mAeriumExternalDownloadManagerPref =\n                (ChromeSwitchPreference) findPreference(PREF_AERIUM_EXTERNAL_DOWNLOAD_MANAGER);\n        if (mAeriumExternalDownloadManagerPref != null) {\n            mAeriumExternalDownloadManagerPref.setOnPreferenceChangeListener(this);\n        }|' $DLS
sed_i 's|^        } else if (PREF_AUTO_OPEN_PDF_ENABLED.equals(preference.getKey())) {$|        } else if (PREF_AERIUM_EXTERNAL_DOWNLOAD_MANAGER.equals(preference.getKey())) {\n            // Aerium: see theme.sh.\n            ChromeSharedPreferences.getInstance()\n                    .writeBoolean(\n                            ChromePreferenceKeys.AERIUM_EXTERNAL_DOWNLOAD_MANAGER,\n                            (boolean) newValue);\n&|' $DLS
sed_i 's|^        mLocationChangePref.updateSummary();$|&\n\n        // Aerium: see theme.sh. First statement of the method, so this sits at\n        // method level rather than inside one of the branches below.\n        if (mAeriumExternalDownloadManagerPref != null) {\n            mAeriumExternalDownloadManagerPref.setChecked(\n                    ChromeSharedPreferences.getInstance()\n                            .readBoolean(\n                                    ChromePreferenceKeys.AERIUM_EXTERNAL_DOWNLOAD_MANAGER,\n                                    false));\n        }|' $DLS

sed_i 's|    /\*\* Whether Aerium blackens sites that ship their own dark theme. \*/|    /** Whether Aerium hands downloads to another app instead of fetching them. */\n    public static final String AERIUM_EXTERNAL_DOWNLOAD_MANAGER =\n            "Chrome.Aerium.ExternalDownloadManager";\n\n&|' \
    $CPK
sed_i 's|^                AERIUM_BLACKEN_DARK_SITES,$|                AERIUM_EXTERNAL_DOWNLOAD_MANAGER,\n&|' $CPK

sed_i 's|      <message name="IDS_MENU_DEV_TOOLS" desc=|      <message name="IDS_AERIUM_EXTERNAL_DOWNLOAD_MANAGER_TITLE" desc="Title of the switch that sends downloads to a separate download manager app.">\n        Download with another app\n      </message>\n      <message name="IDS_AERIUM_EXTERNAL_DOWNLOAD_MANAGER_SUMMARY" desc="Summary under that switch. Warns that sign-in cookies are not passed to the other app.">\n        Offer each download to a download manager app instead of fetching it here. Sign-in cookies are not passed on, so downloads that need an account may fail in the other app.\n      </message>\n&|' \
    chrome/browser/ui/android/strings/android_chrome_strings.grd

echo "[aerium] external download manager applied"


# --- The bottom bar, and with it the new-tab button at the bottom of the tab
# --- switcher.
#
# The most-asked-for thing on the tracker: the tab switcher's + sits in the top
# left corner, which is the hardest place to reach one-handed on a tall phone.
#
# Chromium already has the answer and keeps it switched off. TabSwitcherPaneBase
# hands out an EMPTY action button when the bottom bar is on for the tab
# switcher - getActionButtonDataSupplier() returns mEmptyActionButtonDataSupplier
# when BottomBarConfigUtils.isBottomBarEnabled() && shouldShowOnGts() - and the
# new-tab button appears in the bottom bar instead. So this is upstream's own
# supported layout rather than a button we bolt on, which matters for a surface
# that Chromium reworks regularly.
#
# Done as a feature on the command line rather than by patching
# BottomBarConfigUtils, deliberately. isBottomBarEnabled() carries a
# LINT.IfChange pointing at ToolbarVariationUtils.isToolbarUiRefactorEnabled(),
# so at least one other place mirrors the same condition; forcing the util to
# return true while the feature itself stayed off would leave those two
# disagreeing about whether there is a bottom bar. Turning the real feature on
# keeps every call site reading the same answer.
#
# The params are the ones from the "1A with NTP, GTS and GLIC filled" variation
# in about_flags.cc, minus both GLIC entries. show_bottom_bar_on_gts is the one
# that moves the + ; disable_on_ntp=false keeps the bar on the new tab page so
# it does not appear and disappear as you navigate. always_use_filled_glic_icon
# and show_glic_setting_toggle are left out: they are Google assistant surface,
# nothing here needs them, and a variation nobody can audit is not one to ship.
#
# Default on, with a switch, because that is the layout people asked for and
# the ones who dislike a bottom bar should not have to find chrome://flags to
# get rid of it.
#
# The switch beats the flag, deliberately. base/feature_list.cc registers
# command-line overrides with try_emplace and documents the consequence -
# "only the first override for a given feature name takes effect" - so
# whichever AndroidBottomBar entry appears first in enable-features is the one
# that counts. This appended its params last until a report made the cost
# obvious: issue 5 answered the most-asked-for feature by telling people to set
# chrome://flags#android-bottom-bar by hand, most of those choices are
# variations without "with NTP", and every one of them would have kept
# disable_on_ntp at its default of true and gone on hiding the bar on the new
# tab page after this shipped - looking exactly like the bug that had just been
# fixed for them.
#
# Overriding a deliberate chrome://flags choice is a real cost and worth naming
# rather than glossing: what makes it the right way round here is that this
# feature has a Settings switch of its own, so the flag is no longer the way to
# ask for it. Anyone who does want a different variation still gets it by
# turning the Aerium switch off, which stops this from appending anything at
# all and hands the feature back to chrome://flags entirely. Note the first restart after toggling may not pick the params
# up: Chromium caches field-trial params in shared preferences and reads them
# at the following start, so a second restart settles it.
sed_i 's|    public static final String AERIUM_BLACKEN_DARK_SITES = "Chrome.Aerium.BlackenDarkSites";|&\n\n    /** Whether Aerium shows the bottom bar, which also moves the tab switcher new-tab button. */\n    public static final String AERIUM_BOTTOM_BAR = "Chrome.Aerium.BottomBar";|' \
    $CPK
sed_i 's|^                AERIUM_EXTERNAL_DOWNLOAD_MANAGER,$|                AERIUM_BOTTOM_BAR,\n&|' \
    $CPK

# Distinct local names: the blacken-dark-sites block below already declares
# commandLine, existing and merged in this same scope.
sed_i 's%            FontPreloader.getInstance().load(getApplication());%&\n\n            // Aerium: features are fixed when the process starts, so the bottom\n            // bar goes on the command line here rather than being flipped live.\n            //\n            // Ours goes FIRST in the merged value, ahead of anything already\n            // there. FeatureList::RegisterOverride() uses try_emplace, and says\n            // so in as many words - "only the first override for a given\n            // feature name takes effect" - so with this appended last, an\n            // AndroidBottomBar entry set from chrome://flags won and the params\n            // below were silently dropped. Everyone told to enable that flag by\n            // hand before this shipped is in exactly that position.\n            if (ChromeSharedPreferences.getInstance()\n                    .readBoolean(ChromePreferenceKeys.AERIUM_BOTTOM_BAR, true)) {\n                CommandLine bottomBarLine = CommandLine.getInstance();\n                String bottomBarExisting = bottomBarLine.getSwitchValue("enable-features");\n                String bottomBarFeature =\n                        "AndroidBottomBar:show_bottom_bar_on_gts/true/disable_on_ntp/false";\n                String bottomBarMerged =\n                        (bottomBarExisting == null || bottomBarExisting.isEmpty())\n                                ? bottomBarFeature\n                                : bottomBarFeature + "," + bottomBarExisting;\n                bottomBarLine.appendSwitchWithValue("enable-features", bottomBarMerged);\n            }%' \
    $CAI

sed_i 's|^</PreferenceScreen>$|    <org.chromium.components.browser_ui.settings.ChromeSwitchPreference\n        android:key="aerium_bottom_bar"\n        android:title="@string/aerium_bottom_bar_title"\n        android:summary="@string/aerium_bottom_bar_summary" />\n&|' \
    chrome/browser/ui/android/night_mode/java/res/xml/theme_preferences.xml

sed_i 's|^        // TODO(crbug.com/40198953): Notify feature engagement system that settings were opened.$|        ChromeSwitchPreference bottomBar =\n                (ChromeSwitchPreference) findPreference("aerium_bottom_bar");\n        if (bottomBar != null) {\n            bottomBar.setChecked(\n                    sharedPreferencesManager.readBoolean(\n                            ChromePreferenceKeys.AERIUM_BOTTOM_BAR, true));\n            bottomBar.setOnPreferenceChangeListener(\n                    (preference, newValue) -> {\n                        sharedPreferencesManager.writeBoolean(\n                                ChromePreferenceKeys.AERIUM_BOTTOM_BAR, (boolean) newValue);\n                        showRestartSnackbar();\n                        return true;\n                    });\n        }\n\n&|' \
    $TSF

sed_i 's|      <message name="IDS_AERIUM_EXTERNAL_DOWNLOAD_MANAGER_TITLE" desc=|      <message name="IDS_AERIUM_BOTTOM_BAR_TITLE" desc="Title of the switch that moves the main browser controls to a bar along the bottom of the screen.">\n        Bottom bar\n      </message>\n      <message name="IDS_AERIUM_BOTTOM_BAR_SUMMARY" desc="Summary under the Bottom bar switch. Mentions the new tab button moving and that a restart is needed.">\n        Put the browser controls along the bottom of the screen, within reach of your thumb. The new tab button in the tab switcher moves down with them. Restart Aerium to apply.\n      </message>\n&|' \
    chrome/browser/ui/android/strings/android_chrome_strings.grd

echo "[aerium] bottom bar applied"


# --- The Chrome Web Store, in its desktop layout.
#
# The store only offers the install button on its desktop pages. On a phone
# user agent it renders the listing and no way to add anything, so extensions
# are unreachable from the phone even though this build can install them -
# which is a strange place to leave a browser whose whole point on Android is
# that extensions work.
#
# Written as a per-site content setting rather than forced at request time, so
# it behaves like any other site exception: it appears under Site settings ->
# Desktop site, and turning it off there sticks.
#
# Both hosts on purpose. chrome.google.com/webstore is the address people have
# and pass around, and it redirects to chromewebstore.google.com; seeding only
# the first would stop applying the moment the redirect fires, which is to say
# immediately.
#
# Seeded once per profile and never again. The marker is what makes a later
# change by the user theirs to keep - without it every start would undo them.
# finishNativeInitialization() rather than createInitialTab(), because the
# latter only runs on a cold start with no tabs to restore, so anyone with a
# session already open would never have been seeded at all.
CTA=chrome/android/java/src/org/chromium/chrome/browser/ChromeTabbedActivity.java
sed_i 's|^import org.chromium.url.GURL;$|import org.chromium.components.browser_ui.site_settings.WebsitePreferenceBridge;\nimport org.chromium.components.content_settings.ContentSetting;\nimport org.chromium.components.content_settings.ContentSettingsType;\n&|' \
    $CTA
sed_i 's%            recordFirstAppLaunchTimestampIfNeeded();%&\n\n            // Aerium: give the Chrome Web Store its desktop layout - see theme.sh.\n            if (!ChromeSharedPreferences.getInstance()\n                    .readBoolean(ChromePreferenceKeys.AERIUM_WEBSTORE_DESKTOP_SEEDED, false)) {\n                Profile aeriumProfile = getProfileProviderSupplier().get().getOriginalProfile();\n                for (String aeriumHost :\n                        new String[] {\n                            "https://chrome.google.com", "https://chromewebstore.google.com"\n                        }) {\n                    GURL aeriumWebstore = new GURL(aeriumHost);\n                    WebsitePreferenceBridge.setContentSettingDefaultScope(\n                            aeriumProfile,\n                            ContentSettingsType.REQUEST_DESKTOP_SITE,\n                            aeriumWebstore,\n                            aeriumWebstore,\n                            ContentSetting.ALLOW);\n                }\n                ChromeSharedPreferences.getInstance()\n                        .writeBoolean(\n                                ChromePreferenceKeys.AERIUM_WEBSTORE_DESKTOP_SEEDED, true);\n            }%' \
    $CTA

sed_i 's|    public static final String AERIUM_BOTTOM_BAR = "Chrome.Aerium.BottomBar";|&\n\n    /** Whether the one-time Chrome Web Store desktop-site exception has been written. */\n    public static final String AERIUM_WEBSTORE_DESKTOP_SEEDED = "Chrome.Aerium.WebstoreDesktopSeeded";|' \
    $CPK
sed_i 's|^                AERIUM_BOTTOM_BAR,$|                AERIUM_WEBSTORE_DESKTOP_SEEDED,\n&|' \
    $CPK

echo "[aerium] chrome web store desktop site applied"

# --- Settings -> Advanced -> Media: DRM, and background playback.
#
# Two switches that had no home. Background playback was unconditional, and DRM
# was decided by whether the CDM happened to be on disk - neither was something
# anyone could see or change.
#
# DRM is off by default, which is the Brave arrangement: a browser that does not
# ship Google's CDM should not behave as though it has one until asked. Turning
# it on is a deliberate act and it is one switch away, which is the part that
# was missing before - the old chrome://flags entry could never work, because on
# Linux the CDM is registered before the sandbox closes and long before any
# pref exists to read. Doing it from Java sidesteps that entirely on Android:
# the switch is on the command line before native starts, so the gate added
# earlier in this script - the one that already wraps AddWidevine - sees it at
# the moment it decides. That gate has been here since the beginning; this
# switch is a second, findable way to set the same thing.
#
# Both need a restart, so both offer one.
sed_i 's|    public static final String AERIUM_WEBSTORE_DESKTOP_SEEDED = "Chrome.Aerium.WebstoreDesktopSeeded";|&\n\n    /** Whether Aerium registers the Widevine CDM, so DRM-protected sites can play. */\n    public static final String AERIUM_DRM = "Chrome.Aerium.Drm";\n\n    /** Whether audio and video keep playing when Aerium is in the background. */\n    public static final String AERIUM_BACKGROUND_PLAYBACK = "Chrome.Aerium.BackgroundPlayback";|' \
    $CPK
sed_i 's|^                AERIUM_WEBSTORE_DESKTOP_SEEDED,$|                AERIUM_BACKGROUND_PLAYBACK,\n                AERIUM_DRM,\n&|' \
    $CPK

# The DRM switch, put on the command line before native comes up. Off by
# default, so a build with no CDM installed behaves as if DRM does not exist -
# which it does not.
sed_i 's%            FontPreloader.getInstance().load(getApplication());%&\n\n            // Aerium: DRM is opt-in - see theme.sh. On the command line here so\n            // that cdm_registration.cc can see it when it registers the CDM,\n            // which on some platforms happens before any pref is readable.\n            if (ChromeSharedPreferences.getInstance()\n                    .readBoolean(ChromePreferenceKeys.AERIUM_DRM, false)) {\n                CommandLine.getInstance().appendSwitch("enable-widevine");\n            }%' \
    $CAI

cat > chrome/android/java/res/xml/aerium_media_preferences.xml <<'AERIUM_MEDIA_XML'
<?xml version="1.0" encoding="utf-8"?>
<!-- Copyright 2026 The Chromium Authors
     Use of this source code is governed by a BSD-style license that can be
     found in the LICENSE file. -->
<PreferenceScreen xmlns:android="http://schemas.android.com/apk/res/android">
    <org.chromium.components.browser_ui.settings.ChromeSwitchPreference
        android:key="aerium_background_playback"
        android:persistent="false"
        android:title="@string/aerium_background_playback_title"
        android:summary="@string/aerium_background_playback_summary" />
    <org.chromium.components.browser_ui.settings.ChromeSwitchPreference
        android:key="aerium_drm"
        android:persistent="false"
        android:title="@string/aerium_drm_title"
        android:summary="@string/aerium_drm_summary" />
</PreferenceScreen>
AERIUM_MEDIA_XML

sed_i 's|^  "java/res/xml/aerium_clear_on_exit_preferences.xml",$|  "java/res/xml/aerium_media_preferences.xml",\n&|' \
    chrome/android/chrome_java_resources.gni

mkdir -p chrome/android/java/src/org/chromium/chrome/browser/settings
cat > chrome/android/java/src/org/chromium/chrome/browser/settings/AeriumMediaFragment.java <<'AERIUM_MEDIA_JAVA'
// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package org.chromium.chrome.browser.settings;

import android.app.Activity;
import android.os.Bundle;

import org.chromium.base.supplier.MonotonicObservableSupplier;
import org.chromium.base.supplier.ObservableSuppliers;
import org.chromium.base.supplier.SettableMonotonicObservableSupplier;
import org.chromium.build.annotations.NullMarked;
import org.chromium.build.annotations.Nullable;
import org.chromium.chrome.R;
import org.chromium.chrome.browser.ApplicationLifetime;
import org.chromium.chrome.browser.preferences.ChromePreferenceKeys;
import org.chromium.chrome.browser.preferences.ChromeSharedPreferences;
import org.chromium.chrome.browser.settings.search.ChromeBaseSearchIndexProvider;
import org.chromium.chrome.browser.ui.messages.snackbar.Snackbar;
import org.chromium.chrome.browser.ui.messages.snackbar.SnackbarManager;
import org.chromium.chrome.browser.ui.messages.snackbar.SnackbarManager.SnackbarManageable;
import org.chromium.components.browser_ui.settings.ChromeSwitchPreference;
import org.chromium.components.browser_ui.settings.SettingsFragment;
import org.chromium.components.browser_ui.settings.SettingsUtils;

/**
 * Aerium: Settings -> Advanced -> Media. See theme.sh.
 *
 * <p>Both switches are read before native starts and turned into command-line switches there, so
 * neither can take effect on the process that is already running - which is why every change here
 * offers a restart. They are android:persistent="false" for the same reason: the values live in
 * ChromeSharedPreferences under keys ChromeApplicationImpl reads at startup, not in the preference
 * framework's own store.
 */
@NullMarked
public class AeriumMediaFragment extends ChromeBaseSettingsFragment {
    // Must match the keys in aerium_media_preferences.xml.
    private static final String PREF_BACKGROUND_PLAYBACK = "aerium_background_playback";
    private static final String PREF_DRM = "aerium_drm";

    private static final int RESTART_SNACKBAR_DURATION_MS = 10000;

    private final SettableMonotonicObservableSupplier<String> mPageTitle =
            ObservableSuppliers.createMonotonic();

    @Override
    public void onCreatePreferences(@Nullable Bundle savedInstanceState, @Nullable String rootKey) {
        SettingsUtils.addPreferencesFromResource(this, R.xml.aerium_media_preferences);
        mPageTitle.set(getString(R.string.aerium_media_title));

        bind(PREF_BACKGROUND_PLAYBACK, ChromePreferenceKeys.AERIUM_BACKGROUND_PLAYBACK, true);
        bind(PREF_DRM, ChromePreferenceKeys.AERIUM_DRM, false);
    }

    private void bind(String prefKey, String sharedPrefKey, boolean defaultValue) {
        ChromeSwitchPreference pref = (ChromeSwitchPreference) findPreference(prefKey);
        if (pref == null) return;
        pref.setChecked(
                ChromeSharedPreferences.getInstance().readBoolean(sharedPrefKey, defaultValue));
        pref.setOnPreferenceChangeListener(
                (preference, newValue) -> {
                    ChromeSharedPreferences.getInstance()
                            .writeBoolean(sharedPrefKey, (boolean) newValue);
                    showRestartSnackbar();
                    return true;
                });
    }

    private void showRestartSnackbar() {
        Activity activity = getActivity();
        if (!(activity instanceof SnackbarManageable)) return;
        SnackbarManager manager = ((SnackbarManageable) activity).getSnackbarManager();
        manager.showSnackbar(
                Snackbar.make(
                                getString(R.string.aerium_restart_to_apply),
                                new SnackbarManager.SnackbarController() {
                                    @Override
                                    public void onAction(@Nullable Object actionData) {
                                        ApplicationLifetime.terminate(true);
                                    }
                                },
                                Snackbar.TYPE_ACTION,
                                Snackbar.UMA_UNKNOWN)
                        .setAction(getString(R.string.aerium_relaunch), null)
                        .setDuration(RESTART_SNACKBAR_DURATION_MS));
    }

    @Override
    public MonotonicObservableSupplier<String> getPageTitle() {
        return mPageTitle;
    }

    @Override
    public @SettingsFragment.AnimationType int getAnimationType() {
        return SettingsFragment.AnimationType.PROPERTY;
    }

    public static final ChromeBaseSearchIndexProvider SEARCH_INDEX_DATA_PROVIDER =
            new ChromeBaseSearchIndexProvider(
                    AeriumMediaFragment.class.getName(), R.xml.aerium_media_preferences);
}
AERIUM_MEDIA_JAVA

sed_i 's|^  "java/src/org/chromium/chrome/browser/browsing_data/AeriumClearOnExitFragment.java",$|  "java/src/org/chromium/chrome/browser/settings/AeriumMediaFragment.java",\n&|' \
    chrome/android/chrome_java_sources.gni

# The row in Settings, ordered between Appearance (23) and Glic (25).
sed_i 's|^        android:title="@string/appearance_settings" />$|&\n    <Preference\n        android:fragment="org.chromium.chrome.browser.settings.AeriumMediaFragment"\n        android:key="aerium_media"\n        android:order="24"\n        android:title="@string/aerium_media_title" />|' \
    chrome/android/java/res/xml/main_preferences.xml

# Named in the search-index registry, which is also what keeps R8 from
# stripping a class only ever referenced from XML.
sed_i 's|^import org.chromium.chrome.browser.browsing_data.AeriumClearOnExitFragment;$|&\nimport org.chromium.chrome.browser.settings.AeriumMediaFragment;|' \
    $SIPR
sed_i 's|^                    AeriumClearOnExitFragment.SEARCH_INDEX_DATA_PROVIDER,$|&\n                    AeriumMediaFragment.SEARCH_INDEX_DATA_PROVIDER,|' \
    $SIPR

sed_i 's|      <message name="IDS_AERIUM_BOTTOM_BAR_TITLE" desc=|      <message name="IDS_AERIUM_MEDIA_TITLE" desc="Title of the Media settings screen, which holds the DRM and background playback switches.">\n        Media\n      </message>\n      <message name="IDS_AERIUM_BACKGROUND_PLAYBACK_TITLE" desc="Title of the switch that keeps audio and video playing when the browser is not in front.">\n        Background playback\n      </message>\n      <message name="IDS_AERIUM_BACKGROUND_PLAYBACK_SUMMARY" desc="Summary under the background playback switch. Mentions that a restart is needed.">\n        Keep audio and video playing when you switch away from Aerium or turn the screen off. Restart Aerium to apply.\n      </message>\n      <message name="IDS_AERIUM_DRM_TITLE" desc="Title of the switch that turns on playback of DRM-protected video.">\n        Play DRM-protected content\n      </message>\n      <message name="IDS_AERIUM_DRM_SUMMARY" desc="Summary under the DRM switch. Explains that it is off by default and that the CDM is Google proprietary software.">\n        Register the Widevine CDM so sites like Netflix can play protected video. Off by default: the CDM is proprietary Google software that Aerium does not ship, and a browser without one should not tell sites it has one. Restart Aerium to apply.\n      </message>\n&|' \
    chrome/browser/ui/android/strings/android_chrome_strings.grd

echo "[aerium] media settings applied"

# --- Do not hold the first draw for a new tab page that an extension provides.
#
# ChromeTabbedActivity waits for onContentChanged before letting the toolbar
# draw, so a cold start does not flash an empty toolbar before the native NTP
# is ready:
#
#   if (isTabNtp && !currentTab.isNativePage() && !isTabWebUiNtp) {
#       currentTab.addObserver(... onContentChanged -> onActiveTabAvailable());
#   } else {
#       mAppLaunchDrawBlocker.onActiveTabAvailable();
#   }
#
# An extension-provided new tab page satisfies all three conditions: it keeps
# chrome://newtab as its virtual URL so isTabNtp is true, it is not a native
# page, and isTabWebUiNtp covers only the WebUI override - gated on
# sUseWebUiNtpAndroid and a Google default search engine. So it waits for a
# native page that will never be created, and only the deadline above ends the
# wait. Reported as the browser sitting on the logo for six or seven seconds on
# every launch with TablissNG as the new tab page, and only then - a normal web
# page as the homepage is not an NTP url, takes the else branch, and starts
# instantly. That asymmetry is what identified it.
#
# Upstream reasons exactly this way already. The comment beside isTabWebUiNtp
# reads "The WebUI NTP is not a native Tab, so we don't wait for it to be
# created, otherwise it hangs the rendering thread." An extension NTP is not a
# native tab either, so the same conclusion applies; the guard simply predates
# extensions being usable here.
#
# UrlOverrideUtils.isNtpOverrideEnabled() is upstream's own answer to "is the
# new tab page overridden", backed by ExtensionsUrlOverrideRegistry and the
# policy registry, so a policy-set new tab page is covered for free. The class
# is already imported by this file.
sed_i 's|^                if (isTabNtp \&\& !currentTab.isNativePage() \&\& !isTabWebUiNtp) {$|                // Aerium: an overridden new tab page never becomes a native page, so\n                // waiting for one holds the launch until the deadline. See theme.sh.\n                if (isTabNtp\n                        \&\& !currentTab.isNativePage()\n                        \&\& !isTabWebUiNtp\n                        \&\& !UrlOverrideUtils.isNtpOverrideEnabled()) {|' \
    chrome/android/java/src/org/chromium/chrome/browser/ChromeTabbedActivity.java

echo "[aerium] ntp override draw guard applied"

# --- The performance_manager policies that ship written but switched off.
#
# The desktop repos do this as aerium-runtime-efficiency.patch; this is the
# Android subset of the same change, and it is a subset for a reason rather
# than an oversight.
#
# A de-googled build never reaches the variations server, so every base::Feature
# runs on whatever default is written into the source. Upstream lands a feature
# DISABLED_BY_DEFAULT and turns it on through Finch afterwards, so a disabled
# default in the tree says nothing about whether the code is finished - it is
# just the state it was committed in, and the state we are stuck with. Each of
# these has a consumer already wired up in
# chrome_browser_main_extra_parts_performance_manager.cc.
#
# kUnimportantFramesPriority and kThrottleUnimportantFrameRate are one change
# and enabling either alone does nothing. ImportantFrameDecorator's
# IsImportant() begins "always important if the feature is disabled", so with
# the first off every frame is important, and FrameThrottlingPolicy - whose
# whole body is "if (!frame_node->IsImportant())" - throttles nothing. Together
# they demote a cross-process subframe that does not intersect the viewport, or
# covers only a small part of it and has never been touched, and halve its
# begin-frame rate. That is an ad iframe described structurally, which is what
# makes it work in a browser that ships no filter list. Both consumers sit
# outside the !BUILDFLAG(IS_ANDROID) guards, so both apply here.
#
# kEnableBestEffortTaskInhibitingPolicy fences BEST_EFFORT thread-pool work
# while a visible page is loading or the user is typing, with a floor of 30
# seconds of BEST_EFFORT time per 5 minutes so nothing starves. On a phone that
# is battery as much as speed.
#
# kLevelDBSiteDataStoreBestEffort is one line in leveldb_site_data_store.cc:
# BEST_EFFORT rather than USER_BLOCKING for the site-data store's task runner.
#
# Not here, and not an omission: kInfiniteTabsFreezing and
# kInfiniteTabsFreezingOnMemoryPressure, which the desktop patch does enable.
# FreezingPolicy is constructed inside a !BUILDFLAG(IS_ANDROID) block, with an
# upstream comment saying it "isn't enabled on Android yet as it doesn't play
# well with the freezing logic already in place in renderers" - so the feature
# has no consumer here, and the memory-pressure variant is read only inside
# #if BUILDFLAG(IS_WIN). Enabling a feature nothing reads is noise that later
# reads as coverage.
#
# The two multi-line declarations are addressed by range rather than by their
# second line: "             base::FEATURE_DISABLED_BY_DEFAULT);" appears a
# dozen times in this file, so matching it alone would flip every one of them.
sed_i '/^BASE_FEATURE(kLevelDBSiteDataStoreBestEffort,$/,+1 s|^             base::FEATURE_DISABLED_BY_DEFAULT);$|             base::FEATURE_ENABLED_BY_DEFAULT);|' \
    components/performance_manager/features.cc
sed_i '/^BASE_FEATURE(kEnableBestEffortTaskInhibitingPolicy,$/,+1 s|^             base::FEATURE_DISABLED_BY_DEFAULT);$|             base::FEATURE_ENABLED_BY_DEFAULT);|' \
    components/performance_manager/features.cc
sed_i 's|^BASE_FEATURE(kUnimportantFramesPriority, base::FEATURE_DISABLED_BY_DEFAULT);$|BASE_FEATURE(kUnimportantFramesPriority, base::FEATURE_ENABLED_BY_DEFAULT);|' \
    components/performance_manager/features.cc
sed_i 's|^BASE_FEATURE(kThrottleUnimportantFrameRate, base::FEATURE_DISABLED_BY_DEFAULT);$|BASE_FEATURE(kThrottleUnimportantFrameRate, base::FEATURE_ENABLED_BY_DEFAULT);|' \
    components/performance_manager/features.cc

echo "[aerium] performance_manager defaults applied"

# --- Report a time zone other than the system's.
#
# The desktop repos do this as aerium-timezone.patch; this is the same change,
# and the two are meant to produce byte-identical files.
#
# The system time zone is one of the strongest signals a page can read without
# asking. It is stable, it survives clearing everything, it is the same in
# incognito, and in most of the world it narrows a visitor to a handful of
# countries before anything else has been measured.
# Date.getTimezoneOffset() and Intl.DateTimeFormat().resolvedOptions().timeZone
# both read it, and CreepJS builds part of its identifier from exactly that
# pair. Bromite and Cromite both answer by lying; this is Aerium's version of
# that answer.
#
# Off by default and offered in chrome://flags rather than Settings, because
# unlike the canvas and client-rects noise above, the cost is visible: a
# calendar, a booking site or a flight tracker will show times wrong by the
# difference. Worth offering, not worth imposing.
#
# One zone per renderer process, chosen when the process starts - not per
# navigation, which is what Cromite does. Vanadium's
# 0123-enable-strict-site-isolation-by-default-on-Android.patch means a
# renderer here is a site, so choosing once per process gives a site one
# consistent answer across its frames and reloads while two sites get different
# answers. A per-navigation reroll would give one site a time zone that moves
# while you use it, which no real user has and which is itself a signal.
#
# The pool is 21 named IANA zones, one per whole-hour offset people actually
# live on. ICU will answer "a zone at this offset" itself, via
# createEnumerationForRawOffset(), and it is not used: for several offsets it
# answers "Etc/GMT+5" and similar, and a browser reporting an Etc zone has
# announced that it is lying.
#
# The mechanism is Chromium's own. TimeZoneController::SetTimeZoneOverride() is
# what DevTools emulation uses, it is public, it swaps ICU's default zone and
# notifies V8 and every worker - so Date and Intl cannot disagree and a page
# cannot catch the browser out that way - and it returns an RAII handle.
# Holding that handle for the life of the renderer is the whole implementation.
# Nothing else in timezone_controller.cc changes: no locks are removed and no
# members move, which is the part of Cromite's patch this deliberately does not
# copy.
#
# It goes after the TimeZoneMonitor client is bound, not before, so a real
# system time zone change still reaches OnTimeZoneChange and updates
# host_timezone_id_ underneath the override - which is what makes turning the
# flag off later restore the zone the phone is actually in.
#
# The inserted C++ lives in files rather than inline in the perl for the reason
# the DoH block gives: the text is full of braces, quotes and apostrophes, and
# a perl program inside a shell single-quoted string is where an escaping
# mistake hides. This way the perl program contains no quoting of its own.
AERIUM_TZ_HELPERS=$(mktemp)
AERIUM_TZ_INIT=$(mktemp)
export AERIUM_TZ_HELPERS AERIUM_TZ_INIT
cat > "$AERIUM_TZ_HELPERS" <<'AERIUM_TZ_HELPERS_EOF'
// Aerium: the pool the randomised time zone is drawn from. One populous,
// unambiguous IANA zone per whole-hour offset, rather than whatever ICU's
// createEnumerationForRawOffset() happens to sort first - that answers with
// "Etc/GMT+5" and friends for several offsets, and a browser reporting an Etc
// zone has announced that it is lying. Offsets nobody lives on are left out
// for the same reason.
constexpr auto kAeriumTimeZoneChoices = std::to_array<const char*>({
    "Pacific/Honolulu",     // UTC-10
    "America/Anchorage",    // UTC-9
    "America/Los_Angeles",  // UTC-8
    "America/Denver",       // UTC-7
    "America/Chicago",      // UTC-6
    "America/New_York",     // UTC-5
    "America/Halifax",      // UTC-4
    "America/Sao_Paulo",    // UTC-3
    "Atlantic/Azores",      // UTC-1
    "Europe/London",        // UTC+0
    "Europe/Berlin",        // UTC+1
    "Europe/Athens",        // UTC+2
    "Europe/Istanbul",      // UTC+3
    "Asia/Dubai",           // UTC+4
    "Asia/Karachi",         // UTC+5
    "Asia/Dhaka",           // UTC+6
    "Asia/Bangkok",         // UTC+7
    "Asia/Shanghai",        // UTC+8
    "Asia/Tokyo",           // UTC+9
    "Australia/Sydney",     // UTC+10
    "Pacific/Auckland",     // UTC+12
});

// Aerium: which zone this renderer should claim, or a null String for none.
String AeriumTimeZoneOverrideId() {
  const std::string zone = features::kAeriumTimeZoneIdParam.Get();
  if (zone.empty()) {
    return String();
  }
  if (zone != "random") {
    return String(zone);
  }
  return String(base::RandomChoice(kAeriumTimeZoneChoices));
}

AERIUM_TZ_HELPERS_EOF
cat > "$AERIUM_TZ_INIT" <<'AERIUM_TZ_INIT_EOF'

  // Aerium: claim a time zone that is not the system's, for the life of this
  // renderer process. Here rather than per navigation because the answer has
  // to be one answer: with site isolation a renderer is a site, so a zone
  // chosen once per process is a zone that is stable for a site and differs
  // between sites, which is the shape a real user has and a per-navigation
  // reroll does not.
  //
  // The client is bound above first so a genuine system time zone change still
  // reaches OnTimeZoneChange and updates host_timezone_id_ underneath the
  // override, which is what makes turning the feature off mid-session restore
  // the right zone rather than a stale one.
  if (base::FeatureList::IsEnabled(features::kAeriumTimeZone)) {
    const String aerium_zone = AeriumTimeZoneOverrideId();
    if (!aerium_zone.empty()) {
      TimeZoneOverrideResult aerium_result = SetTimeZoneOverride(aerium_zone);
      if (aerium_result.status == TimeZoneOverrideStatus::kSuccess) {
        // The handle is an RAII object whose destructor clears the override,
        // so the override lasts exactly as long as something holds it. Parked
        // in a NoDestructor because "as long as the renderer" is the intended
        // lifetime and a static with a destructor is not allowed here.
        [[maybe_unused]] static base::NoDestructor<
            std::unique_ptr<TimeZoneOverride>>
            aerium_override(std::move(aerium_result.handle));
      } else {
        // Not fatal: a bad zone id from the feature param should cost the user
        // the override, not the renderer.
        LOG(WARNING) << "Aerium: cannot use time zone override '"
                     << aerium_zone.Utf8() << "'";
      }
    }
  }
AERIUM_TZ_INIT_EOF
perl -0777 -pi -e '
    BEGIN {
        local $/;
        open my $fh, "<", $ENV{AERIUM_TZ_HELPERS}
            or die "[aerium] FATAL: cannot read the time zone helpers file\n";
        $helpers = <$fh>;
        close $fh;
        open $fh, "<", $ENV{AERIUM_TZ_INIT}
            or die "[aerium] FATAL: cannot read the time zone init file\n";
        $init = <$fh>;
        close $fh;
    }
    die "[aerium] FATAL: timezone_controller.cc already mentions kAeriumTimeZone "
      . "- this block has run before; a second pass would duplicate it\n"
        if m!kAeriumTimeZone!;
    s!\#include "base/command_line\.h"\n\#include "base/feature_list\.h"\n!\#include <array>\n\n\#include "base/command_line.h"\n\#include "base/feature_list.h"\n\#include "base/no_destructor.h"\n\#include "base/rand_util.h"\n!
        or die "[aerium] FATAL: timezone_controller.cc no longer opens with the "
             . "command_line and feature_list includes - re-read it\n";
    s!\n\}  // namespace\n\nTimeZoneController::TimeZoneController!"\n" . $helpers . "}  // namespace\n\nTimeZoneController::TimeZoneController"!e
        or die "[aerium] FATAL: no anonymous namespace ending before the "
             . "TimeZoneController constructor in timezone_controller.cc\n";
    s!( {2}monitor->AddClient\(instance\(\)\.receiver_\.BindNewPipeAndPassRemote\(\)\);\n)\}!$1 . $init . "}"!e
        or die "[aerium] FATAL: TimeZoneController::Init no longer ends by "
             . "binding the TimeZoneMonitor client - re-read it\n";
' third_party/blink/renderer/core/timezone/timezone_controller.cc
rm -f "$AERIUM_TZ_HELPERS" "$AERIUM_TZ_INIT"
unset AERIUM_TZ_HELPERS AERIUM_TZ_INIT

# The feature and its parameter, beside the WebGL spoofing pair added above so
# the two Aerium blocks stay together and the file matches the desktop one.
sed_i '/^const base::FeatureParam<std::string> kSpoofWebGLVendorParam{\&kSpoofWebGLInfo, kSpoofWebGLVendor, " "};$/a\
BASE_FEATURE(kAeriumTimeZone, "AeriumTimeZone", base::FEATURE_DISABLED_BY_DEFAULT);\
const char kAeriumTimeZoneId[] = "zone";\
const base::FeatureParam<std::string> kAeriumTimeZoneIdParam{\&kAeriumTimeZone, kAeriumTimeZoneId, "random"};' \
    third_party/blink/common/features.cc
sed_i '/^BLINK_COMMON_EXPORT extern const base::FeatureParam<std::string> kSpoofWebGLVendorParam;$/a\
BLINK_COMMON_EXPORT BASE_DECLARE_FEATURE(kAeriumTimeZone);\
BLINK_COMMON_EXPORT extern const char kAeriumTimeZoneId[];\
BLINK_COMMON_EXPORT extern const base::FeatureParam<std::string> kAeriumTimeZoneIdParam;' \
    third_party/blink/public/common/features.h

# chrome://flags. Two new headers rather than editing the middle of
# about_flags.cc, so a version bump has one line of ours to reconcile in that
# file instead of an entry wedged between upstream's. This is the same shape
# ungoogled-chromium uses on desktop, and the files are byte-identical to the
# ones the desktop patch adds.
cat > chrome/browser/aerium_flag_choices.h <<'AERIUM_FLAG_CHOICES_EOF'
// Aerium's own chrome://flags variations, kept separate from
// ungoogled_flag_choices.h and bromite_flag_choices.h so that neither project's
// file has to be rebased around ours.

#ifndef CHROME_BROWSER_AERIUM_FLAG_CHOICES_H_
#define CHROME_BROWSER_AERIUM_FLAG_CHOICES_H_
const FeatureEntry::FeatureParam kAeriumTimeZone_Random[] = {
    {blink::features::kAeriumTimeZoneId, "random"},
};
const FeatureEntry::FeatureParam kAeriumTimeZone_Utc[] = {
    {blink::features::kAeriumTimeZoneId, "UTC"},
};
const FeatureEntry::FeatureParam kAeriumTimeZone_London[] = {
    {blink::features::kAeriumTimeZoneId, "Europe/London"},
};
const FeatureEntry::FeatureParam kAeriumTimeZone_NewYork[] = {
    {blink::features::kAeriumTimeZoneId, "America/New_York"},
};
const FeatureEntry::FeatureVariation kAeriumTimeZoneChoices[] = {
    {"a different zone for each site", kAeriumTimeZone_Random, nullptr},
    {"UTC everywhere", kAeriumTimeZone_Utc, nullptr},
    {"Europe/London everywhere", kAeriumTimeZone_London, nullptr},
    {"America/New_York everywhere", kAeriumTimeZone_NewYork, nullptr},
};
#endif  // CHROME_BROWSER_AERIUM_FLAG_CHOICES_H_
AERIUM_FLAG_CHOICES_EOF
cat > chrome/browser/aerium_flag_entries.h <<'AERIUM_FLAG_ENTRIES_EOF'
// Aerium's own chrome://flags entries, kept separate from
// ungoogled_flag_entries.h and bromite_flag_entries.h so that neither project's
// file has to be rebased around ours.

#ifndef CHROME_BROWSER_AERIUM_FLAG_ENTRIES_H_
#define CHROME_BROWSER_AERIUM_FLAG_ENTRIES_H_
    {"aerium-time-zone",
     "Report a different time zone",
     "Tell sites a time zone other than the one this computer is set to. With "
     "the default variation each site is told a different zone, chosen when "
     "the process for that site starts, so a site sees one consistent answer "
     "and two sites do not see the same one. The clock itself is unaffected: "
     "this changes what pages are told, not what the computer believes. "
     "Expect times shown by calendars, booking sites and anything that "
     "schedules to be wrong by the difference. Aerium flag.",
     kOsAll, FEATURE_WITH_PARAMS_VALUE_TYPE(blink::features::kAeriumTimeZone,
                                            kAeriumTimeZoneChoices,
                                            "AeriumTimeZone")},
    {"aerium-audio-noise",
     "Audio fingerprint deception",
     "Scale audio a page reads back - the four AnalyserNode getters and the "
     "result of an offline render - by a fixed factor of about a hundredth of "
     "a percent, drawn once per site. The usual audio fingerprint renders an "
     "oscillator through a compressor offline and hashes the result; this "
     "changes that hash without changing anything you can hear, and none of "
     "these paths feeds playback. On by default. Aerium flag.",
     kOsAll, FEATURE_VALUE_TYPE(blink::features::kAeriumAudioNoise)},
    {"aerium-local-font-access",
     "Local Font Access API",
     "Let sites call window.queryLocalFonts() to read the list of fonts "
     "installed on this computer, after asking permission. Off in Aerium: the "
     "list is the strongest font fingerprint there is, and one prompt hands "
     "over all of it. Firefox and Safari do not offer this API at all, and "
     "Chrome does not offer it on Android. Turn it on if you use a design tool "
     "in the browser that needs your fonts. Aerium flag.",
     kOsAll, FEATURE_VALUE_TYPE(blink::features::kFontAccess)},
#endif  // CHROME_BROWSER_AERIUM_FLAG_ENTRIES_H_
AERIUM_FLAG_ENTRIES_EOF
sed_i '/^const FeatureEntry kFeatureEntries\[\] = {$/i\
#include "chrome/browser/aerium_flag_choices.h"' \
    chrome/browser/about_flags.cc
sed_i '/^const FeatureEntry kFeatureEntries\[\] = {$/a\
#include "chrome/browser/aerium_flag_entries.h"' \
    chrome/browser/about_flags.cc

echo "[aerium] time zone override applied"

# --- navigator.hardwareConcurrency answers 2.
#
# The last piece of parity with the reduced-system-info flag that the desktop
# repos now seed on by default. That flag does three things: clamps
# hardwareConcurrency, makes the user agent report a unified platform, and
# populates only low-entropy client hints. Two of the three are already true
# here - Vanadium's
# 0159-Derive-high-entropy-client-hints-with-reduced-user-a.patch ships
# kClientHintsFromReducedUA enabled, which covers the client hints and the
# values derived from the reduced user agent - so only the first was missing.
#
# The core count is a strong signal because it is small, stable and free to
# collect: it survives clearing everything, it is the same in incognito, and
# CreepJS reads it directly. Two is the number ungoogled-chromium reports, so
# Aerium users on both platforms land in the same bucket as every
# ungoogled-chromium user rather than in one shaped like their own hardware.
#
# Unconditional rather than behind a feature, matching the canvas, measureText,
# client-rects and WebGL mitigations above: Vanadium has no flags-seeding
# mechanism, so a feature here would be a switch with no way to reach it.
#
# The assignment is replaced rather than an early return added in front of it,
# so there is no unreachable code for -Wunreachable-code-aggressive to reject,
# and so the probe::ApplyHardwareConcurrencyOverride call below still runs and
# DevTools emulation still works. It also means a rerun finds nothing to match
# and fails, which an inserted return would not.
#
# What it costs: a site that sizes a worker pool from this will use two workers.
perl -0777 -pi -e '
    s!  unsigned int hardware_concurrency =\n      NavigatorConcurrentHardware::hardwareConcurrency\(\);\n!  // Aerium: a fixed answer, so the core count cannot be part of a\n  // fingerprint. The desktop builds reach the same value through the\n  // reduced-system-info flag in ungoogled-chromium; see theme.sh.\n  unsigned int hardware_concurrency = 2;\n!
        or die "[aerium] FATAL: NavigatorBase::hardwareConcurrency no longer "
             . "reads the core count from NavigatorConcurrentHardware - "
             . "upstream restructured it, or this block already ran\n";
' third_party/blink/renderer/core/execution_context/navigator_base.cc

echo "[aerium] hardwareConcurrency clamp applied"

# --- Audio fingerprinting, and the connection type.
#
# The desktop repos do this as aerium-audio-noise.patch; this is the same
# change, and the two are meant to produce byte-identical files.
#
# The audio fingerprint is one of the handful of signals every fingerprinting
# library collects, CreepJS included, and the recipe is always the same: build
# an OfflineAudioContext, run an oscillator through a DynamicsCompressor,
# render, then sum or hash the samples. The result depends on the platform
# float rounding and the compressor implementation, so it is stable per device
# and per build, it survives clearing everything, and it is identical in
# incognito. The four AnalyserNode getters are the same signal read another
# way.
#
# One multiplier, drawn once per renderer process, applied to every path a page
# can read audio back through. Three properties follow from "fixed", and each
# is why it is fixed rather than drawn per sample the way Cromite does it:
#
#   * It survives averaging. Independent per-sample noise does not - render the
#     same graph a hundred times, take the mean, and the true value returns.
#   * It costs one random draw for the life of the process. The callers are
#     per-sample loops a visualiser runs every frame, and two RNG calls per
#     sample there is a real cost on a phone.
#   * It is per process, so with Vanadium's strict site isolation it is per
#     site: one site reads one consistent answer however often it asks, two
#     sites read different answers, and the answer is new the next time the
#     process is. Same reasoning as the time zone block above.
#
# Nothing here touches playback. The analyser getters produce visualisation
# data and the offline path is a rendered result whose gain moves by a part in
# ten thousand; decoded audio on its way to the speaker is in none of them.
#
# baseLatency is quantised to 1ms, the same way outputLatency() right below it
# already is. Upstream mitigated one of that pair and not the other, and
# base_latency_ is the audio hardware buffer size over its sample rate, so it
# names the device just as squarely. It reuses Chromium's own
# kOutputLatencyMaxPrecisionFactor rather than inventing a constant.
#
# NetInfoConstantType is turned on, and that is the whole of the
# navigator.connection change. It matters more here than on desktop:
# NetInfoDownlinkMax is stable on Android and experimental elsewhere, so this
# is where navigator.connection.type and downlinkMax are exposed at all, and
# whether the phone is on wifi or cellular - and which generation of cellular -
# is a signal about the device and where it is. The rest of that interface is
# deliberately left alone: RoundRtt and RoundMbps already bucket rtt and
# downlink and multiply by a per-host random factor first, so two sites already
# read different values, and pinning effectiveType would tell a phone on a bad
# connection to fetch the high quality asset.
#
# All the inserted C++ lives in one file, split on a marker, for the reason the
# DoH block gives: the text is full of braces, quotes and apostrophes, and a
# perl program inside a shell single-quoted string is where an escaping mistake
# hides. The perl programs below contain no quoting of their own.
AERIUM_AUDIO_PARTS=$(mktemp)
export AERIUM_AUDIO_PARTS
cat > "$AERIUM_AUDIO_PARTS" <<'AERIUM_AUDIO_PARTS_EOF'

  // Aerium: scale a sample a page is about to read back, so audio
  // fingerprinting cannot recover a stable value. See base_audio_context.cc
  // for why the factor is drawn once per renderer process. Returns the value
  // unchanged when the mitigation is off, so callers need no check of their
  // own.
  static float AeriumAudioNoise(float value);
===AERIUM-SPLIT===

// static
float BaseAudioContext::AeriumAudioNoise(float value) {
  // One multiplier, drawn on first use and then fixed. Three properties fall
  // out of that choice, and each of them is the reason for it.
  //
  // It survives averaging. Noise drawn per sample does not: a fingerprinter
  // that renders the same graph repeatedly and takes the mean recovers the
  // true value, because independent noise cancels and a constant factor does
  // not.
  //
  // It costs one random draw for the life of the process. These callers are
  // per-sample loops that a visualiser runs every frame, and two RNG calls per
  // sample there - which is what the Cromite version does - is a real cost in
  // a browser that claims efficiency as the point.
  //
  // It is per process, so with site isolation it is per site: one site reads
  // one consistent answer however often it asks, two sites read different
  // answers, and the answer is new the next time the process is. Per document
  // would vary more, but RealtimeAnalyser has no document to hand, and an
  // analyser that disagreed with an offline render on the same page would be a
  // signal of its own.
  //
  // A part in ten thousand, either way. Inaudible, and none of these paths
  // feeds playback: the analyser getters produce visualisation data, and the
  // offline path is a rendered result whose gain moves by 0.01%.
  static const float kFactor =
      base::FeatureList::IsEnabled(features::kAeriumAudioNoise)
          ? 1.0f + static_cast<float>((base::RandDouble() - 0.5) * 0.0002)
          : 1.0f;
  return value * kFactor;
}
===AERIUM-SPLIT===

  // Aerium: scale every sample in this buffer by the process-wide audio noise
  // factor. Called on the result of an offline render, which is the buffer an
  // audio fingerprint is normally computed from.
  void AeriumAddAudioNoise();
===AERIUM-SPLIT===
void AudioBuffer::AeriumAddAudioNoise() {
  for (unsigned channel = 0; channel < channels_.size(); ++channel) {
    NotShared<DOMFloat32Array> array = getChannelData(channel);
    if (!array) {
      continue;
    }
    base::span<float> samples = array->AsSpan();
    for (float& sample : samples) {
      sample = BaseAudioContext::AeriumAudioNoise(sample);
    }
  }
}

===AERIUM-SPLIT===

    // Aerium: the render result is what an audio fingerprint is computed from
    // - the usual recipe is an oscillator through a DynamicsCompressor,
    // rendered offline, then summed or hashed. Scaling here changes that sum
    // and leaves playback of the same buffer inaudibly different.
    rendered_buffer->AeriumAddAudioNoise();
===AERIUM-SPLIT===
  // Aerium: quantised the same way outputLatency() below already is. Upstream
  // mitigated one of this pair and not the other, and there is no reason in
  // the code for the asymmetry: base_latency_ is the audio hardware's buffer
  // size over its sample rate, so it names the device as squarely as the
  // measured latency does. 1ms rather than the 8ms outputLatency uses without
  // microphone permission, because base latency is single-digit milliseconds
  // and 8ms would round most of it to zero - collapsing the distinct values a
  // page can also legitimately schedule against.
  return std::round(base_latency_ / kOutputLatencyMaxPrecisionFactor) *
         kOutputLatencyMaxPrecisionFactor;
===AERIUM-SPLIT===
      // Aerium: turned on. Chromium wrote this mitigation, wired it into
      // NetworkInformation::type() and downlinkMax(), and then left it off,
      // so navigator.connection reports the real connection type wherever the
      // properties are exposed at all - which is Android and ChromeOS, per
      // NetInfoDownlinkMax below. Whether a phone is on wifi or cellular, and
      // which generation of cellular, is a signal about the device and where
      // it is that a page gets for free and that nothing else in this browser
      // covers.
      name: "NetInfoConstantType",
      status: "stable",
===AERIUM-SPLIT===
BASE_FEATURE(kAeriumAudioNoise, "AeriumAudioNoise", base::FEATURE_ENABLED_BY_DEFAULT);
===AERIUM-SPLIT===
BLINK_COMMON_EXPORT BASE_DECLARE_FEATURE(kAeriumAudioNoise);
AERIUM_AUDIO_PARTS_EOF

# BaseAudioContext: the declaration and the helper itself.
perl -0777 -pi -e '
    BEGIN { $p = do { local $/; open my $f, "<", $ENV{AERIUM_AUDIO_PARTS} or die
            "[aerium] FATAL: cannot read the audio parts file\n"; <$f> };
            @P = split /^===AERIUM-SPLIT===\n/m, $p; }
    die "[aerium] FATAL: base_audio_context.h already carries the Aerium audio "
      . "change; a second pass would duplicate it\n"
        if m!\QAeriumAudioNoise\E!;
    s!  bool CheckExecutionContextAndThrowIfNecessary\(ExceptionState&\);\n!  bool CheckExecutionContextAndThrowIfNecessary(ExceptionState&);\n$P[0]!
        or die "[aerium] FATAL: no CheckExecutionContextAndThrowIfNecessary "
             . "declaration in base_audio_context.h\n";
' third_party/blink/renderer/modules/webaudio/base_audio_context.h
perl -0777 -pi -e '
    BEGIN { $p = do { local $/; open my $f, "<", $ENV{AERIUM_AUDIO_PARTS} or die
            "[aerium] FATAL: cannot read the audio parts file\n"; <$f> };
            @P = split /^===AERIUM-SPLIT===\n/m, $p; }
    die "[aerium] FATAL: base_audio_context.cc already carries the Aerium audio "
      . "change; a second pass would duplicate it\n"
        if m!\QAeriumAudioNoise\E!;
    s!\#include "base/metrics/histogram_functions\.h"\n!\#include "base/feature_list.h"\n\#include "base/metrics/histogram_functions.h"\n\#include "base/rand_util.h"\n!
        or die "[aerium] FATAL: base_audio_context.cc no longer includes "
             . "base/metrics/histogram_functions.h\n";
    s!\#include "third_party/blink/public/mojom/devtools/console_message\.mojom-blink\.h"\n!\#include "third_party/blink/public/common/features.h"\n\#include "third_party/blink/public/mojom/devtools/console_message.mojom-blink.h"\n!
        or die "[aerium] FATAL: base_audio_context.cc no longer includes the "
             . "console_message mojom header\n";
    s!(LocalDOMWindow\* BaseAudioContext::GetWindow\(\) const \{\n  return To<LocalDOMWindow>\(GetExecutionContext\(\)\);\n\}\n)!$1 . $P[1]!e
        or die "[aerium] FATAL: BaseAudioContext::GetWindow no longer has the "
             . "body this inserts after\n";
' third_party/blink/renderer/modules/webaudio/base_audio_context.cc

# AudioBuffer: the per-buffer pass.
perl -0777 -pi -e '
    BEGIN { $p = do { local $/; open my $f, "<", $ENV{AERIUM_AUDIO_PARTS} or die
            "[aerium] FATAL: cannot read the audio parts file\n"; <$f> };
            @P = split /^===AERIUM-SPLIT===\n/m, $p; }
    die "[aerium] FATAL: audio_buffer.h already carries the Aerium audio "
      . "change; a second pass would duplicate it\n"
        if m!\QAeriumAddAudioNoise\E!;
    s!  std::unique_ptr<SharedAudioBuffer> CreateSharedAudioBuffer\(\);\n!  std::unique_ptr<SharedAudioBuffer> CreateSharedAudioBuffer();\n$P[2]!
        or die "[aerium] FATAL: no CreateSharedAudioBuffer declaration in "
             . "audio_buffer.h\n";
' third_party/blink/renderer/modules/webaudio/audio_buffer.h
perl -0777 -pi -e '
    BEGIN { $p = do { local $/; open my $f, "<", $ENV{AERIUM_AUDIO_PARTS} or die
            "[aerium] FATAL: cannot read the audio parts file\n"; <$f> };
            @P = split /^===AERIUM-SPLIT===\n/m, $p; }
    die "[aerium] FATAL: audio_buffer.cc already carries the Aerium audio "
      . "change; a second pass would duplicate it\n"
        if m!\QAeriumAddAudioNoise\E!;
    s!(NotShared<DOMFloat32Array> AudioBuffer::getChannelData\(\n    unsigned channel_index,\n    ExceptionState& exception_state\) \{)!$P[3] . $1!e
        or die "[aerium] FATAL: no two-argument AudioBuffer::getChannelData "
             . "definition to insert before\n";
' third_party/blink/renderer/modules/webaudio/audio_buffer.cc

# OfflineAudioContext: the render result.
perl -0777 -pi -e '
    BEGIN { $p = do { local $/; open my $f, "<", $ENV{AERIUM_AUDIO_PARTS} or die
            "[aerium] FATAL: cannot read the audio parts file\n"; <$f> };
            @P = split /^===AERIUM-SPLIT===\n/m, $p; }
    die "[aerium] FATAL: offline_audio_context.cc already carries the Aerium audio "
      . "change; a second pass would duplicate it\n"
        if m!\QAeriumAddAudioNoise\E!;
    s!\#include "third_party/blink/renderer/modules/webaudio/audio_listener\.h"\n!\#include "third_party/blink/renderer/modules/webaudio/audio_buffer.h"\n\#include "third_party/blink/renderer/modules/webaudio/audio_listener.h"\n!
        or die "[aerium] FATAL: offline_audio_context.cc no longer includes "
             . "audio_listener.h\n";
    s!(    DCHECK\(rendered_buffer\);\n    if \(\!rendered_buffer\) \{\n      return;\n    \}\n)!$1 . $P[4]!e
        or die "[aerium] FATAL: FireCompletionEvent no longer null-checks "
             . "rendered_buffer the way this inserts after\n";
' third_party/blink/renderer/modules/webaudio/offline_audio_context.cc

# RealtimeAnalyser: the four read-back paths.
perl -0777 -pi -e '
    die "[aerium] FATAL: realtime_analyser.cc already carries the Aerium audio "
      . "change; a second pass would duplicate it\n"
        if m!\QAeriumAudioNoise\E!;
    s!\#include "third_party/blink/renderer/platform/audio/audio_bus\.h"\n!\#include "third_party/blink/renderer/modules/webaudio/base_audio_context.h"\n\#include "third_party/blink/renderer/platform/audio/audio_bus.h"\n!
        or die "[aerium] FATAL: realtime_analyser.cc no longer includes "
             . "platform/audio/audio_bus.h\n";
    s!      destination\[i\] = static_cast<float>\(db_mag\);\n!      destination[i] =\n          BaseAudioContext::AeriumAudioNoise(static_cast<float>(db_mag));\n!
        or die "[aerium] FATAL: GetFloatFrequencyData no longer writes a plain "
             . "static_cast<float>(db_mag)\n";
    s!      const double scaled_value =\n          UCHAR_MAX \* \(db_mag - min_decibels\) \* range_scale_factor;\n!      const double scaled_value =\n          BaseAudioContext::AeriumAudioNoise(static_cast<float>(\n              UCHAR_MAX * (db_mag - min_decibels) * range_scale_factor));\n!
        or die "[aerium] FATAL: GetByteFrequencyData no longer scales db_mag "
             . "the way this expects\n";
    s!      float value =\n          input_buffer_\[\(i \+ write_index - fft_size \+ kInputBufferSize\) %\n                        kInputBufferSize\];\n!      const float value = BaseAudioContext::AeriumAudioNoise(\n          input_buffer_[(i + write_index - fft_size + kInputBufferSize) %\n                        kInputBufferSize]);\n!
        or die "[aerium] FATAL: GetFloatTimeDomainData no longer reads the "
             . "input buffer the way this expects\n";
    s!      const float value =\n          input_buffer_\[\(i \+ write_index - fft_size \+ kInputBufferSize\) %\n                        kInputBufferSize\];\n!      const float value = BaseAudioContext::AeriumAudioNoise(\n          input_buffer_[(i + write_index - fft_size + kInputBufferSize) %\n                        kInputBufferSize]);\n!
        or die "[aerium] FATAL: GetByteTimeDomainData no longer reads the "
             . "input buffer the way this expects\n";
' third_party/blink/renderer/modules/webaudio/realtime_analyser.cc

# AudioContext::baseLatency.
perl -0777 -pi -e '
    BEGIN { $p = do { local $/; open my $f, "<", $ENV{AERIUM_AUDIO_PARTS} or die
            "[aerium] FATAL: cannot read the audio parts file\n"; <$f> };
            @P = split /^===AERIUM-SPLIT===\n/m, $p; }
    die "[aerium] FATAL: audio_context.cc already carries the Aerium audio "
      . "change; a second pass would duplicate it\n"
        if m!\Qbase_latency_ / kOutputLatencyMaxPrecisionFactor\E!;
    s!  return base_latency_;\n!$P[5]!
        or die "[aerium] FATAL: AudioContext::baseLatency no longer returns "
             . "base_latency_ directly\n";
' third_party/blink/renderer/modules/webaudio/audio_context.cc

# navigator.connection.type and downlinkMax.
perl -0777 -pi -e '
    BEGIN { $p = do { local $/; open my $f, "<", $ENV{AERIUM_AUDIO_PARTS} or die
            "[aerium] FATAL: cannot read the audio parts file\n"; <$f> };
            @P = split /^===AERIUM-SPLIT===\n/m, $p; }
    die "[aerium] FATAL: runtime_enabled_features.json5 already carries the Aerium audio "
      . "change; a second pass would duplicate it\n"
        if m!\QAerium: turned on\E!;
    s!      name: "NetInfoConstantType",\n!$P[6]!
        or die "[aerium] FATAL: no NetInfoConstantType entry in "
             . "runtime_enabled_features.json5\n";
' third_party/blink/renderer/platform/runtime_enabled_features.json5

# The feature itself, beside the time zone one added above. perl rather than
# sed_i, and with the same already-ran guard as everything else here: sed_i
# only notices a substitution that changed nothing, and an "append after this
# line" whose anchor survives its own insertion changes something every time it
# runs. The guard is what makes a second pass fail instead of duplicating.
perl -0777 -pi -e '
    BEGIN { $p = do { local $/; open my $f, "<", $ENV{AERIUM_AUDIO_PARTS} or die
            "[aerium] FATAL: cannot read the audio parts file\n"; <$f> };
            @P = split /^===AERIUM-SPLIT===\n/m, $p; }
    die "[aerium] FATAL: features.cc already declares kAeriumAudioNoise; a "
      . "second pass would duplicate it\n"
        if m!kAeriumAudioNoise!;
    s!(kAeriumTimeZoneIdParam\{&kAeriumTimeZone, kAeriumTimeZoneId, "random"\};\n)!$1 . $P[7]!e
        or die "[aerium] FATAL: no kAeriumTimeZoneIdParam definition in "
             . "features.cc to declare the audio feature after\n";
' third_party/blink/common/features.cc
perl -0777 -pi -e '
    BEGIN { $p = do { local $/; open my $f, "<", $ENV{AERIUM_AUDIO_PARTS} or die
            "[aerium] FATAL: cannot read the audio parts file\n"; <$f> };
            @P = split /^===AERIUM-SPLIT===\n/m, $p; }
    die "[aerium] FATAL: features.h already declares kAeriumAudioNoise; a "
      . "second pass would duplicate it\n"
        if m!kAeriumAudioNoise!;
    s!(BLINK_COMMON_EXPORT extern const base::FeatureParam<std::string> kAeriumTimeZoneIdParam;\n)!$1 . $P[8]!e
        or die "[aerium] FATAL: no kAeriumTimeZoneIdParam declaration in "
             . "features.h to declare the audio feature after\n";
' third_party/blink/public/common/features.h

rm -f "$AERIUM_AUDIO_PARTS"
unset AERIUM_AUDIO_PARTS

echo "[aerium] audio fingerprint noise applied"

# --- Take the font list away from window.queryLocalFonts().
#
# The desktop repos do this as aerium-local-font-access.patch. Here it changes
# no behaviour - upstream already ships the API off on Android, which is the
# whole point being made on the desktop side - and it is applied anyway so that
# the two builds carry the same file and the same chrome://flags entry, and so
# that a future upstream flip to "stable" on Android does not silently turn it
# on here.
#
# The API returns every font installed on the device in one call. It is the
# strongest font signal there is and the only one that does not have to be
# measured a family at a time. Firefox and Safari do not implement it.
#
# An empty status gives the generated blink::features::kFontAccess a disabled
# default, and the json5 schema's copied_from_base_feature_if defaults to
# "enabled_or_overridden", so the chrome://flags entry can turn the Blink
# feature back on. That is the mechanism, not decoration.
#
# It has to be written as {"default": ""} and not as a bare "". json5_generator
# validates the two forms down different branches of _is_valid(): a string is
# matched against valid_values, which is ["stable", "experimental", "test"] and
# does not include the empty string, while a dict is checked per entry with an
# explicit `or val == ""` that permits it. A bare "" therefore fails generation
# with `Unknown value: ''` before anything is compiled. That is what broke run
# 142 - the first build to carry this block - and it would have broken every
# build after it, because it is deterministic. Upstream's own value for this
# entry, {"Android": "", "default": "stable"}, is a dict for the same reason.
#
# Not done here or on desktop: Cromite's Fonts-fingerprinting-mitigation.patch,
# which addresses the other half - the measurement channel, where a page
# renders text in a candidate family and compares widths. Its allowlist has no
# Linux section, its Windows half reads private Skia internals, and its Android
# counterpart is 3300 lines. That wants its own pass with an allowlist built
# for the platforms this project ships, not a partial port that renders text
# wrong.
AERIUM_FONT_PART=$(mktemp)
export AERIUM_FONT_PART
cat > "$AERIUM_FONT_PART" <<'AERIUM_FONT_PART_EOF'
      // Aerium: off, which is what Android already gets. This is
      // window.queryLocalFonts() - the Local Font Access API - and it hands a
      // page the complete list of fonts installed on the machine in one call,
      // which is the strongest font signal there is and the only one that does
      // not have to be measured a family at a time. Firefox and Safari do not
      // implement it and upstream does not ship it on Android, so the desktop
      // builds were the outlier among both their peers and their own siblings.
      // Turn it back on at chrome://flags/#aerium-local-font-access; the entry
      // exists because design tools are a real use for it.
      name: "FontAccess",
      status: {"default": ""},
AERIUM_FONT_PART_EOF
perl -0777 -pi -e '
    BEGIN { $ins = do { local $/; open my $f, "<", $ENV{AERIUM_FONT_PART} or die
            "[aerium] FATAL: cannot read the font part file\n"; <$f> }; }
    die "[aerium] FATAL: runtime_enabled_features.json5 already carries the "
      . "Aerium FontAccess change; a second pass would duplicate it\n"
        if m!aerium-local-font-access!;
    s!      name: "FontAccess",\n      status: \{"Android": "", "default": "stable"\},\n!$ins!
        or die "[aerium] FATAL: the FontAccess entry in "
             . "runtime_enabled_features.json5 no longer reads as an "
             . "Android-off, desktop-stable feature - re-read it before "
             . "changing it\n";
' third_party/blink/renderer/platform/runtime_enabled_features.json5
rm -f "$AERIUM_FONT_PART"
unset AERIUM_FONT_PART

echo "[aerium] local font access disabled"
