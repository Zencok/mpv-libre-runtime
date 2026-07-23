import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function readJson(relativePath) {
    return JSON.parse(fs.readFileSync(path.join(root, relativePath), "utf8"));
}

function assert(condition, message) {
    if (!condition) {
        throw new Error(message);
    }
}

function collectFiles() {
    const result = execFileSync("git", ["ls-files", "-z"], { cwd: root, encoding: "utf8" });
    return result.split("\0").filter(Boolean).map((relativePath) => path.join(root, relativePath));
}

const lock = readJson("versions.lock.json");
assert(lock.schemaVersion === 1, "Unsupported versions.lock.json schema");
for (const [name, source] of Object.entries(lock.sources)) {
    assert(/^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\.git$/.test(source.repository),
        `${name} repository must be an HTTPS GitHub URL`);
    assert(/^[a-f0-9]{40}$/.test(source.commit), `${name} must use a full commit SHA`);
}
for (const target of ["win32-x64", "darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64"]) {
    assert(lock.targets[target]?.status === "verified", `${target} must be verified`);
    assert(lock.targets[target]?.artifact, `${target} must declare an artifact`);
}
assert(fs.existsSync(path.join(root, "build", "unix", "build.sh")),
    "Unix build entry is missing");

readJson("schemas/runtime-manifest-v1.schema.json");
readJson("package.json");

const fixture = readJson("fixtures/ac4-smoke.json");
assert(
    /^https:\/\/samples\.ffmpeg\.org\/.+/.test(fixture.url)
        && /^[a-f0-9]{64}$/.test(fixture.sha256),
    "AC-4 fixture descriptor is invalid",
);

const sourceFiles = collectFiles();
const applicationNamePattern = new RegExp(["Baka", "Music"].join(""), "i");
const legacyEnginePattern = new RegExp(["lib", "vlc"].join(""), "i");
for (const filePath of sourceFiles) {
    const value = fs.readFileSync(filePath, "utf8");
    assert(!applicationNamePattern.test(value), `Application-specific name found in ${filePath}`);
    assert(!legacyEnginePattern.test(value), `Legacy engine reference found in ${filePath}`);
}

const libreBuild = fs.readFileSync(
    path.join(root, "build", "windows-x64", "packages", "librempeg.cmake"),
    "utf8",
);
assert(libreBuild.includes("$ENV{LIBREMPEG_COMMIT}"), "LibreMPEG commit is not injected");
assert(!libreBuild.includes("--enable-nonfree"), "Nonfree features must not be enabled");
assert(libreBuild.includes("--enable-agpl"), "FFmpeg CLI requires the declared AGPL profile");

const mpvBuild = fs.readFileSync(
    path.join(root, "build", "windows-x64", "packages", "mpv.cmake"),
    "utf8",
);
assert(mpvBuild.includes("-Dlibmpv=true"), "libmpv build is not enabled");
assert(mpvBuild.includes("-Dcplayer=false"), "mpv CLI must be disabled");

const unixBuild = fs.readFileSync(path.join(root, "build", "unix", "build.sh"), "utf8");
assert(unixBuild.includes("--enable-gpl"), "Unix LibreMPEG build must enable GPL");
assert(unixBuild.includes("-Dlibmpv=true"), "Unix libmpv build is not enabled");
assert(unixBuild.includes("-Dcplayer=false"), "Unix mpv CLI must be disabled");
assert(!unixBuild.includes("--enable-nonfree"), "Unix build must not enable nonfree features");
assert(unixBuild.includes("--enable-agpl"), "Unix FFmpeg CLI requires the declared AGPL profile");
assert(unixBuild.includes("-Dswift-build=enabled"), "macOS build must enable Swift");
assert(unixBuild.includes("-Dcocoa=enabled"), "macOS build must enable Cocoa");
assert(unixBuild.includes("-Dmacos-cocoa-cb=enabled"), "macOS build must enable cocoa-cb");
assert(unixBuild.includes("-Dvulkan=enabled"), "macOS build must enable Vulkan/MetalLayer");
assert(unixBuild.includes("-Dprefer_static=false"), "Linux must prefer shared system libraries");
assert(
    unixBuild.includes("CXX_LIB") && unixBuild.includes("c_link_args"),
    "libmpv must link the platform C++ runtime",
);
assert(unixBuild.includes("rewrite_system_static_archives"), "Linux must rewrite non-PIC static archives");
assert(unixBuild.includes("copy_darwin_runtime_dependencies"), "macOS dependency packaging missing");
assert(unixBuild.includes("ensure_linux_cxx_runtime"), "Linux must package libstdc++/libgcc_s");
assert(unixBuild.includes("smoke_dlopen_libmpv"), "Build-time libmpv smoke test missing");

const verifyUnix = fs.readFileSync(path.join(root, "scripts", "verify-unix-runtime.sh"), "utf8");
assert(verifyUnix.includes("libstdc++.so.6"), "Unix verify must require packaged libstdc++");
assert(verifyUnix.includes("mpv_create"), "Unix verify must exercise libmpv client API");
assert(verifyUnix.includes("ac4"), "Unix verify must check AC-4");

const releaseWorkflow = fs.readFileSync(
    path.join(root, ".github", "workflows", "release.yml"),
    "utf8",
);
assert(releaseWorkflow.includes("release-unix:"), "release must publish Unix first");
assert(releaseWorkflow.includes("release-windows:"), "release must attach Windows later");
assert(releaseWorkflow.includes("cancel-in-progress: false"),
    "staged release must not cancel in-flight Unix publishes");
assert(
    /release-windows:[\s\S]*?needs:\s*\[contract,\s*verify-windows-x64\]/.test(releaseWorkflow),
    "release-windows must not require unix success",
);
assert(releaseWorkflow.includes("--notes-file"), "release notes must use --notes-file");
for (const jobName of ["release-unix", "release-windows"]) {
    const jobBody = releaseWorkflow.split(new RegExp(`^\\s{2}${jobName}:\\s*$`, "m"))[1] ?? "";
    const checkoutAt = jobBody.indexOf("actions/checkout@v4");
    const downloadAt = jobBody.indexOf("actions/download-artifact@v4");
    assert(
        checkoutAt >= 0 && downloadAt >= 0 && checkoutAt < downloadAt,
        `${jobName} must checkout before download-artifact`,
    );
}

const depsWorkflow = fs.readFileSync(
    path.join(root, ".github", "workflows", "windows-mingw-deps.yml"),
    "utf8",
);
assert(!/^\s+push:\s*$/m.test(depsWorkflow),
    "windows-mingw-deps must not push-trigger (avoids double-build races)");
assert(depsWorkflow.includes("workflow_call:"), "windows-mingw-deps must support workflow_call");

const manifestScript = fs.readFileSync(
    path.join(root, "scripts", "create-release-manifest.mjs"),
    "utf8",
);
assert(manifestScript.includes("RELEASE_PHASE"), "manifest must support staged RELEASE_PHASE");
assert(fs.existsSync(path.join(root, "scripts", "select-release-tag.mjs")),
    "select-release-tag.mjs is missing");

assert(
    fs.existsSync(path.join(root, "build", "windows-x64", "Dockerfile.deps")),
    "Windows deps image Dockerfile is missing",
);
assert(
    fs.existsSync(path.join(root, "scripts", "windows-deps-image.mjs")),
    "Windows deps image helper is missing",
);
assert(
    fs.existsSync(path.join(root, ".github", "workflows", "windows-mingw-deps.yml")),
    "Windows deps workflow is missing",
);
assert(
    fs.existsSync(path.join(root, ".github", "workflows", "windows-runtime.yml")),
    "Windows runtime workflow is missing",
);

const windowsBuild = fs.readFileSync(path.join(root, "build", "windows-x64", "build.sh"), "utf8");
assert(windowsBuild.includes("BUILD_MODE"), "Windows build.sh must support BUILD_MODE");
assert(windowsBuild.includes("CCACHE_DIR"), "Windows build.sh must configure ccache");
assert(windowsBuild.includes("build_deps"), "Windows build.sh must build deps targets");
assert(windowsBuild.includes("load_deps_targets"),
    "Windows build.sh must parse DEPENDS from package cmake files");
assert(windowsBuild.includes("slim_deps_tree"),
    "Windows deps mode must slim the image payload");
assert(windowsBuild.includes(".builder-commit"),
    "deps image must pin builder commit for runtime without .git");
assert(windowsBuild.includes("vendored mingw-cmake-env"),
    "runtime must accept vendored builder tree without re-cloning");
assert(windowsBuild.includes("Always reconfigure"),
    "runtime must reconfigure so ExternalProject picks real MPV/LIBREMPEG pins");

const windowsOrchestrator = fs.readFileSync(
    path.join(root, "scripts", "build-windows-x64.mjs"),
    "utf8",
);
assert(windowsOrchestrator.includes("depsImageRef"), "Windows orchestrator must resolve deps image");
assert(windowsOrchestrator.includes("BUILD_MODE=runtime"), "Windows orchestrator must use runtime mode");
assert(windowsOrchestrator.includes("windows-ccache"), "Windows orchestrator must mount ccache volume");
assert(windowsOrchestrator.includes("verifyArchive"), "Windows orchestrator must verify archives safely");

const schema = readJson("schemas/runtime-manifest-v1.schema.json");
assert(schema.properties?.phase, "manifest schema must declare phase");
assert(schema.properties?.complete, "manifest schema must declare complete");

console.log("Repository contract checks passed.");
