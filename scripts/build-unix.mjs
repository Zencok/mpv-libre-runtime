import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const lock = JSON.parse(fs.readFileSync(path.join(root, "versions.lock.json"), "utf8"));
const target = process.argv[2] ?? process.env.RUNTIME_TARGET;
const supported = new Set(["darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64"]);

if (!supported.has(target)) {
    throw new Error(`Expected a Unix target, received: ${target ?? "<empty>"}`);
}
if (!lock.targets[target]?.artifact) {
    throw new Error(`Target is missing from versions.lock.json: ${target}`);
}

function source(name) {
    const value = lock.sources[name];
    if (!value || !/^[a-f0-9]{40}$/.test(value.commit)) {
        throw new Error(`Invalid ${name} source lock`);
    }
    return value;
}

const mpv = source("mpv");
const librempeg = source("librempeg");
const libplacebo = source("libplacebo");
const result = spawnSync("bash", [path.join(root, "build", "unix", "build.sh")], {
    cwd: root,
    stdio: "inherit",
    env: {
        ...process.env,
        MAKEJOBS: process.env.MAKEJOBS ?? String(Math.max(2, Math.min(8, os.availableParallelism()))),
        RUNTIME_TARGET: target,
        RUNTIME_ARTIFACT: lock.targets[target].artifact,
        MPV_REPOSITORY: mpv.repository,
        MPV_COMMIT: mpv.commit,
        LIBREMPEG_REPOSITORY: librempeg.repository,
        LIBREMPEG_COMMIT: librempeg.commit,
        LIBPLACEBO_REPOSITORY: libplacebo.repository,
        LIBPLACEBO_COMMIT: libplacebo.commit,
    },
});
if (result.error) {
    throw result.error;
}
if (result.status !== 0) {
    throw new Error(`Unix build exited with code ${result.status}`);
}

const artifact = path.join(root, "artifacts", lock.targets[target].artifact);
if (!fs.existsSync(artifact) || fs.statSync(artifact).size < 1_000_000) {
    throw new Error(`Runtime artifact is missing: ${artifact}`);
}
const hash = crypto.createHash("sha256").update(fs.readFileSync(artifact)).digest("hex");
fs.writeFileSync(`${artifact}.sha256`, `${hash}  ${path.basename(artifact)}\n`, "utf8");
console.log(`SHA-256 ${hash}  ${path.basename(artifact)}`);
