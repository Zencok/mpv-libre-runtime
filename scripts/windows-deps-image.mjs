/**
 * Resolve GHCR tag / image name for the Windows MinGW deps image (Plan B).
 */
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function readLock() {
    return JSON.parse(fs.readFileSync(path.join(root, "versions.lock.json"), "utf8"));
}

function hashFiles(relativePaths) {
    const hash = crypto.createHash("sha256");
    for (const relativePath of relativePaths) {
        const absolute = path.join(root, relativePath);
        hash.update(relativePath);
        hash.update("\0");
        hash.update(fs.readFileSync(absolute));
        hash.update("\0");
    }
    return hash.digest("hex");
}

/** Files that affect which deps are built / how they are compiled. */
export const DEPS_PROFILE_FILES = [
    // Dockerfile.deps is self-contained (includes tools stage); tag on its content.
    "build/windows-x64/Dockerfile.deps",
    "build/windows-x64/build.sh",
    "build/windows-x64/packages/librempeg.cmake",
    "build/windows-x64/packages/mpv.cmake",
];

export function depsProfileHash() {
    return hashFiles(DEPS_PROFILE_FILES).slice(0, 16);
}

export function builderCommit() {
    const lock = readLock();
    const commit = lock.sources?.builder?.commit;
    if (!commit || !/^[a-f0-9]{40}$/.test(commit)) {
        throw new Error("versions.lock.json builder.commit must be a full SHA");
    }
    return commit;
}

export function defaultOwner() {
    if (process.env.GITHUB_REPOSITORY_OWNER) {
        return process.env.GITHUB_REPOSITORY_OWNER.toLowerCase();
    }
    if (process.env.GITHUB_REPOSITORY) {
        return process.env.GITHUB_REPOSITORY.split("/")[0].toLowerCase();
    }
    return "zencok";
}

/**
 * Example: ghcr.io/zencok/mpv-libre-mingw-deps:b26fd7edea2a-a1b2c3d4e5f67890
 */
export function depsImageRef(options = {}) {
    if (process.env.MPV_LIBRE_DEPS_IMAGE) {
        return process.env.MPV_LIBRE_DEPS_IMAGE;
    }
    const owner = (options.owner ?? defaultOwner()).toLowerCase();
    const registry = options.registry ?? "ghcr.io";
    const name = options.name ?? "mpv-libre-mingw-deps";
    const builder = builderCommit().slice(0, 12);
    const profile = depsProfileHash();
    return `${registry}/${owner}/${name}:${builder}-${profile}`;
}

const isMain = process.argv[1]
    && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
    console.log(depsImageRef());
}
