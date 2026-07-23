import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const descriptor = JSON.parse(fs.readFileSync(
    path.join(root, "fixtures", "ac4-smoke.json"),
    "utf8",
));
const outputDirectory = path.join(root, "tmp", "fixtures");
const outputPath = path.join(outputDirectory, descriptor.fileName);

function digest(value) {
    return crypto.createHash("sha256").update(value).digest("hex");
}

if (fs.existsSync(outputPath)) {
    const existing = fs.readFileSync(outputPath);
    if (digest(existing) === descriptor.sha256) {
        console.log(outputPath);
        process.exit(0);
    }
}

const response = await fetch(descriptor.url, {
    headers: {
        "user-agent": "mpv-libre-runtime verification",
    },
});
if (!response.ok) {
    throw new Error(`Fixture download failed: ${response.status}`);
}
const value = Buffer.from(await response.arrayBuffer());
const actualDigest = digest(value);
if (actualDigest !== descriptor.sha256) {
    throw new Error(`Fixture SHA-256 mismatch: ${actualDigest}`);
}
fs.mkdirSync(outputDirectory, { recursive: true });
fs.writeFileSync(outputPath, value);
console.log(outputPath);

