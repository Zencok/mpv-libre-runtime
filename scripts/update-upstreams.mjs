import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const lockPath = path.join(root, "versions.lock.json");
const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
const token = process.env.GITHUB_TOKEN;
const dryRun = process.argv.includes("--dry-run");
const changes = [];

function repositorySlug(repository) {
    const url = new URL(repository);
    return url.pathname.replace(/^\//, "").replace(/\.git$/, "");
}

async function latestCommit(repository) {
    const slug = repositorySlug(repository);
    const response = await fetch(`https://api.github.com/repos/${slug}/commits?per_page=1`, {
        headers: {
            accept: "application/vnd.github+json",
            "user-agent": "mpv-libre-runtime-updater",
            ...(token ? { authorization: `Bearer ${token}` } : {}),
        },
    });
    if (!response.ok) {
        throw new Error(`GitHub API failed for ${slug}: ${response.status}`);
    }
    const commits = await response.json();
    const commit = commits[0]?.sha;
    if (!/^[a-f0-9]{40}$/.test(commit)) {
        throw new Error(`GitHub returned an invalid commit for ${slug}`);
    }
    return commit;
}

for (const [name, source] of Object.entries(lock.sources)) {
    if (!source.autoUpdate) {
        continue;
    }
    const commit = await latestCommit(source.repository);
    if (commit !== source.commit) {
        changes.push({ name, from: source.commit, to: commit });
        source.commit = commit;
    }
}

if (changes.length && !dryRun) {
    fs.writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`, "utf8");
}
const summary = changes.length
    ? changes.map((change) => `${change.name}: ${change.from.slice(0, 10)} -> ${change.to.slice(0, 10)}`).join("\n")
    : "No upstream changes.";
console.log(summary);

if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `changed=${changes.length ? "true" : "false"}\n`);
    fs.appendFileSync(
        process.env.GITHUB_OUTPUT,
        `summary=${changes.map((change) => `${change.name}-${change.to.slice(0, 10)}`).join("_")}\n`,
    );
}
