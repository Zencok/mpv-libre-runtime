import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { builderCommit, depsImageRef } from "./windows-deps-image.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const lock = JSON.parse(fs.readFileSync(path.join(root, "versions.lock.json"), "utf8"));
const createSourceBundle = process.argv.includes("--source-bundle");
const buildDepsImageOnly = process.argv.includes("--deps-image");
const forceFull = process.argv.includes("--full")
    || process.env.MPV_LIBRE_WINDOWS_FULL === "1";
const artifactDirectory = path.join(root, "artifacts");
const artifactName = "mpv-libre-runtime-win32-x64.7z";
const sourceArtifactName = "mpv-libre-runtime-sources.tar.xz";
const toolsImage = process.env.MPV_LIBRE_TOOLS_IMAGE ?? "mpv-libre-runtime-build:alpine3.22";
const buildVolume = process.env.MPV_LIBRE_BUILD_VOLUME
    ?? "mpv-libre-runtime-windows-x64-build";
const ccacheVolume = process.env.MPV_LIBRE_CCACHE_VOLUME
    ?? path.join(root, ".cache", "windows-ccache");
const makeJobs = process.env.MAKEJOBS
    ?? String(Math.max(2, Math.min(16, os.availableParallelism())));

function run(command, args, options = {}) {
    const result = spawnSync(command, args, {
        cwd: root,
        stdio: "inherit",
        windowsHide: true,
        ...options,
    });
    if (result.error) {
        throw result.error;
    }
    if (result.status !== 0) {
        throw new Error(`${command} exited with code ${result.status}`);
    }
    return result;
}

function runCapture(command, args) {
    const result = spawnSync(command, args, {
        cwd: root,
        encoding: "utf8",
        windowsHide: true,
    });
    return {
        status: result.status ?? 1,
        stdout: result.stdout ?? "",
        stderr: result.stderr ?? "",
    };
}

function source(name) {
    const value = lock.sources[name];
    if (!value || !/^[a-f0-9]{40}$/.test(value.commit)) {
        throw new Error(`Invalid ${name} source lock`);
    }
    return value;
}

function digest(filePath) {
    return crypto.createHash("sha256")
        .update(fs.readFileSync(filePath))
        .digest("hex");
}

function recordDigest(filePath) {
    const hash = digest(filePath);
    fs.writeFileSync(`${filePath}.sha256`, `${hash}  ${path.basename(filePath)}\n`, "utf8");
    console.log(`SHA-256 ${hash}  ${path.basename(filePath)}`);
}

function ensureDir(dir) {
    fs.mkdirSync(dir, { recursive: true });
}

function dockerBuildTools() {
    console.log(`==> docker build tools image ${toolsImage}`);
    run("docker", [
        "build",
        "--tag",
        toolsImage,
        "--file",
        path.join(root, "build", "windows-x64", "Dockerfile"),
        path.join(root, "build", "windows-x64"),
    ]);
}

function dockerPull(image) {
    console.log(`==> docker pull ${image}`);
    const result = runCapture("docker", ["pull", image]);
    if (result.status === 0) {
        console.log(`pulled ${image}`);
        return true;
    }
    console.warn(`pull failed for ${image} (will fall back if needed)`);
    if (result.stderr) {
        console.warn(result.stderr.trim());
    }
    return false;
}

function dockerImageExistsLocally(image) {
    const result = runCapture("docker", ["image", "inspect", image]);
    return result.status === 0;
}

function ensureToolsImage() {
    if (dockerImageExistsLocally(toolsImage)) {
        return;
    }
    dockerBuildTools();
}

function commonBuildEnv(builder, mpv, librempeg, runtimeVersion) {
    return [
        "--env", `MAKEJOBS=${makeJobs}`,
        "--env", `CREATE_SOURCE_BUNDLE=${createSourceBundle ? "1" : "0"}`,
        "--env", `BUILDER_REPOSITORY=${builder.repository}`,
        "--env", `BUILDER_COMMIT=${builder.commit}`,
        "--env", `MPV_REPOSITORY=${mpv.repository}`,
        "--env", `MPV_COMMIT=${mpv.commit}`,
        "--env", `LIBREMPEG_REPOSITORY=${librempeg.repository}`,
        "--env", `LIBREMPEG_COMMIT=${librempeg.commit}`,
        "--env", `RUNTIME_VERSION=${runtimeVersion}`,
        "--env", "CCACHE_DIR=/ccache",
    ];
}

function mountCcacheArgs() {
    ensureDir(ccacheVolume);
    const volumePath = ccacheVolume.replaceAll("\\", "/");
    return ["--volume", `${volumePath}:/ccache`];
}

function buildDepsImage(image) {
    const builder = source("builder");
    // Dockerfile.deps is self-contained (tools stage + deps); no separate tools build.
    console.log(`==> docker build deps image ${image}`);
    run("docker", [
        "build",
        "--tag",
        image,
        "--file",
        path.join(root, "build", "windows-x64", "Dockerfile.deps"),
        "--build-arg", `BUILDER_REPOSITORY=${builder.repository}`,
        "--build-arg", `BUILDER_COMMIT=${builder.commit}`,
        "--build-arg", `MAKEJOBS=${makeJobs}`,
        // Dummy pins — deps mode never fetches these.
        "--build-arg", "MPV_COMMIT=0000000000000000000000000000000000000001",
        "--build-arg", "LIBREMPEG_COMMIT=0000000000000000000000000000000000000001",
        path.join(root, "build", "windows-x64"),
    ]);
    console.log(`==> deps image ready: ${image}`);
}

function buildRuntimeWithImage(image, builder, mpv, librempeg, runtimeVersion) {
    const dockerRoot = root.replaceAll("\\", "/");
    console.log(`==> runtime build using deps image ${image}`);
    run("docker", [
        "run",
        "--rm",
        "--volume", `${dockerRoot}:/workspace`,
        ...mountCcacheArgs(),
        ...commonBuildEnv(builder, mpv, librempeg, runtimeVersion),
        "--env", "BUILD_MODE=runtime",
        image,
        "sh",
        "/workspace/build/windows-x64/build.sh",
    ]);
}

function buildFull(builder, mpv, librempeg, runtimeVersion) {
    const dockerRoot = root.replaceAll("\\", "/");
    dockerBuildTools();
    console.log("==> full Windows build (llvm + deps + librempeg + mpv)");
    run("docker", [
        "run",
        "--rm",
        "--volume", `${dockerRoot}:/workspace`,
        "--volume", `${buildVolume.replaceAll("\\", "/")}:/build`,
        ...mountCcacheArgs(),
        ...commonBuildEnv(builder, mpv, librempeg, runtimeVersion),
        "--env", "BUILD_MODE=full",
        toolsImage,
        "sh",
        "/workspace/build/windows-x64/build.sh",
    ]);
}

/** Verify 7z without requiring a separate tools image after deps-image path. */
function verifyArchive(archiveRelative, dockerImageForSevenZip) {
    const dockerRoot = root.replaceAll("\\", "/");
    if (dockerImageExistsLocally(dockerImageForSevenZip)) {
        run("docker", [
            "run",
            "--rm",
            "--volume", `${dockerRoot}:/workspace:ro`,
            dockerImageForSevenZip,
            "7z",
            "t",
            `/workspace/${archiveRelative}`,
        ]);
        return;
    }
    // Host fallbacks
    for (const cmd of ["7z", "7za", "7zz"]) {
        const probe = runCapture(cmd, ["t", path.join(root, archiveRelative)]);
        if (probe.status === 0) {
            console.log(`verified archive with host ${cmd}`);
            return;
        }
    }
    ensureToolsImage();
    run("docker", [
        "run",
        "--rm",
        "--volume", `${dockerRoot}:/workspace:ro`,
        toolsImage,
        "7z",
        "t",
        `/workspace/${archiveRelative}`,
    ]);
}

const builder = source("builder");
const mpv = source("mpv");
const librempeg = source("librempeg");
const runtimeVersion = `mpv-${mpv.commit.slice(0, 10)}.librempeg-${librempeg.commit.slice(0, 10)}`;
const resolvedDepsImage = depsImageRef();

ensureDir(artifactDirectory);
ensureDir(ccacheVolume);

if (buildDepsImageOnly) {
    buildDepsImage(resolvedDepsImage);
    process.exit(0);
}

console.log(`builder ${builderCommit()}`);
console.log(`deps image ${resolvedDepsImage}`);
console.log(`ccache volume ${ccacheVolume}`);

let usedDepsImage = false;
let sevenZipImage = toolsImage;
if (!forceFull) {
    const available = dockerImageExistsLocally(resolvedDepsImage)
        || dockerPull(resolvedDepsImage);
    if (available) {
        buildRuntimeWithImage(resolvedDepsImage, builder, mpv, librempeg, runtimeVersion);
        usedDepsImage = true;
        // Deps image is based on tools and includes 7z — prefer it for verify.
        sevenZipImage = resolvedDepsImage;
    }
}

if (!usedDepsImage) {
    console.warn("==> deps image unavailable; using BUILD_MODE=full (slow path)");
    buildFull(builder, mpv, librempeg, runtimeVersion);
    sevenZipImage = toolsImage;
}

const artifactPath = path.join(artifactDirectory, artifactName);
if (!fs.existsSync(artifactPath) || fs.statSync(artifactPath).size < 1_000_000) {
    throw new Error(`Runtime artifact is missing: ${artifactPath}`);
}
verifyArchive(`artifacts/${artifactName}`, sevenZipImage);
recordDigest(artifactPath);

if (createSourceBundle) {
    const sourceArtifactPath = path.join(artifactDirectory, sourceArtifactName);
    if (!fs.existsSync(sourceArtifactPath) || fs.statSync(sourceArtifactPath).size < 1_000_000) {
        throw new Error(`Source artifact is missing: ${sourceArtifactPath}`);
    }
    recordDigest(sourceArtifactPath);
}

console.log(`Windows build finished (depsImage=${usedDepsImage})`);
