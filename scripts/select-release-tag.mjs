/**
 * Print the immutable release tag for the current commit + locked pins.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const lock = JSON.parse(fs.readFileSync(path.join(root, "versions.lock.json"), "utf8"));
const sha = process.env.GITHUB_SHA
    ?? process.argv[2]
    ?? "";

if (!/^[a-f0-9]{7,40}$/i.test(sha)) {
    throw new Error("GITHUB_SHA or a commit argument is required");
}

const mpv = lock.sources.mpv.commit.slice(0, 10);
const librempeg = lock.sources.librempeg.commit.slice(0, 10);
const revision = sha.slice(0, 10);
const tag = `runtime-mpv-${mpv}-librempeg-${librempeg}-${revision}`;
console.log(tag);
