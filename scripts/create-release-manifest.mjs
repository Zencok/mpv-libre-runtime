import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const artifactsDirectory = path.join(root, "artifacts");
const lock = JSON.parse(fs.readFileSync(path.join(root, "versions.lock.json"), "utf8"));
const release = process.argv[2] ?? process.env.RELEASE_TAG;
const repository = process.env.GITHUB_REPOSITORY ?? "Zencok/mpv-libre-runtime";

// unix | complete | auto
// - unix: require every non-win32 target; win32 optional
// - complete: require every target in versions.lock.json
// - auto: publish whatever is present (at least one runtime target)
const phase = (process.env.RELEASE_PHASE
    ?? process.argv.find((arg) => arg.startsWith("--phase="))?.slice("--phase=".length)
    ?? "complete").toLowerCase();

if (!release) {
    throw new Error("Release tag is required");
}
if (!["unix", "complete", "auto"].includes(phase)) {
    throw new Error(`Unsupported RELEASE_PHASE=${phase}`);
}

function listArtifactFiles() {
    if (!fs.existsSync(artifactsDirectory)) {
        return [];
    }
    return fs.readdirSync(artifactsDirectory).sort();
}

function describeArtifact(name, extra = {}) {
    const filePath = path.join(artifactsDirectory, name);
    if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
        return null;
    }
    const sha256 = crypto.createHash("sha256")
        .update(fs.readFileSync(filePath))
        .digest("hex");
    return {
        url: `https://github.com/${repository}/releases/download/${release}/${name}`,
        sha256,
        size: fs.statSync(filePath).size,
        ...extra,
    };
}

function isUnixTarget(target) {
    return target.startsWith("linux-") || target.startsWith("darwin-");
}

function isWindowsTarget(target) {
    return target.startsWith("win32-");
}

const available = listArtifactFiles();
const artifacts = {};
const present = [];
const missingRequired = [];
const missingOptional = [];

for (const [target, descriptor] of Object.entries(lock.targets)) {
    if (!descriptor.artifact) {
        continue;
    }
    const library = isWindowsTarget(target)
        ? "libmpv-2.dll"
        : target.startsWith("darwin-")
            ? "lib/libmpv.2.dylib"
            : "lib/libmpv.so.2";
    const executableSuffix = isWindowsTarget(target) ? ".exe" : "";
    const artifact = describeArtifact(descriptor.artifact, {
        status: descriptor.status,
        files: [library, `ffmpeg${executableSuffix}`, `ffprobe${executableSuffix}`, "runtime.json"],
    });

    const required = phase === "complete"
        || (phase === "unix" && isUnixTarget(target));

    if (!artifact) {
        if (required) {
            missingRequired.push(`${target}: ${descriptor.artifact}`);
        } else {
            missingOptional.push(`${target}: ${descriptor.artifact}`);
        }
        continue;
    }
    artifacts[target] = artifact;
    present.push(target);
}

if (missingRequired.length > 0) {
    throw new Error(
        `Missing required release artifacts (phase=${phase}):\n- ${missingRequired.join("\n- ")}\n` +
        `Available in artifacts/: ${available.length ? available.join(", ") : "(empty)"}`,
    );
}
if (present.length === 0) {
    throw new Error(
        `No runtime artifacts found for phase=${phase}. ` +
        `Available: ${available.length ? available.join(", ") : "(empty)"}`,
    );
}

const sourceArtifact = describeArtifact("mpv-libre-runtime-sources.tar.xz");
if (sourceArtifact) {
    artifacts.source = sourceArtifact;
} else if (phase === "complete") {
    console.warn("Warning: mpv-libre-runtime-sources.tar.xz was not found; continuing without source bundle");
}

const complete = Object.keys(lock.targets).every((target) => Boolean(artifacts[target]));
const manifest = {
    schemaVersion: 1,
    release,
    phase,
    complete,
    engine: "libmpv",
    mediaBackend: "librempeg",
    license: "AGPL-3.0-or-later",
    sources: Object.fromEntries(Object.entries(lock.sources).map(([name, value]) => [
        name,
        {
            repository: value.repository,
            commit: value.commit,
        },
    ])),
    artifacts,
};
const manifestPath = path.join(artifactsDirectory, "runtime-manifest-v1.json");
fs.mkdirSync(artifactsDirectory, { recursive: true });
const serialized = `${JSON.stringify(manifest, null, 2)}\n`;
fs.writeFileSync(manifestPath, serialized, "utf8");
const digest = crypto.createHash("sha256").update(serialized).digest("hex");
fs.writeFileSync(
    `${manifestPath}.sha256`,
    `${digest}  ${path.basename(manifestPath)}\n`,
    "utf8",
);

const notesPath = path.join(artifactsDirectory, "RELEASE_NOTES.md");
const targetList = present.sort().map((t) => `- \`${t}\`: \`${lock.targets[t].artifact}\``).join("\n");
let notes;
if (complete) {
    notes = [
        "Verified libmpv + LibreMPEG runtime for **all** platforms.",
        "",
        "See `runtime-manifest-v1.json` and `NOTICE.md` before redistribution.",
        "",
        "### Targets",
        targetList,
        sourceArtifact ? "\nCorresponding source bundle is attached." : "",
    ].filter(Boolean).join("\n");
} else {
    notes = [
        "Verified libmpv + LibreMPEG **Unix** runtimes are published.",
        "",
        "`win32-x64` (and the Windows source bundle) will be attached to **this same tag** when the Windows job finishes.",
        "",
        "See `runtime-manifest-v1.json` and `NOTICE.md` before redistribution.",
        "",
        "### Targets in this upload",
        targetList,
        missingOptional.length
            ? `\n### Pending\n${missingOptional.map((line) => `- ${line}`).join("\n")}`
            : "",
    ].filter(Boolean).join("\n");
}
fs.writeFileSync(notesPath, `${notes}\n`, "utf8");

console.log(`Created ${manifestPath}`);
console.log(`phase=${phase} complete=${complete}`);
console.log(`Targets: ${present.sort().join(", ")}`);
if (missingOptional.length) {
    console.log(`Pending: ${missingOptional.join("; ")}`);
}
console.log(`Notes: ${notesPath}`);
