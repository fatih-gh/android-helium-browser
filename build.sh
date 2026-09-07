#!/bin/bash
# Aerium for Android — staged/resumable build.
#
# Usage:
#   ./build.sh          one-shot build (needs a beefy machine)
#   ./build.sh --ci     time-boxed CI stage: builds for at most
#                       $BUILD_TIMEOUT_MIN minutes, then stops gracefully so
#                       the next stage can resume from the build tree.
#
# On success writes release/aerium-<version>-<abi>.apk and release/finished.marker
set -e
source common.sh

MODE_CI=0
[ "$1" = "--ci" ] && MODE_CI=1

# Time budget for this stage, expressed as "job timeout minus what the
# checkpoint round-trip needs", and measured from when the STAGE started - not
# from when this script started.
#
# The distinction matters: restoring the saved tree happens in the workflow
# before build.sh is even invoked, and the checkpoint is currently ~20 GB
# compressed, so download+unpack can easily eat 30-45 min. Budgeting 250 min
# from build.sh's own start therefore allowed restore + 250 + pack + upload to
# exceed the 350-min job timeout, at which point GitHub kills the runner
# mid-step: the job shows a step stuck "in_progress", the log upload never
# happens (HTTP 404 when you go looking for it), and the stage's progress is
# lost. That is the failure signature on runs 42/43/45.
#
# The stage action exports STAGE_START_TS before the restore step, so the
# elapsed calculation below covers restore too and self-corrects as the
# checkpoint grows.
JOB_TIMEOUT_MIN=${JOB_TIMEOUT_MIN:-350}
# Measured over a 15-stage run: pack averages 5.7 min and upload 2.2 min,
# so ~8 min of the reserve is actually used. At 80 every stage stopped
# compiling at ~279 of its 350 minutes and threw away ~71 min (20%) of the
# budget. 25 kept a wide margin over the observed 8 while returning most
# of that time to the compile window.
#
# Nudged 25 -> 30 because the reserve now also has to cover the graceful
# shutdown window below: the build backend is given time to finish writing
# its incremental state before anything force-kills it, and that write is
# the whole point of the stage. Overrunning the 350-min job timeout is
# catastrophic (the runner is killed mid-step, so pack and upload never
# happen and the ENTIRE stage is lost), whereas 5 extra minutes of reserve
# costs 1.4% of the compile window.
CHECKPOINT_RESERVE_MIN=${CHECKPOINT_RESERVE_MIN:-30}
TOTAL_BUDGET_MIN=${TOTAL_BUDGET_MIN:-$((JOB_TIMEOUT_MIN - CHECKPOINT_RESERVE_MIN))}
START_TS=${STAGE_START_TS:-$(date +%s)}

export VERSION=$(grep -m1 -o '[0-9]\+\(\.[0-9]\+\)\{3\}' vanadium/args.gn)

# --- target architecture ------------------------------------------------------
# arm64 unless the workflow says otherwise. Everything that varies with the
# architecture is derived here, in one place, so a second workflow only has to
# set AERIUM_TARGET_CPU and nothing downstream needs a second opinion:
#
#   target_cpu    what args.gn is rewritten to say
#   ABI           what Android calls the same thing, and what goes in the APK
#                 filename - it is the name people match against their device,
#                 not the GN spelling
#
# x86 (32-bit) is deliberately absent. Android dropped it for new devices years
# ago and the only things left running it are old emulator images; adding a
# third build to the queue for those is not a trade worth making.
export AERIUM_TARGET_CPU="${AERIUM_TARGET_CPU:-arm64}"
case "$AERIUM_TARGET_CPU" in
    arm64) export AERIUM_ABI=arm64-v8a ;;
    x64)   export AERIUM_ABI=x86_64 ;;
    *)
        echo "[aerium] FATAL: AERIUM_TARGET_CPU=$AERIUM_TARGET_CPU is not one of arm64, x64" >&2
        exit 1
        ;;
esac
echo "[aerium] target cpu: $AERIUM_TARGET_CPU  abi: $AERIUM_ABI"
export CHROMIUM_SOURCE=https://chromium.googlesource.com/chromium/src.git
export DEBIAN_FRONTEND=noninteractive
echo "[aerium] chromium version: $VERSION  ci: $MODE_CI"

# --- stage diagnostics --------------------------------------------------------
# The CI job log can only be read from its tail (~400 KB, i.e. the last couple
# of minutes of a five-hour job), so anything printed near the START of a stage
# is unreadable in practice. Everything worth knowing is therefore appended to
# this file as it happens and dumped by a step at the very END of the job.
# The stage action seeds the same path before the build starts.
STAGE_DIAG="${STAGE_DIAG:-$SCRIPT_DIR/stage-diag.txt}"
# Full build output, kept so the end-of-job dump can show its FIRST lines -
# that is where the backend says whether it loaded the restored incremental
# state. Deliberately named without "siso" in it: the straggler kill below
# matches processes on that string and must not shoot this file's writer.
BUILD_LOG="${BUILD_LOG:-$SCRIPT_DIR/chromium/build_stdout.log}"

# Keep the big tool caches on the large build mount (chromium/) instead of the
# small root filesystem: vpython venvs alone are multiple GB and overflow the
# CI runner's root disk otherwise. Not part of the stage artifact; they are
# recreated cheaply on each stage.
mkdir -p chromium/.vpython-root chromium/.cipd-cache chromium/.tmp
export VPYTHON_VIRTUALENV_ROOT="$SCRIPT_DIR/chromium/.vpython-root"
export CIPD_CACHE_DIR="$SCRIPT_DIR/chromium/.cipd-cache"
export TMPDIR="$SCRIPT_DIR/chromium/.tmp"

# --- system dependencies: needed on every (fresh) CI runner -----------------
sudo apt-get update
sudo apt-get install -y sudo lsb-release file nano git curl python3 python3-pillow imagemagick librsvg2-bin zstd
# Every stage runs on a fresh runner, so this install repeats each time and
# each time it leaves the downloaded .debs and package lists on the ROOT
# filesystem - which maximize-build-space has already shrunk to a ~10 GB
# reserve, minus the 6 GB swap file carved out of it. Root filling up kills the
# runner agent itself, which is why the dead stages have no log at all. Clean
# up immediately instead of only at the end of first-stage setup.
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

# depot_tools must live on the big build mount, not next to the checkout: it
# plus its bootstrapped python3/cipd payload is well over a GB, and
# $SCRIPT_DIR is on the root filesystem. It is deliberately outside
# chromium/src so the checkpoint tar never picks it up; each stage re-clones
# it, which is cheap.
DEPOT_TOOLS_DIR="$SCRIPT_DIR/chromium/depot_tools"
if [ ! -d "$DEPOT_TOOLS_DIR" ]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git \
        "$DEPOT_TOOLS_DIR"
fi
export PATH="$DEPOT_TOOLS_DIR:$PATH"

# depot_tools normally self-bootstraps (fetches its pinned python3/cipd
# tooling) the first time gclient/gn runs. On resumed stages the entire
# fresh-setup block below - the only place that calls gclient/gn - is
# skipped, so a freshly cloned depot_tools here never gets bootstrapped and
# autoninja fails with "python3_bin_reldir.txt not found". Run the
# dedicated bootstrap-only script unconditionally so every stage has a
# working depot_tools regardless of whether source setup runs.
"$DEPOT_TOOLS_DIR/ensure_bootstrap"

# --- source setup: only on the first stage ----------------------------------
if [ ! -f chromium/src/BUILD.gn ]; then
    # git am needs a committer identity on fresh CI runners
    git config --global user.name  >/dev/null 2>&1 || git config --global user.name 'github-actions[bot]'
    git config --global user.email >/dev/null 2>&1 || git config --global user.email 'github-actions[bot]@users.noreply.github.com'
    mkdir -p chromium/src/out/Default
    cd chromium
    gclient root
    cd src
    git init
    git remote add origin $CHROMIUM_SOURCE
    git fetch --depth 1 $CHROMIUM_SOURCE +refs/tags/$VERSION:chromium_$VERSION
    git checkout $VERSION
    export COMMIT=$(git show-ref -s $VERSION | head -n1)
    cat > ../.gclient <<EOF
solutions = [
  {
    "name": "src",
    "url": "$CHROMIUM_SOURCE@$COMMIT",
    "deps_file": "DEPS",
    "managed": False,
    "custom_vars": {
      "checkout_android_prebuilts_build_tools": True,
      # chrome_pgo_phase=2 (args.gn) consumes real profile data - it needs
      # this checked out, or gn gen fails outright looking for a .profdata
      # file that was never downloaded.
      "checkout_pgo_profiles": True,
      "checkout_telemetry_dependencies": False,
      "codesearch": "Debug",
    },
  },
]
target_os = ["android"]
EOF
    git submodule foreach git config -f ./.git/config submodule.$name.ignore all
    git config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'

    # https://grapheneos.org/build#browser-and-webview
    rm -rf $SCRIPT_DIR/vanadium/patches/*trichrome-{apk-build-targets,browser-apk-targets}.patch
    rm -rf $SCRIPT_DIR/vanadium/patches/*{detailed,supported}-language*.patch
    rm -rf $SCRIPT_DIR/vanadium/patches/*component-updates.patch
    rm -rf $SCRIPT_DIR/vanadium/patches/*{pdf,PDF,for-content-public}*.patch
    replace "$SCRIPT_DIR/vanadium/patches" "VANADIUM" "AERIUM"
    replace "$SCRIPT_DIR/vanadium/patches" "Vanadium" "Aerium"
    replace "$SCRIPT_DIR/vanadium/patches" "vanadium" "aerium"
    git am --whitespace=nowarn --keep-non-patch $SCRIPT_DIR/vanadium/patches/*.patch

    gclient sync -D --no-history --nohooks
    gclient runhooks
    rm -rf third_party/angle/third_party/VK-GL-CTS/

    ./build/install-build-deps.sh --no-prompt
    sudo apt-get clean
    sudo rm -rf /var/lib/apt/lists/*

    source $SCRIPT_DIR/patch.sh
    source $SCRIPT_DIR/theme.sh

    # Some Vanadium patches modify .grd string files without updating the
    # checked-in .gritdeps snapshots (e.g. 0272 touches
    # components_strings.grd), which fails the *_check_gritdeps build
    # targets. Regenerate every snapshot with the official command.
    find . -name '*.grd.gritdeps' -not -path './out/*' | while read -r deps; do
        grd="${deps%.gritdeps}"
        [ -f "$grd" ] || continue
        if python3 tools/grit/grit_info.py --all-inputs "$grd" > "$deps.new" 2>/dev/null; then
            if ! cmp -s "$deps" "$deps.new"; then
                echo "[aerium] regenerated $deps"
            fi
            mv "$deps.new" "$deps"
        else
            echo "[aerium] warning: could not regenerate $deps; keeping original"
            rm -f "$deps.new"
        fi
    done

    cp $SCRIPT_DIR/args.gn out/Default/args.gn
    # The checked-in args.gn names arm64. Rewritten rather than kept in two
    # files so that every other argument - and there are thirty of them - stays
    # in one place and cannot drift between architectures.
    sed -i "s|^target_cpu = .*|target_cpu = \"$AERIUM_TARGET_CPU\"|" out/Default/args.gn
    grep -q "^target_cpu = \"$AERIUM_TARGET_CPU\"$" out/Default/args.gn || {
        echo "[aerium] FATAL: target_cpu was not set in out/Default/args.gn" >&2
        exit 1
    }
    gn gen out/Default

    # Nothing past this point runs git against chromium/src (no later stage
    # calls gclient/git - only ninja), so its history is dead weight. This
    # is a modest, low-risk reclaim; it does not touch out/Default or any
    # third_party checkout the build actually depends on.
    rm -rf .git

    cd $SCRIPT_DIR
fi

cd chromium/src

# --- Resume hotfix (removable once a build that STARTED after 2026-07-20
# goes green): theme.sh only runs during source setup, so a tree saved by an
# earlier stage never re-runs it. Trees saved before the unsafe-buffers
# pragma landed in theme.sh fail compiling static_bitmap_image.cc under
# -Werror,-Wunsafe-buffer-usage; patch them in place on resume. Idempotent:
# no-ops on fresh trees (theme.sh already added the pragma) and on already
# patched resumed trees.
SBI=third_party/blink/renderer/platform/graphics/static_bitmap_image.cc
if [ -f "$SBI" ] && grep -q ShuffleSubchannelColorData "$SBI" && ! grep -q allow_unsafe_buffers "$SBI"; then
    sed -i '/^#include "third_party\/blink\/renderer\/platform\/graphics\/static_bitmap_image.h"$/i\
#ifdef UNSAFE_BUFFERS_BUILD\
// The Bromite canvas shuffler below does raw per-pixel pointer arithmetic.\
#pragma allow_unsafe_buffers\
#endif\
' "$SBI"
    echo "[aerium] resume hotfix: allow_unsafe_buffers pragma applied to $SBI"
fi

# --- Resume hotfix (removable once a build that STARTED after 2026-09-03 goes
# green): 152 removed the default argument from base::JSONReader::Read, which
# now requires the options word explicitly. The two calls in
# aerium_site_rules.h passed only the string, so the first translation unit to
# include that header - chrome_browsing_data_lifetime_manager.cc - failed under
# -Werror in run 119 stage 4, 88k targets deep. theme.sh carries the fix, but
# theme.sh only runs during source setup, so a tree checkpointed before it does
# not have it. Idempotent: the pattern is gone after the first application, and
# a fresh tree written by the current theme.sh never matches it.
ASR=chrome/browser/browsing_data/aerium_site_rules.h
if [ -f "$ASR" ] && grep -q 'JSONReader::Read(raw);' "$ASR"; then
    sed -i 's|base::JSONReader::Read(raw);|base::JSONReader::Read(raw, base::JSON_PARSE_RFC);|g' "$ASR"
    echo "[aerium] resume hotfix: JSON_PARSE_RFC added to $ASR"
fi

# --- Resume hotfix (removable alongside the one above): the restored-flag entry
# for android-surface-control named ::gpu::features::kAndroidSurfaceControl.
# gpu_finch_features.h opens `namespace gpu` only to forward-declare
# GpuFeatureInfo; the feature itself is in the global `features` namespace, so
# the qualified name did not resolve and about_flags.cc failed under -Werror in
# run 120. Same reasoning as the JSONReader hotfix: theme.sh has the corrected
# spelling but does not run on a resumed tree. Idempotent both ways.
ABF=chrome/browser/about_flags.cc
if [ -f "$ABF" ] && grep -q '::gpu::features::kAndroidSurfaceControl' "$ABF"; then
    sed -i 's|::gpu::features::kAndroidSurfaceControl|::features::kAndroidSurfaceControl|g' "$ABF"
    echo "[aerium] resume hotfix: kAndroidSurfaceControl requalified in $ABF"
fi

# --- Resume sync for the first-run page: theme.sh only runs during source
# setup, so a tree saved by an earlier stage keeps whatever version of the
# page it was built with. Re-emit the header from theme.sh whenever the tree's
# copy differs, which keeps a resumed tree matching a freshly synced one.
#
# This started as a fix for one bug: the page's data source declared three
# virtual methods with non-empty bodies inside the class body. The
# chromium-style plugin rejects that ("virtual methods with non-empty bodies
# shouldn't be declared inline") and it stopped build-1 of runs 32633921251
# and 32716211686 on chrome_web_ui_configs.o, the only translation unit that
# includes this header. theme.sh now writes those definitions below the class,
# which is what the plugin asks for - it gates the diagnostic on
# CXXMethodDecl::hasInlineBody(), false once the definition is out-of-line.
#
# Comparing against theme.sh rather than grepping for that one bug means
# ordinary edits to the page - wording, links - also reach a resumed tree, so
# a text change costs one translation unit instead of a full re-sync. Copying
# from theme.sh rather than editing in place keeps exactly one copy of the
# page. On a fresh tree the two are identical and nothing happens.
AFR=chrome/browser/ui/webui/aerium_first_run.h
if [ -f "$AFR" ]; then
    AFR_FRESH=$(mktemp)
    awk '/^cat > chrome\/browser\/ui\/webui\/aerium_first_run.h <<.AERIUM_FIRST_RUN_H.$/{f=1;next} /^AERIUM_FIRST_RUN_H$/{f=0} f' \
        "$SCRIPT_DIR/theme.sh" > "$AFR_FRESH"
    if ! grep -q '^inline std::string AeriumFirstRunDataSource::GetSource' "$AFR_FRESH"; then
        echo "[aerium] FATAL: could not extract the first-run page from theme.sh." >&2
        echo "[aerium] The heredoc markers in theme.sh must have moved." >&2
        rm -f "$AFR_FRESH"
        exit 1
    fi
    if cmp -s "$AFR_FRESH" "$AFR"; then
        echo "[aerium] first-run page in the tree already matches theme.sh"
    else
        cp "$AFR_FRESH" "$AFR"
        echo "[aerium] resume sync: refreshed $AFR from theme.sh"
    fi
    rm -f "$AFR_FRESH"
fi

# --- chrome://aerium, the same way. The page header comes from theme.sh, so a
# resumed tree gets the same treatment as the first-run page above.
APH=chrome/browser/ui/webui/aerium_patches.h
if [ -f "$APH" ]; then
    APH_FRESH=$(mktemp)
    awk '/^cat > chrome\/browser\/ui\/webui\/aerium_patches.h <<.AERIUM_PATCHES_H.$/{f=1;next} /^AERIUM_PATCHES_H$/{f=0} f' \
        "$SCRIPT_DIR/theme.sh" > "$APH_FRESH"
    if ! grep -q '^inline std::string AeriumPatchesDataSource::GetSource' "$APH_FRESH"; then
        echo "[aerium] FATAL: could not extract the patches page from theme.sh." >&2
        echo "[aerium] The heredoc markers in theme.sh must have moved." >&2
        rm -f "$APH_FRESH"
        exit 1
    fi
    if ! cmp -s "$APH_FRESH" "$APH"; then
        cp "$APH_FRESH" "$APH"
        echo "[aerium] resume sync: refreshed $APH from theme.sh"
    fi
    rm -f "$APH_FRESH"
fi

# --- The update checker, the same way, and for the same plugin. Run 121 stopped
# on chrome_browser_main_extra_parts_profiles.o, the only translation unit that
# includes this header:
#
#   aerium_update_checker.h:138:3: error: [chromium-style] Complex constructor
#   has an inlined body.
#   aerium_update_checker.h:143:3: error: [chromium-style] Complex destructor
#   has an inline body.
#
# AeriumUpdateChecker holds a unique_ptr, a OneShotTimer and a WeakPtrFactory,
# which is what makes it "complex" to the plugin; Shutdown() was already out of
# line for the neighbouring rule and the constructor and destructor now are too.
# The desktop repos never saw this because they build against a stock LLVM with
# clang_use_chrome_plugins off, so the plugin does not run there at all.
#
# Re-emitted rather than sed-patched for the reason given above: any later edit
# to this header reaches a resumed tree too.
AUC=chrome/browser/aerium/aerium_update_checker.h
if [ -f "$AUC" ]; then
    AUC_FRESH=$(mktemp)
    awk '/^cat > chrome\/browser\/aerium\/aerium_update_checker.h <<.AERIUM_UPDATE_CHECKER_H.$/{f=1;next} /^AERIUM_UPDATE_CHECKER_H$/{f=0} f' \
        "$SCRIPT_DIR/theme.sh" > "$AUC_FRESH"
    if ! grep -q '^inline AeriumUpdateChecker::~AeriumUpdateChecker() = default;' "$AUC_FRESH"; then
        echo "[aerium] FATAL: could not extract the update checker from theme.sh." >&2
        echo "[aerium] The heredoc markers in theme.sh must have moved." >&2
        rm -f "$AUC_FRESH"
        exit 1
    fi
    if cmp -s "$AUC_FRESH" "$AUC"; then
        echo "[aerium] update checker in the tree already matches theme.sh"
    else
        cp "$AUC_FRESH" "$AUC"
        echo "[aerium] resume sync: refreshed $AUC from theme.sh"
    fi
    rm -f "$AUC_FRESH"
fi

# The manifest that page includes. Regenerated on every stage rather than only
# during source setup: it is derived entirely from files in this repository -
# the Vanadium patch series and the two build scripts - so it costs a second
# and is always in step with what the tree was patched with. A resumed stage
# that skipped this would ship a table describing a previous commit.
#
# Guarded on the page existing, the same way the sync above is: a tree
# checkpointed before this landed has neither the page nor the registration in
# chrome_web_ui_configs.cc, and generating a manifest for a page that is not
# there would achieve nothing. Where the page IS there the generator runs under
# set -e with no `|| true`, because a manifest that failed to regenerate would
# leave the previous commit's table in place - which is the one thing this page
# must not do.
if [ -f "$APH" ]; then
    "$SCRIPT_DIR/devutils/generate_patch_manifest.py" \
        --version "$VERSION" \
        --build-number "${GITHUB_RUN_NUMBER:-}" \
        --out chrome/browser/ui/webui/aerium_patch_manifest.inc
fi

# compile prerequisites must exist on every fresh runner
./build/install-build-deps.sh --no-prompt || true
# ...and its .debs must not be left sitting on the small root filesystem.
sudo apt-get clean || true
sudo rm -rf /var/lib/apt/lists/* || true
df -h / "$SCRIPT_DIR/chromium" || true

# --- build (time-boxed in CI mode) -------------------------------------------
if [ $MODE_CI = 1 ]; then
    ELAPSED_MIN=$(( ($(date +%s) - START_TS) / 60 ))
    REMAINING_MIN=$(( TOTAL_BUDGET_MIN - ELAPSED_MIN ))
    if [ $REMAINING_MIN -lt 15 ]; then
        echo "[aerium] no time left for compiling this stage; resuming next stage"
        exit 0
    fi
    echo "[aerium] compiling for at most $REMAINING_MIN minutes"
    # -j 2: the free runners have 4 vCPUs but only 16 GB RAM; even -j 3 got
    # the compiler OOM-killed (exit 137) on heavy TU clusters. Two jobs peak
    # at ~14 GB worst case, which fits without relying on swap.
    #
    # NOTE on the timeout invocation: do NOT pass --foreground here. Per GNU
    # coreutils docs, --foreground means "children of command will not be
    # timed out" - i.e. the SIGINT would only reach the `autoninja` wrapper,
    # not ninja's actual compiler subprocesses, which could then keep
    # compiling (and writing object files) for the full -k grace period
    # regardless of the intended cutoff. Every previous timed-out stage
    # failed with exit 137 at almost exactly the REMAINING_MIN mark - the
    # signature of the -k grace period's SIGKILL, not a graceful stop.
    # Without --foreground, timeout puts autoninja/ninja in their own
    # process group and signals the whole group, so SIGINT reaches the
    # in-flight compiler jobs directly. -k is a backstop for any single
    # translation unit that's slow to unwind; it was 10m, which together
    # with the graceful wait below could push the stage past its 350-min
    # job timeout, and 5m is already far more than an interrupted compile
    # needs.
    # The `|| true` is not decoration: this runs under `set -e`, and a
    # pipeline's status is tee's, so an unwritable diagnostics file would
    # otherwise abort the stage before it compiled anything.
    { set +e
      echo "=== [$(date -u '+%H:%M:%SZ')] PRE-BUILD incremental state ==="
      ls -la out/Default/.siso_fs_state out/Default/.siso_fs_state.journal 2>&1
    } 2>&1 | tee -a "$STAGE_DIAG" || true

    # If the log is not creatable, send it to /dev/null rather than leaving
    # tee to die on its first write: tee holds the read end of autoninja's
    # stdout pipe, so a dead tee means SIGPIPE straight into the compiler.
    : > "$BUILD_LOG" 2>/dev/null || BUILD_LOG=/dev/null
    set +e
    # Output goes through a process substitution rather than a plain `|
    # tee` on purpose: a pipe would make the shell block until every
    # process holding the write end has exited, which is unbounded if the
    # backend hangs. With >(...) the exit status below is still timeout's
    # own and the wait stays bounded by the loop that follows.
    timeout -s INT -k 5m ${REMAINING_MIN}m \
        autoninja -j "${NINJA_JOBS:-2}" -C out/Default chrome_public_apk \
        > >(tee -a "$BUILD_LOG") 2>&1
    RET=$?
    set -e

    # Let the build backend finish its own shutdown before force-killing
    # anything.
    #
    # `timeout` returns as soon as its DIRECT child exits - verified: with a
    # child that dies on SIGINT while a grandchild lives on, timeout returns
    # 124 immediately and the grandchild keeps running. Here the direct child
    # is the autoninja wrapper and the grandchild is siso, so the old
    # `pkill -9 -f siso` on the very next line could be landing while siso is
    # still unwinding.
    #
    # That matters because the tail end of that unwind is where siso writes
    # out/Default/.siso_fs_state - the record of which command produced which
    # output, and therefore the ONLY thing that lets the next stage skip work
    # it has already done. The object files themselves carry no such marker,
    # which is why every stage has been rewriting the same ~28,300 objects
    # byte-identically. Whether the SIGKILL really was landing mid-write is
    # what the end-of-job diagnostics settle: a checkpoint carrying a large
    # .siso_fs_state and no journal means siso now shuts down cleanly.
    #
    # Bounded at 4 minutes: writing the state takes seconds, and the stage
    # still has to pack and upload ~20 GB inside the job timeout.
    #
    # Matched on the process NAME, not on `pgrep -f siso`: -f tests the whole
    # command line, which also matches any shell whose arguments merely
    # mention siso, and a false positive here burns the full four minutes of
    # a stage's budget waiting for a process that was never the build.
    siso_alive() {
        pgrep -x siso >/dev/null 2>&1 || pgrep -f '(^|/)siso ninja' >/dev/null 2>&1
    }
    for _ in $(seq 1 120); do
        siso_alive || break
        sleep 2
    done
    # Anything still alive after that is a straggler that would keep writing
    # to the tree while the stage action packs it into the resume artifact.
    pkill -9 -f 'siso' 2>/dev/null || true
    sleep 3

    { set +e
      echo "=== [$(date -u '+%H:%M:%SZ')] POST-BUILD incremental state (autoninja rc=$RET) ==="
      ls -la out/Default/.siso_fs_state out/Default/.siso_fs_state.journal 2>&1
      echo "--- every siso/ninja entry in out/Default ---"
      ls -la out/Default 2>/dev/null | grep -i 'siso\|ninja'
    } 2>&1 | tee -a "$STAGE_DIAG" || true
    if [ $RET = 124 ]; then
        echo "[aerium] time budget reached; build will resume on the next stage"
        exit 0
    elif [ $RET != 0 ]; then
        echo "[aerium] build failed with exit code $RET"
        # siso (the build backend modern Chromium/Vanadium uses in place of
        # plain ninja) does not echo a failing command's own output to
        # stdout - it only prints "see ./out/Default/siso_output for full
        # command line and output" and leaves it at that. Without this dump,
        # every CI failure was a black box that could only be diagnosed by
        # downloading the multi-GB resume artifact and looking inside it.
        if [ -f out/Default/siso_output ]; then
            echo "[aerium] --- tail of out/Default/siso_output (last 200 lines) ---"
            tail -n 200 out/Default/siso_output || true
            echo "[aerium] --- end of siso_output tail ---"
        fi
        exit $RET
    fi
else
    autoninja -j "${NINJA_JOBS:-2}" -C out/Default chrome_public_apk
fi

# --- sign & finish ------------------------------------------------------------
export PATH=$PWD/third_party/jdk/current/bin/:$PATH
export ANDROID_HOME=$PWD/third_party/android_sdk/public

mkdir -p $SCRIPT_DIR/release
set_keys
sign_apk "$(find out/Default/apks -name 'Chrome*.apk' | head -n1)" "$SCRIPT_DIR/release/aerium-$VERSION-$AERIUM_ABI.apk"
rm -rf $SCRIPT_DIR/keys
echo "$VERSION" > $SCRIPT_DIR/release/version.txt
touch $SCRIPT_DIR/release/finished.marker
echo "[aerium] build finished: release/aerium-$VERSION-$AERIUM_ABI.apk"
