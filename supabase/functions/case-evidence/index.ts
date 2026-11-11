import { createCaseEvidenceHandler } from "../_shared/case-evidence.mjs";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const uploadSigningKey = Deno.env.get("NBD_CASE_UPLOAD_TOKEN_KEY");
if (!supabaseUrl || !anonKey || !serviceRoleKey || !uploadSigningKey)
  throw new Error("case evidence server configuration missing");

const baseUrl = new URL(supabaseUrl).origin;
const serverHeaders = {
  apikey: serviceRoleKey,
  authorization: `Bearer ${serviceRoleKey}`,
};

function storagePath(bucket: string, key: string) {
  return `${baseUrl}/storage/v1/object/${bucket}/${key.split("/").map(encodeURIComponent).join("/")}`;
}

async function storageRequest(path: string, init: RequestInit) {
  const response = await fetch(path, {
    ...init,
    headers: { ...serverHeaders, ...init.headers },
  });
  if (!response.ok) throw new Error("private storage operation failed");
  return response;
}

Deno.serve(
  createCaseEvidenceHandler({
    verifyActor: async (token: string) => {
      const response = await fetch(`${baseUrl}/auth/v1/user`, {
        headers: { apikey: anonKey, authorization: `Bearer ${token}` },
      });
      if (!response.ok) return null;
      const user = await response.json();
      return { id: user.id };
    },
    rpc: async (name: string, args: Record<string, unknown>) => {
      const response = await fetch(`${baseUrl}/rest/v1/rpc/${name}`, {
        method: "POST",
        headers: { ...serverHeaders, "content-type": "application/json" },
        body: JSON.stringify(args),
      });
      const result = await response.json().catch(() => null);
      if (!response.ok) {
        const error = new Error("case evidence command failed") as Error & {
          code?: string;
        };
        error.code = result?.message;
        throw error;
      }
      return result;
    },
    storeUpload: async (
      bucket: string,
      key: string,
      bytes: Uint8Array,
      options: { contentType: string; cacheControl: string; upsert: boolean },
    ) => {
      await storageRequest(storagePath(bucket, key), {
        method: "POST",
        headers: {
          "content-type": options.contentType,
          "cache-control": options.cacheControl,
          "x-upsert": String(options.upsert),
        },
        body: bytes,
      });
    },
    readUpload: async (bucket: string, key: string) => {
      const response = await storageRequest(storagePath(bucket, key), {
        method: "GET",
      });
      return new Uint8Array(await response.arrayBuffer());
    },
    removeUpload: async (bucket: string, key: string) => {
      await storageRequest(`${baseUrl}/storage/v1/object/${bucket}`, {
        method: "DELETE",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ prefixes: [key] }),
      });
    },
    uploadSigningKey,
  }),
);
