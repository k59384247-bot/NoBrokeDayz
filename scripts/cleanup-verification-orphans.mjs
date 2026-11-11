import { spawnSync } from "node:child_process";
import { createClient } from "@supabase/supabase-js";
import { resolve } from "node:path";
import { localSupabaseEnv } from "./local-supabase-env.mjs";

const root = resolve(import.meta.dirname, "..");
const cli = resolve(root, "node_modules/.bin/supabase");
const env = localSupabaseEnv();

function localStatus() {
  const result = spawnSync(cli, ["status", "--output-format", "json"], {
    cwd: root,
    env,
    encoding: "utf8",
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.error || result.status !== 0)
    throw new Error("local Supabase status is unavailable");
  const status = JSON.parse(result.stdout);
  const apiUrl = new URL(status.env?.API_URL);
  if (
    status.runtime !== "native" ||
    !["127.0.0.1", "localhost"].includes(apiUrl.hostname) ||
    apiUrl.port !== "54321" ||
    !status.env?.SERVICE_ROLE_KEY
  ) {
    throw new Error(
      "orphan cleanup requires this repository's local native stack",
    );
  }
  return status;
}

async function listObjects(client, prefix = "") {
  const objects = [];
  const folders = [];
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await client.storage
      .from("verification-quarantine")
      .list(prefix, {
        limit: 1000,
        offset,
        sortBy: { column: "name", order: "asc" },
      });
    if (error || !data) throw new Error("local quarantine listing failed");
    for (const item of data) {
      const path = prefix ? `${prefix}/${item.name}` : item.name;
      if (item.id == null && item.metadata == null) folders.push(path);
      else objects.push(path);
    }
    if (data.length < 1000) break;
  }
  for (const folder of folders)
    objects.push(...(await listObjects(client, folder)));
  return objects;
}

try {
  if (Number(process.versions.node.split(".")[0]) < 22)
    throw new Error("use the pinned Node 22 runtime");
  const status = localStatus();
  const admin = createClient(status.env.API_URL, status.env.SERVICE_ROLE_KEY, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
  const candidates = await listObjects(admin);
  const cutoff = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  let removed = 0;
  for (let offset = 0; offset < candidates.length; offset += 1000) {
    const { data, error } = await admin.rpc(
      "server_list_verification_orphans_for_cleanup",
      {
        p_candidate_keys: candidates.slice(offset, offset + 1000),
        p_before: cutoff,
      },
    );
    if (error || !Array.isArray(data))
      throw new Error("local orphan eligibility check failed");
    for (let batch = 0; batch < data.length; batch += 100) {
      const { error: removeError } = await admin.storage
        .from("verification-quarantine")
        .remove(data.slice(batch, batch + 100));
      if (removeError)
        throw new Error("local quarantine orphan removal failed");
      removed += data.slice(batch, batch + 100).length;
    }
  }
  console.log(
    `PASS removed ${removed} unreferenced quarantine objects older than 24 hours; finalized evidence was excluded`,
  );
} catch (error) {
  console.error(
    `FAIL verification orphan cleanup: ${error instanceof Error ? error.message : "local cleanup failed"}`,
  );
  process.exitCode = 1;
}
